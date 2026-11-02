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
        "place-?order",
        "submit-?order",
        "order-?confirm",
        "gift-?card",
        "/account/(delete|close|security|password)",
        "/addresses?/(add|edit|delete|new)",
    ]

    /// Hosts every store's login may return to.
    public static let mealioHosts: [String] = ["mealio.co"]

    /// Identity providers a store's login page may hand off to, for every store.
    /// Only top-frame navigations in the login sheet are checked; captcha and
    /// consent iframes inside a store page are not navigations of the sheet.
    public static let commonAuthHosts: [String] = [
        "b2clogin.com", "ciamlogin.com", "login.microsoftonline.com", "okta.com", "auth0.com",
        "accounts.google.com", "appleid.apple.com", "facebook.com",
    ]

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
            "wegmans": StoreHosts(hosts: ["wegmans.com"], authHosts: []),
        ]
        for (id, d) in albertsonsBanners { out[id] = StoreHosts(hosts: [d], authHosts: ["albertsons.com"]) }
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

    // Same as the TS: /^([a-z][a-z0-9+.-]*):\/\/([^/?#:]+)(?::\d+)?([^#]*)/i
    private static let urlRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"^([a-z][a-z0-9+.-]*)://([^/?#:]+)(?::\d+)?([^#]*)"#, options: [.caseInsensitive])
    }()

    /// Last two labels, with a short list of two-label public suffixes.
    public static func registrableDomain(_ host: String) -> String {
        let parts = host.lowercased().split(separator: ".", omittingEmptySubsequences: true).map(String.init)
        if parts.count <= 2 { return parts.joined(separator: ".") }
        let last2 = parts.suffix(2).joined(separator: ".")
        if ["co.uk", "com.au", "co.nz"].contains(last2) { return parts.suffix(3).joined(separator: ".") }
        return last2
    }

    public static func isBlockedPath(_ pathAndQuery: String) -> Bool {
        let range = NSRange(pathAndQuery.startIndex..., in: pathAndQuery)
        return blockedRegex.firstMatch(in: pathAndQuery, options: [], range: range) != nil
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
        let ns = url as NSString
        guard let m = Allowlist.urlRegex.firstMatch(in: url, options: [], range: NSRange(location: 0, length: ns.length)) else {
            return .refused(.badUrl)
        }
        func group(_ i: Int) -> String {
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
        if group(1).lowercased() != "https" { return .refused(.notHttps) }
        let host = group(2)
        var rest = group(3)
        if rest.isEmpty { rest = "/" }
        let own = s.hosts.contains { Allowlist.hostMatches(host, $0) }
        let auth = use == .login && (s.authHosts + Allowlist.commonAuthHosts + Allowlist.mealioHosts)
            .contains { Allowlist.hostMatches(host, $0) }
        if !own && !auth { return .refused(.host) }
        if Allowlist.isBlockedPath(rest) { return .refused(.blockedPath) }
        return .allowed
    }
}
