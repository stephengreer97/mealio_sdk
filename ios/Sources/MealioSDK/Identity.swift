// SHARED_IDENTITY_HOSTS and the rule that says which of a store's hosts the
// native network block runs on (0.6 round 7). protocol/shared-identity-hosts.json
// is the source: this list is a copy, and the tests run that file's vectors
// and check the list against it. PROTOCOL.md "Native blocking hosts" is the
// spec; packages/core/src/identity.ts is the reference this ports.
//
// The block covers the store's own hosts AND its store-owned sign-in hosts
// (albertsons.okta.com for an Albertsons banner, kroger.com and
// login.kroger.com for the Kroger family), never a shared identity provider,
// so a Google, Apple or generic Okta sign-in page is never refused natively.

import Foundation

public enum SharedIdentity {
    /// Identity providers many stores share. Native blocking never runs on
    /// them, except on a tenant subdomain whose tenant label names the store.
    public static let hosts: [String] = [
        "google.com",
        "gstatic.com",
        "apple.com",
        "facebook.com",
        "microsoftonline.com",
        "b2clogin.com",
        "ciamlogin.com",
        "live.com",
        "okta.com",
        "auth0.com",
        "mealio.co",
    ]

    /// Lowercased, one trailing dot dropped.
    static func norm(_ host: String) -> String {
        var h = host.lowercased()
        if h.hasSuffix(".") { h.removeLast() }
        return h
    }

    /// The entry `host` (normalized) is under: equal, or a subdomain by whole labels.
    static func sharedEntry(_ host: String) -> String? {
        hosts.first { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The store's names: the first label of the registrable domain of each
    /// of its hosts and authHosts that is not under a shared entry.
    public static func storeNames(_ store: StoreHosts) -> [String] {
        var out: [String] = []
        for h in store.hosts + store.authHosts {
            let n = norm(h)
            if sharedEntry(n) != nil { continue }
            let label = Allowlist.registrableDomain(n).split(separator: ".", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            if !label.isEmpty, !out.contains(label) { out.append(label) }
        }
        return out
    }

    /// True when `host` belongs to a shared identity provider, for this
    /// store: it is under an entry, and it is not a tenant of that provider
    /// whose tenant label (the label just left of the entry) is one of the
    /// store's names. okta.com and login.okta.com are shared;
    /// albertsons.okta.com is not, for an Albertsons banner.
    public static func isShared(_ host: String, store: StoreHosts) -> Bool {
        let h = norm(host)
        guard let e = sharedEntry(h) else { return false }
        if h == e { return true }
        let under = h.dropLast(e.count + 1).split(separator: ".", omittingEmptySubsequences: false)
        let tenant = under.last.map(String.init) ?? ""
        return !storeNames(store).contains(tenant)
    }

    /// The hosts the native block runs on for a store: its hosts, then its
    /// authHosts, normalized, without repeats, leaving out shared hosts.
    public static func nativeBlockHosts(_ store: StoreHosts) -> [String] {
        var out: [String] = []
        for h in store.hosts + store.authHosts {
            let n = norm(h)
            if !out.contains(n), !isShared(n, store: store) { out.append(n) }
        }
        return out
    }
}
