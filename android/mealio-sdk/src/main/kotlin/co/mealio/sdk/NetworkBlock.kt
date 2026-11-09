package co.mealio.sdk

import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import java.io.ByteArrayInputStream

// Native network blocking (PROTOCOL.md "When native blocking is on"). While
// Mealio runs a job, the requests the page makes to the current store's own
// hosts, in any frame, are asked of requestBlocked before they leave the
// device. A blocked one gets an empty 403 and never reaches the store. Page
// code cannot turn this off: it runs in the app, not in the page.
//
// Three limits keep it from breaking the store:
// - Only the store's hosts and its store-owned sign-in hosts (blockHostsFor).
//   A third-party host (a Stripe or captcha iframe) or a shared identity
//   provider (Google, Okta's own pages) is never blocked, whatever its path.
// - Only requests that change state (POST, PUT, PATCH, DELETE) and documents
//   (main-frame and subframe navigations, any method). A store's own page
//   assets (scripts, styles, images, fonts: GETs that are not documents) are
//   never blocked, whatever their path.
// - Only during a job. It turns on (arm) right before the first Mealio script
//   of a job and stays on for the whole job, across page navigations. It
//   turns off only when the job ends (done, failed or cancelled), the store
//   changes, or the sign-in sheet closes. Nothing the page does turns it off,
//   so there is no window between a navigation and its commit.
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

/** Methods that change state on the server. Only these (and documents) are ever blocked. */
internal val STATE_CHANGING_METHODS: Set<String> = setOf("POST", "PUT", "PATCH", "DELETE")

/**
 * Is this request a document (a frame navigation)? The main frame says so.
 * A subframe document is told by its Accept header, which the browser sets
 * to text/html (or application/xhtml+xml) for navigations and never for
 * scripts, styles, images, fonts or a default fetch.
 */
internal fun isDocumentRequest(mainFrame: Boolean, headers: Map<String, String>?): Boolean {
    if (mainFrame) return true
    val accept = headers?.entries?.firstOrNull { it.key.equals("Accept", ignoreCase = true) }?.value ?: return false
    val first = accept.substringBefore(',').substringBefore(';').trim().lowercase()
    return first == "text/html" || first == "application/xhtml+xml"
}

/**
 * One WebView's blocking state. Set on the main thread, read on WebView
 * background threads. Off until [arm]; [disarm] only when the job ends, the
 * store changes, or the sign-in sheet closes. Never at a navigation.
 */
internal class NetworkBlock {
    @Volatile private var hosts: List<String>? = null

    val armed: Boolean get() = hosts != null

    /** Turn on for these hosts (the current store's). Called right before each Mealio script; arming again only replaces the hosts. */
    fun arm(storeHosts: List<String>) {
        hosts = storeHosts.toList()
    }

    fun disarm() {
        hosts = null
    }

    /** Is `url` to a blocked path on the store's hosts, while armed? The path and host alone; see [blocksRequest]. */
    fun blocks(url: String?): Boolean {
        val h = hosts ?: return false
        return requestBlocked(url) && onHosts(url, h)
    }

    /**
     * Refuse this request? Only a state-changing method or a document, to a
     * blocked path on the store's hosts, while armed. A store's own assets
     * (a GET that is not a document) always pass.
     */
    fun blocksRequest(url: String?, method: String?, document: Boolean): Boolean {
        if (!document && (method ?: "GET").uppercase() !in STATE_CHANGING_METHODS) return false
        return blocks(url)
    }
}

/**
 * The WebViewClient both SDK WebViews use. shouldInterceptRequest is called
 * for every request of every frame (on a WebView background thread); it is
 * final so the hidden and login clients cannot lose it. Subclasses call
 * [navigationBlocked] first in shouldOverrideUrlLoading. No navigation turns
 * blocking off.
 */
internal open class BlockingWebViewClient(val block: NetworkBlock) : WebViewClient() {
    final override fun shouldInterceptRequest(view: WebView?, request: WebResourceRequest?): WebResourceResponse? {
        if (request == null) return null
        val document = isDocumentRequest(request.isForMainFrame, request.requestHeaders)
        if (block.blocksRequest(request.url?.toString(), request.method, document)) return blockedResponse()
        return null
    }

    /** A navigation of any frame (any method) to a blocked path on the store's hosts, while armed, is refused (true) before it starts. */
    protected fun navigationBlocked(request: WebResourceRequest): Boolean = block.blocks(request.url?.toString())
}
