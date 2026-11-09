package co.mealio.sdk.testing

import co.mealio.sdk.AddResult
import co.mealio.sdk.CartRecipe
import co.mealio.sdk.CartWarning
import co.mealio.sdk.Envelope
import co.mealio.sdk.FetchRequest
import co.mealio.sdk.FetchResponse
import co.mealio.sdk.Host
import co.mealio.sdk.HttpResponse
import co.mealio.sdk.HttpTransport
import co.mealio.sdk.ItemRecipe
import co.mealio.sdk.LoginOutcome
import co.mealio.sdk.LoginRequest
import co.mealio.sdk.LoginResult
import co.mealio.sdk.Matcher
import co.mealio.sdk.MealioCart
import co.mealio.sdk.MealioClient
import co.mealio.sdk.MealioConfig
import co.mealio.sdk.MealioTesting
import co.mealio.sdk.MealioTestingHook
import co.mealio.sdk.PageLoad
import co.mealio.sdk.Product
import co.mealio.sdk.STORES
import co.mealio.sdk.ScriptRun
import co.mealio.sdk.Selection
import co.mealio.sdk.StoreHosts
import co.mealio.sdk.StoreInfo
import co.mealio.sdk.StoreLocation
import co.mealio.sdk.StorePreferences
import co.mealio.sdk.TestSessions
import kotlinx.coroutines.CompletableDeferred
import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters
import org.bouncycastle.crypto.signers.Ed25519Signer
import org.json.JSONArray
import org.json.JSONObject
import java.net.URLDecoder
import java.util.Base64

// co.mealio:mealio-sdk-testing (package co.mealio.sdk.testing), a separate
// artifact for `testImplementation` only, so none of this can ship in a
// release app. Run the REAL MealioClient, CartSession, MealioCart
// and drop-in sheet in JVM or Robolectric tests with no network. Port of
// @mealio/sdk-core/testing (packages/core/src/testing.ts); the scripts are the
// same plain data. It signs with the protocol TEST key, which no production
// build trusts: KEYS holds only the production key, and the test key is used
// only where `keys` is passed (config() and install() do that).
//
//   val fake = FakeMealio(FakeScript(items = listOf(FakeItem("milk", options = listOf(Product("m1", "Milk", unitPrice = 3.0)), remembered = "m1"))))
//   val client = fake.client()                       // a real MealioClient on the fake
//   val cart = client.prepareCart("heb", Recipe("r", listOf(RecipeIngredient("milk"))))
//   // Or make MealioCart (and MealioCartButton) use it:  fake.install()  ...  FakeMealio.uninstall()

/** The protocol test key's id and public key (protocol/test-vectors.json). Pass as MealioConfig.keys. */
val TEST_KEYS: Map<String, String> = mapOf("ktest" to "6kpsY+KcUgq+9VB7Ey7F+ZVHdq6+vnuSQh7qaRRG0iw=")

/** The base URL the fake answers on. */
const val FAKE_BASE_URL = "https://mealio.test"

private val TEST_PRIVATE = Ed25519PrivateKeyParameters(ByteArray(32) { 7 }, 0)

/** An envelope signed with the test key, for tests that script instructions themselves. */
fun signTestEnvelope(job: String, seq: Int, store: String, instructions: List<JSONObject>): Envelope {
    val payload = JSONObject().put("v", 1).put("kind", "instructions").put("job", job).put("seq", seq)
        .put("exp", 4102444800L).put("store", store).put("instructions", JSONArray(instructions)).toString()
    val s = Ed25519Signer()
    s.init(true, TEST_PRIVATE)
    val b = payload.toByteArray(Charsets.UTF_8)
    s.update(b, 0, b.size)
    return Envelope(payload, Base64.getEncoder().encodeToString(s.generateSignature()), "ktest")
}

/** An error by code. With `status` it is an HTTP error; without, a job that fails with it. */
data class FakeError @JvmOverloads constructor(val code: String, val message: String? = null, val status: Int? = null)

