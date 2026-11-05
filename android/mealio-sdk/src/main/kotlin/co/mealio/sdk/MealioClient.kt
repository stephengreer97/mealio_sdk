package co.mealio.sdk

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

// The partner-facing flow. Port of packages/core/src/client.ts: start a job
// (cart, search or add, each carrying who is calling and the device epoch),
// drive it through step calls until done or fail, and a single retry with a
// fresh session token on 401.

const val SDK_CORE_VERSION = "0.2.0"
const val DEFAULT_BASE_URL = "https://mealio.co"

/** How long a warm-up is offered to the next prepare. The server holds the same line (WARM_TTL_MS). */
const val WARM_FRESH_MS = 4 * 60_000L

/**
 * An error raised to the app. `code` is one of the PROTOCOL.md codes:
 * bad_envelope, blocked, store_unavailable, login_cancelled, session_expired,
 * network, unsupported, store_required. Also "server" (Mealio answered with an error),
 * "unknown_item" / "unknown_product" (CartSession.choose), "bad_recipe" /
 * "too_many_recipes" (prepareCart with no recipes or more than MAX_RECIPES),
 * or any code the server's `fail` instruction carries.
 */
/**
 * What the SDK is doing right now, for a progress screen. Inferred from the
 * server's instruction ids (open-, session-, login-, search-, add-), never from
 * store specifics.
 */
enum class Step(val wire: String) {
    CONNECTING("connecting"),
    CHECKING_SIGN_IN("checking_sign_in"),
    SIGNING_IN("signing_in"),
    SEARCHING("searching"),
    ADDING("adding"),
}

/** Called before each instruction the SDK runs. */
typealias StepListener = (step: Step, instruction: Instruction) -> Unit

fun stepOf(ins: Instruction): Step {
    if (ins is Instruction.ShowLogin) return Step.SIGNING_IN
    val id = ins.id
    return when {
        id.startsWith("search") -> Step.SEARCHING
        id.startsWith("add") -> Step.ADDING
        id.startsWith("session") || id.startsWith("resession") -> Step.CHECKING_SIGN_IN
        else -> Step.CONNECTING
    }
}

class MealioException(val code: String, message: String, cause: Throwable? = null) : Exception(message, cause)

class MealioConfig(
    val publishableKey: String,
    /** From POST /api/v1/sessions on the partner's server. Called again after a 401. */
    val sessionTokenProvider: suspend () -> String,
    val platform: String = "android",
    val sdkVersion: String = MealioCart.SDK_VERSION,
    val baseUrl: String = DEFAULT_BASE_URL,
    /** Play Integrity token, when the partner has turned attestation on. */
    val attestationProvider: (suspend () -> String?)? = null,
    /** The device's store-session epoch (bumped by signOutOfAllStores). */
    val epochProvider: (suspend () -> Int)? = null,
    val keys: Map<String, String> = KEYS,
)

// ── HTTP to Mealio ─────────────────────────────────────────────────────────

data class HttpResponse(val status: Int, val body: String?)

/** How the client reaches Mealio. Swappable for tests. Throw IOException when there is no answer. */
interface HttpTransport {
    suspend fun post(url: String, headers: Map<String, String>, body: String): HttpResponse

    /** A plain GET (the public store list). */
    suspend fun get(url: String, headers: Map<String, String>): HttpResponse =
        throw IOException("This transport does not do GET")
}

