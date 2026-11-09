// The allowlist. It lives in the SDK so a compromised server cannot turn it
// off. PROTOCOL.md "Allowlist" is the spec; packages/core/src/allowlist.ts is
// the reference this mirrors.

import Foundation

public struct StoreHosts: Equatable {
    /// The store's own hosts. Subdomains are allowed too.
    public var hosts: [String]
    /// Hosts the login sheet may visit (identity providers).
    public var authHosts: [String]

    public init(hosts: [String], authHosts: [String]) {
        self.hosts = hosts
        self.authHosts = authHosts
    }
}

public enum UrlUse: String {
    case page, fetch, login
}

public enum UrlVerdict: Equatable {
    case allowed
    case refused(Reason)

    public enum Reason: String {
        case badUrl = "bad_url"
        case notHttps = "not_https"
        case host
        case blockedPath = "blocked_path"
        case unknownStore = "unknown_store"
    }

    public var ok: Bool { self == .allowed }
}

public final class Allowlist {
    /// Never relaxed remotely. Case-insensitive, tested against path + query.
    public static let blockedPatterns: [String] = [
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
    ]

    /// Hosts every store's login may return to.
    public static let mealioHosts: [String] = ["mealio.co"]

    /// Identity providers a store's login page may hand off to, for every store.
    /// Only top-frame navigations in the login sheet are checked; captcha and
    /// consent iframes inside a store page are not navigations of the sheet.
    public static let commonAuthHosts: [String] = ["accounts.google.com", "appleid.apple.com", "facebook.com"]

    /// Multi-tenant identity providers, ONLY for the store that uses them. Anyone
    /// can register a tenant on okta.com or b2clogin.com, so allowing the whole
    /// provider for every store let any tenant's page into the sign-in sheet.
    /// Albertsons signs in through its own Okta tenant. Wegmans uses Azure AD B2C,
    /// whose tenant host the page reads at run time, so B2C stays provider-wide but
    /// for Wegmans alone.
    public static let albertsonsAuthHosts: [String] = ["albertsons.com", "albertsons.okta.com"]
    public static let wegmansAuthHosts: [String] = ["b2clogin.com", "ciamlogin.com", "login.microsoftonline.com"]

    // Store ids match mealio_app/src/constants/stores.ts and the server catalog.
    private static let albertsonsBanners: [String: String] = [
        "albertsons": "albertsons.com", "safeway": "safeway.com", "vons": "vons.com", "jewel_osco": "jewelosco.com",
        "shaws": "shaws.com", "acme": "acmemarkets.com", "tom_thumb": "tomthumb.com", "randalls": "randalls.com",
        "pavilions": "pavilions.com", "star_market": "starmarket.com", "haggen": "haggen.com", "carrs": "carrsqc.com",
        "kings": "kingsfoodmarkets.com", "balduccis": "balduccis.com", "united": "shopunitedsupermarkets.com",
    ]

    private static let instacartTenants: [String: String] = [
        "aldi": "aldi.us", "publix": "delivery.publix.com", "bristol_farms": "shop.bristolfarms.com",
        "save_mart": "shop.savemart.com", "gelsons": "shop.gelsons.com", "dierbergs": "shop.dierbergs.com",
        "sprouts": "shop.sprouts.com", "the_fresh_market": "shop.thefreshmarket.com", "costco_sameday": "sameday.costco.com",
    ]

    private static let krogerBanners: [String] = [
        "kroger", "bakers", "city_market", "dillons", "fred_meyer", "frys", "harris_teeter", "king_soopers",
        "marianos", "metro_market", "pay_less", "pick_n_save", "qfc", "ralphs", "smiths",
    ]

    /// The bundled allowlist, by store id.
    public static let bundledStores: [String: StoreHosts] = {
        var out: [String: StoreHosts] = [
            "heb": StoreHosts(hosts: ["heb.com"], authHosts: []),
            "wegmans": StoreHosts(hosts: ["wegmans.com"], authHosts: wegmansAuthHosts),
        ]
        for (id, d) in albertsonsBanners { out[id] = StoreHosts(hosts: [d], authHosts: albertsonsAuthHosts) }
        for (id, d) in instacartTenants { out[id] = StoreHosts(hosts: [d], authHosts: ["instacart.com"]) }
        // The Kroger family is server-side through Kroger's API. The SDK only
        // ever shows Kroger's OAuth consent page.
        for id in krogerBanners {
            out[id] = StoreHosts(hosts: [], authHosts: ["api.kroger.com", "login.kroger.com", "kroger.com"])
        }
        return out
    }()

