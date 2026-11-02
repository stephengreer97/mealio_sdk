package co.mealio.sdk

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.webkit.CookieManager
import android.webkit.JavascriptInterface
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.ProtocolException
import java.net.SocketTimeoutException
import java.net.URL
import java.nio.charset.Charset

// The Android Host. One hidden WebView holds the store session (cookies and
// storage, shared process-wide through CookieManager with the visible login
// WebView, in the cart flow sheet or the login activity). Every WebView call happens on the main thread.

/** The name the page sees for the JavascriptInterface. */
internal const val NATIVE_BRIDGE_NAME = "__mealioNativeBridge"

/**
 * Defines window.__mealioNativePost on top of the JavascriptInterface, then
 * BRIDGE_SHIM defines window.ReactNativeWebView.postMessage on top of that.
 * Both halves are idempotent, so injecting it again is harmless.
 */
internal val BOOTSTRAP_SCRIPT: String =
    "window.__mealioNativePost = function(s){ $NATIVE_BRIDGE_NAME.post(String(s)); };\n" + BRIDGE_SHIM

/**
 * The object behind `window.__mealioNativeBridge`. `post` is called on a
 * WebView background thread (the JavaBridge thread), never the main thread.
 *
 * Note: addJavascriptInterface exposes the object to every frame of the page,
 * iframes included. A message can only change what the SDK reports back to the
 * server (which decides what it means); it can never make the SDK act.
 */
class MealioNativeBridge internal constructor(private val onPost: (String) -> Unit) {
    @JavascriptInterface
    fun post(message: String?) {
        if (message != null) onPost(message)
    }
}

/**
 * Shared setup for the hidden and the login WebView. Returns true when the
 * bootstrap is installed as a document-start script, false when the caller
 * must inject it from onPageStarted instead.
 */
@SuppressLint("SetJavaScriptEnabled", "JavascriptInterface", "RequiresFeature")
internal fun configureMealioWebView(wv: WebView, bridge: MealioNativeBridge): Boolean {
    val s = wv.settings
    s.javaScriptEnabled = true
    s.domStorageEnabled = true
    s.javaScriptCanOpenWindowsAutomatically = false
    // target=_blank and window.open load in this same WebView, so they still
    // pass through shouldOverrideUrlLoading.
    s.setSupportMultipleWindows(false)
    s.allowFileAccess = false
    s.allowContentAccess = false
    s.mediaPlaybackRequiresUserGesture = true

    val cm = CookieManager.getInstance()
    cm.setAcceptCookie(true)
    cm.setAcceptThirdPartyCookies(wv, true)

    wv.addJavascriptInterface(bridge, NATIVE_BRIDGE_NAME)
    return if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
        // VERIFY: "*" is accepted as an allowed-origin rule meaning every origin
        // (androidx.webkit docs say so); the returned ScriptHandler is not kept
        // because the script lives as long as the WebView.
        WebViewCompat.addDocumentStartJavaScript(wv, BOOTSTRAP_SCRIPT, setOf("*"))
        true
    } else {
        false
    }
}

private suspend fun <T> onMain(block: () -> T): T = withContext(Dispatchers.Main) { block() }

class WebViewHost(context: Context) : Host {
    private val appContext: Context = context.applicationContext

    // ── main-thread state ──
    private var webView: WebView? = null
    private var docStartScript = false
    private var pendingLoad: CompletableDeferred<PageLoad>? = null
    private var loadStarted = false

    /** The WebView's own User-Agent, reused for `fetch` so the store sees one browser. */
    @Volatile private var userAgent: String? = null

    /** Where bridge messages go while a page_script is collecting. Null drops them. */
    @Volatile private var sink: Channel<String>? = null

    /**
     * Create the hidden WebView on first use (main thread only).
     *
     * It is built on the application context and attached to no window. JS,
     * network, cookies and storage all work this way. Some page features need
     * a window or visibility: requestAnimationFrame does not fire, the page
     * reports document.visibilityState "hidden", and timers may be throttled.
     * The server's scripts are written for that; if a store ever needs a window,
     * attach the WebView to a 1x1 invisible view in the current activity.
     */
    private fun ensureWebView(): WebView {
        webView?.let { return it }
        val wv = WebView(appContext)
        docStartScript = configureMealioWebView(wv, MealioNativeBridge { raw -> sink?.trySend(raw) })
        wv.webViewClient = HiddenClient()
        userAgent = wv.settings.userAgentString
        webView = wv
        return wv
    }

