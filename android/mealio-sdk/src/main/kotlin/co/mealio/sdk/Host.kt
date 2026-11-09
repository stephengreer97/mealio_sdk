package co.mealio.sdk

import org.json.JSONObject

// The Host is the only platform-specific part of the relay: WebViews, HTTP
// and UI. Runner calls it; WebViewHost is the Android implementation. Tests
// use a fake. Mirrors the Host interface in packages/core/src/runner.ts.

data class PageLoad(val ok: Boolean, val finalUrl: String? = null, val error: String? = null)

data class ScriptRun(val messages: List<JSONObject>, val timedOut: Boolean, val error: String? = null)

// @JvmOverloads keeps 0.5's constructor (no `cancel`) for callers built against it.
class LoginRequest @JvmOverloads constructor(
    val store: String,
    val url: String,
    val title: String,
    /** GUARD_SCRIPT, the unarmed copy the WebView injects into every store frame at document start. */
    val guard: String,
    val check: LoginCheck?,
    val doneWhen: List<Matcher>,
    /** A regex source. A main-frame URL that matches it means signed in. */
    val doneWhenUrl: String?,
    val timeoutMs: Long,
    /** Must be asked for every top-frame navigation. Cancel the navigation when false. */
    val allowNavigation: (String) -> Boolean,
    /** Close the sheet as cancelled when this fires. */
    val cancel: CancelToken? = null,
    /** GUARD_ARM_SCRIPT: injected into the top frame right before each check script. It arms the guard. */
    val armGuard: String = GUARD_ARM_SCRIPT,
    /**
     * The hosts native network blocking covers on the login page (the store's
     * own and its sign-in hosts, signed widenings included). Null: the bundled
     * allowlist's for `store`.
     */
    val blockHosts: List<String>? = null,
)

data class LoginResult(val outcome: LoginOutcome, val messages: List<JSONObject>)

data class FetchResponse(
    val ok: Boolean,
    val status: Int? = null,
    val headers: Map<String, String>? = null,
    val body: String? = null,
    val truncated: Boolean? = null,
    val error: String? = null,
)

interface Host {
    /**
     * How many times the hidden page was lost without being told to load, for
     * example a WebView replaced after its renderer crashed. A warm-up left on a
     * lost page is not offered to the next cart.
     */
    val pagesLost: Int get() = 0

    /**
     * Leave the hidden page blank (about:blank). Called before a job when
     * exclusive work outlived its cap and the page may be anywhere.
     */
    suspend fun resetPage() = Unit

    /** Load `url` in the hidden WebView. */
    suspend fun openPage(store: String, url: String, timeoutMs: Long): PageLoad

    /**
     * Inject `guard` then `script` into the hidden page's top frame. `guard` is
     * GUARD_ARM_SCRIPT, the per-script copy that arms the guard; the hidden
     * WebView's document-start copy is GUARD_SCRIPT. Return every JSON
     * message posted after injection, stopping at the first that matches
     * `until` or when `timeoutMs` passes.
     */
    suspend fun runScript(store: String, guard: String, script: String, until: List<Matcher>, timeoutMs: Long): ScriptRun

    /** Show the login sheet and wait for signed in, closed, or timeout. */
    suspend fun showLogin(request: LoginRequest): LoginResult

    /** One HTTP request with the store's cookies. */
    suspend fun fetch(store: String, request: FetchRequest, timeoutMs: Long, maxBytes: Int): FetchResponse
}
