package co.mealio.sdk

import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import java.io.ByteArrayInputStream

// Native network blocking (PROTOCOL.md "Guard script", threat model). While
// Mealio drives a page, every request that page makes to the current store's
// own hosts, in any frame and of any kind (documents, subframe documents,
// fetch, XHR, beacons, form POSTs, images), is asked of requestBlocked before
// it leaves the device. A blocked one gets an empty 403 and never reaches the
// store. Page code cannot turn this off: it runs in the app, not in the page.
//
// Two limits keep it from breaking the store:
// - Only the store's hosts. A third-party host (a Stripe or captcha iframe) is
//   never blocked, whatever its path.
// - Only while Mealio drives the page. It turns on (arm) right before the first
//   Mealio script for the page, the same moment the in-page guard arms, and
//   turns off when a new main document starts or the store changes. The
//   store's own boot requests before that always go through.
//
// Service worker requests do not reach a WebViewClient and are outside this
// block (the SDK never sets the process-wide ServiceWorkerClient).

/** scheme://authority, then path + query; the fragment is never sent. */
private val REQUEST_URL_RE = Regex("^[a-z][a-z0-9+.-]*://([^/?#]*)([^#]*)", RegexOption.IGNORE_CASE)

/**
 * The host a browser sends `url` to: the authority after any userinfo, without
 * a port or a trailing dot, lowercased. Null for URLs without an authority
 * (data:, blob:, about:), which never reach the network.
 */
internal fun requestHost(url: String?): String? {
    val m = REQUEST_URL_RE.find(url ?: return null) ?: return null
    var a = m.groupValues[1].substringAfterLast('@')
    a = if (a.startsWith("[")) a.substringBefore(']') + "]" else a.substringBefore(':')
    return a.trimEnd('.').lowercase().ifEmpty { null }
}

/**
 * Is a request to a blocked path (BLOCKED_PATTERNS, after percent-decoding as
 * isBlockedPath does)? The path alone; [NetworkBlock] adds the host and the
 * armed state.
 */
internal fun requestBlocked(url: String?): Boolean {
    val m = REQUEST_URL_RE.find(url ?: return false) ?: return false
    return isBlockedPath(m.groupValues[2].ifEmpty { "/" })
}

/** Is `url` on one of `hosts` or a subdomain of one? */
internal fun onHosts(url: String?, hosts: Collection<String>): Boolean {
    val h = requestHost(url) ?: return false
    return hosts.any { val a = it.lowercase(); h == a || h.endsWith(".$a") }
}

/**
 * The hosts native blocking covers for a store: its own hosts and its
 * store-specific sign-in hosts from the allowlist (signed widenings
 * included). The identity providers every store shares are not the store's.
 */
internal fun blockHostsFor(allowlist: Allowlist, store: String): List<String> {
    // The store's own hosts only, as on iOS. Sign-in hosts are often shared
    // providers (Microsoft, Okta) that other sites use too.
    val h = allowlist.hostsFor(store) ?: return emptyList()
    return h.hosts
}

/** The answer to a blocked request: an empty 403. A new one each time (the stream is read once). */
internal fun blockedResponse(): WebResourceResponse =
    WebResourceResponse("text/plain", "utf-8", 403, "Forbidden", emptyMap(), ByteArrayInputStream(ByteArray(0)))

/**
 * One WebView's blocking state. Set on the main thread, read on WebView
 * background threads. Off until [arm]; [disarm] at a new main document or a
 * store change.
 */
internal class NetworkBlock {
    @Volatile private var hosts: List<String>? = null

    val armed: Boolean get() = hosts != null

    /** Turn on for these hosts (the current store's). Called right before each Mealio script. */
    fun arm(storeHosts: List<String>) {
        hosts = storeHosts.toList()
    }

    fun disarm() {
        hosts = null
    }

    /** Refuse `url`? Only while armed, only on the store's hosts, only for a blocked path. */
    fun blocks(url: String?): Boolean {
        val h = hosts ?: return false
        return requestBlocked(url) && onHosts(url, h)
    }
}

/**
 * The WebViewClient both SDK WebViews use. shouldInterceptRequest is called
 * for every request of every frame (on a WebView background thread); it is
 * final so the hidden and login clients cannot lose it. Subclasses call
 * [navigationBlocked] first in shouldOverrideUrlLoading and
 * [newMainDocument] from onPageStarted.
 */
internal open class BlockingWebViewClient(val block: NetworkBlock) : WebViewClient() {
    final override fun shouldInterceptRequest(view: WebView?, request: WebResourceRequest?): WebResourceResponse? =
        if (block.blocks(request?.url?.toString())) blockedResponse() else null

    /** A navigation of any frame to a blocked path on the store's hosts, while armed, is refused (true) before it starts. */
    protected fun navigationBlocked(request: WebResourceRequest): Boolean = block.blocks(request.url?.toString())

    /** A new main document started: the page Mealio drove is gone, so blocking turns off until the next script. */
    protected fun newMainDocument() = block.disarm()
}
