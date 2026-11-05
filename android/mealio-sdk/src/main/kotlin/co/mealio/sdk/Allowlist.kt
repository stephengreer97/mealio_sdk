package co.mealio.sdk

// The allowlist. It lives in the SDK so a compromised server cannot turn it
// off. PROTOCOL.md "Allowlist" is the spec; packages/core/src/allowlist.ts is
// the reference this ports.

/** Never relaxed remotely. Case-insensitive, tested against path + query. */
val BLOCKED_PATTERNS: List<String> = listOf(
    "checkout",
    "payment",
    "billing",
    "wallet",
    "place-?order",
    "submit-?order",
    "order-?confirm",
    "gift-?card",
    "/account/(delete|close|security|password)",
    "/addresses?/(add|edit|delete|new)",
)

private val BLOCKED_RE = Regex(BLOCKED_PATTERNS.joinToString("|"), RegexOption.IGNORE_CASE)

data class StoreHosts(
    /** The store's own hosts. Subdomains are allowed too. */
    val hosts: List<String>,
    /** Hosts the login sheet may visit (identity providers). */
    val authHosts: List<String>,
)

/** Hosts every store's login may return to. */
val MEALIO_HOSTS: List<String> = listOf("mealio.co")

/**
 * Identity providers a store's login page may hand off to, for every store.
 * Only TOP-FRAME navigations in the login sheet are checked; captcha and
 * consent iframes inside a store page are not navigations of the sheet.
 */
val COMMON_AUTH_HOSTS: List<String> = listOf("accounts.google.com", "appleid.apple.com", "facebook.com")

/**
 * Multi-tenant identity providers, ONLY for the store that uses them. Anyone
 * can register a tenant on okta.com or b2clogin.com, so allowing the whole
 * provider for every store let any tenant's page into the sign-in sheet.
 * Albertsons signs in through its own Okta tenant. Wegmans uses Azure AD B2C,
 * whose tenant host the page reads at run time, so B2C stays provider-wide but
 * for Wegmans alone.
 */
val ALBERTSONS_AUTH_HOSTS: List<String> = listOf("albertsons.com", "albertsons.okta.com")
val WEGMANS_AUTH_HOSTS: List<String> = listOf("b2clogin.com", "ciamlogin.com", "login.microsoftonline.com")

// Store ids match mealio_app/src/constants/stores.ts and the server catalog.
private val ALBERTSONS_BANNERS: Map<String, String> = linkedMapOf(
    "albertsons" to "albertsons.com", "safeway" to "safeway.com", "vons" to "vons.com", "jewel_osco" to "jewelosco.com",
    "shaws" to "shaws.com", "acme" to "acmemarkets.com", "tom_thumb" to "tomthumb.com", "randalls" to "randalls.com",
    "pavilions" to "pavilions.com", "star_market" to "starmarket.com", "haggen" to "haggen.com", "carrs" to "carrsqc.com",
    "kings" to "kingsfoodmarkets.com", "balduccis" to "balduccis.com", "united" to "shopunitedsupermarkets.com",
)

private val INSTACART_TENANTS: Map<String, String> = linkedMapOf(
    "aldi" to "aldi.us", "publix" to "delivery.publix.com", "bristol_farms" to "shop.bristolfarms.com",
    "save_mart" to "shop.savemart.com", "gelsons" to "shop.gelsons.com", "dierbergs" to "shop.dierbergs.com",
    "sprouts" to "shop.sprouts.com", "the_fresh_market" to "shop.thefreshmarket.com", "costco_sameday" to "sameday.costco.com",
)

private val KROGER_BANNERS: List<String> = listOf(
    "kroger", "bakers", "city_market", "dillons", "fred_meyer", "frys", "harris_teeter", "king_soopers",
    "marianos", "metro_market", "pay_less", "pick_n_save", "qfc", "ralphs", "smiths",
)

