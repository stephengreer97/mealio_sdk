package co.mealio.sdk

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.isActive
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.atomic.AtomicInteger
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

const val SDK_CORE_VERSION = "0.6.0"
const val DEFAULT_BASE_URL = "https://mealio.co"

/** How long a warm-up is offered to the next prepare. The server holds the same line (WARM_TTL_MS). */
const val WARM_FRESH_MS = 4 * 60_000L

/** Every HTTP request, and your session function, gets this long. */
const val REQUEST_TIMEOUT_MS = 30_000L

/**
 * An error raised to the app. `code` is one of the PROTOCOL.md codes:
 * bad_envelope, blocked, store_unavailable, login_cancelled, session_expired,
 * network, unsupported, store_required, location_required. Also "session_failed"
 * (your sessionTokenProvider threw or took over 30 seconds; its message is kept),
 * "not_signed_in" (setUser(null)), "cancelled" (a CancelToken fired),
 * "server" (Mealio answered with an error or something unreadable),
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

class MealioException @JvmOverloads constructor(
    val code: String,
    message: String,
    cause: Throwable? = null,
    /**
     * Set when `code` is "cancelled": [CancelReason.USER_CHANGED] (prepare
     * again for the new user), [CancelReason.CLOSED] (the sheet closed) or
     * [CancelReason.CANCELLED] (anything else). Null for other codes.
     */
    val reason: String? = null,
) : Exception(message, cause)

/** The "cancelled" error for a job stopped by `cancel` (its reason, else "cancelled"). */
internal fun cancelledError(cancel: CancelToken?): MealioException =
    MealioException("cancelled", "Cancelled", reason = cancel?.reason ?: CancelReason.CANCELLED)

/** A job whose session was reset (resetSession) while its token was on its way. */
internal fun userChangedError(): MealioException =
    MealioException("cancelled", "Cancelled", reason = CancelReason.USER_CHANGED)

/** How long the reset of a page left dirty (see [JobQueue]) may take before the next job starts anyway. */
const val PAGE_RESET_MS = 10_000L

/** How long [MealioClient.runExclusive] may hold the job queue, whatever its work does. */
const val EXCLUSIVE_CAP_MS = 60_000L

/**
 * The job queue: one job at a time on the hidden page. Clients that share a
 * hidden page share one (MealioCart passes the same one to every client it
 * configures). A new job waits for the one before it to end.
 */
class JobQueue {
    internal val lock = Mutex()

    /** Cart calls waiting or running. A warm-up does not start while any are. */
    internal val pending = AtomicInteger(0)

    /**
     * Exclusive work outlived [EXCLUSIVE_CAP_MS] and the queue moved on without
     * it: the page may be anywhere. The next job resets it first.
     */
    @Volatile internal var dirty = false
}