/** One line of a scripted cart, as the server would build it. */
data class FakeItem @JvmOverloads constructor(
    val key: String,
    val options: List<Product> = emptyList(),
    /** The remembered product's id. In `options` and in stock: status remembered, pre-selected. */
    val remembered: String? = null,
    val ingredient: String? = null,
    /**
     * Packages, as TypeScript's `quantity?: number`: any Int, Long or Double,
     * kept as given (no truncating or clamping to Int). The cart sends it as
     * JSON.stringify would (a non-finite one as null).
     */
    val quantity: Number = 1,
    val rememberedPreferenceId: String? = null,
    /** The remembered product is gone this time: status remembered_unavailable, nothing pre-selected. */
    val rememberedUnavailable: Boolean = false,
    /** Pantry or optional: starts unticked (selectedId stays as the server sends it). */
    val startUnchecked: Boolean = false,
    /** The recipe's own weight, lb. */
    val weightLb: Double? = null,
    val recipes: List<ItemRecipe>? = null,
    /** Nothing found: status unavailable with this reason. */
    val unavailable: String? = null,
)

/** What a request is, for [FakeScript.errors], [FakeMealio.hold] and [FakeRequest]. */
enum class FakeKind { PREPARE, SEARCH, ADD, WARM, STEP, STORES, PREFERENCES, LOCATIONS, SESSION, OTHER }

/**
 * What the fake Mealio answers. Plain data; change it between calls.
 * Same fields as FakeScript in @mealio/sdk-core/testing.
 */
class FakeScript @JvmOverloads constructor(
    var store: String? = null,
    var storeName: String? = null,
    var items: List<FakeItem> = emptyList(),
    var recipes: List<CartRecipe>? = null,
    var warnings: List<CartWarning> = emptyList(),
    /** Results per query (exact, case-insensitive). An unlisted query finds nothing. */
    var search: Map<String, List<Product>> = emptyMap(),
    /** Results computed from (query, key). Wins over [search]. */
    var searchWith: ((query: String, key: String) -> List<Product>)? = null,
    /**
     * What an add does. Default (null): each selection whose product this cart
     * offered (prepare or a search on THIS cart) is added with its price; any
     * other product fails as `not_offered`, as the server does.
     */
    var add: ((selections: List<Selection>, offered: List<Product>) -> AddResult)? = null,
    /** The add fails with this. */
    var addFail: FakeError? = null,
    /** Prepare asks the user to sign in, and the fake store page answers this. Null: already signed in. */
    var signIn: LoginOutcome? = null,
    /** Errors by kind. SESSION makes the default session token provider throw. */
    var errors: Map<FakeKind, FakeError> = emptyMap(),
    var stores: List<StoreInfo>? = null,
    var preferences: StorePreferences? = null,
    var locations: List<StoreLocation> = emptyList(),
    /** What a warm-up finds: true signed in (default), false not, null no store to warm. */
    var warmSignedIn: Boolean? = true,
) {
    companion object {
        /** A script from JSON with TypeScript's FakeScript field names (see fakeScriptFromJson). */
        @JvmStatic
        fun fromJson(json: String): FakeScript = fakeScriptFromJson(json)
    }
}

/** One request the client sent. `body` is null for a GET. */
data class FakeRequest(val kind: FakeKind, val path: String, val body: JSONObject?, val token: String?)

