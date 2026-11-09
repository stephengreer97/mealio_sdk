// Native network blocking of checkout paths (0.6, round 7: store hosts only,
// while Mealio drives the page).
//
// A WKContentRuleList blocks every request, in every frame and of every
// resource type (documents, subframes, fetch, XHR, form posts, beacons,
// workers' loads), whose HOST is one of the current store's own hosts (or a
// subdomain of one) and whose path + query matches a BLOCKED_PATTERNS entry.
// Page code cannot turn it off: WebKit applies it outside the page.
//
// Round 6 blocked those paths on every host from the first page load. That
// stopped the store's own boot requests (a /payment config fetch) and
// third-party frames (a Stripe or captcha iframe whose path says "payment")
// before Mealio did anything, as the in-page guard did before round 5. So:
//
// - Only the store's own hosts, from the SDK allowlist with any signed
//   widening (`StoreHosts.hosts`, never its sign-in hosts). WebKit's
//   `if-domain` reads the page's (top document's) domain, not the request's,
//   so each filter anchors the request's own host instead:
//   `^scheme://[userinfo@][sub.]store.com[:port]` then the path. A request to
//   any other host matches no rule.
// - Only while Mealio drives the page. WebViewHost adds the list to the
//   hidden page's user content controller right before the first server
//   script for a page (when the in-page guard arms) and removes it when the
//   page commits a new document; the sign-in sheet adds it before each check
//   script. A store page's boot requests before that are never blocked.
//
// WebKit's url-filter is a small regex language with no `|`, matched against
// the whole URL. So each pattern is expanded into one filter per
// alternative, anchored after the host, and run case-insensitively.
//
// Allowlist.isBlockedPath also tests the path as a server would decode it
// (%XX, twice). A filter cannot decode, so instead any store-host request
// whose path or query percent-encodes a letter, `-` or `_` (once or twice),
// or holds a broken escape that two decodings could turn into one, is
// blocked. Browsers and encodeURIComponent never encode those characters.
//
// One list per set of store hosts, compiled once per process and kept. A
// page load waits (bounded) for its store's list; jobs are refused with a
// clear error when WebKit cannot compile the rules (`ready` compiles a probe
// list with the same filters), and a page is neither loaded nor driven
// without its list.

import Foundation
#if canImport(UIKit) && canImport(WebKit)
import WebKit
#endif

public enum NetworkBlock {
    /// Path + query characters that a server's decoding (twice, %XX) could
    /// turn into a letter, `-` or `_`.
    static let encodedSuffixes: [String] = [
        "%[46][1-9a-f]", "%[57][0-9a]", "%2d", "%5f",          // %63 -> c
        "%25[46][1-9a-f]", "%25[57][0-9a]", "%252d", "%255f",  // %2563 -> %63 -> c
        "%[0-9a-f]?%",                                        // %%36%33, %6%33 -> %63 -> c
        "%25%3[0-9]", "%25%[46][1-6]",                         // %25%36%33 -> %63 -> c
        "%25[0-9a-f]%3[0-9]", "%25[0-9a-f]%[46][1-6]",         // %256%33 -> %63 -> c
    ]

    /// One pattern with each `(a|b|c)` group (not nested) written out: one
    /// string per combination of alternatives.
    static func expand(_ pattern: String) -> [String] {
        guard let open = pattern.firstIndex(of: "(") else { return [pattern] }
        guard let close = pattern[open...].firstIndex(of: ")") else { return [pattern] }
        let head = String(pattern[..<open])
        let body = pattern[pattern.index(after: open)..<close]
        let tail = String(pattern[pattern.index(after: close)...])
        var out: [String] = []
        for alt in body.split(separator: "|", omittingEmptySubsequences: false) {
            for rest in expand(tail) { out.append(head + alt + rest) }
        }
        return out
    }

    /// What follows the host (and port) in each filter: the path + query part.
    static let pathFilters: [String] = {
        var out: [String] = []
        for p in Allowlist.blockedPatterns {
            for e in expand(p) {
                // Any path or query character onward. A pattern that starts
                // with `/` may also start at the path's own first slash.
                if e.hasPrefix("/") { out.append(e) }
                out.append("[/?].*" + e)
            }
        }
        for s in encodedSuffixes { out.append("[/?].*" + s) }
        return out
    }()

    /// A store host as the rules take it: lowercased, letters, digits, `-`
    /// and `.` only, no leading or trailing dot. Anything else is no host.
    static func normalizedHost(_ host: String) -> String? {
        var h = host.lowercased()
        while h.hasPrefix(".") { h.removeFirst() }
        while h.hasSuffix(".") { h.removeLast() }
        guard !h.isEmpty, !h.contains(".."),
              h.unicodeScalars.allSatisfy({ ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "-" || $0 == "." })
        else { return nil }
        return h
    }

