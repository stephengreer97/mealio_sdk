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
    "place[-_]?order",
    "submit[-_]?order",
    "order[-_]?confirm",
    "gift-?card",
    "/account/(delete|close|security|password)",
    "/addresses?/(add|edit|delete|new)",
    "/orders?/(submit|place)(/|\\?|$)",
    "/cart/confirm",
    "/purchase(/|\\?|$)",
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
private val FORM_FIELD_RE = Regex("(?:^|&)(operationName|query|operations)=([^&]*)")
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

/** JavaScript's line terminators: `.` in a JS regex stops at these. */
private fun isLineEnd(c: Char) = c == '\n' || c == '\r' || c == '\u2028' || c == '\u2029'

private fun isNameStart(c: Char) = c in 'A'..'Z' || c in 'a'..'z' || c == '_'
private fun isNamePart(c: Char) = isNameStart(c) || c in '0'..'9'

/**
 * Names and the tokens ... { } ( ) : @ of a GraphQL document, with block
 * strings (\""" inside them included), strings and comments left out. A hand-written scanner rather than the
 * reference's regex, which java.util.regex can overflow its stack on with a
 * long string; it reads the same tokens.
 */
private fun graphqlTokens(doc: String): List<String> {
    val out = ArrayList<String>()
    var i = 0
    val n = doc.length
    while (i < n) {
        val c = doc[i]
        if (c == '"') {
            if (doc.startsWith("\"\"\"", i)) {
                // """(?:\\"""|[\s\S])*?""": the first """ not escaped as \""" ends
                // it. With none, the regex backtracks: the last \""" ends it.
                var j = i + 3
                var end = -1
                var lastEscaped = -1
                while (j < n) {
                    if (doc.startsWith("\"\"\"", j)) { end = j; break }
                    if (doc[j] == '\\' && doc.startsWith("\"\"\"", j + 1)) { lastEscaped = j; j += 4; continue }
                    j += 1
                }
                if (end < 0 && lastEscaped >= 0) end = lastEscaped + 1
                if (end >= 0) { i = end + 3; continue }
            }
            // "(?:[^"\\]|\\.)*": a backslash escapes any one character but a line end.
            var j = i + 1
            var closed = -1
            while (j < n) {
                val d = doc[j]
                if (d == '"') { closed = j; break }
                if (d == '\\') {
                    if (j + 1 < n && !isLineEnd(doc[j + 1])) { j += 2; continue }
                    break
                }
                j += 1
            }
            i = if (closed >= 0) closed + 1 else i + 1
            continue
        }
        if (c == '#') {
            while (i < n && doc[i] != '\n' && doc[i] != '\r') i += 1
            continue
        }
        if (c == '.' && doc.startsWith("...", i)) { out.add("..."); i += 3; continue }
        if (c == '{' || c == '}' || c == '(' || c == ')' || c == ':' || c == '@') { out.add(c.toString()); i += 1; continue }
        if (isNameStart(c)) {
            val start = i
            while (i < n && isNamePart(doc[i])) i += 1
            out.add(doc.substring(start, i))
            continue
        }
        i += 1
    }
    return out
}

/**
 * The names a GraphQL document's mutations are judged by: each mutation's own
 * name, and its ROOT fields. A root field is a field in the mutation's top
 * selection set, in an inline fragment at that level (`... on Mutation { x }`),
 * or at the top of a fragment spread there (followed through further spreads).
 * Aliases, nested fields, arguments, variables, directives, strings and
 * comments are never names. A query, subscription or fragment on its own gives
 * none, so a mutation may select `cart { checkoutUrl }` and a query may read
 * `paymentMethods`. Port of mutationNames in packages/core/src/allowlist.ts.
 */