/** HttpURLConnection on Dispatchers.IO. Never sends store cookies (it has no cookie handler of ours). */
class UrlConnectionTransport(
    private val connectTimeoutMs: Int = 15_000,
    private val readTimeoutMs: Int = 60_000,
) : HttpTransport {
    override suspend fun post(url: String, headers: Map<String, String>, body: String): HttpResponse =
        withContext(Dispatchers.IO) {
            val c = URL(url).openConnection() as HttpURLConnection
            try {
                c.requestMethod = "POST"
                c.connectTimeout = connectTimeoutMs
                c.readTimeout = readTimeoutMs
                c.useCaches = false
                c.instanceFollowRedirects = false
                for ((k, v) in headers) c.setRequestProperty(k, v)
                val bytes = body.toByteArray(Charsets.UTF_8)
                c.doOutput = true
                c.setFixedLengthStreamingMode(bytes.size)
                c.outputStream.use { it.write(bytes) }
                val status = c.responseCode
                val stream = if (status >= 400) c.errorStream else c.inputStream
                val text = stream?.use { it.readBytes().toString(Charsets.UTF_8) }
                HttpResponse(status, text)
            } finally {
                c.disconnect()
            }
        }

    override suspend fun get(url: String, headers: Map<String, String>): HttpResponse =
        withContext(Dispatchers.IO) {
            val c = URL(url).openConnection() as HttpURLConnection
            try {
                c.requestMethod = "GET"
                c.connectTimeout = connectTimeoutMs
                c.readTimeout = readTimeoutMs
                c.useCaches = false
                c.instanceFollowRedirects = false
                for ((k, v) in headers) c.setRequestProperty(k, v)
                val status = c.responseCode
                val stream = if (status >= 400) c.errorStream else c.inputStream
                val text = stream?.use { it.readBytes().toString(Charsets.UTF_8) }
                HttpResponse(status, text)
            } finally {
                c.disconnect()
            }
        }
}

/** encodeURIComponent: URLEncoder plus the characters JavaScript leaves alone. */
internal fun encodeUriComponent(s: String): String =
    URLEncoder.encode(s, "UTF-8")
        .replace("+", "%20")
        .replace("%21", "!")
        .replace("%27", "'")
        .replace("%28", "(")
        .replace("%29", ")")
        .replace("%7E", "~")

// ── the client ─────────────────────────────────────────────────────────────

