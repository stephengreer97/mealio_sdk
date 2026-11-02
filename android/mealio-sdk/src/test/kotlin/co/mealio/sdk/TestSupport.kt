package co.mealio.sdk

import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters
import org.bouncycastle.crypto.signers.Ed25519Signer
import org.json.JSONArray
import org.json.JSONObject
import java.util.Base64

fun readResource(name: String): String {
    val stream = Vectors::class.java.classLoader!!.getResourceAsStream(name) ?: error("missing test resource $name")
    return stream.use { it.readBytes().toString(Charsets.UTF_8) }
}

/** protocol/test-vectors.json, shared with the TypeScript, Swift and Dart suites. */
object Vectors {
    val json: JSONObject by lazy { JSONObject(readResource("test-vectors.json")) }
    val keys: Map<String, String> get() = mapOf(json.getString("kid") to json.getString("publicKey"))

    fun cases(): List<JSONObject> = json.getJSONArray("cases").objects()

    fun case(name: String): JSONObject = cases().first { it.getString("name") == name }

    fun envelope(name: String): Envelope = Envelope.fromJson(case(name).getJSONObject("envelope"))!!
}

/**
 * Signs with the same deterministic TEST key as protocol/make-vectors.mjs
 * (seed = 32 bytes of 7), so tests can build envelopes the vectors do not cover.
 */
object TestSigner {
    private val priv = Ed25519PrivateKeyParameters(ByteArray(32) { 7 }, 0)

    val publicKeyB64: String get() = Base64.getEncoder().encodeToString(priv.generatePublicKey().encoded)

    fun sign(payload: String, kid: String = "ktest"): Envelope {
        val s = Ed25519Signer()
        s.init(true, priv)
        val b = payload.toByteArray(Charsets.UTF_8)
        s.update(b, 0, b.size)
        return Envelope(payload, Base64.getEncoder().encodeToString(s.generateSignature()), kid)
    }

    fun instructions(
        seq: Int,
        instructions: List<JSONObject>,
        job: String = "job_test",
        store: String = "heb",
        exp: Long = 4102444800L,
        v: Int = 1,
        kind: String = "instructions",
    ): Envelope {
        val p = JSONObject()
            .put("v", v).put("kind", kind).put("job", job).put("seq", seq).put("exp", exp).put("store", store)
            .put("instructions", JSONArray(instructions))
        return sign(p.toString())
    }
}

fun pageOpen(id: String, url: String) = JSONObject().put("op", "page_open").put("id", id).put("url", url).put("timeoutMs", 1000)
fun pageScript(id: String, type: String) = JSONObject().put("op", "page_script").put("id", id).put("script", "true;")
    .put("until", JSONArray().put(JSONObject().put("type", type))).put("timeoutMs", 1000)
fun fetchOp(id: String, url: String) = JSONObject().put("op", "fetch").put("id", id)
    .put("request", JSONObject().put("method", "GET").put("url", url)).put("timeoutMs", 1000).put("maxBytes", 1000)
fun showLoginOp(id: String, url: String) = JSONObject().put("op", "show_login").put("id", id).put("url", url)
    .put("title", "Sign in").put("doneWhen", JSONArray()).put("timeoutMs", 1000)
fun doneOp(id: String, result: Any?) = JSONObject().put("op", "done").put("id", id).put("result", result ?: JSONObject.NULL)
fun failOp(id: String, code: String, message: String) = JSONObject().put("op", "fail").put("id", id).put("code", code).put("message", message)

/** The fake Host from core.test.ts. */
class FakeHost(
    private val onFetch: (suspend (FetchRequest) -> FetchResponse)? = null,
    private val onOpen: (suspend (String) -> PageLoad)? = null,
) : Host {
    val calls = mutableListOf<String>()

    override suspend fun openPage(store: String, url: String, timeoutMs: Long): PageLoad {
        calls.add("open $url")
        return onOpen?.invoke(url) ?: PageLoad(ok = true, finalUrl = url)
    }

    override suspend fun runScript(store: String, guard: String, script: String, until: List<Matcher>, timeoutMs: Long): ScriptRun {
        calls.add("script")
        val msg = JSONObject().put("type", until.firstOrNull()?.type ?: "X").put("loggedIn", true)
        return ScriptRun(listOf(msg), timedOut = false)
    }

    override suspend fun showLogin(request: LoginRequest): LoginResult {
        calls.add("login")
        return LoginResult(LoginOutcome.SIGNED_IN, emptyList())
    }

    override suspend fun fetch(store: String, request: FetchRequest, timeoutMs: Long, maxBytes: Int): FetchResponse {
        calls.add("fetch")
        return onFetch?.invoke(request) ?: FetchResponse(ok = true, status = 200, body = "{}")
    }
}

/** Records every Mealio call; `handler` gets the path (base URL removed). */
class FakeTransport(
    private val base: String = "https://mealio.test",
    private val onGet: ((path: String) -> HttpResponse)? = null,
    private val handler: (path: String, headers: Map<String, String>, body: JSONObject) -> HttpResponse,
) : HttpTransport {
    override suspend fun get(url: String, headers: Map<String, String>): HttpResponse {
        val path = url.removePrefix(base)
        seen.add("GET $path")
        this.headers.add(headers)
        return onGet?.invoke(path) ?: error("unexpected GET $path")
    }

    val seen = mutableListOf<String>()
    val headers = mutableListOf<Map<String, String>>()

    override suspend fun post(url: String, headers: Map<String, String>, body: String): HttpResponse {
        val path = url.removePrefix(base)
        seen.add(path)
        this.headers.add(headers)
        return handler(path, headers, JSONObject(body))
    }
}

fun ok(o: JSONObject) = HttpResponse(200, o.toString())