fun mutationNames(doc: String): List<String> {
    class Def(val kind: String) {
        var name = ""
        val fields = ArrayList<String>()
        val spreads = ArrayList<String>()
    }
    val defs = ArrayList<Def>()
    var def: Def? = null
    // One entry per open selection set: true when it is at its definition's root.
    val sets = ArrayList<Boolean>()
    var parens = 0
    var inline = false
    var expect = ""
    var pushed = false
    for (t in graphqlTokens(doc)) {
        val was = pushed
        pushed = false
        if (t == "(") { parens += 1; continue }
        if (t == ")") { parens = maxOf(0, parens - 1); continue }
        if (parens > 0) continue
        if (t == "@") { expect = "directive"; continue }
        if (t == "{") {
            if (def == null) { def = Def("query"); defs.add(def) }
            sets.add(sets.isEmpty() || (inline && sets.last()))
            inline = false; expect = ""
            continue
        }
        if (t == "}") {
            if (sets.isNotEmpty()) sets.removeAt(sets.size - 1)
            inline = false; expect = ""
            if (sets.isEmpty()) def = null
            continue
        }
        if (sets.isEmpty()) {
            // A definition's header: its keyword, its name, and nothing else counts.
            if (expect == "directive") expect = ""
            else if (def == null && t in GRAPHQL_KINDS) { def = Def(t); defs.add(def) }
            else if (def != null && def.name.isEmpty() && t != "on" && t != ":" && t != "...") def.name = t
            continue
        }
        val root = sets.last()
        if (t == "...") { expect = "spread"; inline = true; continue }
        if (t == ":") { if (was && def != null) def.fields.removeAt(def.fields.size - 1); continue }
        if (expect == "directive" || expect == "type") { expect = ""; continue }
        if (expect == "spread") {
            expect = ""
            if (t == "on") { expect = "type"; continue }
            inline = false
            if (root && def != null) def.spreads.add(t)
            continue
        }
        inline = false
        if (root && def != null) { def.fields.add(t); pushed = true }
    }
    // new Map(entries) in the reference: a later fragment of the same name replaces an earlier one.
    val fragments = HashMap<String, Def>()
    for (d in defs) if (d.kind == "fragment") fragments[d.name] = d
    val names = ArrayList<String>()
    for (d in defs) {
        if (d.kind != "mutation") continue
        if (d.name.isNotEmpty()) names.add(d.name)
        val seen = HashSet<String>()
        fun walk(x: Def) {
            names.addAll(x.fields)
            for (sp in x.spreads) {
                val f = fragments[sp]
                if (f != null && seen.add(sp)) walk(f)
            }
        }
        walk(d)
    }
    return names
}

private val GRAPHQL_KINDS = setOf("mutation", "query", "subscription", "fragment")

/**
 * The fields of a multipart/form-data body sent as raw text: every match of
 * MULTIPART_FIELD in packages/core/src/allowlist.ts, in order, as (name,
 * value):
 *
 *   name=["']?(operationName|query|operations)(?=["';\s]|$)[^\r\n]*\r?\n(?:[^\r\n]+\r?\n)*\r?\n([\s\S]*?)(?=\r?\n--|$)
 *
 * Read by hand: java.util.regex recurses once per header line of the
 * `(?:...)*` group, so a part with a few thousand header lines overflowed the
 * stack. The pattern never needs to backtrack into a line it has read, so a
 * scan finds the same matches. The name may be double-quoted, single-quoted or
 * bare; `operationsX` is another field.
 *
 * Linear in the body length (0.6 round 6): a port, line for line, of
 * multipartFields in packages/core/src/allowlist.ts. Two caches keep it
 * linear. The header line's first break is cached as a range: every later
 * name before that break shares it. The header-lines outcome is cached for
 * the run of lines it walked: a later header that ends inside that run
 * reaches the same blank line (or the same failure).
 */
internal fun multipartFields(b: String): List<Pair<String, String>> {
    val out = ArrayList<Pair<String, String>>()
    val n = b.length
    // nextBreak(p) for p in [brkFrom, brkAt] is brkAt.
    var brkFrom = -1
    var brkAt = -1
    // valueStart(p) for p in [runFrom, runTo] is runValue (-1: no match).
    var runFrom = -1
    var runTo = -1
    var runValue = -1
    var from = 0
    fun eol(c: Char) = c == '\r' || c == '\n'
    while (true) {
        val c = b.indexOf("name=", from)
        if (c < 0) break
        from = c + 1
        var k = c + 5
        if (k < n && (b[k] == '"' || b[k] == '\'')) k++
        val name = MULTIPART_NAMES.firstOrNull { b.startsWith(it, k) } ?: continue
        val j = k + name.length
        if (j < n && b[j] != '"' && b[j] != '\'' && b[j] != ';' && !isJsSpace(b[j])) continue
        // The header line.
        val q: Int
        if (j in brkFrom..brkAt) q = brkAt
        else {
            var e = j
            while (e < n && !eol(b[e])) e++
            q = e
            brkFrom = j; brkAt = q
        }
        val p = when {
            q < n && b[q] == '\n' -> q + 1
            q + 1 < n && b[q] == '\r' && b[q + 1] == '\n' -> q + 2
            else -> continue
        }
        // Header lines, then the blank line.
        val v: Int
        if (p in runFrom..runTo) v = runValue
        else {
            var s = p
            var found = -1
            while (s < n) {
                val h = b[s]
                if (h == '\n') { found = s + 1; break }
                if (h == '\r') { if (s + 1 < n && b[s + 1] == '\n') found = s + 2; break }
                var e = s
                while (e < n && !eol(b[e])) e++
                s = when {
                    e < n && b[e] == '\n' -> e + 1
                    e + 1 < n && b[e] == '\r' && b[e + 1] == '\n' -> e + 2
                    else -> break
                }
            }
            v = found
            runFrom = p; runTo = s; runValue = v
        }
        if (v < 0) continue
        // The value: up to the first \r?\n-- after it, or the end.
        var end = b.indexOf("\n--", v)
        if (end < 0) end = n
        else if (end > v && b[end - 1] == '\r') end--
        out.add(name to b.substring(v, end))
        from = end
    }
    return out
}

