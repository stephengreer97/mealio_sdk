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
// - Only the store's hosts and its store-owned sign-in hosts (blockHostsFor).
//   A third-party host (a Stripe or captcha iframe) or a shared identity
//   provider (Google, Okta's own pages) is never blocked, whatever its path.
// - Only while Mealio drives the page. It turns on (arm) right before the first
//   Mealio script for the page, the same moment the in-page guard arms, and
//   turns off the moment a new main document is requested (or the store
//   changes). The store's own boot requests before that always go through.
//
// Turning off at the request, not at onPageStarted: onPageStarted is posted
// after the new document commits, so the new page's first subresources went
// out still armed (and refused), and a script armed after the commit was
// disarmed by the late callback. The cost: between the request and the
// commit the old page runs unblocked (its in-page guard is still armed), and
// a main-frame request that never commits (a 204, a download) leaves it off
// until the next script.
//
// Known limit: Android WebView does not show redirects of fetch, XHR or
// subresources to shouldInterceptRequest, only the first URL. A request to an
// ordinary path that the store redirects to a checkout path is not caught here
// (the in-page guard judges what the page asked for). Navigation redirects
// reach shouldOverrideUrlLoading and are caught.
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
 * Identity providers many stores and apps share (protocol/shared-identity-hosts.json,
 * which a test keeps this list equal to). Native blocking never runs on them,
 * so it never refuses a request a shared sign-in page makes, except on a
 * tenant named for the store ([sharedIdentityHost]).
 */
val SHARED_IDENTITY_HOSTS: List<String> = listOf(
    "google.com", "gstatic.com", "apple.com", "facebook.com", "microsoftonline.com", "b2clogin.com",
    "ciamlogin.com", "live.com", "okta.com", "auth0.com", "mealio.co",
)

private fun normHost(h: String): String = h.lowercase().removeSuffix(".")

/** Is `host` equal to `entry` or a subdomain of it (whole labels)? */
private fun under(host: String, entry: String): Boolean = host == entry || host.endsWith(".$entry")

/**
 * The store's names: the first label of the registrable domain of each of its
 * hosts and auth hosts (widenings included) that is not a shared identity
 * host. Safeway (safeway.com, albertsons.com, albertsons.okta.com): safeway
 * and albertsons. Every Kroger banner: kroger.
 */
internal fun storeNames(hosts: StoreHosts): Set<String> =
    (hosts.hosts + hosts.authHosts).map(::normHost)
        .filter { h -> SHARED_IDENTITY_HOSTS.none { under(h, it) } }
        .map { registrableDomain(it).substringBefore('.') }
        .filter { it.isNotEmpty() }
        .toSet()

/**
 * Is `host` a shared identity host for a store with these names? It is when
 * it equals or is under an entry of [SHARED_IDENTITY_HOSTS], unless it is a
 * strict subdomain of the entry whose tenant label (the one just left of the
 * entry) is one of the store's names: login.okta.com is shared,
 * albertsons.okta.com is not for an Albertsons banner, kroger.okta.com is.
 */
internal fun sharedIdentityHost(host: String, names: Set<String>): Boolean {
    val h = normHost(host)
    for (e in SHARED_IDENTITY_HOSTS) {
        if (!under(h, e)) continue
        if (h == e) return true
        val tenant = h.removeSuffix(".$e").substringAfterLast('.')
        return tenant !in names
    }
    return false
}

/**
 * The hosts native blocking covers for a store: its own hosts, then its
 * sign-in hosts (the Albertsons Okta tenant, Kroger's login hosts), signed
 * widenings included, without repeats, leaving out shared identity
 * providers ([sharedIdentityHost]). protocol/shared-identity-hosts.json
 * spells out the rule with vectors.
 */
internal fun blockHostsFor(allowlist: Allowlist, store: String): List<String> {
    val h = allowlist.hostsFor(store) ?: return emptyList()
    val names = storeNames(h)
    return (h.hosts + h.authHosts).map(::normHost).distinct().filter { !sharedIdentityHost(it, names) }
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
 * [mainFrameAllowed] when they let a main-frame navigation go.
 */
internal open class BlockingWebViewClient(val block: NetworkBlock) : WebViewClient() {
    final override fun shouldInterceptRequest(view: WebView?, request: WebResourceRequest?): WebResourceResponse? {
        val url = request?.url?.toString()
        if (block.blocks(url)) return blockedResponse()
        // A new main document is requested (loadUrl, a form POST, a reload):
        // the page Mealio drove is going away, so blocking turns off before
        // the new page's own requests.
        if (request?.isForMainFrame == true) block.disarm()
        return null
    }

    /** A navigation of any frame to a blocked path on the store's hosts, while armed, is refused (true) before it starts. */
    protected fun navigationBlocked(request: WebResourceRequest): Boolean = block.blocks(request.url?.toString())

    /** shouldOverrideUrlLoading lets `request` go: a main-frame one is a new document, so blocking turns off. Returns false. */
    protected fun mainFrameAllowed(request: WebResourceRequest): Boolean {
        if (request.isForMainFrame) block.disarm()
        return false
    }
}