/** A scripted Mealio server, a fake store page and the test keys. */
class FakeMealio @JvmOverloads constructor(
    /** The script in force. Change it, or its fields, between calls. */
    @Volatile var script: FakeScript = FakeScript(),
) {
    private val requestLog = ArrayList<FakeRequest>()
    private val hostLog = ArrayList<String>()
    private class Cart(val store: String, val offered: MutableList<Product>)
    private val carts = HashMap<String, Cart>()
    private class Job(val store: String, val finish: (LoginOutcome?) -> List<JSONObject>)
    private val jobs = HashMap<String, Job>()
    private val holds = HashMap<FakeKind, ArrayDeque<CompletableDeferred<Unit>>>()
    private var nJob = 0
    private var nCart = 0
    private val memory = MemorySessions()

    val keys: Map<String, String> get() = TEST_KEYS
    val baseUrl: String get() = FAKE_BASE_URL

    /** Every request the client sent, in order. */
    val requests: List<FakeRequest> get() = synchronized(requestLog) { requestLog.toList() }

    /** What the fake store page was asked to do: "open <url>", "script", "login", "fetch", "reset". */
    val hostCalls: List<String> get() = synchronized(hostLog) { hostLog.toList() }

    /** The sign-out epoch while [install]ed: bumped by each store sign-out (setUser to another user, signOutOfAllStores). */
    val storeEpoch: Int get() = memory.epoch()

    /** The products a cart offered so far (prepare and its own searches). */
    fun offered(cartId: String): List<Product> = synchronized(this) { carts[cartId]?.offered?.toList() ?: emptyList() }

    /** Hold the next request of this kind until the returned function is called. */
    fun hold(kind: FakeKind): () -> Unit {
        val d = CompletableDeferred<Unit>()
        synchronized(holds) { holds.getOrPut(kind) { ArrayDeque() }.addLast(d) }
        return { d.complete(Unit) }
    }

    /** The transport the client talks to Mealio through. */
    val transport: HttpTransport = object : HttpTransport {
        override suspend fun post(url: String, headers: Map<String, String>, body: String): HttpResponse =
            exchange(url, headers, JSONObject(body))

        override suspend fun get(url: String, headers: Map<String, String>): HttpResponse = exchange(url, headers, null)
    }

    private suspend fun exchange(url: String, headers: Map<String, String>, body: JSONObject?): HttpResponse {
        val path = url.removePrefix(FAKE_BASE_URL)
        val kind = kindOf(path)
        val token = headers["Authorization"]?.removePrefix("Bearer ")
        synchronized(requestLog) { requestLog.add(FakeRequest(kind, path, body, token)) }
        val held = synchronized(holds) { holds[kind]?.removeFirstOrNull() }
        held?.await()
        return synchronized(this) { answer(kind, path, body ?: JSONObject()) }
    }

    /** The store page. Every call is recorded in [hostCalls]. */
    val host: Host = object : Host {
        override suspend fun openPage(store: String, url: String, timeoutMs: Long): PageLoad {
            log("open $url")
            return PageLoad(true, url)
        }

        override suspend fun runScript(store: String, guard: String, script: String, until: List<Matcher>, timeoutMs: Long): ScriptRun {
            log("script")
            return ScriptRun(emptyList(), false)
        }

        override suspend fun showLogin(request: LoginRequest): LoginResult {
            log("login")
            if (request.cancel?.cancelled == true) return LoginResult(LoginOutcome.CANCELLED, emptyList())
            return LoginResult(this@FakeMealio.script.signIn ?: LoginOutcome.SIGNED_IN, emptyList())
        }

        override suspend fun fetch(store: String, request: FetchRequest, timeoutMs: Long, maxBytes: Int): FetchResponse {
            log("fetch")
            return FetchResponse(true, 200, emptyMap(), "")
        }

        override suspend fun resetPage() = log("reset")
    }

    private fun log(s: String) = synchronized(hostLog) { hostLog.add(s); Unit }

    /** A session token provider that answers "session_test", or throws the SESSION error. */
    val sessionTokenProvider: suspend () -> String = {
        val e = script.errors[FakeKind.SESSION]
        if (e != null) throw IllegalStateException(e.message ?: e.code)
        "session_test"
    }

    /** A MealioConfig on this fake, with the test keys. */
    @JvmOverloads
    fun config(
        sessionTokenProvider: suspend () -> String = this.sessionTokenProvider,
        epochProvider: (suspend () -> Int)? = null,
        attestationProvider: (suspend () -> String?)? = null,
        platform: String = "android-test",
    ): MealioConfig = MealioConfig(
        publishableKey = "pk_test_fake",
        sessionTokenProvider = sessionTokenProvider,
        platform = platform,
        sdkVersion = MealioCart.SDK_VERSION,
        baseUrl = FAKE_BASE_URL,
        attestationProvider = attestationProvider,
        epochProvider = epochProvider,
        keys = TEST_KEYS,
    )

    /** A real MealioClient on this fake. */
    @JvmOverloads
    fun client(config: MealioConfig = config()): MealioClient = MealioClient(config, host, transport)

    /**
     * Make MealioCart use this fake, as configure() would: MealioCart.prepareCart,
     * setUser, the sign-outs and MealioCartButton's sheet then run the real
     * client against it. No Context needed. Store sign-outs bump [storeEpoch]
     * instead of touching cookies. Call [uninstall] after the test.
     */
    @JvmOverloads
    @OptIn(MealioTestingHook::class)
    fun install(sessionTokenProvider: suspend () -> String = this.sessionTokenProvider): MealioClient {
        val cfg = config(sessionTokenProvider, epochProvider = { memory.epoch() }, platform = "android")
        return MealioTesting.install(host, memory) { q -> MealioClient(cfg, host, transport, q) }
    }

    companion object {
        /** A fake from a JSON script, the same text TypeScript's createFakeMealio and Swift's FakeMealio(json:) take. */
        @JvmStatic
        fun fromJson(json: String): FakeMealio = FakeMealio(fakeScriptFromJson(json))

        /** Undo [install]: MealioCart is unconfigured again and forgets the user. */
        @JvmStatic
        @OptIn(MealioTestingHook::class)
        fun uninstall() = MealioTesting.uninstall()
    }

    // ── the scripted server ───────────────────────────────────────────

    private fun kindOf(path: String): FakeKind = when {
        path == "/api/v1/stores" -> FakeKind.STORES
        path == "/api/v1/sdk/preferences" -> FakeKind.PREFERENCES
        path == "/api/v1/sdk/locations" -> FakeKind.LOCATIONS
        path == "/api/v1/sdk/warm" -> FakeKind.WARM
        path == "/api/v1/sdk/carts" -> FakeKind.PREPARE
        Regex("^/api/v1/sdk/carts/[^/]+/search$").matches(path) -> FakeKind.SEARCH
        Regex("^/api/v1/sdk/carts/[^/]+/add$").matches(path) -> FakeKind.ADD
        Regex("^/api/v1/sdk/jobs/[^/]+/step$").matches(path) -> FakeKind.STEP
        else -> FakeKind.OTHER
    }

    private fun reply(o: JSONObject, status: Int = 200) = HttpResponse(status, o.toString())

    private fun errorBody(e: FakeError) = JSONObject().put("error", JSONObject().put("code", e.code).put("message", e.message ?: e.code))

    private fun httpError(e: FakeError) = reply(errorBody(e), e.status ?: 400)

    private fun failOp(e: FakeError) = JSONObject().put("op", "fail").put("id", "fail-1").put("code", e.code).put("message", e.message ?: e.code)

    private fun done(result: Any) = JSONObject().put("op", "done").put("id", "done-1").put("result", result)

    private fun start(store: String, instructions: List<JSONObject>, finish: ((LoginOutcome?) -> List<JSONObject>)? = null): HttpResponse {
        val job = "job_${++nJob}"
        if (finish != null) jobs[job] = Job(store, finish)
        return reply(JSONObject().put("job", job).put("envelope", signTestEnvelope(job, 1, store, instructions).toJson()))
    }

    /** HTTP when it has a status, else a job that fails. */
    private fun jobError(store: String, e: FakeError) = if (e.status != null) httpError(e) else start(store, listOf(failOp(e)))

    private fun prefs(): StorePreferences = script.preferences ?: StorePreferences(script.store ?: "heb", null)

    private fun hostsOf(store: String): StoreHosts? = STORES[store]

    private fun home(store: String) = "https://www.${hostsOf(store)?.hosts?.firstOrNull() ?: "heb.com"}/"

    private fun loginUrl(store: String): String {
        val s = hostsOf(store)
        val h = s?.hosts?.firstOrNull()
        return if (h != null) "https://www.$h/login" else "https://${s?.authHosts?.firstOrNull() ?: "www.heb.com"}/login"
    }

    private fun answer(kind: FakeKind, path: String, body: JSONObject): HttpResponse {
        val s = script
        val err = s.errors[kind]
        return when (kind) {
            FakeKind.STORES -> if (err != null) httpError(err) else reply(JSONObject().put("stores", JSONArray(
                (s.stores ?: listOf(StoreInfo("heb", "H-E-B", "device"))).map { JSONObject().put("id", it.id).put("name", it.name).put("via", it.via) })))
            FakeKind.PREFERENCES -> {
                if (err != null) return httpError(err)
                val store = body.opt("store") as? String
                if (store != null) {
                    val loc = (body.opt("locationId") as? String)?.let { id -> s.locations.firstOrNull { it.id == id } } ?: prefs().location
                    s.preferences = StorePreferences(store, loc)
                }
                reply(prefsJson(prefs()))
            }
            FakeKind.LOCATIONS -> if (err != null) httpError(err) else reply(JSONObject().put("locations", JSONArray(s.locations.map { locationJson(it) })))
            FakeKind.WARM -> {
                val store = body.opt("store") as? String ?: prefs().defaultStore
                val signedIn = s.warmSignedIn
                if (store == null || signedIn == null) reply(JSONObject().put("warm", JSONObject.NULL))
                else if (err != null) jobError(store, err)
                else start(store, listOf(done(JSONObject().put("store", store).put("signedIn", signedIn))))
            }
            FakeKind.PREPARE -> prepare(body)
            FakeKind.SEARCH -> search(cartOf(path), body)
            FakeKind.ADD -> add(cartOf(path), body)
            FakeKind.STEP -> {
                val job = cartOf(path)
                val j = jobs.remove(job) ?: return reply(errorBody(FakeError("unknown_job", "No such job")), 404)
                val results = body.optJSONArray("results") ?: JSONArray()
                var outcome: LoginOutcome? = null
                for (i in 0 until results.length()) {
                    val w = results.optJSONObject(i)?.opt("outcome") as? String ?: continue
                    outcome = LoginOutcome.values().firstOrNull { it.wire == w }
                }
                reply(JSONObject().put("envelope", signTestEnvelope(job, body.optInt("seq", 1) + 1, j.store, j.finish(outcome)).toJson()))
            }
            else -> reply(JSONObject())
        }
    }

    private fun cartOf(path: String) = URLDecoder.decode(path.split("/")[5], "UTF-8")

    private fun prepare(body: JSONObject): HttpResponse {
        val s = script
        val store = body.opt("store") as? String ?: s.store ?: prefs().defaultStore
            ?: return httpError(FakeError("store_required", "Pick a store", 400))
        s.errors[FakeKind.PREPARE]?.let { return jobError(store, it) }
        val items = s.items.map { fakeCartItem(it) }
        val cartId = "cart_${++nCart}"
        carts[cartId] = Cart(store, s.items.flatMap { it.options }.toMutableList())
        val recipes = s.recipes?.map { JSONObject().put("id", it.id).put("title", it.title ?: JSONObject.NULL) }
            ?: run {
                val list = body.optJSONArray("recipes") ?: body.optJSONObject("recipe")?.let { JSONArray().put(it) } ?: JSONArray()
                (0 until list.length()).mapNotNull { list.optJSONObject(it) }
                    .map { JSONObject().put("id", it.opt("id")).put("title", it.opt("title") ?: JSONObject.NULL) }
            }
        val cart = JSONObject().put("cartId", cartId).put("store", store)
            .put("storeName", s.storeName ?: if (store == "heb") "H-E-B" else store)
            .put("items", JSONArray(items)).put("ready", JSONArray()).put("needsChoice", JSONArray()).put("unavailable", JSONArray())
            .put("recipes", JSONArray(recipes))
            .put("warnings", JSONArray(s.warnings.map { JSONObject().put("code", it.code).put("message", it.message) }))
        // A Kroger family store has no page of its own: only its sign-in.
        val open = if (hostsOf(store)?.hosts?.isNotEmpty() == true)
            listOf(JSONObject().put("op", "page_open").put("id", "open-1").put("url", home(store)).put("timeoutMs", 15000)) else emptyList()
        if (s.signIn == null) return start(store, open + done(cart))
        val login = JSONObject().put("op", "show_login").put("id", "login-1").put("url", loginUrl(store)).put("title", "Sign in")
            .put("doneWhen", JSONArray().put(JSONObject().put("type", "FAKE_SIGNED_IN"))).put("timeoutMs", 120000)
        return start(store, open + login) { outcome ->
            if (outcome == LoginOutcome.SIGNED_IN) listOf(done(cart)) else listOf(failOp(FakeError("login_cancelled", "Sign-in was closed")))
        }
    }

    private fun search(cartId: String, body: JSONObject): HttpResponse {
        val c = carts[cartId]
        val store = c?.store ?: "heb"
        script.errors[FakeKind.SEARCH]?.let { return jobError(store, it) }
        val query = body.opt("query") as? String ?: ""
        val key = body.opt("key") as? String ?: ""
        val found = script.searchWith?.invoke(query, key)
            ?: script.search.entries.firstOrNull { it.key.equals(query, ignoreCase = true) }?.value ?: emptyList()
        c?.offered?.addAll(found)
        return start(store, listOf(done(JSONObject().put("key", key).put("query", query).put("options", JSONArray(found.map { productJson(it) })))))
    }

    private fun add(cartId: String, body: JSONObject): HttpResponse {
        val c = carts[cartId]
        val store = c?.store ?: "heb"
        (script.errors[FakeKind.ADD] ?: script.addFail)?.let { return jobError(store, it) }
        val offered = c?.offered?.toList() ?: emptyList()
        val arr = body.optJSONArray("selections") ?: JSONArray()
        val selections = (0 until arr.length()).mapNotNull { arr.optJSONObject(it) }.map {
            Selection(
                it.optString("key"), it.opt("productId") as? String, (it.opt("quantity") as? Number)?.toInt(),
                it.opt("remember") as? Boolean, it.opt("preferenceId") as? String, (it.opt("weightLb") as? Number)?.toDouble(),
            )
        }
        script.add?.let { return start(store, listOf(done(addJson(it(selections, offered))))) }
        val added = JSONArray()
        val skipped = JSONArray()
        val failed = JSONArray()
        for (sel in selections) {
            val id = sel.productId
            if (id == null) { skipped.put(JSONObject().put("key", sel.key).put("reason", "not_selected")); continue }
            val p = offered.firstOrNull { it.id == id }
            if (p == null) { failed.put(JSONObject().put("key", sel.key).put("productId", id).put("name", id).put("reason", "not_offered")); continue }
            val a = JSONObject().put("key", sel.key).put("productId", p.id).put("name", p.name).put("quantity", sel.quantity ?: 1)
            sel.weightLb?.let { a.put("weightLb", it) }
            p.unitPrice?.let { a.put("unitPrice", it) }
            p.pricePerLb?.let { a.put("pricePerLb", it) }
            if (p.estimated) a.put("estimated", true)
            added.put(a)
        }
        val result = JSONObject().put("cartId", cartId).put("store", store).put("added", added).put("skipped", skipped).put("failed", failed)
            .put("storeCartUrl", home(store) + "cart").put("verified", true)
        return start(store, listOf(done(result)))
    }
}