private val MULTIPART_NAMES = listOf("operationName", "query", "operations")

/** JavaScript's `\s`. */
private fun isJsSpace(c: Char) = c == ' ' || c in '\t'..'\r' || c == '\u00a0' || c == '\u1680' || c in '\u2000'..'\u200a' ||
    c == '\u2028' || c == '\u2029' || c == '\u202f' || c == '\u205f' || c == '\u3000' || c == '\ufeff'

/**
 * Does a request body name a blocked operation? Reads `operationName` the way
 * the server will (after JSON parsing, so `\\u004f` escapes do not hide it),
 * for a single request or a batch, or form-encoded, and the names of every
 * mutation it carries (see mutationNames). A GraphQL multipart upload's
 * `operations` field is JSON and is judged like a JSON body. A persisted query that sends only an innocent
 * name and a hash cannot be read here; the signature on the envelope covers it.
 * The guard script applies the same rule to requests a page script makes; this
 * applies it to the runner's own `fetch` op, which never passes through the page.
 */
/**
 * How many times a body may nest inside an `operations` field (form-encoded
 * or a raw multipart part) and still be read. One nested deeper is blocked.
 */
const val BODY_MAX_DEPTH = 8

/**
 * The longest body (UTF-16 code units, after a leading byte order mark is
 * dropped) that is read. A longer one is blocked without being read: it could
 * hide a blocked name in escapes no text match would see.
 */
const val BODY_MAX_TEXT = 1048576

fun bodyBlocked(body: String?): Boolean = try {
    bodyBlockedAt(body, 0)
} catch (e: StackOverflowError) {
    // A body built to exhaust the stack (regex backtracking, nested fragments) is never sent.
    true
}

private fun bodyBlockedAt(body: String?, depth: Int): Boolean {
    if (body == null) return false
    // A leading byte order mark is dropped, as a server's JSON reader would.
    val text = body.removePrefix("\uFEFF")
    if (text.isEmpty()) return false
    if (depth > BODY_MAX_DEPTH) return true
    // Too long to read: blocked unread. Store requests are far smaller.
    if (text.length > BODY_MAX_TEXT) return true
    val names = ArrayList<String>()
    val docs = ArrayList<String>()
    for (m in OPERATION_NAME_RE.findAll(text)) names.add(m.groupValues[1])
    // Strict, as JSON.parse: text org.json would bend into JSON (single
    // quotes, bare words, comments) is judged as a document instead.
    val j = StrictJson.parse(text)
    if (j !== StrictJson.INVALID) {
        val list: List<Any?> = if (j is List<*>) j else listOf(j)
        for (o in list) {
            if (o !is Map<*, *>) continue
            (o["operationName"] as? String)?.let { names.add(it) }
            (o["query"] as? String)?.let { docs.add(it) }
        }
    } else {
        // Not JSON: form-encoded, raw multipart, or a bare GraphQL document.
        val body = text
        docs.add(body)
        for (m in FORM_FIELD_RE.findAll(body)) {
            val v = decodePercent(m.groupValues[2].replace('+', ' '))
            when (m.groupValues[1]) {
                "query" -> docs.add(v)
                // GraphQL multipart: `operations` is JSON, judged like a JSON body.
                "operations" -> if (bodyBlockedAt(v, depth + 1)) return true
                else -> names.add(v)
            }
        }
        for ((field, v) in multipartFields(body)) {
            when (field) {
                "query" -> docs.add(v)
                "operations" -> if (bodyBlockedAt(v, depth + 1)) return true
                else -> names.add(v)
            }
        }
    }
    for (d in docs) names.addAll(mutationNames(d))
    return names.any { OPS_RE.containsMatchIn(it) }
}
