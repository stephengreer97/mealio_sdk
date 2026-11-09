// Native network blocking of checkout paths (0.6 round 6).
//
// A WKContentRuleList blocks every request the store page makes, in every
// frame and of every resource type (documents, subframes, fetch, XHR, form
// posts, beacons, workers' loads), whose path + query matches a
// BLOCKED_PATTERNS entry. Page code cannot turn it off: WebKit applies it
// outside the page. It goes on the hidden page and on the login page.
//
// WebKit's url-filter is a small regex language with no `|`, matched against
// the whole URL. So each pattern is expanded into one filter per
// alternative, anchored after the host (a host such as
// checkout.example.com is not a path), and run case-insensitively.
//
// Allowlist.isBlockedPath also tests the path as a server would decode it
// (%XX, twice). A filter cannot decode, so instead any request whose path or
// query percent-encodes a letter, `-` or `_` (once or twice), or holds a
// broken escape that two decodings could turn into one, is blocked. Browsers
// and encodeURIComponent never encode those characters.
//
// The list is compiled once per process, asynchronously, when a WebViewHost
// is made (MealioCart.configure). Page loads and sign-ins wait for it, for a
// bounded time. If it cannot be compiled, jobs are refused with a clear
// error instead of running unprotected.

import Foundation
#if canImport(UIKit) && canImport(WebKit)
import WebKit
#endif

public enum NetworkBlock {
    /// The scheme and host of a URL: everything before its path or query.
    static let hostPart = "^[^:]+://[^/?#]*"

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

    /// Every url-filter of the rule list.
    public static let urlFilters: [String] = {
        var out: [String] = []
        for p in Allowlist.blockedPatterns {
            for e in expand(p) {
                // Any path or query character onward. A pattern that starts
                // with `/` may also start at the path's own first slash.
                if e.hasPrefix("/") { out.append(hostPart + e) }
                out.append(hostPart + "[/?].*" + e)
            }
        }
        for s in encodedSuffixes { out.append(hostPart + "[/?].*" + s) }
        return out
    }()

    /// The WKContentRuleList source: one block rule per filter, every
    /// resource type and load (no resource-type or load-type given).
    public static let ruleListJSON: String = {
        let rules: [[String: Any]] = urlFilters.map { f in
            ["trigger": ["url-filter": f, "url-filter-is-case-sensitive": false] as [String: Any],
             "action": ["type": "block"]]
        }
        // Constant input: serialization cannot fail.
        let data = (try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }()

    /// The identifier the compiled list is stored under.
    static let identifier = "co.mealio.sdk.blocked-paths"

    /// How long a page load or sign-in waits for the list to compile.
    static let waitMs = 10_000
}

#if canImport(UIKit) && canImport(WebKit)
/// The compiled rule list, made once per process.
@MainActor
final class BlockedPathRules {
    static let shared = BlockedPathRules()

    private var started = false
    private var finished = false
    private var compiled: WKContentRuleList?
    private var failure: String?
    private var waiters: [ResumeOnce<Void>] = []

    /// Start compiling, once. Returns at once.
    func prepare() {
        guard !started else { return }
        started = true
        Task { @MainActor in
            do {
                let store: WKContentRuleListStore? = WKContentRuleListStore.default()
                if let store = store {
                    let list: WKContentRuleList? = try await store.compileContentRuleList(
                        forIdentifier: NetworkBlock.identifier, encodedContentRuleList: NetworkBlock.ruleListJSON)
                    if let list = list { self.compiled = list } else { self.failure = "WebKit returned no rule list" }
                } else {
                    self.failure = "no content rule list store"
                }
            } catch {
                self.failure = "\(error)"
            }
            self.finished = true
            let waiting = self.waiters
            self.waiters = []
            for w in waiting { _ = w.resume(()) }
        }
    }

    /// The compiled list, waiting at most `ms` for it. Throws when it failed
    /// to compile or is not ready in time: the caller must not load a page.
    func list(waitingAtMost ms: Int = NetworkBlock.waitMs) async throws -> WKContentRuleList {
        prepare()
        if !finished {
            await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
                let once = ResumeOnce(k)
                waiters.append(once)
                _ = after(ms) { _ = once.resume(()) }
            }
        }
        if let list = compiled { return list }
        let why = finished
            ? "it could not be compiled (\(failure ?? "unknown error"))"
            : "it was not ready after \(ms) ms"
        throw MealioError(code: MealioError.Code.unsupported,
                          message: "Mealio refuses to run: the network block for checkout paths is not in place, because \(why)")
    }
}
#endif