/** In memory, for [FakeMealio.install]: a sign-out bumps the epoch and clears nothing. */
@OptIn(MealioTestingHook::class)
private class MemorySessions : TestSessions {
    @Volatile private var n = 0
    override fun epoch(): Int = n
    @Synchronized override fun bumpEpoch(): Int = ++n
}

// ── JSON as the server sends it ─────────────────────────────────────

/** A cart item from a script line, as the server builds it. */
fun fakeCartItem(f: FakeItem): JSONObject {
    val rem = f.remembered?.let { id -> f.options.firstOrNull { it.id == id } ?: Product(id, id) }
    val usable = rem != null && !f.rememberedUnavailable && !rem.outOfStock && f.options.any { it.id == rem.id }
    val status = when {
        f.unavailable != null || f.options.isEmpty() -> "unavailable"
        usable -> "remembered"
        rem != null -> "remembered_unavailable"
        else -> "choose"
    }
    val o = JSONObject().put("key", f.key).put("ingredient", f.ingredient ?: f.key).put("quantity", wireNumber(f.quantity)).put("status", status)
        .put("options", JSONArray(f.options.map { productJson(it) }))
        .put("selectedId", if (usable) rem!!.id else JSONObject.NULL)
        .put("remembered", if (rem == null) JSONObject.NULL else productJson(if (usable) rem else rem.copy(outOfStock = true)))
    f.rememberedPreferenceId?.let { o.put("rememberedPreferenceId", it) }
    if (f.startUnchecked) o.put("startUnchecked", true)
    f.weightLb?.let { o.put("weightLb", it) }
    f.recipes?.let { r -> o.put("recipes", JSONArray(r.map { JSONObject().put("id", it.id).put("title", it.title ?: JSONObject.NULL).put("quantity", wireNumber(it.quantity)) })) }
    if (status == "unavailable") o.put("reason", f.unavailable ?: "not_found")
    return o
}