    private inner class HiddenClient : WebViewClient() {
        override fun onPageStarted(view: WebView?, url: String?, favicon: Bitmap?) {
            if (!docStartScript) view?.evaluateJavascript(BOOTSTRAP_SCRIPT, null)
            if (url != null && url != "about:blank") loadStarted = true
        }

        override fun onPageFinished(view: WebView?, url: String?) {
            // Ignore the finish of a page we did not start (stopped loads, about:blank).
            if (!loadStarted || url == null || url == "about:blank") return
            pendingLoad?.complete(PageLoad(ok = true, finalUrl = view?.url ?: url))
        }

        override fun onReceivedError(view: WebView?, request: WebResourceRequest?, error: WebResourceError?) {
            if (request?.isForMainFrame == true) {
                pendingLoad?.complete(PageLoad(ok = false, finalUrl = request.url?.toString(), error = "load_failed"))
            }
        }

        // Defense in depth for redirects and page-driven navigations of the
        // hidden view: never leave https, never land on a blocked path. The
        // runner already checked the URL that page_open asked for.
        override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean {
            if (request == null || !request.isForMainFrame) return false
            val u = request.url ?: return true
            val pathAndQuery = (u.encodedPath ?: "/") + (u.encodedQuery?.let { "?$it" } ?: "")
            if (!"https".equals(u.scheme, ignoreCase = true) || isBlockedPath(pathAndQuery)) {
                pendingLoad?.complete(PageLoad(ok = false, finalUrl = u.toString(), error = "blocked"))
                return true
            }
            return false
        }

        // API 26+. Without this a crashed renderer takes the app down with it.
        override fun onRenderProcessGone(view: WebView?, detail: RenderProcessGoneDetail?): Boolean {
            if (view != null && view === webView) {
                webView = null
                pendingLoad?.complete(PageLoad(ok = false, error = "load_failed"))
                view.destroy()
            }
            return true
        }
    }

    override suspend fun openPage(store: String, url: String, timeoutMs: Long): PageLoad {
        val load = CompletableDeferred<PageLoad>()
        onMain {
            val wv = ensureWebView()
            pendingLoad?.complete(PageLoad(ok = false, error = "load_failed")) // superseded
            pendingLoad = load
            loadStarted = false
            wv.stopLoading()
            wv.loadUrl(url)
        }
        var result: PageLoad? = null
        try {
            result = withTimeoutOrNull(timeoutMs) { load.await() }
            return result ?: PageLoad(ok = false, error = "timeout")
        } finally {
            val timedOut = result == null
            withContext(NonCancellable + Dispatchers.Main) {
                if (pendingLoad === load) pendingLoad = null
                if (timedOut) webView?.stopLoading()
            }
        }
    }

    override suspend fun runScript(
        store: String,
        guard: String,
        script: String,
        until: List<Matcher>,
        timeoutMs: Long,
    ): ScriptRun {
        val ch = Channel<String>(Channel.UNLIMITED)
        val messages = ArrayList<org.json.JSONObject>()
        try {
            onMain {
                val wv = ensureWebView()
                sink = ch
                // evaluateJavascript calls run in order. The bootstrap is repeated
                // because the fallback path (no document-start script) may have
                // raced the page; it does nothing when already installed.
                wv.evaluateJavascript(BOOTSTRAP_SCRIPT, null)
                wv.evaluateJavascript(guard, null)
                wv.evaluateJavascript(script, null)
            }
            val matched = withTimeoutOrNull(timeoutMs) {
                for (raw in ch) {
                    val m = parseMessage(raw) ?: continue
                    messages.add(m)
                    if (matchesAny(m, until)) return@withTimeoutOrNull true
                }
                false
            }
            return ScriptRun(messages.toList(), timedOut = matched == null)
        } finally {
            if (sink === ch) sink = null
            ch.close()
        }
    }

