// 0.6 round 6: the native block list's filters (round 7: on the store's own
// hosts only), jobs refused without it, and the linear multipart scan. Platform-neutral: runs with `swift test`. The
// block list itself, in a real WKWebView, is in GuardBrowserTests.

import Foundation
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif
import XCTest
@testable import MealioSDK

/// A host that is never safe to run a job on (its network block failed).
@MainActor
private final class UnreadyHost: MealioHost {
    var calls: [String] = []

    func ready() async throws {
        throw MealioError(code: MealioError.Code.unsupported, message: "no network block")
    }

    func openPage(store: String, url: String, timeoutMs: Int) async throws -> PageOpenOutcome {
        calls.append("open")
        return PageOpenOutcome(ok: true, finalUrl: url)
    }

    func runScript(store: String, guardScript: String, script: String, until: [Matcher], timeoutMs: Int) async throws -> ScriptOutcome {
        calls.append("script")
        return ScriptOutcome(messages: [], timedOut: false)
    }

    func showLogin(_ request: LoginRequest) async throws -> LoginOutcome {
        calls.append("login")
        return LoginOutcome(outcome: .signedIn, messages: [])
    }

    func fetch(store: String, request: FetchRequest, timeoutMs: Int, maxBytes: Int) async throws -> FetchOutcome {
        calls.append("fetch")
        return FetchOutcome(ok: true, status: 200, body: "")
    }
}