/**
 * A number as JSON.stringify writes it: a non-finite one is null, a whole one
 * is written without a fraction (2, not 2.0), anything else as it is.
 */
internal fun wireNumber(n: Number): Any {
    if (n is Int || n is Long || n is Short || n is Byte) return n
    val d = n.toDouble()
    if (!d.isFinite()) return JSONObject.NULL
    if (d == Math.rint(d) && Math.abs(d) < 9.007199254740992E15) return d.toLong()
    return d
}

/** A Product as the server sends it. */
fun productJson(p: Product): JSONObject {
    val o = JSONObject().put("id", p.id).put("name", p.name)
    p.price?.let { o.put("price", it) }
    p.imageUrl?.let { o.put("imageUrl", it) }
    p.size?.let { o.put("size", it) }
    if (p.outOfStock) o.put("outOfStock", true)
    p.badge?.let { o.put("badge", it) }
    p.badgeLabel?.let { o.put("badgeLabel", it) }
    if (p.preferences.isNotEmpty()) o.put("preferences", JSONArray(p.preferences.map { JSONObject().put("id", it.id).put("label", it.label) }))
    p.unitPrice?.let { o.put("unitPrice", it) }
    if (p.estimated) o.put("estimated", true)
    p.maxQuantity?.let { o.put("maxQuantity", it) }
    p.soldByWeight?.let { o.put("soldByWeight", it) }
    p.weightOptions?.let { o.put("weightOptions", JSONArray(it)) }
    p.pricePerLb?.let { o.put("pricePerLb", it) }
    return o
}