    /// The store hosts a list is made for: normalized, unique, sorted.
    public static func ruleHosts(_ hosts: [String]) -> [String] {
        Array(Set(hosts.compactMap(normalizedHost))).sorted()
    }

    /// Scheme, optional userinfo, the host or any subdomain of it, optional
    /// port: everything before the path or query of a request to `host`.
    /// `host` must be normalized. A host such as heb.com.evil.io or
    /// xheb.com does not match, and nothing after the authority can.
    static func hostPrefix(_ host: String) -> String {
        "^[^:]+://([^/?#]*@)?([^/?#@]*\\.)?" + host.replacingOccurrences(of: ".", with: "\\.") + "(:[0-9]*)?"
    }

    /// Every url-filter of the list for these store hosts.
    public static func urlFilters(hosts: [String]) -> [String] {
        var out: [String] = []
        for h in ruleHosts(hosts) {
            let prefix = hostPrefix(h)
            for p in pathFilters { out.append(prefix + p) }
        }
        return out
    }

    /// The WKContentRuleList source: one block rule per filter, every
    /// resource type and load (no resource-type or load-type given).
    public static func ruleListJSON(hosts: [String]) -> String {
        let rules: [[String: Any]] = urlFilters(hosts: hosts).map { f in
            ["trigger": ["url-filter": f, "url-filter-is-case-sensitive": false] as [String: Any],
             "action": ["type": "block"]]
        }
        // Strings and booleans only: serialization cannot fail.
        let data = (try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// The identifier the compiled list for these hosts is stored under.
    public static func identifier(hosts: [String]) -> String {
        "co.mealio.sdk.blocked-paths." + ruleHosts(hosts).joined(separator: ",")
    }

    /// The hosts of the list `ready` compiles: the same filters on a host
    /// no store has, to learn whether WebKit takes them before any job.
    static let probeHosts = ["probe.mealio.invalid"]

    /// How long a page load or sign-in waits for a list to compile.
    static let waitMs = 10_000
}

#if canImport(UIKit) && canImport(WebKit)
/// The compiled rule lists, one per set of store hosts, made once per process.
@MainActor
final class BlockedPathRules {
    static let shared = BlockedPathRules()

    private final class Entry {
        var finished = false
        var compiled: WKContentRuleList?
        var failure: String?
        var waiters: [ResumeOnce<Void>] = []
    }

    private var entries: [String: Entry] = [:]

    /// Start compiling the list for `hosts`, once. Returns at once. Hosts
    /// with no usable store host have no list.
    func prepare(hosts: [String]) {
        _ = entry(hosts)
    }

    private func entry(_ hosts: [String]) -> Entry? {
        let clean = NetworkBlock.ruleHosts(hosts)
        guard !clean.isEmpty else { return nil }
        let id = NetworkBlock.identifier(hosts: clean)
        if let e = entries[id] { return e }
        let e = Entry()
        entries[id] = e
        let source = NetworkBlock.ruleListJSON(hosts: clean)
        Task { @MainActor in
            do {
                let store: WKContentRuleListStore? = WKContentRuleListStore.default()
                if let store = store {
                    let list: WKContentRuleList? = try await store.compileContentRuleList(
                        forIdentifier: id, encodedContentRuleList: source)
                    if let list = list { e.compiled = list } else { e.failure = "WebKit returned no rule list" }
                } else {
                    e.failure = "no content rule list store"
                }
            } catch {
                e.failure = "\(error)"
            }
            e.finished = true
            let waiting = e.waiters
            e.waiters = []
            for w in waiting { _ = w.resume(()) }
        }
        return e
    }

    /// The compiled list for `hosts`, waiting at most `ms` for it. Nil when
    /// the store has no host of its own (nothing to block). Throws when it
    /// failed to compile or is not ready in time: the caller must not load
    /// or drive a page.
    func list(hosts: [String], waitingAtMost ms: Int = NetworkBlock.waitMs) async throws -> WKContentRuleList? {
        guard let e = entry(hosts) else { return nil }
        if !e.finished {
            await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
                let once = ResumeOnce(k)
                e.waiters.append(once)
                _ = after(ms) { _ = once.resume(()) }
            }
        }
        if let list = e.compiled { return list }
        let why = e.finished
            ? "it could not be compiled (\(e.failure ?? "unknown error"))"
            : "it was not ready after \(ms) ms"
        throw MealioError(code: MealioError.Code.unsupported,
                          message: "Mealio refuses to run: the network block for checkout paths is not in place, because \(why)")
    }

    /// Throws unless WebKit compiles the rules (the probe list).
    func ready(waitingAtMost ms: Int = NetworkBlock.waitMs) async throws {
        _ = try await list(hosts: NetworkBlock.probeHosts, waitingAtMost: ms)
    }
}
#endif
