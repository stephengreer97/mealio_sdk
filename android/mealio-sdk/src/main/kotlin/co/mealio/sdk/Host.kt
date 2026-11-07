package co.mealio.sdk

import org.json.JSONObject

// The Host is the only platform-specific part of the relay: WebViews, HTTP
// and UI. Runner calls it; WebViewHost is the Android implementation. Tests
// use a fake. Mirrors the Host interface in packages/core/src/runner.ts.

data class PageLoad(val ok: Boolean, val finalUrl: String? = null, val error: String? = null)

data class ScriptRun(val messages: List<JSONObject>, val timedOut: Boolean, val error: String? = null)

class LoginRequest(
    val store: String,
    val url: String,
    val title: String,
    /** GUARD_SCRIPT, injected before every check script. */
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

    /** Load `url` in the hidden WebView. */
    suspend fun openPage(store: String, url: String, timeoutMs: Long): PageLoad

    /**
     * Inject `guard` then `script` into the hidden page. Return every JSON
     * message posted after injection, stopping at the first that matches
     * `until` or when `timeoutMs` passes.
     */
    suspend fun runScript(store: String, guard: String, script: String, until: List<Matcher>, timeoutMs: Long): ScriptRun

    /** Show the login sheet and wait for signed in, closed, or timeout. */
    suspend fun showLogin(request: LoginRequest): LoginResult

    /** One HTTP request with the store's cookies. */
    suspend fun fetch(store: String, request: FetchRequest, timeoutMs: Long, maxBytes: Int): FetchResponse
}
