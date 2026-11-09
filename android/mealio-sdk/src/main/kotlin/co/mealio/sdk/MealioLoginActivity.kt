package co.mealio.sdk

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import kotlinx.coroutines.CompletableDeferred
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

// The store login. A VISIBLE WebView shares the hidden WebView's session
// because CookieManager and WebStorage are process-wide. It shows either inside
// an open MealioCartFlow sheet (MealioInlineLogin) or, when no flow sheet is
// open, in this full-screen activity with a title bar and a Close button.
// LoginWebController holds the one copy of the WebView rules both use.
//
// The host hands the request over through LoginBroker (in-process, by id)
// because a LoginRequest holds a callback and cannot go in an Intent.

/** One login sheet's request, result and collected messages. */
internal class LoginSession(val id: String, val request: LoginRequest) {
    val result = CompletableDeferred<LoginOutcome>()
    private val messages = ArrayList<JSONObject>()

    /** First outcome wins; later calls do nothing. */
    fun complete(outcome: LoginOutcome): Boolean = result.complete(outcome)

    /** A bridge message (any thread). A doneWhen match means signed in. */
    fun onMessage(raw: String) {
        val m = parseMessage(raw) ?: return
        if (result.isCompleted) return
        synchronized(messages) { messages.add(m) }
        if (matchesAny(m, request.doneWhen)) complete(LoginOutcome.SIGNED_IN)
    }

    fun messages(): List<JSONObject> = synchronized(messages) { messages.toList() }
}

internal object LoginBroker {
    private val sessions = ConcurrentHashMap<String, LoginSession>()

    fun open(request: LoginRequest): LoginSession {
        val s = LoginSession(UUID.randomUUID().toString(), request)
        sessions[s.id] = s
        return s
    }

    fun get(id: String): LoginSession? = sessions[id]

    fun close(id: String) {
        sessions.remove(id)
    }
}

/**
 * The visible login WebView and its rules: every top-frame navigation is asked
 * of allowNavigation, a doneWhenUrl match or a doneWhen message means signed
 * in, and the check script is injected after each load and on its interval.
 * Main thread only.
 */
internal class LoginWebController(
    context: Context,
    private val session: LoginSession,
    /** The renderer died; the session is already completed as cancelled. */
    private val onGone: () -> Unit = {},
) {
    private val handler = Handler(Looper.getMainLooper())
    private var docStartScript = false
    private var bootstrap = BOOTSTRAP_SCRIPT
    /** Native network blocking for the sign-in sheet: armed at the first check script, on until the sheet closes ([destroy]). */
    internal val networkBlock = NetworkBlock()
    // doneWhenUrl is a JavaScript regex source. java.util.regex reads the
    // patterns the server uses (plain URL prefixes and escapes) the same way.
    private val doneUrl: Regex? = session.request.doneWhenUrl?.takeIf { it.isNotEmpty() }
        ?.let { runCatching { Regex(it) }.getOrNull() }

    var webView: WebView? = null
        private set

    private val tick = object : Runnable {
        override fun run() {
            injectCheck()
            val c = session.request.check ?: return
            handler.postDelayed(this, c.intervalMs.coerceAtLeast(MIN_INTERVAL_MS))
        }
    }

    init {
        val wv = WebView(context)
        val setup = configureMealioWebView(wv, MealioNativeBridge { raw -> session.onMessage(raw) })
        docStartScript = setup.docStartScript
        bootstrap = setup.bootstrap
        wv.webViewClient = LoginClient()
        webView = wv
    }

    fun start() {
        val wv = webView ?: return
        wv.loadUrl(session.request.url)
        session.request.check?.let { handler.postDelayed(tick, it.intervalMs.coerceAtLeast(MIN_INTERVAL_MS)) }
    }

    /** Back inside the store's pages. False when there is nowhere to go back to. */
    fun goBack(): Boolean {
        val wv = webView ?: return false
        if (!wv.canGoBack()) return false
        wv.goBack()
        return true
    }

    fun destroy() {
        handler.removeCallbacksAndMessages(null)
        networkBlock.disarm()
        CookieManager.getInstance().flush()
        webView?.let {
            it.stopLoading()
            (it.parent as? ViewGroup)?.removeView(it)
            it.destroy()
        }
        webView = null
    }

    /** Inject GUARD_ARM_SCRIPT (installs the guard if missing, and arms it) then the server's check script into the visible page. */
    private fun injectCheck() {
        val wv = webView ?: return
        val c = session.request.check ?: return
        if (session.result.isCompleted) return
        wv.evaluateJavascript(bootstrap, null)
        // On from the first check until the sheet closes; arming again is the same hosts.
        if (!networkBlock.armed) networkBlock.arm(session.request.blockHosts ?: blockHostsFor(Allowlist(), session.request.store))
        wv.evaluateJavascript(session.request.armGuard, null)
        wv.evaluateJavascript(c.script, null)
    }

    /** A main-frame URL matching doneWhenUrl means signed in. */
    private fun urlMeansDone(url: String): Boolean {
        val re = doneUrl ?: return false
        if (!re.containsMatchIn(url)) return false
        session.complete(LoginOutcome.SIGNED_IN)
        return true
    }

    /** May the main frame go to `url`? Asks the allowlist through the runner. */
    private fun admit(url: String): Boolean {
        if (urlMeansDone(url)) return false // signed in; no need to load it
        if (url == "about:blank") return true
        return session.request.allowNavigation(url)
    }

    private inner class LoginClient : BlockingWebViewClient(networkBlock) {
        override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean {
            if (request == null) return false
            // A blocked path, in any frame (iframes included), never loads.
            if (navigationBlocked(request)) return true
            if (!request.isForMainFrame) return false
            val url = request.url?.toString() ?: return true
            if (!admit(url)) return true
            return false
        }

        override fun onPageStarted(view: WebView?, url: String?, favicon: Bitmap?) {
            if (!docStartScript) view?.evaluateJavascript(bootstrap, null)
            // Backstop for navigations shouldOverrideUrlLoading does not see
            // (POST form submissions).
            if (url != null && !admit(url)) view?.stopLoading()
        }

        override fun onPageFinished(view: WebView?, url: String?) {
            if (url != null && urlMeansDone(url)) return
            injectCheck()
        }

        override fun onRenderProcessGone(view: WebView?, detail: RenderProcessGoneDetail?): Boolean {
            session.complete(LoginOutcome.CANCELLED)
            if (view != null && view === webView) {
                webView = null
                handler.removeCallbacksAndMessages(null)
                (view.parent as? ViewGroup)?.removeView(view)
                view.destroy()
            }
            onGone()
            return true
        }
    }

    companion object {
        private const val MIN_INTERVAL_MS = 500L
    }
}

