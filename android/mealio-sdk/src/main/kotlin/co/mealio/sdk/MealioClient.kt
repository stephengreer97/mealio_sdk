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

// The partner-facing flow. Port of packages/core/src/client.ts: hello, start a
// cart, drive the job through step calls until done or fail, and a single
// retry with a fresh session token on 401.

const val SDK_CORE_VERSION = "0.1.0"
const val DEFAULT_BASE_URL = "https://mealio.co"

/**
 * An error raised to the app. `code` is one of the PROTOCOL.md codes:
 * bad_envelope, blocked, store_unavailable, login_cancelled, session_expired,
 * network, unsupported. Also "server" (Mealio answered with an error),
 * "unknown_item" / "unknown_product" (CartSession.choose), or any code the
 * server's `fail` instruction carries.
 */
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

    @Volatile private var helloDone = false
    @Volatile private var token: String? = null

    /** The allowlist in force, including hosts a signed hello widened. */
    val allowlist: Allowlist get() = runner.allowlist

    /** Start a cart: signs in to the store if needed, searches every ingredient. */
    suspend fun prepareCart(store: String, recipe: Recipe, zip: String? = null): CartSession = runLock.withLock {
        hello()
        val body = JSONObject().put("store", store).put("recipe", recipe.toJson()).putNullable("zip", zip)
        val result = drive(post("/api/v1/sdk/carts", body))
        val o = result as? JSONObject ?: throw MealioException("server", "Mealio returned no cart")
        CartSession(this, PreparedCart.fromJson(o))
    }

    /** Fill the store cart with the user's choices. */
    suspend fun addToCart(cartId: String, selections: List<Selection>): AddResult = runLock.withLock {
        hello()
        val body = JSONObject().put("selections", JSONArray(selections.map { it.toJson() }))
        val result = drive(post("/api/v1/sdk/carts/${encodeUriComponent(cartId)}/add", body))
        val o = result as? JSONObject ?: throw MealioException("server", "Mealio returned no add result")
        AddResult.fromJson(o)
    }

    /** Send hello again on the next run (after a sign-out bumps the epoch). */
    fun resetHello() {
        helloDone = false
    }

    internal suspend fun hello() {
        if (helloDone) return
        val epoch = config.epochProvider?.invoke() ?: 0
        val sdk = JSONObject()
            .put("platform", config.platform)
            .put("version", config.sdkVersion)
            .put("core", SDK_CORE_VERSION)
            .put("ops", JSONArray(SUPPORTED_OPS))
        val res = post("/api/v1/sdk/hello", JSONObject().put("sdk", sdk).put("epoch", epoch))
        val env = Envelope.fromJson(res.opt("allowlist"))
        if (env != null) {
            try {
                AllowlistPayload.fromJson(openEnvelope(env, config.keys))?.let { runner.allowlist.widen(it) }
            } catch (e: EnvelopeException) {
                // An allowlist we cannot verify is ignored; the bundled one stands.
            }
        }
        helloDone = true
    }

    private suspend fun drive(start: JSONObject): Any? {
        val job = start.opt("job") as? String
        var env = Envelope.fromJson(start.opt("envelope"))
        var seq = 0
        repeat(200) {
            val out = try {
                runner.run(env, job, seq)
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
            helloDone = false
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