    override suspend fun showLogin(request: LoginRequest): LoginResult {
        val session = LoginBroker.open(request)
        var inline: InlineLogin? = null
        try {
            onMain {
                CookieManager.getInstance() // make sure the cookie store is up before the sheet
                if (MealioInlineLogin.hasSheet) {
                    // A cart flow sheet is open: it shows the sign-in itself.
                    inline = InlineLogin(session).also { MealioInlineLogin.publish(it) }
                } else {
                    appContext.startActivity(MealioLoginActivity.intent(appContext, session.id))
                }
            }
            val outcome = withTimeoutOrNull(request.timeoutMs) { session.result.await() }
                ?: run {
                    session.complete(LoginOutcome.TIMEOUT)
                    session.result.await() // whichever outcome won the race
                }
            return LoginResult(outcome, session.messages())
        } finally {
            // Closes the sheet if it is still up (timeout or a cancelled run).
            session.complete(LoginOutcome.CANCELLED)
            LoginBroker.close(session.id)
            inline?.let { l -> withContext(NonCancellable + Dispatchers.Main) { MealioInlineLogin.clear(l) } }
        }
    }

    override suspend fun fetch(store: String, request: FetchRequest, timeoutMs: Long, maxBytes: Int): FetchResponse {
        // VERIFY: CookieManager.getInstance() should be first touched on the main
        // thread on older WebView builds; getCookie/setCookie are then safe on IO.
        val ua = onMain {
            CookieManager.getInstance()
            ensureWebView()
            userAgent
        }
        return withContext(Dispatchers.IO) { StoreFetch(request, timeoutMs, maxBytes, ua).run() }
    }

    /** Leave the store page (after a sign-out). */
    suspend fun reset() = onMain {
        webView?.stopLoading()
        webView?.loadUrl("about:blank")
    }

    /** Release the hidden WebView. The host can still be used; it makes a new one. */
    fun destroy() {
        Handler(Looper.getMainLooper()).post {
            webView?.let {
                it.stopLoading()
                it.destroy()
            }
            webView = null
        }
    }
}

/**
 * One `fetch` instruction over HttpURLConnection, with the store's cookies from
 * CookieManager and Set-Cookie written back. Redirects are followed by hand so
 * every hop stays on https, on the same registrable domain, and off blocked
 * paths. A redirect that would leave is returned to the server as-is.
 */