class MealioLoginActivity : Activity() {
    private val handler = Handler(Looper.getMainLooper())
    private var session: LoginSession? = null
    private var controller: LoginWebController? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val s = intent?.getStringExtra(EXTRA_SESSION)?.let { LoginBroker.get(it) }
        // No session: the run already ended, or the process was restarted.
        if (s == null || s.result.isCompleted) {
            finish()
            return
        }
        session = s
        val c = LoginWebController(this, s, onGone = { finish() })
        controller = c
        setContentView(layout(s.request.title, c.webView!!))

        // Any outcome (signed in, Close, timeout, cancelled run) closes the sheet.
        s.result.invokeOnCompletion { handler.post { if (!isFinishing) finish() } }
        c.start()
    }

    private fun layout(title: String, wv: WebView): View {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.WHITE)
        }
        // Android 15 draws apps edge to edge. Pad for the system bars (and the
        // keyboard) so the title bar is not under the status bar.
        // VERIFY: on API 35 edge-to-edge, systemWindowInsets still include the IME.
        root.setOnApplyWindowInsetsListener { v, insets ->
            @Suppress("DEPRECATION")
            v.setPadding(insets.systemWindowInsetLeft, insets.systemWindowInsetTop, insets.systemWindowInsetRight, insets.systemWindowInsetBottom)
            insets
        }

        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(16), dp(6), dp(6), dp(6))
        }
        val titleView = TextView(this).apply {
            text = title
            setTextColor(Color.BLACK)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
            setTypeface(typeface, Typeface.BOLD)
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
        }
        bar.addView(titleView, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        val close = Button(this).apply {
            text = "Close"
            isAllCaps = false
            contentDescription = "Close sign in"
            setOnClickListener { session?.complete(LoginOutcome.CANCELLED) }
        }
        bar.addView(close, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        root.addView(bar, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))

        val divider = View(this).apply { setBackgroundColor(0x1F000000) }
        root.addView(divider, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 1))
        root.addView(wv, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        return root
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    // On apps that opt in to predictive back (enableOnBackInvokedCallback) this
    // is not called; back then closes the sheet, which onDestroy reports as cancelled.
    @Deprecated("Deprecated in Java")
    @Suppress("DEPRECATION")
    override fun onBackPressed() {
        if (controller?.goBack() == true) return
        session?.complete(LoginOutcome.CANCELLED)
        super.onBackPressed()
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        session?.complete(LoginOutcome.CANCELLED)
        controller?.destroy()
        controller = null
        super.onDestroy()
    }

    companion object {
        private const val EXTRA_SESSION = "co.mealio.sdk.LOGIN_SESSION"

        internal fun intent(context: Context, sessionId: String): Intent =
            Intent(context, MealioLoginActivity::class.java)
                .putExtra(EXTRA_SESSION, sessionId)
                // Started from the application context, so it needs its own task
                // flag. It joins the app's task (same affinity) on top of the app.
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }
}