final class Round6Tests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.handler = nil
        StubURLProtocol.hangs = false
        super.tearDown()
    }

    // MARK: the block list's url-filters

    /// The filters of H-E-B's list (its own host, heb.com).
    private let hebFilters = NetworkBlock.urlFilters(hosts: ["heb.com"])

    /// Blocked by some filter, read as WebKit reads a url-filter (no `|`,
    /// case-insensitive, matched anywhere unless anchored).
    private func filtered(_ url: String, hosts: [String]? = nil) -> Bool {
        let filters = hosts.map { NetworkBlock.urlFilters(hosts: $0) } ?? hebFilters
        return filters.contains { f in
            let re = try! NSRegularExpression(pattern: f, options: [.caseInsensitive])
            return re.firstMatch(in: url, options: [], range: NSRange(location: 0, length: (url as NSString).length)) != nil
        }
    }

    func testEveryFilterIsOneWebKitAccepts() {
        XCTAssertFalse(hebFilters.isEmpty)
        for f in hebFilters {
            XCTAssertFalse(f.contains("|"), "WebKit has no disjunction: \(f)")
            XCTAssertFalse(f.contains("{"), "WebKit has no counted quantifier: \(f)")
            XCTAssertTrue(f.unicodeScalars.allSatisfy { $0.isASCII }, f)
            XCTAssertTrue(f.hasPrefix("^"), f)
            XCTAssertFalse(f.replacingOccurrences(of: "[^", with: "[").dropFirst().contains("^"), "^ only at the start: \(f)")
            if let i = f.firstIndex(of: "$") { XCTAssertEqual(i, f.index(before: f.endIndex), "$ only at the end: \(f)") }
            XCTAssertNoThrow(try NSRegularExpression(pattern: f, options: []), f)
        }
        // The JSON WebKit compiles: one block rule per filter.
        let data = Data(NetworkBlock.ruleListJSON(hosts: ["heb.com"]).utf8)
        let rules = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        XCTAssertEqual(rules?.count, hebFilters.count)
        let first = rules?.first
        XCTAssertEqual((first?["action"] as? [String: Any])?["type"] as? String, "block")
        let trigger = first?["trigger"] as? [String: Any]
        XCTAssertEqual(trigger?["url-filter-is-case-sensitive"] as? Bool, false)
        XCTAssertNil(trigger?["resource-type"], "every resource type")
        XCTAssertNil(trigger?["load-type"], "first and third party")
        XCTAssertNil(trigger?["if-domain"], "the request's host is in the filter, not the page's")
    }

    /// The store's own hosts and their subdomains, whatever the scheme, case,
    /// port or userinfo. No other host, however its URL is dressed up.
    func testTheFiltersAreAnchoredToTheStoresOwnHosts() {
        for url in ["https://www.heb.com/checkout", "https://heb.com/checkout", "https://a.b.heb.com/api/payment",
                    "HTTPS://WWW.HEB.COM/CHECKOUT", "https://www.heb.com:443/checkout", "https://u:p@www.heb.com/checkout",
                    "https://evil.io:x@www.heb.com/checkout", "https://www.heb.com?step=billing",
                    "mealio-test://www.heb.com/checkout/x"] {
            XCTAssertTrue(filtered(url), url)
        }
        for url in ["https://js.stripe.com/v3/payment", "https://hcaptcha.com/checkout", "https://xheb.com/checkout",
                    "https://heb.com.evil.io/checkout", "https://www.heb.com@evil.io/checkout",
                    "https://www.heb.com.evil.io:443/checkout", "https://evil.io/?next=https://www.heb.com/checkout",
                    "https://evil.io/www.heb.com/checkout", "https://evil.io#www.heb.com/checkout",
                    "mealio-test://js.stripe.com/payment"] {
            XCTAssertFalse(filtered(url), url)
        }
        // A widened host is a store host too; a store with none has no filters.
        XCTAssertTrue(filtered("https://cdn.heb-static.com/checkout", hosts: ["heb.com", "heb-static.com"]))
        XCTAssertFalse(filtered("https://cdn.heb-static.com/checkout"))
        XCTAssertEqual(NetworkBlock.urlFilters(hosts: []), [])
    }

    func testRuleHostsAreCleanUniqueAndSorted() {
        XCTAssertEqual(NetworkBlock.ruleHosts(["WWW.HEB.com", "heb.com", ".heb.com.", "www.heb.com"]), ["heb.com", "www.heb.com"])
        XCTAssertEqual(NetworkBlock.ruleHosts(["", ".", "a..b", "evil.io/x", "a*b.com", "h\u{e9}b.com"]), [])
        XCTAssertEqual(NetworkBlock.identifier(hosts: ["safeway.com", "Albertsons.com"]),
                       "co.mealio.sdk.blocked-paths.albertsons.com,safeway.com")
        XCTAssertEqual(NetworkBlock.hostPrefix("heb.com"), #"^[^:]+://([^/?#]*@)?([^/?#@]*\.)?heb\.com(:[0-9]*)?"#)
    }

    func testExpandWritesOutEachAlternative() {
        XCTAssertEqual(NetworkBlock.expand("checkout"), ["checkout"])
        XCTAssertEqual(NetworkBlock.expand("/a/(b|c)"), ["/a/b", "/a/c"])
        XCTAssertEqual(NetworkBlock.expand("/(x|y)/(1|2)"), ["/x/1", "/x/2", "/y/1", "/y/2"])
        XCTAssertEqual(NetworkBlock.expand("/p(/|\\?|$)"), ["/p/", "/p\\?", "/p$"])
    }

    /// The filters block what Allowlist.isBlockedPath blocks, judged on the
    /// path and query only: a host is never a path.
    func testTheFiltersBlockExactlyTheBlockedPathsOnPathAndQuery() {
        let paths = [
            "/", "/checkout", "/Checkout/submit", "/api/payment/config", "/x?step=billing", "/my-wallet",
            "/place-order", "/placeorder", "/submit_order", "/order-confirmation", "/giftcard", "/gift-card/balance",
            "/account/delete", "/account/Password/reset", "/account/settings", "/addresses/new", "/address/edit/1",
            "/addresses", "/orders/submit", "/order/place?x=1", "/orders/placed", "/orders/submitted", "/cart/confirm",
            "/cart", "/purchase", "/purchase/1", "/purchase?x", "/purchases", "/search?q=apples", "/graphql",
            "/a/b/account/close", "/x/orders/place", "/?next=/purchase",
        ]
        for p in paths {
            for host in ["https://www.heb.com", "mealio-test://www.heb.com"] {
                XCTAssertEqual(filtered(host + p), Allowlist.isBlockedPath(p), host + p)
            }
        }
        // A host or scheme that names checkout is not a path.
        for url in ["https://checkout.heb.com/", "https://payment.heb.com/cart", "https://wallet.heb.com/?a=1"] {
            XCTAssertFalse(filtered(url), url)
        }
    }

    /// A path a server would decode into a blocked one is blocked; ordinary
    /// escapes (spaces, slashes, JSON in a query, UTF-8) are not.
    func testEncodedLettersAreBlockedOrdinaryEscapesAreNot() {
        for p in ["/%63heckout", "/%43HECKOUT", "/%2563heckout", "/%%36%33heckout", "/%6%33heckout", "/%25%36%33heckout",
                  "/%256%33heckout", "/place%2dorder", "/submit%5forder", "/x?q=%61"] {
            XCTAssertTrue(filtered("https://www.heb.com" + p), p)
        }
        for p in ["/search?q=green%20beans", "/x?redirect=%2Fcart", "/q?v=%7B%22a%22%3A1%7D", "/caf%C3%A9",
                  "/x?d=50%25%20off", "/x?a=%5B1%5D", "/x?b=%253D"] {
            XCTAssertFalse(filtered("https://www.heb.com" + p), p)
        }
    }

    // MARK: no job without the network block

    @MainActor
    func testAJobOnAHostThatIsNotReadyIsRefusedBeforeItStarts() async throws {
        let server = JobServer()
        StubURLProtocol.handler = { req, body in
            server.rec.record(req, body: body)
            return server.start([jobsOpen("o"), jobsDone(jobsCart)])
        }
        let host = UnreadyHost()
        let config = MealioClientConfig(publishableKey: "pk", sessionTokenProvider: { "tok" },
                                        baseURL: URL(string: "https://mealio.test/")!,
                                        epochProvider: { 0 }, keys: TestSigner.keys,
                                        urlSession: StubURLProtocol.session(), sdkVersion: "0")
        let client = MealioClient(config: config, host: host)
        do {
            _ = try await client.prepareCart(recipe: Recipe(id: "r", ingredients: []))
            XCTFail("the job ran")
        } catch let e as MealioError {
            XCTAssertEqual(e.code, MealioError.Code.unsupported)
            XCTAssertEqual(e.message, "no network block")
        }
        XCTAssertEqual(host.calls, [])
        // Refused before Mealio is asked to start one.
        XCTAssertEqual(server.paths, [])
    }

    // MARK: the multipart scan is linear

    #if canImport(JavaScriptCore)
    /// isJsSpace is exactly JavaScript's `\s`, asked of JavaScriptCore.
    func testIsJsSpaceIsExactlyJavaScriptsWhitespace() throws {
        let ctx = try XCTUnwrap(JSContext())
        let js = ctx.evaluateScript("(function(){var o=[];for(var c=0;c<65536;c++)if(/\\s/.test(String.fromCharCode(c)))o.push(c);return o.join(',');})()")?.toString() ?? ""
        let swift = (0..<65536).filter { Allowlist.isJsSpace(UInt16($0)) }.map(String.init).joined(separator: ",")
        XCTAssertFalse(js.isEmpty)
        XCTAssertEqual(swift, js)
    }
    #endif

    /// multipartFields finds exactly what MULTIPART_FIELD (the spec) does.
    func testMultipartFieldsMatchesTheRegexOnRandomBodies() {
        let pieces = ["name=", "\"", "'", ";", " ", "\r", "\n", "\r\n", "--", "query", "operations", "operationName",
                      "operationsX", "x", "Content-Type: a", "\u{0B}", "\u{FEFF}", "{}", "-"]
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<3000 {
            var body = ""
            for _ in 0..<Int.random(in: 0...24, using: &rng) { body += pieces.randomElement(using: &rng)! }
            let ns = body as NSString
            let want = Allowlist.multipartFieldRegex.matches(in: body, options: [], range: NSRange(location: 0, length: ns.length))
                .map { [ns.substring(with: $0.range(at: 1)), ns.substring(with: $0.range(at: 2))] }
            let got = Allowlist.multipartFields(body).map { [$0.0, $0.1] }
            XCTAssertEqual(got, want, body.debugDescription)
            if got != want { return }
        }
    }

    /// protocol/test-vectors.json multipartScan: each body judged as the
    /// vector says, quickly. A regex scan took minutes on these.
    func testEveryMultipartScanVectorIsJudgedQuickly() throws {
        let list = try XCTUnwrap(try Fixtures.vectors()["multipartScan"]?.arrayValue)
        XCTAssertFalse(list.isEmpty)
        for v in list {
            let fill = try XCTUnwrap(v["fill"]?.stringValue)
            let times = try XCTUnwrap(v["times"]?.intValue)
            let suffix = try XCTUnwrap(v["suffix"]?.stringValue)
            let body = try XCTUnwrap(v["prefix"]?.stringValue) + String(repeating: fill, count: times) + suffix
            XCTAssertLessThanOrEqual((body as NSString).length, Allowlist.bodyMaxText)
            let what = "\(times)x \(fill.debugDescription) \(suffix.debugDescription)"
            let start = Date()
            XCTAssertEqual(Allowlist.bodyBlocked(body), try XCTUnwrap(v["blocked"]?.boolValue), what)
            // "Well under a second" in TS; a debug build on a CI runner gets more.
            XCTAssertLessThan(Date().timeIntervalSince(start), 5, what)
        }
    }

    func testAMegabyteOfNameQueryLinesIsJudgedInWellUnderASecond() {
        let line = "name=query\n"
        let body = String(repeating: line, count: (Allowlist.bodyMaxText - 1) / line.utf16.count)
        XCTAssertLessThanOrEqual(body.utf16.count, Allowlist.bodyMaxText)
        let t0 = Date()
        _ = Allowlist.bodyBlocked(body)
        let took = Date().timeIntervalSince(t0)
        // Generous for a slow CI machine; the quadratic scan took minutes.
        XCTAssertLessThan(took, 5, "took \(took)s")
        // CR LF, quoted and with a header line, judged as fast.
        let crlf = String(repeating: "Content-Disposition: form-data; name=\"query\"\r\n", count: 20_000)
        let t1 = Date()
        _ = Allowlist.bodyBlocked(crlf)
        XCTAssertLessThan(Date().timeIntervalSince(t1), 5)
    }
}