private class StoreFetch(
    private val request: FetchRequest,
    private val timeoutMs: Long,
    private val maxBytes: Int,
    private val userAgent: String?,
) {
    private val cookies = CookieManager.getInstance()

    fun run(): FetchResponse {
        var url = request.url
        var method = request.method.uppercase()
        var body = request.body
        val home = registrableDomain(hostOf(url) ?: return FetchResponse(ok = false, error = "no_response"))
        val timeout = timeoutMs.coerceIn(1L, Int.MAX_VALUE.toLong()).toInt()

        try {
            for (hop in 0..MAX_REDIRECTS) {
                val conn = URL(url).openConnection() as HttpURLConnection
                try {
                    conn.instanceFollowRedirects = false
                    conn.connectTimeout = timeout
                    conn.readTimeout = timeout
                    conn.useCaches = false
                    // Throws ProtocolException for methods HttpURLConnection lacks (PATCH).
                    conn.requestMethod = method
                    applyHeaders(conn, url)

                    val sendBody = body != null && method != "GET" && method != "HEAD"
                    if (sendBody) {
                        val bytes = body!!.toByteArray(Charsets.UTF_8)
                        conn.doOutput = true
                        conn.setFixedLengthStreamingMode(bytes.size)
                        conn.outputStream.use { it.write(bytes) }
                    }

                    val status = conn.responseCode
                    storeCookies(url, conn.headerFields)

                    if (status in 300..399 && status != 304 && hop < MAX_REDIRECTS) {
                        val next = conn.getHeaderField("Location")?.let { loc ->
                            try { URL(URL(url), loc).toString() } catch (e: Exception) { null }
                        }
                        if (next != null && redirectAllowed(next, home)) {
                            if (status == 303 || ((status == 301 || status == 302) && method == "POST")) {
                                method = "GET"
                                body = null
                            }
                            url = next
                            continue
                        }
                    }
                    return readResponse(conn, status)
                } finally {
                    conn.disconnect()
                }
            }
            return FetchResponse(ok = false, error = "no_response")
        } catch (e: SocketTimeoutException) {
            return FetchResponse(ok = false, error = "timeout")
        } catch (e: ProtocolException) {
            return FetchResponse(ok = false, error = "bad_method")
        } catch (e: IOException) {
            return FetchResponse(ok = false, error = "no_response")
        } catch (e: IllegalArgumentException) {
            return FetchResponse(ok = false, error = "no_response")
        }
    }

    private fun applyHeaders(conn: HttpURLConnection, url: String) {
        var extraCookie: String? = null
        var hasUa = false
        for ((k, v) in request.headers) {
            when (k.lowercase()) {
                "cookie" -> { extraCookie = v; continue }
                // HttpURLConnection sets these itself. Setting accept-encoding by
                // hand would turn off its transparent gzip.
                "host", "content-length", "connection", "accept-encoding" -> continue
                "user-agent" -> hasUa = true
            }
            conn.setRequestProperty(k, v)
        }
        if (!hasUa && userAgent != null) conn.setRequestProperty("User-Agent", userAgent)
        val jar = cookies.getCookie(url)
        val cookie = listOfNotNull(jar?.takeIf { it.isNotEmpty() }, extraCookie?.takeIf { it.isNotEmpty() }).joinToString("; ")
        if (cookie.isNotEmpty()) conn.setRequestProperty("Cookie", cookie)
    }

    private fun storeCookies(url: String, fields: Map<String?, List<String>>?) {
        if (fields == null) return
        var any = false
        for ((k, values) in fields) {
            if (k == null || !k.equals("set-cookie", ignoreCase = true)) continue
            for (v in values) {
                cookies.setCookie(url, v)
                any = true
            }
        }
        if (any) cookies.flush()
    }

    private fun readResponse(conn: HttpURLConnection, status: Int): FetchResponse {
        val headers = LinkedHashMap<String, String>()
        conn.headerFields?.forEach { (k, v) ->
            // The status line has a null key. Set-Cookie stays on the device:
            // the user's store cookies are never sent to Mealio.
            if (k == null || k.equals("set-cookie", ignoreCase = true) || k.equals("set-cookie2", ignoreCase = true)) return@forEach
            val key = k.lowercase()
            headers[key] = (headers[key]?.let { listOf(it) } ?: emptyList<String>()).plus(v).joinToString(", ")
        }
        val stream: InputStream? = try {
            if (status >= 400) conn.errorStream else conn.inputStream
        } catch (e: IOException) {
            conn.errorStream
        }
        val limit = maxBytes.coerceAtLeast(0)
        val out = ByteArrayOutputStream()
        var truncated = false
        stream?.use { s ->
            val buf = ByteArray(16 * 1024)
            while (true) {
                val n = s.read(buf)
                if (n < 0) break
                val room = limit - out.size()
                if (n > room) {
                    out.write(buf, 0, room.coerceAtLeast(0))
                    truncated = true
                    break
                }
                out.write(buf, 0, n)
            }
        }
        val text = String(out.toByteArray(), charsetOf(conn.contentType))
        return FetchResponse(ok = true, status = status, headers = headers, body = text, truncated = truncated)
    }

    private fun redirectAllowed(next: String, home: String): Boolean {
        val u = try { URL(next) } catch (e: Exception) { return false }
        if (!u.protocol.equals("https", ignoreCase = true)) return false
        val host = u.host ?: return false
        if (registrableDomain(host) != home) return false
        val pathAndQuery = (u.path.ifEmpty { "/" }) + (u.query?.let { "?$it" } ?: "")
        return !isBlockedPath(pathAndQuery)
    }

    private fun hostOf(url: String): String? = try { URL(url).host } catch (e: Exception) { null }

    private fun charsetOf(contentType: String?): Charset {
        val name = contentType?.split(';')?.map { it.trim() }
            ?.firstOrNull { it.startsWith("charset=", ignoreCase = true) }
            ?.substringAfter('=')?.trim('"', ' ')
        return try { if (name.isNullOrEmpty()) Charsets.UTF_8 else Charset.forName(name) } catch (e: Exception) { Charsets.UTF_8 }
    }

    companion object {
        const val MAX_REDIRECTS = 5
    }
}