private fun locationJson(l: StoreLocation) = JSONObject().put("id", l.id).put("name", l.name).put("address", l.address).put("zip", l.zip ?: JSONObject.NULL)

private fun prefsJson(p: StorePreferences) = JSONObject().put("defaultStore", p.defaultStore ?: JSONObject.NULL)
    .put("location", p.location?.let { locationJson(it) } ?: JSONObject.NULL)

private fun addJson(r: AddResult): JSONObject = JSONObject().put("cartId", r.cartId).put("store", r.store)
    .put("added", JSONArray(r.added.map { a ->
        JSONObject().put("key", a.key).put("productId", a.productId).put("name", a.name).put("quantity", a.quantity).also { o ->
            a.weightLb?.let { o.put("weightLb", it) }
            a.imageUrl?.let { o.put("imageUrl", it) }
            a.ingredient?.let { o.put("ingredient", it) }
            a.unitPrice?.let { o.put("unitPrice", it) }
            a.pricePerLb?.let { o.put("pricePerLb", it) }
            a.estimated?.let { o.put("estimated", it) }
        }
    }))
    .put("skipped", JSONArray(r.skipped.map { JSONObject().put("key", it.key).put("reason", it.reason) }))
    .put("failed", JSONArray(r.failed.map { JSONObject().put("key", it.key).put("productId", it.productId).put("name", it.name).put("reason", it.reason) }))
    .put("storeCartUrl", r.storeCartUrl ?: JSONObject.NULL)
    .also { o -> r.verified?.let { o.put("verified", it) } }