private fun bundled(): Map<String, StoreHosts> {
    val out = LinkedHashMap<String, StoreHosts>()
    out["heb"] = StoreHosts(listOf("heb.com"), emptyList())
    out["wegmans"] = StoreHosts(listOf("wegmans.com"), WEGMANS_AUTH_HOSTS.toList())
    for ((id, d) in ALBERTSONS_BANNERS) out[id] = StoreHosts(listOf(d), ALBERTSONS_AUTH_HOSTS.toList())
    for ((id, d) in INSTACART_TENANTS) out[id] = StoreHosts(listOf(d), listOf("instacart.com"))
    // The Kroger family is server-side through Kroger's API. The SDK only ever
    // shows Kroger's OAuth consent page.
    for (id in KROGER_BANNERS) out[id] = StoreHosts(emptyList(), listOf("api.kroger.com", "login.kroger.com", "kroger.com"))
    return out
}

/** The bundled allowlist. */
val STORES: Map<String, StoreHosts> = bundled()

/** Last two labels, with a short list of two-label public suffixes. */
fun registrableDomain(host: String): String {
    val parts = host.lowercase().split('.').filter { it.isNotEmpty() }
    if (parts.size <= 2) return parts.joinToString(".")
    val last2 = parts.takeLast(2).joinToString(".")
    if (last2 in listOf("co.uk", "com.au", "co.nz")) return parts.takeLast(3).joinToString(".")
    return last2
}

private fun hostMatches(host: String, allowed: String): Boolean {
    val h = host.lowercase()
    val a = allowed.lowercase()
    return h == a || h.endsWith(".$a")
}

enum class UrlUse { PAGE, FETCH, LOGIN }

/** Why a URL was refused. Null reason means allowed. */
data class UrlVerdict(val ok: Boolean, val reason: String? = null) {
    companion object {
        val OK = UrlVerdict(true)
        fun no(reason: String) = UrlVerdict(false, reason)
    }
}

/** A URL split the way the reference parseUrl splits it. */
data class ParsedUrl(val scheme: String, val host: String, val rest: String)

// Backslash, whitespace (JS \s, which includes the Unicode spaces) and control
// characters anywhere refuse the URL.
private val URL_BAD_CHARS = Regex("[\\\\\\s\\x00-\\x1f\\x7f\\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000\\ufeff]")
private val URL_RE = Regex("^([a-z][a-z0-9+.-]*)://([^/?#]*)([^#]*)", RegexOption.IGNORE_CASE)
private val AUTHORITY_RE = Regex("^([a-z0-9-]+(?:\\.[a-z0-9-]+)*)(?::\\d{1,5})?$", RegexOption.IGNORE_CASE)
private val PERCENT_RE = Regex("%([0-9a-fA-F]{2})")
private val OPERATION_NAME_RE = Regex("\"operationName\"\\s*:\\s*\"([^\"]*)\"")
private val MUTATION_RE = Regex("\\bmutation\\s+([A-Za-z_][A-Za-z0-9_]*)")
private val OPS_RE = Regex(BLOCKED_GRAPHQL_OPERATION, RegexOption.IGNORE_CASE)

/**
 * Split a URL into scheme, host and path + query, or null if it is not one we
 * will reason about. STRICT on purpose: the authority must be a bare host name
 * with an optional port. A browser reads `https://www.heb.com:x@evil.com/` as
 * host evil.com, and `https://evil.com\\.heb.com/` as host evil.com too, while
 * a looser pattern read both as heb.com. So userinfo (@), backslashes,
 * whitespace and control characters anywhere are refused outright, as is any
 * host that is not plain ASCII letters, digits, dots and hyphens.
 */
fun parseUrl(url: String?): ParsedUrl? {
    val raw = url ?: ""
    if (URL_BAD_CHARS.containsMatchIn(raw)) return null
    val m = URL_RE.find(raw) ?: return null
    val a = AUTHORITY_RE.find(m.groupValues[2]) ?: return null
    val rest = m.groupValues[3].ifEmpty { "/" }
    return ParsedUrl(
        scheme = m.groupValues[1].lowercase(),
        host = a.groupValues[1].lowercase(),
        rest = if (rest.startsWith("/") || rest.startsWith("?")) rest else "/$rest",
    )
}

