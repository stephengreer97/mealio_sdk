package co.mealio.sdk

import android.webkit.ServiceWorkerClient
import android.webkit.ServiceWorkerController
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import java.io.ByteArrayInputStream

// Native network blocking (PROTOCOL.md "Guard script", threat model). Every
// request the hidden page or the login page makes, in any frame and of any
// kind (documents, subframe documents, fetch, XHR, beacons, form POSTs,
// images), is asked of requestBlocked before it leaves the device. A blocked
// one gets an empty 403 and never reaches the store. Page code cannot turn
// this off: it runs in the app, not in the page.

/** scheme://authority, then path + query; the fragment is never sent. */
private val REQUEST_URL_RE = Regex("^[a-z][a-z0-9+.-]*://[^/?#]*([^#]*)", RegexOption.IGNORE_CASE)

/**
 * Is a request the store page makes to a blocked path (BLOCKED_PATTERNS, after
 * percent-decoding as isBlockedPath does)? Any host: the store's own, an
 * iframe's, a third party's. URLs without an authority (data:, blob:, about:)
 * never reach the network and are not judged.
 */
internal fun requestBlocked(url: String?): Boolean {
    val m = REQUEST_URL_RE.find(url ?: return false) ?: return false
    return isBlockedPath(m.groupValues[1].ifEmpty { "/" })
}

/** The answer to a blocked request: an empty 403. A new one each time (the stream is read once). */
internal fun blockedResponse(): WebResourceResponse =
    WebResourceResponse("text/plain", "utf-8", 403, "Forbidden", emptyMap(), ByteArrayInputStream(ByteArray(0)))

/**
 * The WebViewClient both SDK WebViews use. shouldInterceptRequest is called
 * for every request of every frame (on a WebView background thread); it is
 * final so the hidden and login clients cannot lose it. Subclasses call
 * [navigationBlocked] first in shouldOverrideUrlLoading.
 */
internal open class BlockingWebViewClient : WebViewClient() {
    final override fun shouldInterceptRequest(view: WebView?, request: WebResourceRequest?): WebResourceResponse? =
        if (requestBlocked(request?.url?.toString())) blockedResponse() else null

    /** A navigation of any frame to a blocked path is refused (true) before it starts. */
    protected fun navigationBlocked(request: WebResourceRequest): Boolean = requestBlocked(request.url?.toString())
}

/** The store domains (registrable) a service worker request is judged for. */
private val STORE_DOMAINS: Set<String> by lazy {
    val a = Allowlist()
    val out = HashSet<String>()
    for (store in STORES.keys) {
        val h = a.hostsFor(store) ?: continue
        for (host in h.hosts + h.authHosts) out.add(registrableDomain(host))
    }
    out
}

/**
 * Should a service worker's request be refused? Only for a store's own
 * domains (the service worker client is process-wide, so the partner app's
 * own WebViews are left alone), or a URL too odd to read a host from.
 * A signed widening only adds hosts on a domain already listed, so the
 * bundled list covers it.
 */
internal fun serviceWorkerRequestBlocked(url: String?): Boolean {
    if (!requestBlocked(url)) return false
    val host = parseUrl(url)?.host ?: return true
    return STORE_DOMAINS.any { host == it || host.endsWith(".$it") }
}

@Volatile private var serviceWorkerBlockInstalled = false

/**
 * Requests a store's service worker makes (including the page's own fetches it
 * answers from the network) go to the process-wide ServiceWorkerClient, not to
 * the WebViewClient. Installed once, the first time an SDK WebView is set up.
 * It replaces any ServiceWorkerClient the app set earlier.
 */
internal fun installServiceWorkerBlock() {
    if (serviceWorkerBlockInstalled) return
    serviceWorkerBlockInstalled = true
    try {
        ServiceWorkerController.getInstance().setServiceWorkerClient(object : ServiceWorkerClient() {
            override fun shouldInterceptRequest(request: WebResourceRequest?): WebResourceResponse? =
                if (serviceWorkerRequestBlocked(request?.url?.toString())) blockedResponse() else null
        })
    } catch (e: Throwable) {
        // No WebView provider (or a test runtime without one): nothing to install into.
    }
}
