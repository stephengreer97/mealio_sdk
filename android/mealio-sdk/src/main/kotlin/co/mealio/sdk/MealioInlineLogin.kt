package co.mealio.sdk

import android.content.Context
import android.webkit.WebView
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * A store sign-in waiting to be shown inside an open cart flow sheet.
 *
 * The sheet places [createWebView] in its layout (with its own Activity
 * context, so pickers and dialogs in the store's page work) and calls
 * [releaseWebView] when the view leaves the screen. The WebView enforces the
 * same rules as the full-screen login activity: allowNavigation on every
 * top-frame navigation, doneWhen / doneWhenUrl, the check script.
 *
 * Main thread only.
 */
class InlineLogin internal constructor(internal val session: LoginSession) {
    val store: String get() = session.request.store
    val url: String get() = session.request.url
    /** The server's title for the sign-in, e.g. "Sign in to H-E-B". */
    val title: String get() = session.request.title

    private var controller: LoginWebController? = null

    /** The visible login WebView, once the sheet created it. */
    val webView: WebView? get() = controller?.webView

    /** Build the login WebView and start loading the store's sign-in page. Returns the same view if already built. */
    fun createWebView(context: Context): WebView {
        controller?.webView?.let { return it }
        val c = LoginWebController(context, session, onGone = { controller = null })
        controller = c
        c.start()
        return c.webView!!
    }

    /** Destroy the WebView (the sheet's view went away). Does not end the sign-in. */
    fun releaseWebView() {
        controller?.destroy()
        controller = null
    }

    /** Back inside the store's pages. False when there is nowhere to go back to. */
    fun goBack(): Boolean = controller?.goBack() == true

    /** The user closed the sign-in. The run sees login_cancelled. */
    fun cancel() {
        session.complete(LoginOutcome.CANCELLED)
    }
}

/**
 * Where WebViewHost publishes a sign-in when a cart flow sheet is open.
 * mealio-sdk-compose's MealioCartFlow attaches while it is visible; with no
 * sheet attached, the sign-in opens MealioLoginActivity as before.
 */
object MealioInlineLogin {
    private val state = MutableStateFlow<InlineLogin?>(null)
    @Volatile private var sheets = 0

    /** The sign-in to show in the sheet, or null. */
    val current: StateFlow<InlineLogin?> = state.asStateFlow()

    /** True while a flow sheet is attached and will show the sign-in itself. */
    val hasSheet: Boolean get() = sheets > 0

    /**
     * A flow sheet is open. Call the returned function when it closes. When the
     * last sheet closes during a sign-in, that sign-in is cancelled.
     */
    @Synchronized
    fun attachSheet(): () -> Unit {
        sheets += 1
        var detached = false
        return {
            synchronized(this) {
                if (!detached) {
                    detached = true
                    sheets = (sheets - 1).coerceAtLeast(0)
                    if (sheets == 0) state.value?.cancel()
                }
            }
        }
    }

    internal fun publish(login: InlineLogin) {
        state.value = login
    }

    internal fun clear(login: InlineLogin) {
        state.compareAndSet(login, null)
    }
}
