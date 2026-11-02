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
val COMMON_AUTH_HOSTS: List<String> = listOf(
    "b2clogin.com", "ciamlogin.com", "login.microsoftonline.com", "okta.com", "auth0.com",
    "accounts.google.com", "appleid.apple.com", "facebook.com",
)

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
    out["wegmans"] = StoreHosts(listOf("wegmans.com"), emptyList())
    for ((id, d) in ALBERTSONS_BANNERS) out[id] = StoreHosts(listOf(d), listOf("albertsons.com"))
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

// Same expression as the reference: scheme, host (no port, no userinfo split),
// optional port, then path + query up to any fragment.
private val URL_RE = Regex("^([a-z][a-z0-9+.-]*)://([^/?#:]+)(?::\\d+)?([^#]*)", RegexOption.IGNORE_CASE)

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
        val m = URL_RE.find(url ?: "") ?: return UrlVerdict.no("bad_url")
        if (m.groupValues[1].lowercase() != "https") return UrlVerdict.no("not_https")
        val host = m.groupValues[2]
        val rest = m.groupValues[3].ifEmpty { "/" }
        val own = s.hosts.any { hostMatches(host, it) }
        val auth = use == UrlUse.LOGIN && (s.authHosts + COMMON_AUTH_HOSTS + MEALIO_HOSTS).any { hostMatches(host, it) }
        if (!own && !auth) return UrlVerdict.no("host")
        if (isBlockedPath(rest)) return UrlVerdict.no("blocked_path")
        return UrlVerdict.OK
    }
}

fun isBlockedPath(pathAndQuery: String?): Boolean = BLOCKED_RE.containsMatchIn(pathAndQuery ?: "")
