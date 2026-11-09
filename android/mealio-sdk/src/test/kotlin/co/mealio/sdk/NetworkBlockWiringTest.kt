package co.mealio.sdk

import android.net.Uri
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/**
 * 0.6 round 6, item 1: the hidden page's and the login page's WebViewClients
 * refuse blocked requests (any frame, any method) with an empty 403, and
 * blocked navigations in every frame. Nothing here loads a page.
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

    private fun assertBlocks(wv: WebView, client: WebViewClient) {
        // Subresources of every kind: fetch / XHR (GET and POST), a subframe document, a form POST into an iframe.
        for ((url, main, method) in listOf(
            Triple("https://www.heb.com/checkout", false, "GET"),
            Triple("https://www.heb.com/api/payment", false, "POST"),
            Triple("https://www.heb.com/%63heckout/frame", false, "GET"),
            Triple("https://www.heb.com/place-order", true, "POST"),
            Triple("https://pay.other.example/wallet", false, "GET"),
        )) {
            val r = client.shouldInterceptRequest(wv, Req(url, main, method))
            assertNotNull(url, r)
            assertEquals(url, 403, r!!.statusCode)
            assertEquals(url, 0, r.data.readBytes().size)
        }
        assertNull(client.shouldInterceptRequest(wv, Req("https://www.heb.com/search?q=milk", false)))
        assertNull(client.shouldInterceptRequest(wv, Req("https://www.heb.com/", true)))

        // Navigations: a subframe to a blocked path is refused, an ordinary one is not.
        assertTrue(client.shouldOverrideUrlLoading(wv, Req("https://www.heb.com/checkout", false)))
        assertTrue(client.shouldOverrideUrlLoading(wv, Req("https://ads.other.example/payment/frame", false)))
        assertFalse(client.shouldOverrideUrlLoading(wv, Req("https://ads.other.example/frame", false)))
        assertTrue(client.shouldOverrideUrlLoading(wv, Req("https://www.heb.com/checkout", true)))
    }

    @Test fun hiddenPage() {
        val host = WebViewHost(RuntimeEnvironment.getApplication())
        val wv = host.ensureWebView()
        assertBlocks(wv, wv.webViewClient)
    }

    @Test fun loginPage() {
        val req = LoginRequest(
            store = "heb", url = "https://www.heb.com/login", title = "H-E-B", guard = GUARD_SCRIPT, check = null,
            doneWhen = emptyList(), doneWhenUrl = null, timeoutMs = 1000,
            // Even a navigation the runner would allow is refused for a blocked path.
            allowNavigation = { true },
        )
        val c = LoginWebController(RuntimeEnvironment.getApplication(), LoginSession("t", req))
        val wv = c.webView!!
        assertBlocks(wv, wv.webViewClient)
        assertFalse(wv.webViewClient.shouldOverrideUrlLoading(wv, Req("https://www.heb.com/login/next", true)))
        c.destroy()
    }
}
