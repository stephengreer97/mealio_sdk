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
import java.time.Duration
import java.util.concurrent.CompletableFuture

/**
 * 0.6 round 6, item 1 (revised in rounds 7 and 8): the hidden page's and the
 * login page's WebViewClients refuse state-changing requests and documents to
 * blocked paths on the store's own hosts with an empty 403, and blocked
 * navigations in every frame, while Mealio runs a job. A store's own assets
 * and third-party hosts always pass. Nothing here loads a page.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class NetworkBlockWiringTest {
    private class Req(
        url: String,
        private val main: Boolean,
        private val method: String = "GET",
        private val headers: Map<String, String> = emptyMap(),
    ) : WebResourceRequest {
        private val u = Uri.parse(url)
        override fun getUrl(): Uri = u
        override fun isForMainFrame(): Boolean = main
        override fun isRedirect(): Boolean = false
        override fun hasGesture(): Boolean = false
        override fun getMethod(): String = method
        override fun getRequestHeaders(): Map<String, String> = headers
    }

    private val html = mapOf("Accept" to "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
    private val storeRequests = listOf(
        Req("https://www.heb.com/checkout", true),
        Req("https://www.heb.com/api/payment", false, "POST"),
        Req("https://www.heb.com/%63heckout/frame", false, "GET", html),
        Req("https://api.heb.com/graphql/payment", false, "POST"),
        Req("https://www.heb.com/place-order", true, "POST"),
        Req("https://www.heb.com/cart/checkout", false, "PUT"),
        Req("https://www.heb.com/payment/card", false, "patch"),
        Req("https://www.heb.com/payment/card", false, "DELETE"),
    )
    /** The store's own page assets: GETs that are not documents, on blocked-looking paths. Never blocked. */
    private val storeAssets = listOf(
        Req("https://www.heb.com/checkout/static/app.js", false),
        Req("https://www.heb.com/payment/icons/visa.svg", false, "GET", mapOf("Accept" to "image/avif,image/webp,*/*")),
        Req("https://www.heb.com/checkout.css", false, "GET", mapOf("Accept" to "text/css,*/*;q=0.1")),
        Req("https://api.heb.com/graphql/payment", false, "GET", mapOf("Accept" to "*/*")),
        Req("https://www.heb.com/payment/font.woff2", false, "HEAD"),
    )
    private val thirdParty = listOf(
        "https://js.stripe.com/v3/payment",
        "https://pay.other.example/wallet",
        "https://www.google.com/recaptcha/api2/payment",
    )

    /** Before arming: every request passes, store host or not, and subframes may navigate anywhere. */
    private fun assertOff(wv: WebView, client: WebViewClient) {
        for (r in storeRequests + storeAssets) assertNull(r.url.toString(), client.shouldInterceptRequest(wv, r))
        for (url in thirdParty) assertNull(url, client.shouldInterceptRequest(wv, Req(url, false)))
        assertFalse(client.shouldOverrideUrlLoading(wv, Req("https://www.heb.com/checkout", false)))
        assertFalse(client.shouldOverrideUrlLoading(wv, Req("https://js.stripe.com/payment/frame", false)))
    }

    /** Armed: state-changing requests and documents to store-host blocked paths get an empty 403; navigations to them are refused; assets pass. */
    private fun assertOn(wv: WebView, client: WebViewClient) {
        for (q in storeRequests) {
            val url = "${q.method} ${q.url}"
            val r = client.shouldInterceptRequest(wv, q)
            assertNotNull(url, r)
            assertEquals(url, 403, r!!.statusCode)
            assertEquals(url, 0, r.data.readBytes().size)
        }
        for (q in storeAssets) assertNull(q.url.toString(), client.shouldInterceptRequest(wv, q))
        for (url in thirdParty) {
            assertNull(url, client.shouldInterceptRequest(wv, Req(url, false)))
            assertNull(url, client.shouldInterceptRequest(wv, Req(url, false, "POST")))
        }
        assertNull(client.shouldInterceptRequest(wv, Req("https://www.heb.com/search?q=milk", false)))
        assertNull(client.shouldInterceptRequest(wv, Req("https://www.heb.com/api/cart/add", false, "POST")))
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

        // A new main document does not turn it off: it stays on for the whole job.
        assertNull(client.shouldInterceptRequest(wv, Req("https://www.heb.com/next", true)))
        assertFalse(client.shouldOverrideUrlLoading(wv, Req("https://www.heb.com/next", true)))
        client.onPageStarted(wv, "https://www.heb.com/next", null)
        assertTrue(host.networkBlock.armed)
        assertOn(wv, client)

        // Opening another page of the same store keeps it on.
        drive { host.openPage("heb", "https://www.heb.com/aisle", 10) }
        assertTrue(host.networkBlock.armed)

        // The store changes through openPage: off.
        drive { host.openPage("safeway", "https://www.safeway.com/", 10) }
        assertFalse(host.networkBlock.armed)
        assertOff(wv, client)

        // Armed for another store: heb's hosts are not that store's.
        drive { host.runScript("safeway", GUARD_ARM_SCRIPT, "true;", emptyList(), 10) }
        assertNull(client.shouldInterceptRequest(wv, Req("https://www.heb.com/checkout", false)))
        assertNotNull(client.shouldInterceptRequest(wv, Req("https://www.safeway.com/checkout", false, "POST")))

        // The job ends: off.
        host.jobEnded()
        assertFalse(host.networkBlock.armed)
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

        // The next main document does not turn it off; closing the sheet does.
        assertNull(client.shouldInterceptRequest(wv, Req("https://www.heb.com/login/next", true)))
        client.onPageStarted(wv, "https://www.heb.com/login/next", null)
        assertTrue(c.networkBlock.armed)
        assertOn(wv, client)
        c.destroy()
        assertFalse(c.networkBlock.armed)
    }

    /**
     * Round 8, timing: blocking is on from the job's first script to the
     * job's end, whatever the page does in between, so no navigation opens
     * a window and none closes one on the new page's own assets.
     */
    @Test fun hiddenPageStaysOnAcrossNavigationsThatNeverCommit() {
        val host = WebViewHost(RuntimeEnvironment.getApplication())
        val wv = host.ensureWebView()
        val client = wv.webViewClient
        drive { host.runScript("heb", GUARD_ARM_SCRIPT, "true;", emptyList(), 10) }
        // A main-frame navigation that never commits (a 204, a download, window.stop).
        assertFalse(client.shouldOverrideUrlLoading(wv, Req("https://www.heb.com/no-content-204", true)))
        assertNull(client.shouldInterceptRequest(wv, Req("https://www.heb.com/no-content-204", true)))
        // The old page is still the document, and its checkout POST is still refused.
        assertTrue(host.networkBlock.armed)
        assertNotNull(client.shouldInterceptRequest(wv, Req("https://www.heb.com/checkout/place", false, "POST")))
    }

    @Test fun hiddenPageScriptDuringAProvisionalLoadLeavesTheNewPagesAssetsAlone() {
        val host = WebViewHost(RuntimeEnvironment.getApplication())
        val wv = host.ensureWebView()
        val client = wv.webViewClient
        drive { host.runScript("heb", GUARD_ARM_SCRIPT, "true;", emptyList(), 10) }
        assertFalse(client.shouldOverrideUrlLoading(wv, Req("https://www.heb.com/search?q=milk", true)))
        drive { host.runScript("heb", GUARD_ARM_SCRIPT, "true;", emptyList(), 10) }
        client.onPageStarted(wv, "https://www.heb.com/search?q=milk", null)
        assertTrue(host.networkBlock.armed)
        // The new page's own boot assets go through, blocked-looking path or not.
        assertNull(client.shouldInterceptRequest(wv, Req("https://www.heb.com/static/wallet-badge.js", false)))
        assertNull(client.shouldInterceptRequest(wv, Req("https://www.heb.com/checkout/boot.js", false)))
        // Its state-changing requests to blocked paths do not.
        assertNotNull(client.shouldInterceptRequest(wv, Req("https://www.heb.com/checkout", false, "POST")))
    }

    @Test fun loginCheckTickDuringAProvisionalLoadLeavesTheNewPagesAssetsAlone() {
        val req = LoginRequest(
            store = "heb", url = "https://www.heb.com/login", title = "H-E-B", guard = GUARD_SCRIPT,
            check = LoginCheck("true;", 500), doneWhen = emptyList(), doneWhenUrl = null, timeoutMs = 60_000,
            allowNavigation = { true },
        )
        val c = LoginWebController(RuntimeEnvironment.getApplication(), LoginSession("t8", req))
        val wv = c.webView!!
        val client = wv.webViewClient
        c.start()
        client.onPageFinished(wv, "https://www.heb.com/login")
        assertTrue(c.networkBlock.armed)
        // The user taps Next; the server takes 600 ms; the check tick fires meanwhile.
        assertFalse(client.shouldOverrideUrlLoading(wv, Req("https://www.heb.com/login/next", true)))
        assertTrue(c.networkBlock.armed)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(600))
        client.onPageStarted(wv, "https://www.heb.com/login/next", null)
        assertNull(client.shouldInterceptRequest(wv, Req("https://www.heb.com/login/next/static/payment-icons.svg", false)))
        assertNotNull(client.shouldInterceptRequest(wv, Req("https://www.heb.com/login/next/payment", false, "POST")))
        assertTrue(c.networkBlock.armed)
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
        assertNotNull(wv.webViewClient.shouldInterceptRequest(wv, Req("https://login.heb-auth.example/payment", false, "POST")))
        c.destroy()
    }
}