class MealioConfig(
    val publishableKey: String,
    /**
     * From POST /api/v1/sessions on the partner's server. Called again after a
     * 401. If it throws or takes over 30 seconds, the call fails with
     * "session_failed", with your error's message as `message`.
     */
    val sessionTokenProvider: suspend () -> String,
    val platform: String = "android",
    val sdkVersion: String = MealioCart.SDK_VERSION,
    val baseUrl: String = DEFAULT_BASE_URL,
    /** Play Integrity token, when the partner has turned attestation on. */
    val attestationProvider: (suspend () -> String?)? = null,
    /** The device's store-session epoch (bumped by signOutOfAllStores). */
    val epochProvider: (suspend () -> Int)? = null,
    val keys: Map<String, String> = KEYS,
    /** Log server warnings (see CartSession.warnings). Debug builds only. */
    val debug: Boolean = false,
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

/**
 * HttpURLConnection on Dispatchers.IO. Never sends store cookies (it has no
 * cookie handler of ours). A cancelled call (the client's 30 second bound)
 * disconnects at once instead of waiting out a blocked read.
 */
class UrlConnectionTransport(
    private val connectTimeoutMs: Int = 15_000,
    private val readTimeoutMs: Int = 30_000,
) : HttpTransport {
    override suspend fun post(url: String, headers: Map<String, String>, body: String): HttpResponse =
        exchange(url, headers) { c ->
            c.requestMethod = "POST"
            val bytes = body.toByteArray(Charsets.UTF_8)
            c.doOutput = true
            c.setFixedLengthStreamingMode(bytes.size)
            c.outputStream.use { it.write(bytes) }
        }

    override suspend fun get(url: String, headers: Map<String, String>): HttpResponse =
        exchange(url, headers) { c -> c.requestMethod = "GET" }

    private suspend fun exchange(url: String, headers: Map<String, String>, send: (HttpURLConnection) -> Unit): HttpResponse =
        withContext(Dispatchers.IO) {
            val c = URL(url).openConnection() as HttpURLConnection
            // Runs on another IO thread when this call is cancelled, which
            // unblocks a read stuck in this one.
            val unblock = launch(start = CoroutineStart.UNDISPATCHED) {
                try {
                    awaitCancellation()
                } finally {
                    c.disconnect()
                }
            }
            try {
                c.connectTimeout = connectTimeoutMs
                c.readTimeout = readTimeoutMs
                c.useCaches = false
                c.instanceFollowRedirects = false
                for ((k, v) in headers) c.setRequestProperty(k, v)
                send(c)
                val status = c.responseCode
                val stream = if (status >= 400) c.errorStream else c.inputStream
                val text = stream?.use { it.readBytes().toString(Charsets.UTF_8) }
                HttpResponse(status, text)
            } finally {
                unblock.cancel()
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
    private val host: Host,
    private val transport: HttpTransport = UrlConnectionTransport(),
    /** Share one with every client that drives the same hidden page. */
    private val queue: JobQueue = JobQueue(),
) {
    private val runner = Runner(host, Allowlist(), config.keys)
    private val base = config.baseUrl.trimEnd('/')

    /**
     * One job at a time on the hidden page. Prepare, search, add and warm all
     * hold it, and a new job waits for the one before it to end (Mutex is fair).
     */
    private val runLock get() = queue.lock

    /** Cart calls waiting or running. A warm-up does not start while any are. */
    private val pending get() = queue.pending

    /** Tokens of the prepares and searches waiting or running. */
    private val active = LinkedHashSet<CancelToken>()

    @Volatile private var token: String? = null
    /** Bumped by resetSession, so a token still on its way is not kept. */
    private var sessionGen = 0

    /** False until setUser is first called: users are not tracked. */
    @Volatile private var tracksUser = false
    /** Who is signed in. Null with tracksUser means nobody. */
    @Volatile private var user: String? = null

    /** A finished warm-up the next prepare may start from. */
    private class Warmed(val job: String, val store: String, val at: Long, val pageOpens: Int, val epoch: Int)
    @Volatile private var warmed: Warmed? = null
    @Volatile private var lastWarmAt = 0L
    @Volatile private var warmCancel: CancelToken? = null

    /** The allowlist in force, including hosts a signed widening added. */
    val allowlist: Allowlist get() = runner.allowlist

    /** True when setUser says nobody is signed in. */
    val signedOut: Boolean get() = tracksUser && user == null

    /** The stores this app offers right now. No session needed. */
    suspend fun stores(): List<StoreInfo> {
        val res = request { transport.get("$base/api/v1/stores", mapOf("Accept" to "application/json", "X-Mealio-Publishable-Key" to config.publishableKey)) }
        val json = answer(res)
        return json.arr("stores")?.objects()?.map { StoreInfo.fromJson(it) } ?: emptyList()
    }

    /**
     * A Kroger family chain's stores near a zip, nearest first, for the user to
     * choose from. Save their choice with [setStore].
     */
    suspend fun storeLocations(store: String, zip: String): List<StoreLocation> {
        val j = post("/api/v1/sdk/locations", JSONObject().put("store", store).put("zip", zip))
        return j.arr("locations")?.objects()?.map { StoreLocation.fromJson(it) } ?: emptyList()
    }

    /** The user's default store, and their exact store if it is in the Kroger family. */
    suspend fun storePreferences(): StorePreferences =
        StorePreferences.fromJson(post("/api/v1/sdk/preferences", JSONObject()))

    /**
     * Make a store the user's default. A Kroger family store needs `locationId`
     * from [storeLocations] the first time, and otherwise fails with
     * "location_required". Sending it later moves them to that store.
     */
    @JvmOverloads
    suspend fun setStore(store: String, locationId: String? = null): StorePreferences {
        val body = JSONObject().put("store", store).putIfNotNull("locationId", locationId?.takeIf { it.isNotEmpty() })
        return StorePreferences.fromJson(post("/api/v1/sdk/preferences", body))
    }

    /**
     * Start a cart: signs in to the store if needed, searches every ingredient.
     * A Kroger family store the user has not chosen a location for fails with
     * "location_required", before any sign-in. Pass `zip` to use the nearest
     * store instead of asking them.
     * `store` is optional: null uses the user's default store, and the job fails
     * with "store_required" when they have none yet.
     */
    @JvmOverloads
    suspend fun prepareCart(store: String?, recipe: Recipe, zip: String? = null, onStep: StepListener? = null): CartSession =
        prepareCart(store, listOf(recipe), zip, CancelToken(), onStep)

    /**
     * Start one cart from several recipes, at most [MAX_RECIPES]. Ingredients
     * they share become one item, each item lists the recipes it is for, and a
     * pick is remembered under every one of them. Throws MealioException
     * "bad_recipe" for an empty list and "too_many_recipes" for more than
     * MAX_RECIPES, before any network call.
     */
    @JvmOverloads
    suspend fun prepareCart(store: String?, recipes: List<Recipe>, zip: String? = null, onStep: StepListener? = null): CartSession =
        prepareCart(store, recipes, zip, CancelToken(), onStep)

    /**
     * As above, stopped by `cancel`: it stops after the current step, sends
     * nothing more, never shows sign-in, and fails with "cancelled".
     */
    suspend fun prepareCart(
        store: String?,
        recipes: List<Recipe>,
        zip: String?,
        cancel: CancelToken,
        onStep: StepListener? = null,
    ): CartSession {
        if (recipes.isEmpty()) throw MealioException("bad_recipe", "Pass at least one recipe.")
        if (recipes.size > MAX_RECIPES) throw MealioException("too_many_recipes", "At most $MAX_RECIPES recipes in one cart.")
        val stop = cancel
        return cartJob(stop) {
            val fields = JSONObject().putNullable("store", store).putNullable("zip", zip)
            // One recipe goes as `recipe`, so a server from before multi-recipe still understands it.
            if (recipes.size == 1) fields.put("recipe", recipes[0].toJson())
            else fields.put("recipes", JSONArray(recipes.map { it.toJson() }))
            val body = about(fields)
            stopIf(stop)
            takeWarm(store, body.optInt("epoch"))?.let { body.put("warm", it) }
            val result = driveLoop(post("/api/v1/sdk/carts", body, cancel = stop), onStep, cancel = stop)
            val o = result as? JSONObject ?: throw MealioException("server", "Mealio returned no cart")
            val cart = PreparedCart.fromJson(o)
            if (config.debug) for (w in cart.warnings) debugLog("${w.code}: ${w.message}")
            CartSession(this, cart)
        }
    }

    /**
     * Run the login check for the user's store now, before they tap, so the
     * cart that follows can start at search. Mealio picks the store: the
     * user's default, or none, in which case nothing happens (a new user has
     * no store to check yet). Never shows sign-in, never throws, and does
     * nothing if it ran in the last few minutes, while a cart is waiting or
     * running, or while nobody is signed in. MealioCartButton calls it when it
     * appears. Mirrors MealioClient.warm() in packages/core.
     */
    @JvmOverloads
    suspend fun warm(store: String? = null) {
        if (signedOut) return
        // A cart is already waiting for the one hidden page: a warm-up now
        // would load over it. Nothing to gain either, the cart has the session.
        if (pending.get() > 0) return
        val now = System.currentTimeMillis()
        val cancel = CancelToken()
        synchronized(this) {
            if (now - lastWarmAt < WARM_FRESH_MS) return
            lastWarmAt = now
            warmCancel = cancel
        }
        try {
            locked(cancel) {
                val body = about(JSONObject().putIfNotNull("store", store))
                stopIf(cancel)
                val start = post("/api/v1/sdk/warm", body, cancel = cancel)
                val job = start.opt("job") as? String
                if (job == null) { if (!cancel.cancelled) warmed = null; return@locked }
                val r = driveLoop(start, null, warm = true, cancel = cancel) as? JSONObject
                val s = r?.opt("store") as? String
                val w = if (r?.opt("signedIn") == true && s != null) {
                    Warmed(job, s, System.currentTimeMillis(), runner.pageOpens, body.optInt("epoch"))
                } else null
                // A reset while this ran: its result belongs to the last session.
                if (!cancel.cancelled) warmed = w
            }
        } catch (e: Throwable) {
            rethrowIfCancelled(e)
            if (e is Error) throw e
            // A warm-up that fails costs the user nothing: the cart runs as it always has.
            if (!cancel.cancelled) warmed = null
        } finally {
            synchronized(this) { if (warmCancel === cancel) warmCancel = null }
        }
    }

    /**
     * The signed-in user changed. Forget the session, so the next call asks your
     * server for a new one. Signing out of the stores does this too. A warm-up
     * under way stops, and its result is never offered to the next prepare.
     */
    fun resetSession() {
        val w = synchronized(this) {
            sessionGen += 1
            token = null
            warmCancel
        }
        w?.cancel(CancelReason.USER_CHANGED)
        clearWarm()
    }

    /**
     * Tell the SDK who is signed in to your app, or null for nobody. On a change
     * it cancels any prepare or search and resets the session. An add runs on.
     * While null, warm does nothing and calls that need a session fail with
     * "not_signed_in", without asking your server. Returns true when the old
     * value was a user: the caller then signs out of the stores.
     */
    fun setUser(id: String?): Boolean {
        val old: String?
        val wasTracked: Boolean
        synchronized(this) {
            wasTracked = tracksUser
            old = user
            if (wasTracked && id == old) return false
            tracksUser = true
            user = id
        }
        cancelJobs(CancelReason.USER_CHANGED)
        resetSession()
        return wasTracked && old != null
    }

    /**
     * Cancel every prepare and search, waiting or running. An add is not
     * touched. A job waiting in the queue ends at once with "cancelled".
     */
    fun cancelJobs() = cancelJobs(CancelReason.CANCELLED)

    /** As above, with the reason the "cancelled" errors carry. */
    fun cancelJobs(reason: String) {
        val list = synchronized(active) { active.toList() }
        for (c in list) c.cancel(reason)
        warmCancel?.cancel(reason)
    }

    /**
     * Run `block` with the hidden page to itself, in the queue with the jobs.
     * For work that must not land in the middle of one, like clearing store
     * sessions. Fails with "network" after 30 seconds (`block` is cancelled
     * then). The queue stays held until `block` has really ended, but never
     * longer than [EXCLUSIVE_CAP_MS]: after that the queue moves on without it,
     * and the next job first resets the hidden page (about:blank).
     *
     * Its place in the queue is taken before the first suspension: called with
     * CoroutineStart.UNDISPATCHED, it is ahead of any job started afterwards.
     * A caller cancelled while it waits takes it out of the queue; one
     * cancelled while it runs cancels it, and the queue waits for it to end
     * (within the cap).
     */
    suspend fun <T> runExclusive(block: suspend () -> T): T {
        val started = CompletableDeferred<Unit>()
        val scope = CoroutineScope(currentCoroutineContext().minusKey(Job))
        val holder = CompletableDeferred<Deferred<T>>()
        // Owned by no caller: the lock is let go when block ends, or at the cap.
        val hold = scope.launch(start = CoroutineStart.UNDISPATCHED) {
            runLock.withLock {
                cleanPage()
                started.complete(Unit)
                val work = scope.async(start = CoroutineStart.UNDISPATCHED) { block() }
                holder.complete(work)
                if (withTimeoutOrNull(EXCLUSIVE_CAP_MS) { work.join() } == null) {
                    // Stuck past the cap: let the queue go, and have the next job
                    // start from a clean page.
                    work.cancel()
                    queue.dirty = true
                }
            }
        }
        try {
            started.await()
            val work = holder.await()
            val box = withTimeoutOrNull(REQUEST_TIMEOUT_MS) { Box(work.await()) }
            if (box == null) {
                work.cancel()
                throw MealioException("network", "That took too long")
            }
            return box.value
        } catch (e: CancellationException) {
            if (holder.isCompleted) holder.getCompleted().cancel() else hold.cancel()
            throw e
        }
    }

    private class Box<T>(val value: T)

    /**
     * The current token. One that arrives after a reset belongs to the last
     * user. Inside a cancellable job (`cancel` set) a reset while the token was
     * on its way ends the job with "cancelled": it never asks for the next
     * user's token and never sends anything.
     */
    private suspend fun sessionToken(cancel: CancelToken? = null): String = sessionPin(cancel).token

    /** A token and the session generation it belongs to. An add keeps both. */
    private class Pin(@Volatile var token: String, val gen: Int)

    private suspend fun sessionPin(cancel: CancelToken? = null): Pin {
        while (true) {
            if (cancel != null) stopIf(cancel)
            if (signedOut) throw MealioException("not_signed_in", "Nobody is signed in")
            val (have, gen) = synchronized(this) { token to sessionGen }
            if (have != null) return Pin(have, gen)
            val fresh = try {
                fetchToken()
            } catch (e: MealioException) {
                // Cancelled (cancelJobs, a user change) while the token came:
                // the job was over before the fetch failed.
                if (cancel != null && cancel.cancelled) throw cancelledError(cancel)
                if (synchronized(this) { gen != sessionGen }) {
                    if (cancel != null) throw userChangedError()
                    continue
                }
                throw e
            }
            if (cancel != null) stopIf(cancel)
            synchronized(this) {
                if (gen == sessionGen) {
                    token = fresh
                    return Pin(fresh, gen)
                }
            }
            if (cancel != null) throw userChangedError()
        }
    }

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
        search(cartId, key, query, CancelToken(), onStep)

    /** As above, stopped by `cancel` (see prepareCart). */
    suspend fun search(cartId: String, key: String, query: String, cancel: CancelToken, onStep: StepListener? = null): SearchResult {
        val stop = cancel
        return cartJob(stop) {
            val body = about(JSONObject().put("key", key).put("query", query))
            stopIf(stop)
            val result = driveLoop(post("/api/v1/sdk/carts/${encodeUriComponent(cartId)}/search", body, cancel = stop), onStep, cancel = stop)
            val o = result as? JSONObject ?: throw MealioException("server", "Mealio returned no search result")
            SearchResult.fromJson(o)
        }
    }

    /**
     * Fill the store cart with the user's choices. It cannot be cancelled: once
     * tapped it runs to its end under the session it started with, even if the
     * user changes meanwhile. Every wait in it is bounded, so it does end.
     */
    @JvmOverloads
    suspend fun addToCart(cartId: String, selections: List<Selection>, onStep: StepListener? = null): AddResult {
        // Counted from the call, so a warm-up cannot slip in while the token comes.
        pending.incrementAndGet()
        try {
            // The session of whoever tapped, taken now and not after the wait
            // in the queue: a user change meanwhile must not lend it theirs.
            val pin = sessionPin()
            return cartJob(null) {
                val body = about(JSONObject().put("selections", JSONArray(selections.map { it.toJson() })))
                val result = driveLoop(post("/api/v1/sdk/carts/${encodeUriComponent(cartId)}/add", body, pin = pin), onStep, pin = pin)
                val o = result as? JSONObject ?: throw MealioException("server", "Mealio returned no add result")
                AddResult.fromJson(o)
            }
        } finally {
            pending.decrementAndGet()
        }
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

    /**
     * A cart call, queued. It counts as pending from the moment it is called, so
     * a warm-up cannot slip in ahead of it. A cancelled call never starts.
     */
    private suspend fun <T> cartJob(cancel: CancelToken?, block: suspend () -> T): T {
        pending.incrementAndGet()
        if (cancel != null) synchronized(active) { active.add(cancel) }
        try {
            return locked(cancel, block)
        } finally {
            pending.decrementAndGet()
            if (cancel != null) synchronized(active) { active.remove(cancel) }
        }
    }

    /**
     * `block` holding the queue. With `cancel`, a cancel while waiting for the
     * queue ends the wait at once with "cancelled" and leaves the queue. A page
     * left dirty by exclusive work past its cap is reset before `block` runs.
     */
    private suspend fun <T> locked(cancel: CancelToken?, block: suspend () -> T): T {
        val owner = Any()
        if (cancel == null) {
            runLock.lock(owner)
        } else {
            stopIf(cancel)
            val waiter = Job(currentCoroutineContext()[Job])
            val off = cancel.onCancel { waiter.cancel() }
            try {
                withContext(waiter) { runLock.lock(owner) }
            } catch (e: CancellationException) {
                // The lock may have been taken just as the wait was cancelled.
                if (runLock.holdsLock(owner)) runLock.unlock(owner)
                if (cancel.cancelled && currentCoroutineContext().isActive) throw cancelledError(cancel)
                throw e
            } finally {
                off()
                waiter.complete()
            }
        }
        try {
            if (cancel != null) stopIf(cancel)
            cleanPage()
            return block()
        } finally {
            runLock.unlock(owner)
        }
    }

    /**
     * Holding the queue: if exclusive work was cut off by its cap, load
     * about:blank in the hidden page, bounded by [PAGE_RESET_MS]. A warm-up is
     * no longer worth anything after that.
     */
    private suspend fun cleanPage() {
        if (!queue.dirty) return
        queue.dirty = false
        runner.pageReset()
        try {
            withTimeoutOrNull(PAGE_RESET_MS) { host.resetPage() }
        } catch (e: Throwable) {
            rethrowIfCancelled(e)
            if (e is Error) throw e
        }
    }

    /** Who is calling and the device epoch, carried on every job-starting call. */
    private suspend fun about(body: JSONObject): JSONObject {
        val provider = config.epochProvider
        val epoch = if (provider == null) 0 else {
            val e = try {
                withTimeoutOrNull(REQUEST_TIMEOUT_MS) { provider() }
            } catch (e: Throwable) {
                rethrowIfCancelled(e)
                throw MealioException("network", "Could not read the store sign-out state", e)
            }
            e ?: throw MealioException("network", "Could not read the store sign-out state")
        }
        val sdk = JSONObject()
            .put("platform", config.platform)
            .put("version", config.sdkVersion)
            .put("core", SDK_CORE_VERSION)
            .put("ops", JSONArray(SUPPORTED_OPS))
        return body.put("sdk", sdk).put("epoch", epoch)
    }

    /**
     * `warm` is true for a warm-up: it runs before the user has tapped
     * anything, so it may check who is signed in but never show a sign-in sheet.
     * `pin` pins the session (an add keeps the one it was called with).
     */
    private suspend fun driveLoop(
        start: JSONObject,
        onStep: StepListener?,
        warm: Boolean = false,
        cancel: CancelToken? = null,
        pin: Pin? = null,
    ): Any? {
        // Native blocking stays on from the job's first script to here: the
        // job ends however it ends (done, failed, cancelled).
        try {
            return driveJob(start, onStep, warm, cancel, pin)
        } finally {
            host.jobEnded()
        }
    }

    private suspend fun driveJob(
        start: JSONObject,
        onStep: StepListener?,
        warm: Boolean,
        cancel: CancelToken?,
        pin: Pin?,
    ): Any? {
        val job = start.opt("job") as? String
        var env = Envelope.fromJson(start.opt("envelope"))
        var seq = 0
        repeat(200) {
            val out = try {
                runner.run(env, job, seq, allowLogin = !warm, onStep = onStep?.let { l -> { ins: Instruction -> l(stepOf(ins), ins) } }, cancel = cancel)
            } catch (e: EnvelopeException) {
                throw MealioException(if (e.why == "unsupported_op") "unsupported" else "bad_envelope", e.message ?: e.why, e)
            }
            if (cancel != null) stopIf(cancel)
            seq = out.payload.seq
            when (val t = out.terminal) {
                is Terminal.Done -> return t.result
                is Terminal.Fail -> throw MealioException(t.code, t.message)
                null -> Unit
            }
            val next = post("/api/v1/sdk/jobs/${encodeUriComponent(job ?: "")}/step", StepRequest(seq, out.results).toJson(), pin = pin, cancel = cancel)
            env = Envelope.fromJson(next.opt("envelope"))
        }
        throw MealioException("server", "job did not finish")
    }

    /**
     * One HTTP call, bounded by REQUEST_TIMEOUT_MS. No answer, a transport
     * error, or a transport's own cancellation while this call is still wanted
     * is "network".
     */
    private suspend fun request(send: suspend () -> HttpResponse): HttpResponse {
        val res = try {
            withTimeoutOrNull(REQUEST_TIMEOUT_MS) { send() }
        } catch (e: Throwable) {
            rethrowIfCancelled(e)
            if (e is Error) throw e
            throw MealioException("network", "Could not reach Mealio", e)
        }
        return res ?: throw MealioException("network", "Could not reach Mealio")
    }

    /**
     * `pin`: the add's session. On a 401 it is renewed only for the same
     * user (no reset since it was taken), else the add fails with
     * "session_expired". `cancel`: the job's token, for sessionToken.
     */
    private suspend fun post(
        path: String,
        body: JSONObject,
        pin: Pin? = null,
        cancel: CancelToken? = null,
        retried: Boolean = false,
    ): JSONObject {
        val tok = pin?.token ?: sessionToken(cancel)
        val headers = LinkedHashMap<String, String>()
        headers["Content-Type"] = "application/json"
        headers["Authorization"] = "Bearer $tok"
        headers["X-Mealio-Publishable-Key"] = config.publishableKey
        headers["X-Mealio-SDK"] = "${config.platform}/${config.sdkVersion}"
        config.attestationProvider?.let { provider ->
            val a = try {
                withTimeoutOrNull(REQUEST_TIMEOUT_MS) { provider() }
            } catch (e: Throwable) {
                rethrowIfCancelled(e)
                if (e is Error) throw e
                null
            }
            if (!a.isNullOrEmpty()) headers["X-Mealio-Attestation"] = a
        }

        val res = request { transport.post(base + path, headers, body.toString()) }
        if (res.status == 401 && !retried) {
            if (pin != null) {
                if (synchronized(this) { pin.gen != sessionGen }) throw MealioException("session_expired", "The Mealio session expired")
                synchronized(this) { if (token == tok) token = null }
                val fresh = sessionPin()
                // The user changed while the new token came: it is not theirs.
                if (fresh.gen != pin.gen) throw MealioException("session_expired", "The Mealio session expired")
                pin.token = fresh.token
                return post(path, body, pin, cancel, true)
            }
            synchronized(this) { if (token == tok) token = null }
            return post(path, body, null, cancel, true)
        }
        if (res.status == 401) throw MealioException("session_expired", "The Mealio session expired")
        return answer(res)
    }

    private suspend fun fetchToken(): String {
        val fresh = try {
            withTimeoutOrNull(REQUEST_TIMEOUT_MS) { config.sessionTokenProvider() }
        } catch (e: Throwable) {
            // Only a cancel of this call itself ends it quietly. A partner's own
            // timeout (a CancellationException too) is a failed session.
            rethrowIfCancelled(e)
            if (e is Error) throw e
            throw MealioException("session_failed", e.message?.takeIf { it.isNotEmpty() } ?: "Could not start a Mealio session", e)
        }
        return fresh ?: throw MealioException("session_failed", "sessionTokenProvider did not answer in time")
    }
}

/** The body of a good answer, or the error it stands for. */
private fun answer(res: HttpResponse): JSONObject {
    val json = res.body?.let {
        try {
            parseJson(it) as? JSONObject
        } catch (e: JSONException) {
            null
        }
    }
    if (res.status !in 200..299) {
        val err = json?.obj("error")
        throw MealioException(err?.str("code") ?: "server", err?.str("message") ?: "Mealio answered ${res.status}")
    }
    // A captive portal or a proxy can answer 200 with a web page.
    return json ?: throw MealioException("server", "Mealio sent an answer that could not be read")
}

private fun stopIf(cancel: CancelToken) {
    if (cancel.cancelled) throw cancelledError(cancel)
}

private fun debugLog(message: String) {
    try {
        android.util.Log.w("Mealio", message)
    } catch (e: Throwable) {
        // Not on a device (a JVM test): nowhere to log.
    }
}