/** Percent-decoding, twice, of %XX only: a server decodes `%63heckout` to `checkout`. */
fun decodePercent(s: String): String {
    var out = s
    repeat(2) { out = PERCENT_RE.replace(out) { r -> r.groupValues[1].toInt(16).toChar().toString() } }
    return out
}

class Allowlist(base: Map<String, StoreHosts> = STORES) {
    private class Mutable(val hosts: MutableList<String>, val authHosts: MutableList<String>)

    private val stores = LinkedHashMap<String, Mutable>().also { m ->
        for ((k, v) in base) m[k] = Mutable(v.hosts.toMutableList(), v.authHosts.toMutableList())
    }

    /**
     * Widen hosts from a signed allowlist payload. A new host must share a
     * registrable domain with a host already listed for that store; anything
     * else is ignored. Stores the SDK does not know are ignored.
     */
    @Synchronized
    fun widen(p: AllowlistPayload) {
        for ((store, add) in p.stores) {
            val cur = stores[store] ?: continue
            val known = (cur.hosts + cur.authHosts).map(::registrableDomain).toSet()
            for (h in add.hosts) if (registrableDomain(h) in known && h !in cur.hosts) cur.hosts.add(h)
            for (h in add.authHosts) if (registrableDomain(h) in known && h !in cur.authHosts) cur.authHosts.add(h)
        }
    }

    @Synchronized
    fun hostsFor(store: String): StoreHosts? = stores[store]?.let { StoreHosts(it.hosts.toList(), it.authHosts.toList()) }

    @Synchronized
    fun check(store: String, url: String?, use: UrlUse): UrlVerdict {
        val s = stores[store] ?: return UrlVerdict.no("unknown_store")
        val p = parseUrl(url) ?: return UrlVerdict.no("bad_url")
        if (p.scheme != "https") return UrlVerdict.no("not_https")
        val host = p.host
        val rest = p.rest
        val own = s.hosts.any { hostMatches(host, it) }
        val auth = use == UrlUse.LOGIN && (s.authHosts + COMMON_AUTH_HOSTS + MEALIO_HOSTS).any { hostMatches(host, it) }
        if (!own && !auth) return UrlVerdict.no("host")
        if (isBlockedPath(rest)) return UrlVerdict.no("blocked_path")
        return UrlVerdict.OK
    }
}

fun isBlockedPath(pathAndQuery: String?): Boolean {
    val s = pathAndQuery ?: ""
    return BLOCKED_RE.containsMatchIn(s) || BLOCKED_RE.containsMatchIn(decodePercent(s))
}

/**
 * Does a request body name a blocked operation? Reads `operationName` the way
 * the server will (after JSON parsing, so `\\u004f` escapes do not hide it),
 * for a single request or a batch, and the names of any mutations in `query`.
 * The guard script applies the same rule to requests a page script makes; this
 * applies it to the runner's own `fetch` op, which never passes through the page.
 */
fun bodyBlocked(body: String?): Boolean {
    if (body.isNullOrEmpty()) return false
    val names = ArrayList<String>()
    for (m in OPERATION_NAME_RE.findAll(body)) names.add(m.groupValues[1])
    try {
        val list: List<Any?> = when (val j = org.json.JSONTokener(body).nextValue()) {
            is org.json.JSONArray -> (0 until j.length()).map { j.opt(it) }
            is org.json.JSONObject -> listOf(j)
            else -> emptyList()
        }
        for (o in list) {
            if (o !is org.json.JSONObject) continue
            (o.opt("operationName") as? String)?.let { names.add(it) }
            val q = o.opt("query") as? String
            if (q != null) for (m in MUTATION_RE.findAll(q)) names.add(m.groupValues[1])
        }
    } catch (e: Exception) {
        // not JSON: the raw scan above stands
    }
    return names.any { OPS_RE.containsMatchIn(it) }
}