    private static let blockedRegex: NSRegularExpression = {
        // The patterns are constants; a bad one is a programming error.
        try! NSRegularExpression(pattern: blockedPatterns.joined(separator: "|"), options: [.caseInsensitive])
    }()

    // The TS parseUrl. Character classes are spelled out in ASCII instead of
    // using .caseInsensitive, because ICU case folding would let a non-ASCII
    // letter such as the Kelvin sign match [a-z]; JS without the u flag does not.
    private static let refusedCharRegex: NSRegularExpression = {
        // /[\\\s\u0000-\u001f\u007f]/ (\ufeff is in JS \s but not ICU's)
        try! NSRegularExpression(pattern: #"[\\\s\u0000-\u001f\u007f\ufeff]"#, options: [])
    }()

    private static let urlRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"^([A-Za-z][A-Za-z0-9+.-]*)://([^/?#]*)([^#]*)"#, options: [])
    }()

    private static let authorityRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"^([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*)(?::[0-9]{1,5})?\z"#, options: [])
    }()

    private static let blockedOperationRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: MealioScripts.blockedGraphQLOperation, options: [.caseInsensitive])
    }()

    private static let operationNameRegex: NSRegularExpression = {
        // JS \s is ICU \s plus \v and U+FEFF.
        try! NSRegularExpression(pattern: #""operationName"[\s\u000b\ufeff]*:[\s\u000b\ufeff]*"([^"]*)""#, options: [])
    }()

    /// Strings, block strings and comments, which hold no GraphQL names.
    private static let gqlNoiseRegex: NSRegularExpression = {
        // Starts with a group: a raw string may not open with three quotes.
        // JS `.` is any character but \n, \r, U+2028 and U+2029; ICU's `.`
        // also stops at \v, \f and U+0085, so the escape is spelled out.
        try! NSRegularExpression(pattern: #"(?:"""(?:\\"""|[\s\S])*?""")|"(?:[^"\\]|\\[^\n\r\u2028\u2029])*"|#[^\n\r]*"#, options: [])
    }()

    private static let gqlTokenRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"[A-Za-z_][A-Za-z0-9_]*|\.\.\.|[{}():@]"#, options: [])
    }()

    private static let formFieldRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"(?:^|&)(operationName|query|operations)=([^&]*)"#, options: [])
    }()

    /// MULTIPART_FIELD in allowlist.ts: a field of a multipart/form-data body
    /// sent as raw text. Group 1 is the field's name, group 2 its value. JS's
    /// `$` (no m flag) is the very end of the text, which ICU spells `\z`.
    /// The name may be double-quoted, single-quoted or bare; a longer name
    /// (`operationsX`) is a different field.
    ///
    /// This is the SPEC, not the implementation: run as a regex it takes time
    /// quadratic in the body. `multipartFields` finds the same matches in one
    /// pass; tests check it against this regex.
    public static let multipartField = #"name=["']?(operationName|query|operations)(?=["';\s]|$)[^\r\n]*\r?\n(?:[^\r\n]+\r?\n)*\r?\n([\s\S]*?)(?=\r?\n--|$)"#
    /// MULTIPART_FIELD as a regex, for tests that check `multipartFields`.
    static let multipartFieldRegex: NSRegularExpression = {
        // ICU spellings: `$` is `\z`, and JS \s adds \v and U+FEFF to ICU's.
        let icu = multipartField
            .replacingOccurrences(of: "|$)", with: "|\\z)")
            .replacingOccurrences(of: #"["';\s]"#, with: #"["';\s\u000b\ufeff]"#)
        return try! NSRegularExpression(pattern: icu, options: [])
    }()

    /// A URL split into scheme, host and path + query, or nil if it is not one
    /// we will reason about. STRICT on purpose: the authority must be a bare host
    /// name with an optional port. A browser reads `https://www.heb.com:x@evil.com/`
    /// as host evil.com, and `https://evil.com\.heb.com/` as host evil.com too,
    /// while a looser pattern read both as heb.com. So userinfo (@), backslashes,
    /// whitespace and control characters anywhere are refused outright, as is any
    /// host that is not plain ASCII letters, digits, dots and hyphens.
    public static func parseUrl(_ url: String?) -> (scheme: String, host: String, rest: String)? {
        let raw = url ?? ""
        let ns = raw as NSString
        let all = NSRange(location: 0, length: ns.length)
        if refusedCharRegex.firstMatch(in: raw, options: [], range: all) != nil { return nil }
        guard let m = urlRegex.firstMatch(in: raw, options: [], range: all) else { return nil }
        func group(_ i: Int) -> String {
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
        let authority = group(2)
        let an = authority as NSString
        guard let a = authorityRegex.firstMatch(in: authority, options: [], range: NSRange(location: 0, length: an.length)) else {
            return nil
        }
        let host = an.substring(with: a.range(at: 1))
        var rest = group(3)
        if rest.isEmpty { rest = "/" }
        if !rest.hasPrefix("/") && !rest.hasPrefix("?") { rest = "/" + rest }
        return (group(1).lowercased(), host.lowercased(), rest)
    }

    /// Percent-decoding, twice, of %XX only: a server decodes `%63heckout` to `checkout`.
    public static func decodePercent(_ s: String) -> String {
        var units = Array(s.utf16)
        for _ in 0..<2 {
            var out: [UInt16] = []
            out.reserveCapacity(units.count)
            var i = 0
            while i < units.count {
                if units[i] == 0x25, i + 2 < units.count,
                   let hi = hexValue(units[i + 1]), let lo = hexValue(units[i + 2]) {
                    out.append(UInt16(hi * 16 + lo))
                    i += 3
                } else {
                    out.append(units[i])
                    i += 1
                }
            }
            units = out
        }
        return String(decoding: units, as: UTF16.self)
    }

    private static func hexValue(_ u: UInt16) -> Int? {
        switch u {
        case 0x30...0x39: return Int(u - 0x30)
        case 0x41...0x46: return Int(u - 0x41 + 10)
        case 0x61...0x66: return Int(u - 0x61 + 10)
        default: return nil
        }
    }

    /// The names a GraphQL document's mutations are judged by: each
    /// mutation's own name, and its ROOT fields. A root field is a field in the
    /// mutation's top selection set, in an inline fragment at that level
    /// (`... on Mutation { x }`), or at the top of a fragment spread there
    /// (followed through further spreads). Aliases, nested fields, arguments,
    /// variables, directives, strings and comments are never names. A query,
    /// subscription or fragment on its own gives none, so a mutation may select
    /// `cart { checkoutUrl }` and a query may read `paymentMethods`. Mirrors
    /// `mutationNames` in allowlist.ts.
    public static func mutationNames(_ doc: String) -> [String] {
        let dn = doc as NSString
        let text = gqlNoiseRegex.stringByReplacingMatches(in: doc, options: [], range: NSRange(location: 0, length: dn.length), withTemplate: " ")
        let tn = text as NSString
        let tokens = gqlTokenRegex.matches(in: text, options: [], range: NSRange(location: 0, length: tn.length)).map { tn.substring(with: $0.range) }
        var defs: [GraphQLDefinition] = []
        var def: GraphQLDefinition?
        // One entry per open selection set: true when it is at its definition's root.
        var sets: [Bool] = []
        var parens = 0
        var inline = false, pushed = false
        var expect = ""
        for t in tokens {
            let was = pushed
            pushed = false
            if t == "(" { parens += 1; continue }
            if t == ")" { parens = max(0, parens - 1); continue }
            if parens > 0 { continue }
            if t == "@" { expect = "directive"; continue }
            if t == "{" {
                if def == nil {
                    let d = GraphQLDefinition(kind: "query")
                    def = d
                    defs.append(d)
                }
                sets.append(sets.isEmpty || (inline && sets[sets.count - 1]))
                inline = false
                expect = ""
                continue
            }
            if t == "}" {
                _ = sets.popLast()
                inline = false
                expect = ""
                if sets.isEmpty { def = nil }
                continue
            }
            if sets.isEmpty {
                // A definition's header: its keyword, its name, and nothing else counts.
                if expect == "directive" {
                    expect = ""
                } else if def == nil && ["query", "mutation", "subscription", "fragment"].contains(t) {
                    let d = GraphQLDefinition(kind: t)
                    def = d
                    defs.append(d)
                } else if let d = def, d.name.isEmpty, t != "on", t != ":", t != "..." {
                    d.name = t
                }
                continue
            }
            let root = sets[sets.count - 1]
            if t == "..." { expect = "spread"; inline = true; continue }
            if t == ":" {
                if was, let d = def { _ = d.fields.popLast() }
                continue
            }
            if expect == "directive" || expect == "type" { expect = ""; continue }
            if expect == "spread" {
                expect = ""
                if t == "on" { expect = "type"; continue }
                inline = false
                if root, let d = def { d.spreads.append(t) }
                continue
            }
            inline = false
            if root, let d = def {
                d.fields.append(t)
                pushed = true
            }
        }
        // A later fragment of the same name wins, as in the TS Map.
        var fragments: [String: GraphQLDefinition] = [:]
        for d in defs where d.kind == "fragment" { fragments[d.name] = d }
        var names: [String] = []
        for d in defs where d.kind == "mutation" {
            if !d.name.isEmpty { names.append(d.name) }
            var seen = Set<String>()
            func walk(_ x: GraphQLDefinition) {
                names.append(contentsOf: x.fields)
                for s in x.spreads {
                    if let f = fragments[s], !seen.contains(s) {
                        seen.insert(s)
                        walk(f)
                    }
                }
            }
            walk(d)
        }
        return names
    }

    /// Does a request body name a blocked operation? Reads `operationName` the
    /// way the server will (after JSON parsing, so `\u004f` escapes do not hide
    /// it), for a single request or a batch, or form-encoded, and the names of
    /// every mutation it carries (see `mutationNames`). A GraphQL multipart
    /// upload's `operations` field is JSON and is judged like a JSON body,
    /// form-encoded or as raw multipart text (`multipartField`). A leading
    /// byte order mark is dropped first. A persisted query that sends only an
    /// innocent name and a hash cannot be read here; the signature on the
    /// envelope covers it. The guard script applies the same rule to requests a
    /// page script makes; this applies it to the runner's own `fetch` op, which
    /// never passes through the page.
    ///
    /// A body nested deeper than `bodyMaxDepth` inside `operations` fields is
    /// blocked, and so is one longer than `bodyMaxText`.
    public static func bodyBlocked(_ given: String?) -> Bool {
        judged(given, depth: 0)
    }

    /// How many times a body may nest inside an `operations` field
    /// (form-encoded or a raw multipart part) and still be read. One nested
    /// deeper is blocked. BODY_MAX_DEPTH in allowlist.ts.
    public static let bodyMaxDepth = 8

    /// The longest body (UTF-16 code units, after a leading byte order mark is
    /// dropped) that is read. A longer one is blocked, unread. BODY_MAX_TEXT.
    public static let bodyMaxText = 1_048_576

    private static func judged(_ given: String?, depth: Int) -> Bool {
        guard var body = given else { return false }
        // A leading byte order mark is dropped, as a server's JSON reader would.
        if body.unicodeScalars.first == "\u{FEFF}" { body = String(body.unicodeScalars.dropFirst()) }
        if body.isEmpty { return false }
        if depth > bodyMaxDepth { return true }
        let ns = body as NSString
        // Store requests are far smaller. A body this big is refused unread:
        // a text match could miss a blocked name hidden in escapes.
        if ns.length > bodyMaxText { return true }
        var names: [String] = []
        var docs: [String] = []
        for m in operationNameRegex.matches(in: body, options: [], range: NSRange(location: 0, length: ns.length)) {
            names.append(ns.substring(with: m.range(at: 1)))
        }
        // Read as JSON.parse reads it (any depth, lone surrogates), keeping
        // only the two levels this rule looks at.
        if let j = StrictJSON.parse(body, keep: 2) {
            let list: [JSONValue] = j.arrayValue ?? [j]
            for item in list {
                guard case .object(let o) = item else { continue }
                if case .string(let n)? = o["operationName"] { names.append(n) }
                if case .string(let q)? = o["query"] { docs.append(q) }
            }
        } else {
            // Not JSON: form-encoded, raw multipart, or a bare GraphQL document.
            docs.append(body)
            for m in formFieldRegex.matches(in: body, options: [], range: NSRange(location: 0, length: ns.length)) {
                let v = decodePercent(ns.substring(with: m.range(at: 2)).replacingOccurrences(of: "+", with: " "))
                let field = ns.substring(with: m.range(at: 1))
                if field == "query" {
                    docs.append(v)
                } else if field == "operations" {
                    if judged(v, depth: depth + 1) { return true }
                } else {
                    names.append(v)
                }
            }
            for (field, v) in multipartFields(body) {
                if field == "query" {
                    docs.append(v)
                } else if field == "operations" {
                    if judged(v, depth: depth + 1) { return true }
                } else {
                    names.append(v)
                }
            }
        }
        for d in docs { names.append(contentsOf: mutationNames(d)) }
        return names.contains { n in
            blockedOperationRegex.firstMatch(in: n, options: [], range: NSRange(location: 0, length: (n as NSString).length)) != nil
        }
    }

    /// JavaScript's `\s`, which MULTIPART_FIELD's lookahead uses (isJsSpace
    /// in allowlist.ts). Swift's and ICU's differ.
    static func isJsSpace(_ c: UInt16) -> Bool {
        c == 0x20 || (c >= 0x09 && c <= 0x0d) || c == 0xa0 || c == 0x1680 || (c >= 0x2000 && c <= 0x200a)
            || c == 0x2028 || c == 0x2029 || c == 0x202f || c == 0x205f || c == 0x3000 || c == 0xfeff
    }

    private static let partNameStrings = ["operationName", "query", "operations"]
    private static let partNames: [[UInt16]] = partNameStrings.map { Array($0.utf16) }
    private static let nameEq: [UInt16] = Array("name=".utf16)

    /// Every match of MULTIPART_FIELD in a body, as (name, value) pairs, in
    /// one linear pass. A line-for-line port of multipartFields in
    /// allowlist.ts (UTF-16 offsets, as JS strings): see there for the steps
    /// and the two caches that keep it linear.
    static func multipartFields(_ text: String) -> [(String, String)] {
        let ns = text as NSString
        let body = Array(text.utf16)
        let n = body.count
        var out: [(String, String)] = []
        func at(_ i: Int) -> UInt16 { i < n ? body[i] : 0 }
        func startsWith(_ x: [UInt16], _ k: Int) -> Bool {
            guard k + x.count <= n else { return false }
            for i in 0..<x.count where body[k + i] != x[i] { return false }
            return true
        }
        func indexOf(_ x: [UInt16], _ from: Int) -> Int {
            var i = max(from, 0)
            while i + x.count <= n {
                if startsWith(x, i) { return i }
                i += 1
            }
            return -1
        }
        let lf: UInt16 = 0x0a, cr: UInt16 = 0x0d
        let valueEnd: [UInt16] = [lf, 0x2d, 0x2d] // "\n--"
        // nextBreak(p) for p in [brkFrom, brkAt] is brkAt.
        var brkFrom = -1, brkAt = -1
        // valueStart(p) for p in [runFrom, runTo] is runValue (-1: no match).
        var runFrom = -1, runTo = -1, runValue = -1
        var from = 0
        while true {
            let c = indexOf(nameEq, from)
            if c < 0 { break }
            from = c + 1
            var k = c + 5
            if k < n && (body[k] == 0x22 || body[k] == 0x27) { k += 1 }
            var nameIndex = -1
            for (i, x) in partNames.enumerated() where startsWith(x, k) {
                nameIndex = i
                break
            }
            if nameIndex < 0 { continue }
            let j = k + partNames[nameIndex].count
            if j < n {
                let ch = body[j]
                if ch != 0x22 && ch != 0x27 && ch != 0x3b && !isJsSpace(ch) { continue }
            }
            // 2. The header line.
            var q: Int
            if j >= brkFrom && j <= brkAt {
                q = brkAt
            } else {
                q = j
                while q < n && body[q] != cr && body[q] != lf { q += 1 }
                brkFrom = j
                brkAt = q
            }
            var p: Int
            if q < n && body[q] == lf {
                p = q + 1
            } else if q + 1 < n && body[q] == cr && body[q + 1] == lf {
                p = q + 2
            } else {
                continue
            }
            // 3. Header lines, then the blank line.
            var v: Int
            if p >= runFrom && p <= runTo {
                v = runValue
            } else {
                var s = p
                v = -1
                while true {
                    if s >= n { break }
                    let h = body[s]
                    if h == lf { v = s + 1; break }
                    if h == cr {
                        if s + 1 < n && body[s + 1] == lf { v = s + 2 }
                        break
                    }
                    var e = s
                    while e < n && body[e] != cr && body[e] != lf { e += 1 }
                    if e < n && body[e] == lf {
                        s = e + 1
                    } else if e + 1 < n && body[e] == cr && body[e + 1] == lf {
                        s = e + 2
                    } else {
                        break
                    }
                }
                runFrom = p
                runTo = s
                runValue = v
            }
            if v < 0 { continue }
            // 4. The value.
            var end = indexOf(valueEnd, v)
            if end < 0 {
                end = n
            } else if end > v && at(end - 1) == cr {
                end -= 1
            }
            // Through NSString: a lone surrogate stays as it is, as in a JS slice.
            out.append((partNameStrings[nameIndex], ns.substring(with: NSRange(location: v, length: end - v))))
            from = end
        }
        return out
    }

    /// Last two labels, with a short list of two-label public suffixes.
    public static func registrableDomain(_ host: String) -> String {
        let parts = host.lowercased().split(separator: ".", omittingEmptySubsequences: true).map(String.init)
        if parts.count <= 2 { return parts.joined(separator: ".") }
        let last2 = parts.suffix(2).joined(separator: ".")
        if ["co.uk", "com.au", "co.nz"].contains(last2) { return parts.suffix(3).joined(separator: ".") }
        return last2
    }

    /// Tested against the path as given and as a server would decode it.
    public static func isBlockedPath(_ pathAndQuery: String) -> Bool {
        func test(_ s: String) -> Bool {
            blockedRegex.firstMatch(in: s, options: [], range: NSRange(location: 0, length: (s as NSString).length)) != nil
        }
        return test(pathAndQuery) || test(decodePercent(pathAndQuery))
    }

    private static func hostMatches(_ host: String, _ allowed: String) -> Bool {
        let h = host.lowercased()
        let a = allowed.lowercased()
        return h == a || h.hasSuffix("." + a)
    }

    // MARK: instance

    private var stores: [String: StoreHosts]

    public init(base: [String: StoreHosts] = Allowlist.bundledStores) {
        self.stores = base
    }

    /// Widen hosts from a signed allowlist payload. A new host must share a
    /// registrable domain with a host already listed for that store; anything
    /// else is ignored. Stores the SDK does not know are ignored.
    public func widen(_ p: AllowlistPayload) {
        for (store, add) in p.stores {
            guard var cur = stores[store] else { continue }
            let known = Set((cur.hosts + cur.authHosts).map(Allowlist.registrableDomain))
            for h in add.hosts ?? [] where known.contains(Allowlist.registrableDomain(h)) && !cur.hosts.contains(h) {
                cur.hosts.append(h)
            }
            for h in add.authHosts ?? [] where known.contains(Allowlist.registrableDomain(h)) && !cur.authHosts.contains(h) {
                cur.authHosts.append(h)
            }
            stores[store] = cur
        }
    }

    public func hostsFor(_ store: String) -> StoreHosts? {
        stores[store]
    }

    /// Every store id this allowlist knows.
    public var storeIds: [String] { Array(stores.keys) }

    public func check(_ store: String, _ url: String, _ use: UrlUse) -> UrlVerdict {
        guard let s = stores[store] else { return .refused(.unknownStore) }
        guard let p = Allowlist.parseUrl(url) else { return .refused(.badUrl) }
        if p.scheme != "https" { return .refused(.notHttps) }
        let host = p.host
        let rest = p.rest
        let own = s.hosts.contains { Allowlist.hostMatches(host, $0) }
        let auth = use == .login && (s.authHosts + Allowlist.commonAuthHosts + Allowlist.mealioHosts)
            .contains { Allowlist.hostMatches(host, $0) }
        if !own && !auth { return .refused(.host) }
        if Allowlist.isBlockedPath(rest) { return .refused(.blockedPath) }
        return .allowed
    }
}

/// One definition of a GraphQL document, for `Allowlist.mutationNames`.
private final class GraphQLDefinition {
    let kind: String
    var name = ""
    /// Root fields, in order.
    var fields: [String] = []
    /// Fragment spreads at the root.
    var spreads: [String] = []

    init(kind: String) {
        self.kind = kind
    }
}