class MealioClient @JvmOverloads constructor(
    private val config: MealioConfig,
    host: Host,
    private val transport: HttpTransport = UrlConnectionTransport(),
) {
    private val runner = Runner(host, Allowlist(), config.keys)
    private val base = config.baseUrl.trimEnd('/')

    /** One run at a time: there is one hidden WebView. */
    private val runLock = Mutex()

    @Volatile private var token: String? = null

    /** A finished warm-up the next prepare may start from. */
    private class Warmed(val job: String, val store: String, val at: Long, val pageOpens: Int, val epoch: Int)
    @Volatile private var warmed: Warmed? = null
    @Volatile private var lastWarmAt = 0L

    /** The allowlist in force, including hosts a signed widening added. */
    val allowlist: Allowlist get() = runner.allowlist

    /** Stores the SDK supports right now. Public, no session needed. Throws MealioException "network". */
    suspend fun stores(): List<StoreInfo> {
        val res = try {
            transport.get("$base/api/v1/stores", mapOf("Accept" to "application/json"))
        } catch (e: CancellationException) {
            throw e
        } catch (e: IOException) {
            throw MealioException("network", "Could not reach Mealio", e)
        }
        val json = try {
            res.body?.let { parseJson(it) }
        } catch (e: JSONException) {
            null
        } ?: throw MealioException("network", "Could not reach Mealio")
        return (json as? JSONObject)?.arr("stores")?.objects()?.map { StoreInfo.fromJson(it) } ?: emptyList()
    }

    /**
     * Start a cart: signs in to the store if needed, searches every ingredient.
     * `store` is optional: null uses the user's default store, and the job fails
     * with "store_required" when they have none yet.
     */
    @JvmOverloads
    suspend fun prepareCart(store: String?, recipe: Recipe, zip: String? = null, onStep: StepListener? = null): CartSession =
        prepareCart(store, listOf(recipe), zip, onStep)

    /**
     * Start one cart from several recipes, at most [MAX_RECIPES]. Ingredients
     * they share become one item, each item lists the recipes it is for, and a
     * pick is remembered under every one of them. Throws MealioException
     * "bad_recipe" for an empty list and "too_many_recipes" for more than
     * MAX_RECIPES, before any network call.
     */
    @JvmOverloads
    suspend fun prepareCart(store: String?, recipes: List<Recipe>, zip: String? = null, onStep: StepListener? = null): CartSession {
        if (recipes.isEmpty()) throw MealioException("bad_recipe", "Pass at least one recipe.")
        if (recipes.size > MAX_RECIPES) throw MealioException("too_many_recipes", "At most $MAX_RECIPES recipes in one cart.")
        return runLock.withLock {
            val fields = JSONObject().putNullable("store", store).putNullable("zip", zip)
            // One recipe goes as `recipe`, so a server from before multi-recipe still understands it.
            if (recipes.size == 1) fields.put("recipe", recipes[0].toJson())
            else fields.put("recipes", JSONArray(recipes.map { it.toJson() }))
            val body = about(fields)
            takeWarm(store, body.optInt("epoch"))?.let { body.put("warm", it) }
            val result = drive(post("/api/v1/sdk/carts", body), onStep)
            val o = result as? JSONObject ?: throw MealioException("server", "Mealio returned no cart")
            CartSession(this, PreparedCart.fromJson(o))
        }
    }

    /**
     * Run the login check for the user's store now, before they tap, so the
     * cart that follows can start at search. Mealio picks the store: the
     * user's default, or none, in which case nothing happens (a new user has
     * no store to check yet). Never shows sign-in, never throws, and does
     * nothing if it ran in the last few minutes, or while a cart is running.
     * MealioCartButton calls it when it appears. Mirrors MealioClient.warm()
     * in packages/core.
     */
    @JvmOverloads
    suspend fun warm(store: String? = null) {
        val now = System.currentTimeMillis()
        synchronized(this) {
            if (now - lastWarmAt < WARM_FRESH_MS) return
            lastWarmAt = now
        }
        // Holding runLock is what makes a prepare wait for this: both drive the
        // one hidden page. A run already holding it makes a warm-up pointless.
        if (!runLock.tryLock()) return
        try {
            val body = about(JSONObject().putIfNotNull("store", store))
            val start = post("/api/v1/sdk/warm", body)
            val job = start.opt("job") as? String
            if (job == null) { warmed = null; return }
            val r = drive(start, null) as? JSONObject
            val s = r?.opt("store") as? String
            warmed = if (r?.opt("signedIn") == true && s != null) {
                Warmed(job, s, System.currentTimeMillis(), runner.pageOpens, body.optInt("epoch"))
            } else null
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // A warm-up that fails costs the user nothing: the cart runs as it always has.
            warmed = null
        } finally {
            runLock.unlock()
        }
    }

    /** Forget any warm-up, e.g. after signing out of the stores. */
    fun clearWarm() {
        synchronized(this) {
            warmed = null
            lastWarmAt = 0L
        }
    }

    /** The warm job id, once, if the page it left is still showing and it is still fresh. */
    private fun takeWarm(store: String?, epoch: Int): String? {
        val w = synchronized(this) { warmed.also { warmed = null } } ?: return null
        if (store != null && store != w.store) return null
        if (w.pageOpens != runner.pageOpens || w.epoch != epoch) return null
        if (System.currentTimeMillis() - w.at > WARM_FRESH_MS) return null
        return w.job
    }

    /** Search the store again for one item ("minced garlic jar"). */
    @JvmOverloads
    suspend fun search(cartId: String, key: String, query: String, onStep: StepListener? = null): SearchResult =
        runLock.withLock {
            val body = about(JSONObject().put("key", key).put("query", query))
            val result = drive(post("/api/v1/sdk/carts/${encodeUriComponent(cartId)}/search", body), onStep)
            val o = result as? JSONObject ?: throw MealioException("server", "Mealio returned no search result")
            SearchResult.fromJson(o)
        }

    /** Fill the store cart with the user's choices. */
    @JvmOverloads
    suspend fun addToCart(cartId: String, selections: List<Selection>, onStep: StepListener? = null): AddResult =
        runLock.withLock {
            val body = about(JSONObject().put("selections", JSONArray(selections.map { it.toJson() })))
            val result = drive(post("/api/v1/sdk/carts/${encodeUriComponent(cartId)}/add", body), onStep)
            val o = result as? JSONObject ?: throw MealioException("server", "Mealio returned no add result")
            AddResult.fromJson(o)
        }

    /** There is no hello call any more; every job-starting call says who is calling. */
    @Deprecated("No hello call any more. Nothing to reset.")
    fun resetHello() = Unit

    /** Apply a signed allowlist widening, if the server ever sends one. Unverifiable ones are ignored. */
    fun widenAllowlist(env: Envelope) {
        try {
            AllowlistPayload.fromJson(openEnvelope(env, config.keys))?.let { runner.allowlist.widen(it) }
        } catch (e: EnvelopeException) {
            // An allowlist we cannot verify is ignored; the bundled one stands.
        }
    }

    /** Who is calling and the device epoch, carried on every job-starting call. */
    private suspend fun about(body: JSONObject): JSONObject {
        val epoch = config.epochProvider?.invoke() ?: 0
        val sdk = JSONObject()
            .put("platform", config.platform)
            .put("version", config.sdkVersion)
            .put("core", SDK_CORE_VERSION)
            .put("ops", JSONArray(SUPPORTED_OPS))
        return body.put("sdk", sdk).put("epoch", epoch)
    }

    private suspend fun drive(start: JSONObject, onStep: StepListener?): Any? {
        val job = start.opt("job") as? String
        var env = Envelope.fromJson(start.opt("envelope"))
        var seq = 0
        repeat(200) {
            val out = try {
                runner.run(env, job, seq, onStep?.let { l -> { ins: Instruction -> l(stepOf(ins), ins) } })
            } catch (e: EnvelopeException) {
                throw MealioException(if (e.why == "unsupported_op") "unsupported" else "bad_envelope", e.message ?: e.why, e)
            }
            seq = out.payload.seq
            when (val t = out.terminal) {
                is Terminal.Done -> return t.result
                is Terminal.Fail -> throw MealioException(t.code, t.message)
                null -> Unit
            }
            val next = post("/api/v1/sdk/jobs/${encodeUriComponent(job ?: "")}/step", StepRequest(seq, out.results).toJson())
            env = Envelope.fromJson(next.opt("envelope"))
        }
        throw MealioException("server", "job did not finish")
    }

    private suspend fun post(path: String, body: JSONObject, retried: Boolean = false): JSONObject {
        val tok = token ?: fetchToken().also { token = it }
        val headers = LinkedHashMap<String, String>()
        headers["Content-Type"] = "application/json"
        headers["Authorization"] = "Bearer $tok"
        headers["X-Mealio-Publishable-Key"] = config.publishableKey
        headers["X-Mealio-SDK"] = "${config.platform}/${config.sdkVersion}"
        config.attestationProvider?.let { provider ->
            val a = try {
                provider()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                null
            }
            if (!a.isNullOrEmpty()) headers["X-Mealio-Attestation"] = a
        }

        val res = try {
            transport.post(base + path, headers, body.toString())
        } catch (e: CancellationException) {
            throw e
        } catch (e: IOException) {
            throw MealioException("network", "Could not reach Mealio", e)
        }

        if (res.status == 401 && !retried) {
            token = null
            return post(path, body, true)
        }
        val json = res.body?.let {
            try {
                parseJson(it) as? JSONObject
            } catch (e: JSONException) {
                null
            }
        }
        if (res.status == 401) throw MealioException("session_expired", "The Mealio session expired")
        if (res.status !in 200..299) {
            val err = json?.obj("error")
            throw MealioException(err?.str("code") ?: "server", err?.str("message") ?: "Mealio answered ${res.status}")
        }
        return json ?: JSONObject()
    }

    private suspend fun fetchToken(): String = try {
        config.sessionTokenProvider()
    } catch (e: CancellationException) {
        throw e
    } catch (e: MealioException) {
        throw e
    } catch (e: Exception) {
        throw MealioException("session_expired", "Could not get a Mealio session token: ${e.message}", e)
    }
}
