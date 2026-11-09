package co.mealio.sdk

import android.net.Uri
import android.os.Looper
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.util.concurrent.CompletableFuture

/**
 * 0.6 round 6, item 1 (revised in round 7): the hidden page's and the login
 * page's WebViewClients refuse blocked requests to the store's own hosts with
 * an empty 403, and blocked navigations in every frame, only while Mealio
 * drives the page. Third-party hosts always pass. Nothing here loads a page.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class NetworkBlockWiringTest {
    private class Req(url: String, private val main: Boolean, private val method: String = "GET") : WebResourceRequest {
        private val u = Uri.parse(url)
        override fun getUrl(): Uri = u
        override fun isForMainFrame(): Boolean = main
        override fun isRedirect(): Boolean = false
        override fun hasGesture(): Boolean = false
        override fun getMethod(): String = method
        override fun getRequestHeaders(): Map<String, String> = emptyMap()
    }

    private val storeRequests = listOf(
        Triple("https://www.heb.com/checkout", false, "GET"),
        Triple("https://www.heb.com/api/payment", false, "POST"),
        Triple("https://www.heb.com/%63heckout/frame", false, "GET"),
        Triple("https://api.heb.com/graphql/payment", false, "POST"),
        Triple("https://www.heb.com/place-order", true, "POST"),
    )
    private val thirdParty = listOf(
        "https://js.stripe.com/v3/payment",
        "https://pay.other.example/wallet",
        "https://www.google.com/recaptcha/api2/payment",
    )

    /** Before arming: every request passes, store host or not, and subframes may navigate anywhere. */
    private fun assertOff(wv: WebView, client: WebViewClient) {
        for ((url, main, method) in storeRequests) assertNull(url, client.shouldInterceptRequest(wv, Req(url, main, method)))
        for (url in thirdParty) assertNull(url, client.shouldInterceptRequest(wv, Req(url, false)))
        assertFalse(client.shouldOverrideUrlLoading(wv, Req("https://www.heb.com/checkout", false)))
        assertFalse(client.shouldOverrideUrlLoading(wv, Req("https://js.stripe.com/payment/frame", false)))
    }

    /** Armed: store-host blocked paths get an empty 403 and subframe navigations to them are refused. */
    private fun assertOn(wv: WebView, client: WebViewClient) {
        for ((url, main, method) in storeRequests) {
            val r = client.shouldInterceptRequest(wv, Req(url, main, method))
            assertNotNull(url, r)
            assertEquals(url, 403, r!!.statusCode)
            assertEquals(url, 0, r.data.readBytes().size)
        }
        for (url in thirdParty) assertNull(url, client.shouldInterceptRequest(wv, Req(url, false)))
        assertNull(client.shouldInterceptRequest(wv, Req("https://www.heb.com/search?q=milk", false)))
        assertNull(client.shouldInterceptRequest(wv, Req("https://www.heb.com/", true)))
        assertTrue(client.shouldOverrideUrlLoading(wv, Req("https://www.heb.com/checkout", false)))
        assertFalse(client.shouldOverrideUrlLoading(wv, Req("https://js.stripe.com/payment/frame", false)))
        assertFalse(client.shouldOverrideUrlLoading(wv, Req("https://www.heb.com/frame", false)))
    }

    /** Run a suspend host call off the main thread while the test (main) thread drains the main looper. */
    private fun <T> drive(block: suspend () -> T): T {
        val f = CompletableFuture<T>()
        CoroutineScope(Dispatchers.Default).launch {
            try { f.complete(block()) } catch (e: Throwable) { f.completeExceptionally(e) }
        }
        while (!f.isDone) {
            shadowOf(Looper.getMainLooper()).idle()
            Thread.sleep(2)
        }
        return f.get()
    }

    @Test fun hiddenPage() {
        val host = WebViewHost(RuntimeEnvironment.getApplication())
        val wv = host.ensureWebView()
        val client = wv.webViewClient
        assertOff(wv, client)

        // The first server script arms it, for the store it runs for.
        drive { host.runScript("heb", GUARD_ARM_SCRIPT, "true;", emptyList(), 10) }
        assertTrue(host.networkBlock.armed)
        assertOn(wv, client)

        // A new main document turns it off.
        client.onPageStarted(wv, "https://www.heb.com/next", null)
        assertFalse(host.networkBlock.armed)
        assertOff(wv, client)

        // Armed again, then the page (or the store) changes through openPage: off.
        drive { host.runScript("heb", GUARD_ARM_SCRIPT, "true;", emptyList(), 10) }
        assertTrue(host.networkBlock.armed)
        drive { host.openPage("safeway", "https://www.safeway.com/", 10) }
        assertFalse(host.networkBlock.armed)
        assertOff(wv, client)

        // Armed for another store: heb's hosts are not that store's.
        drive { host.runScript("safeway", GUARD_ARM_SCRIPT, "true;", emptyList(), 10) }
        assertNull(client.shouldInterceptRequest(wv, Req("https://www.heb.com/checkout", false)))
        assertNotNull(client.shouldInterceptRequest(wv, Req("https://www.safeway.com/checkout", false)))
    }

    @Test fun loginPage() {
        val req = LoginRequest(
            store = "heb", url = "https://www.heb.com/login", title = "H-E-B", guard = GUARD_SCRIPT,
            check = LoginCheck("true;", 60_000),
            doneWhen = emptyList(), doneWhenUrl = null, timeoutMs = 1000,
            allowNavigation = { true },
        )
        val c = LoginWebController(RuntimeEnvironment.getApplication(), LoginSession("t", req))
        val wv = c.webView!!
        val client = wv.webViewClient
        // The sign-in page's own boot requests are never blocked.
        assertOff(wv, client)
        assertFalse(c.networkBlock.armed)

        // The check script after the load arms it.
        client.onPageFinished(wv, "https://www.heb.com/login")
        assertTrue(c.networkBlock.armed)
        assertOn(wv, client)
        assertFalse(client.shouldOverrideUrlLoading(wv, Req("https://www.heb.com/login/next", true)))

        // The next main document starts unblocked, until its check script.
        client.onPageStarted(wv, "https://www.heb.com/login/next", null)
        assertFalse(c.networkBlock.armed)
        assertOff(wv, client)
        c.destroy()
    }

    /**
     * The SDK never replaces a ServiceWorkerClient the partner app set: no
     * main source touches the process-wide ServiceWorkerController. (There is
     * no WebView provider under Robolectric to ask instead.)
     */
    @Test fun leavesTheAppsServiceWorkerClientAlone() {
        val src = java.io.File("src/main")
        assertTrue(src.absolutePath, src.isDirectory)
        val offenders = src.walk().filter { it.isFile && it.extension in setOf("kt", "java") }
            .filter { it.readText().contains("ServiceWorkerController") || it.readText().contains("setServiceWorkerClient") }
            .map { it.name }.toList()
        assertEquals(emptyList<String>(), offenders)
    }

    @Test fun loginPageUsesTheHostsItWasGiven() {
        val req = LoginRequest(
            store = "heb", url = "https://www.heb.com/login", title = "H-E-B", guard = GUARD_SCRIPT,
            check = LoginCheck("true;", 60_000),
            doneWhen = emptyList(), doneWhenUrl = null, timeoutMs = 1000,
            allowNavigation = { true }, blockHosts = listOf("login.heb-auth.example"),
        )
        val c = LoginWebController(RuntimeEnvironment.getApplication(), LoginSession("t", req))
        val wv = c.webView!!
        wv.webViewClient.onPageFinished(wv, "https://www.heb.com/login")
        assertNotNull(wv.webViewClient.shouldInterceptRequest(wv, Req("https://login.heb-auth.example/payment", false)))
        c.destroy()
    }
}
