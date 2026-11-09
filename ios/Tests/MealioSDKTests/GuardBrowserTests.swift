// The guard in a real WKWebView, set up as WebViewHost sets up its pages (the
// unarmed guard as a document-start user script in every frame, armed by the
// per-script copy as the runner injects it). Mirrors
// packages/core/test/guard.browser.test.ts and round5.browser.test.ts. iOS
// only: run with xcodebuild, not `swift test`.
//
// No network: pages come from a WKURLSchemeHandler at mealio-test://www.heb.com/.
// A request the guard lets through either reaches that handler or fails in
// WebKit; both count as "sent". Only the guard's own refusal ("mealio guard:
// <reason>") counts as blocked. Every wait here is bounded to a few seconds.
//
// Most tests here test the in-page guard ALONE: their pages leave out the
// network block list (NetworkBlock.swift) that the SDK's own pages carry.
// The "network block" tests at the end add it.
//
// Each page is shown in a window, as WebViewHost parks its hidden page in
// the key window. A WKWebView in no window counts as hidden: WebKit throttles
// its timers (and may suspend its process), which made a long test's
// setTimeout-based waits outlive their bounds on a cold simulator.

#if canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit
import XCTest
@testable import MealioSDK

/// Serves the test pages and records every other path asked for.
@MainActor
private final class TestPages: NSObject, WKURLSchemeHandler {
    static let scheme = "mealio-test"
    static let home = "mealio-test://www.heb.com/"
    var pages: [String: String] = ["/": "<html><body>page</body></html>", "/frame": "<html><body>page</body></html>"]
    private(set) var reached: [String] = []

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
        let path = url.path.isEmpty ? "/" : url.path
        // Pages on www.heb.com by path; on any other host by host + path.
        let key = url.host == "www.heb.com" ? path : (url.host ?? "") + path
        let html = pages[key]
        if html == nil { reached.append(key) }
        let type = html == nil ? "application/json" : "text/html"
        if let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                          headerFields: ["Content-Type": type, "Access-Control-Allow-Origin": "*"]) {
            urlSchemeTask.didReceive(response)
        }
        urlSchemeTask.didReceive(Data((html ?? "{}").utf8))
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

private struct TimedOut: Error, CustomStringConvertible {
    let what: String
    var description: String { "timed out: \(what)" }
}

/// Resumes its continuation once: with the script's answer or the timeout.
private final class Once: @unchecked Sendable {
    var k: CheckedContinuation<String, Error>?

    func finish(_ r: Result<String, Error>) {
        guard let k = k else { return }
        self.k = nil
        k.resume(with: r)
    }
}

final class GuardBrowserTests: XCTestCase {

    /// The windows this test's pages are shown in, taken down after it.
    @MainActor private var windows: [UIWindow] = []

    override func tearDown() async throws {
        await MainActor.run {
            for w in self.windows {
                w.subviews.forEach { $0.removeFromSuperview() }
                w.isHidden = true
            }
            self.windows = []
        }
        try await super.tearDown()
    }

    /// The application, if the test process has one. Read through the
    /// runtime: UIApplication.shared is not optional, and a test bundle run
    /// without a host application has none.
    @MainActor
    private static func application() -> UIApplication? {
        typealias Shared = @convention(c) (AnyClass, Selector) -> UIApplication?
        let sel = NSSelectorFromString("sharedApplication")
        guard let m = class_getClassMethod(UIApplication.self, sel) else { return nil }
        return unsafeBitCast(method_getImplementation(m), to: Shared.self)(UIApplication.self, sel)
    }

    /// A window for a page, on the app's scene when there is one.
    @MainActor
    private func show(_ web: WKWebView) {
        let frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        let scene = GuardBrowserTests.application()?.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window: UIWindow
        if let scene = scene {
            window = UIWindow(windowScene: scene)
            window.frame = frame
        } else {
            window = UIWindow(frame: frame)
        }
        window.addSubview(web)
        window.isHidden = false
        windows.append(window)
    }

    /// The run's first page load has happened (it may take longer).
    @MainActor private static var firstLoadDone = false

    private static let mutation = #"{"query":"mutation { placeOrder { id } }"}"#

    /// A page set up like WebViewHost's (the guard in every frame at document
    /// start), or with the guard only in the main frame's own markup. `arm`:
    /// then inject the per-script copy, as the runner does before a script.
    @MainActor
    /// `rules`: with the SDK's network block list, as its own pages have it.
    private func page(allFrames: Bool = true, pages given: TestPages? = nil, arm: Bool = true,
                      rules: Bool = false) async throws -> WKWebView {
        let pages = given ?? TestPages()
        let config: WKWebViewConfiguration
        var list: WKContentRuleList?
        if rules { list = try await BlockedPathRules.shared.list() }
        if allFrames {
            config = WebViewHost.makeConfiguration(handler: ScriptHandler(), rules: list)
        } else {
            config = WKWebViewConfiguration()
            if let list = list { config.userContentController.add(list) }
        }
        config.setURLSchemeHandler(pages, forURLScheme: TestPages.scheme)
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: config)
        show(web)
        _ = web.load(URLRequest(url: URL(string: TestPages.home)!))
        // Bounded: 3 seconds at most, 20 for the run's first page, which
        // also starts WebKit's processes on a cold simulator.
        let seconds = GuardBrowserTests.firstLoadDone ? 3 : 20
        for _ in 0..<(seconds * 100) {
            try await Task.sleep(nanoseconds: 10_000_000)
            if !web.isLoading { break }
        }
        XCTAssertFalse(web.isLoading, "the test page did not load in \(seconds)s")
        GuardBrowserTests.firstLoadDone = true
        if arm { try await self.arm(web) }
        return web
    }

    /// GUARD_ARM_SCRIPT in the top frame, as WebViewHost injects it before
    /// every server script.
    @MainActor
    private func arm(_ web: WKWebView) async throws {
        // Indirect eval: global scope, as evaluateJavaScript runs it.
        _ = try await js(web, "(0, eval)(\(MealioScripts.jsStringLiteral(MealioScripts.guardArmScript))); return 'armed';")
    }

    /// Wait (bounded) until `cond`, a JS expression, is true in the page.
    @MainActor
    private func until(_ web: WKWebView, _ cond: String, seconds: Int = 10) async throws {
        let ok = try await js(web, """
            for (let i = 0; i < \(seconds * 20); i++) {
              if (\(cond)) return 'yes';
              await new Promise((res) => setTimeout(res, 50));
            }
            return 'no';
            """, seconds: Double(seconds + 5))
        XCTAssertEqual(ok, "yes", "never true: \(cond)")
    }

    /// Run an async function body in the page; it returns a string. Bounded.
    @MainActor
    private func js(_ web: WKWebView, _ body: String, seconds: Double = 15) async throws -> String {
        let once = Once()
        return try await withCheckedThrowingContinuation { (k: CheckedContinuation<String, Error>) in
            once.k = k
            web.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let v): once.finish(.success((v as? String) ?? "\(v)"))
                case .failure(let e): once.finish(.failure(e))
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                once.finish(.failure(TimedOut(what: "script")))
            }
        }
    }

    /// What each named call did in the page: "sent" or the guard's reason.
    /// `body` builds an object `r`; it comes back as JSON.
    @MainActor
    private func run(_ web: WKWebView, _ body: String) async throws -> [String: JSONValue] {
        let text = try await js(web, """
            const t = async (f) => {
              const late = new Promise((res) => setTimeout(() => res('sent'), 1500));
              const go = (async () => { try { await f(); return 'sent'; } catch (e) {
                const m = String(e && e.message || e);
                return m.indexOf('mealio guard: ') === 0 ? m.slice(14) : 'sent';
              } })();
              return Promise.race([go, late]);
            };
            const wait = (ms) => new Promise((res) => setTimeout(res, ms));
            const M = \(MealioScripts.jsStringLiteral(GuardBrowserTests.mutation));
            const r = {};
            \(body)
            return JSON.stringify(r);
            """)
        return try XCTUnwrap(JSONValue.parse(text)?.objectValue, "not a JSON object: \(text)")
    }

    private func all(_ value: JSONValue, _ keys: [String]) -> [String: JSONValue] {
        var o: [String: JSONValue] = [:]
        for k in keys { o[k] = value }
        return o
    }

    @MainActor
    func testChecksFetchAndXHRInASameOriginIframeHoweverItIsReached() async throws {
        let web = try await page()
        let out = try await run(web, """
            const a = document.createElement('iframe'); document.body.appendChild(a);
            const b = document.createElement('iframe'); b.src = '/frame'; document.body.appendChild(b);
            await Promise.race([new Promise((res) => b.addEventListener('load', res)), wait(2000)]);
            const c = document.createElement('div'); c.innerHTML = '<iframe></iframe>'; document.body.appendChild(c);
            await wait(0);
            const xhr = (w) => t(() => { const x = new w.XMLHttpRequest(); x.open('POST', '/graphql'); x.send(M); });
            r.appendedBody = await t(() => a.contentWindow.fetch('/graphql', { method: 'POST', body: M }));
            r.appendedPath = await t(() => a.contentWindow.fetch('/checkout/submit', { method: 'POST' }));
            r.viaDocument = await t(() => a.contentDocument.defaultView.fetch('/graphql', { method: 'POST', body: M }));
            r.navigated = await t(() => window.frames[1].fetch('/graphql', { method: 'POST', body: M }));
            r.innerHtml = await t(() => window.frames[2].fetch('/graphql', { method: 'POST', body: M }));
            r.xhr = await xhr(a.contentWindow);
            // WebKit runs the document-start copy in an added about:blank frame
            // too (Chromium's init script does not), so that frame's guard is
            // its own, and this Blob is from another realm. Before round 6 the
            // guard knew a Blob by instanceof, missed it and sent it; it now
            // knows one by its brand (Blob's own size getter), from any frame.
            r.blobFromTop = await t(() => a.contentWindow.fetch('/graphql', { method: 'POST', body: new Blob([M]) }));
            r.allowed = await t(() => a.contentWindow.fetch('/graphql', { method: 'POST', body: '{"operationName":"cartItemsV2"}' }));
            """)
        XCTAssertEqual(out, [
            "appendedBody": "blocked_operation", "appendedPath": "blocked_path", "viaDocument": "blocked_operation",
            "navigated": "blocked_operation", "innerHtml": "blocked_operation", "xhr": "blocked_operation",
            "blobFromTop": "blocked_operation", "allowed": "sent",
        ])
    }

    @MainActor
    func testGuardsASameOriginFrameUsedInTheSameTickWhicheverDOMCallAddedIt() async throws {
        let pages = TestPages()
        let web = try await page(pages: pages)
        let out = try await run(web, """
            // Each frame lands last in the page, so it is window[window.length - 1],
            // reached without touching the element (whose getters are hooked).
            const last = () => window[window.length - 1];
            const box = () => { const b = document.createElement('div'); document.body.appendChild(b); return b; };
            const frame = () => document.createElement('iframe');
            const send = () => t(() => last().fetch('/checkout/same-tick', { method: 'POST' }));
            document.body.append(frame()); r.append = await send();
            box().prepend(frame()); r.prepend = await send();
            { const b = box(), s = document.createElement('span'); b.appendChild(s); s.before(frame()); } r.before = await send();
            { const b = box(), s = document.createElement('span'); b.appendChild(s); s.after(frame()); } r.after = await send();
            { const b = box(), s = document.createElement('span'); b.appendChild(s); s.replaceWith(frame()); } r.replaceWith = await send();
            { const b = box(), s = document.createTextNode('x'); b.appendChild(s); s.after(frame()); } r.textAfter = await send();
            box().replaceChildren(frame()); r.replaceChildren = await send();
            document.body.insertAdjacentElement('beforeend', frame()); r.insertAdjacentElement = await send();
            box().insertAdjacentHTML('beforeend', '<iframe></iframe>'); r.insertAdjacentHTML = await send();
            { const b = box(), s = document.createElement('span'); b.appendChild(s); s.insertAdjacentHTML('afterend', '<iframe></iframe>'); } r.adjacentAfterEnd = await send();
            box().innerHTML = '<p><iframe></iframe></p>'; r.innerHTML = await send();
            { const b = box(), s = document.createElement('span'); b.appendChild(s); s.outerHTML = '<iframe></iframe>'; } r.outerHTML = await send();
            { const f = document.createDocumentFragment(); f.appendChild(document.createElement('p')).appendChild(frame()); box().append(f); } r.fragment = await send();
            { const f = document.createDocumentFragment(); f.appendChild(frame()); document.body.appendChild(f); } r.fragmentAppendChild = await send();
            """)
        let keys = ["append", "prepend", "before", "after", "replaceWith", "textAfter", "replaceChildren",
                    "insertAdjacentElement", "insertAdjacentHTML", "adjacentAfterEnd", "innerHTML", "outerHTML",
                    "fragment", "fragmentAppendChild"]
        XCTAssertEqual(out, all("blocked_path", keys))
        XCTAssertEqual(pages.reached.filter { $0.contains("same-tick") }, [])
    }

    @MainActor
    func testWorkerPrototypeConstructorIsTheGuardedConstructor() async throws {
        let web = try await page()
        let out = try await run(web, """
            const src = 'fetch("/checkout/ctor", { method: "POST" })';
            const blob = () => URL.createObjectURL(new Blob([src], { type: 'text/javascript' }));
            r.worker = await t(() => new Worker.prototype.constructor(blob()));
            // WebKit has SharedWorker from iOS 16; the simulator CI runs is newer.
            r.shared = typeof SharedWorker === 'function' ? await t(() => new SharedWorker.prototype.constructor(blob())) : 'no SharedWorker';
            r.same = Worker.prototype.constructor === Worker && (typeof SharedWorker !== 'function' || SharedWorker.prototype.constructor === SharedWorker);
            """)
        XCTAssertEqual(out, ["worker": "blocked_worker", "shared": "blocked_worker", "same": true])
    }

    @MainActor
    func testRefusesBlobAndDataWorkersInThePageAndInAFrame() async throws {
        let web = try await page()
        let out = try await run(web, """
            const src = 'fetch("/checkout/w", { method: "POST" })';
            const a = document.createElement('iframe'); document.body.appendChild(a);
            r.blob = await t(() => new Worker(URL.createObjectURL(new Blob([src], { type: 'text/javascript' }))));
            r.data = await t(() => new Worker('data:text/javascript,' + encodeURIComponent(src)));
            r.shared = typeof SharedWorker === 'function' ? await t(() => new SharedWorker(URL.createObjectURL(new Blob([src], { type: 'text/javascript' })))) : 'no SharedWorker';
            r.frame = await t(() => new a.contentWindow.Worker(URL.createObjectURL(new Blob([src], { type: 'text/javascript' }))));
            """)
        XCTAssertEqual(out, all("blocked_worker", ["blob", "data", "shared", "frame"]))
    }

    /// The DOM hooks reach a frame only once the page touches it; a frame's
    /// own first script runs before that. So WebViewHost also injects the
    /// guard into every frame at document start. A frame that loads into an
    /// armed page arms itself from its parent.
    @MainActor
    func testNeedsTheDocumentStartInjectionInEveryFrameForAFramesOwnFirstScript() async throws {
        func hits(allFrames: Bool) async throws -> [String] {
            let pages = TestPages()
            let top = allFrames ? "" : "<script>\(MealioScripts.guardScript)</script>" // main frame only
            pages.pages = [
                "/": "<html><head>\(top)</head><body></body></html>",
                // A second navigation: the first one reuses the frame's about:blank window.
                "/hop": "<script>location.replace('/inner')</script>",
                "/inner": "<script>fetch('/checkout/first', { method: 'POST' }).catch(function () {});</script>",
            ]
            let web = try await page(allFrames: allFrames, pages: pages)
            _ = try await js(web, """
                const f = document.createElement('iframe'); f.src = '/hop'; document.body.appendChild(f);
                await new Promise((res) => setTimeout(res, 800));
                return 'done';
                """)
            return pages.reached
        }
        let bare = try await hits(allFrames: false)
        XCTAssertEqual(bare, ["/checkout/first"])
        let guarded = try await hits(allFrames: true)
        XCTAssertEqual(guarded, [])
    }

    @MainActor
    func testReadsBOMJSONAndRawMultipartText() async throws {
        let pages = TestPages()
        let web = try await page(pages: pages)
        let out = try await run(web, """
            const mp = '--b\\r\\nContent-Disposition: form-data; name="operations"\\r\\n\\r\\n' + M + '\\r\\n--b--';
            r.bom = await t(() => fetch('/graphql', { method: 'POST', body: '\\ufeff' + M }));
            r.multipart = await t(() => fetch('/graphql', { method: 'POST', headers: { 'content-type': 'multipart/form-data; boundary=b' }, body: mp }));
            """)
        XCTAssertEqual(out, all("blocked_operation", ["bom", "multipart"]))
        XCTAssertEqual(pages.reached.filter { $0.contains("checkout") }, [])
    }

    // MARK: round 5: the guard arms when Mealio uses the page

    /// The challenge frame makes a blob: worker and fetches its own /payment
    /// path, as Cloudflare's does, on load and again when asked. The guard
    /// never installs there, armed page or not.
    @MainActor
    func testNeverRunsInACrossOriginFrameATurnstileStyleBlobWorkerWorksThereArmedOrNot() async throws {
        let pages = TestPages()
        pages.pages = [
            "/": "<html><head><script>window.msgs = []; addEventListener('message', function (e) { msgs.push(e.data); });</script></head>"
                + "<body><iframe src=\"\(TestPages.scheme)://challenges.cloudflare.com/turnstile\"></iframe></body></html>",
            "challenges.cloudflare.com/turnstile": """
                <script>
                  function go() {
                    var out = { guard: typeof window.__mealioGuard, arm: typeof window.__mealioArm };
                    var src = 'postMessage("pow")';
                    try {
                      var w = new Worker(URL.createObjectURL(new Blob([src], { type: 'text/javascript' })));
                      w.onmessage = function (e) {
                        out.worker = e.data;
                        fetch('/payment/pat', { method: 'POST' }).then(function () { out.fetch = 'sent'; }, function (e) { out.fetch = String(e.message); })
                          .then(function () { parent.postMessage(out, '*'); });
                      };
                    } catch (e) { out.worker = String(e.message); parent.postMessage(out, '*'); }
                  }
                  addEventListener('message', go); go();
                </script>
                """,
        ]
        let web = try await page(pages: pages, arm: false)
        let want: [String: JSONValue] = ["guard": "undefined", "arm": "undefined", "worker": "pow", "fetch": "sent"]
        try await until(web, "msgs.length === 1")
        let first = try await js(web, "return JSON.stringify(msgs[0]);")
        XCTAssertEqual(JSONValue.parse(first)?.objectValue, want, first)
        try await arm(web)
        _ = try await js(web, "frames[0].postMessage('again', '*'); return 'ok';")
        try await until(web, "msgs.length === 2")
        let second = try await js(web, "return JSON.stringify(msgs[1]);")
        XCTAssertEqual(JSONValue.parse(second)?.objectValue, want, second)
        XCTAssertEqual(pages.reached.filter { $0.contains("/payment/pat") }.count, 2)
    }

    /// The store's own boot code runs before any Mealio script: its blob
    /// worker, its fetch to a /payment path and its burst of requests all go
    /// through, and none of them count toward the rate cap once armed.
    @MainActor
    func testLeavesTheStoresBootAloneItsWorkerItsPaymentFetchesItsTrafficVolumeThenBlocksOnceArmed() async throws {
        let pages = TestPages()
        let boot = """
            <script>
              window.boot = { fetches: 0 };
              var w = new Worker(URL.createObjectURL(new Blob(['postMessage("boot worker")'], { type: 'text/javascript' })));
              w.onmessage = function (e) { window.boot.worker = e.data; };
              fetch('/api/payment/config').then(function () { window.boot.payment = 'sent'; }, function (e) { window.boot.payment = e.message; });
              var x = new XMLHttpRequest(); x.open('POST', '/graphql'); x.send(\(MealioScripts.jsStringLiteral(GuardBrowserTests.mutation))); window.boot.xhr = 'sent';
              for (var i = 0; i < 250; i++) fetch('/api/boot/' + i).then(function () { window.boot.fetches++; }, function () {});
            </script>
            """
        pages.pages = ["/": "<html><head>\(boot)</head><body></body></html>"]
        let web = try await page(pages: pages, arm: false)
        try await until(web, "window.boot.fetches === 250 && window.boot.worker && window.boot.payment")
        let bootText = try await js(web, "return JSON.stringify(window.boot);")
        let booted = JSONValue.parse(bootText)?.objectValue
        XCTAssertEqual(booted, ["fetches": 250, "worker": "boot worker", "payment": "sent", "xhr": "sent"])
        XCTAssertTrue(pages.reached.contains("/api/payment/config"))
        XCTAssertTrue(pages.reached.contains("/graphql"))
        try await arm(web)
        let out = try await run(web, """
            r.after = await t(() => fetch('/api/after'));
            r.payment = await t(() => fetch('/api/payment/config'));
            r.body = await t(() => fetch('/graphql', { method: 'POST', body: M }));
            r.worker = await t(() => new Worker(URL.createObjectURL(new Blob(['1'], { type: 'text/javascript' }))));
            """)
        // The 250 boot requests did not count toward the 240 a minute.
        XCTAssertEqual(out, ["after": "sent", "payment": "blocked_path", "body": "blocked_operation", "worker": "blocked_worker"])
    }

    @MainActor
    func testArmingArmsTheFramesThePageAlreadyHasNestedOnesTooAndFramesThatLoadLater() async throws {
        let pages = TestPages()
        pages.pages = [
            "/": "<html><body><iframe src=\"/frame\"></iframe></body></html>",
            "/frame": "<html><body><iframe></iframe></body></html>",
            "/later": "<html><body>later</body></html>",
        ]
        let web = try await page(pages: pages, arm: false)
        try await until(web, "frames[0] && frames[0].document.readyState === 'complete' && frames[0].frames.length === 1")
        func send(_ w: String) -> String { "await t(() => \(w).fetch('/checkout/x', { method: 'POST' }))" }
        let before = try await run(web, """
            const a = document.createElement('iframe'); document.body.appendChild(a);
            r.top = \(send("window")); r.frame = \(send("frames[0]")); r.nested = \(send("frames[0].frames[0]"));
            r.added = \(send("frames[1]")); r.armed = window.__mealioArmed();
            """)
        XCTAssertEqual(before, ["top": "sent", "frame": "sent", "nested": "sent", "added": "sent", "armed": false])
        try await arm(web)
        let after = try await run(web, """
            const b = document.createElement('iframe'); b.src = '/later'; document.body.appendChild(b);
            await Promise.race([new Promise((res) => b.addEventListener('load', res)), wait(3000)]);
            r.top = \(send("window")); r.frame = \(send("frames[0]")); r.nested = \(send("frames[0].frames[0]"));
            r.added = \(send("frames[1]")); r.later = \(send("frames[2]"));
            """)
        XCTAssertEqual(after, all("blocked_path", ["top", "frame", "nested", "added", "later"]))
        XCTAssertEqual(pages.reached.filter { $0.contains("checkout") }.count, 4)
        // The page cannot turn it off or swap the switch.
        let tamper = try await run(web, """
            try { window.__mealioArm = () => {}; window.__mealioArmed = () => false; delete window.__mealioArm; } catch (e) {}
            r.armed = window.__mealioArmed(); r.send = \(send("window"));
            """)
        XCTAssertEqual(tamper, ["armed": true, "send": "blocked_path"])
    }

    /// No document-start copy here, only the per-script one (the Android
    /// path). WebKit has setHTMLUnsafe from iOS 17.4; older simulators skip it.
    @MainActor
    func testOnceArmedBlocksAFrameMadeBySetHTMLUnsafeAShadowRootARangeExecCommandOrDocumentWrite() async throws {
        let pages = TestPages()
        pages.pages = ["/": "<html><body><div id=\"h\"></div></body></html>"]
        let web = try await page(allFrames: false, pages: pages, arm: true)
        let out = try await run(web, """
            const last = () => window[window.length - 1];
            const box = () => { const b = document.createElement('div'); document.body.appendChild(b); return b; };
            const send = (w) => t(() => (w || last()).fetch('/checkout/r5', { method: 'POST', body: M }));
            const unsafe = typeof Element.prototype.setHTMLUnsafe === 'function';
            if (unsafe) { box().setHTMLUnsafe('<iframe></iframe>'); r.setHTMLUnsafe = await send(); } else r.setHTMLUnsafe = 'missing';
            // A frame in a shadow tree is not in window.frames: only its element reaches it.
            if (unsafe) { const sr = box().attachShadow({ mode: 'open' }); sr.setHTMLUnsafe('<iframe></iframe>'); r.shadowSetHTMLUnsafe = await send(sr.querySelector('iframe').contentWindow); } else r.shadowSetHTMLUnsafe = 'missing';
            { const sr = box().attachShadow({ mode: 'open' }); sr.innerHTML = '<iframe></iframe>'; r.shadowInnerHTML = await send(sr.querySelector('iframe').contentWindow); }
            { const g = document.createRange(); g.selectNodeContents(box()); g.insertNode(document.createElement('iframe')); } r.rangeInsertNode = await send();
            { const b = box(); b.appendChild(document.createElement('span')); const g = document.createRange(); g.selectNodeContents(b); g.surroundContents(document.createElement('iframe')); } r.surroundContents = await send();
            { const d = document.getElementById('h'); d.contentEditable = 'true'; d.focus(); document.execCommand('insertHTML', false, '<iframe></iframe>'); } r.execCommand = await send();
            { const a = document.createElement('iframe'); document.body.appendChild(a); a.contentDocument.write('<iframe></iframe>'); r.frameWrite = await send(a.contentWindow.frames[0]); }
            { const a = document.createElement('iframe'); document.body.appendChild(a); a.contentDocument.writeln('<iframe></iframe>'); r.frameWriteln = await send(a.contentWindow.frames[0]); }
            """)
        XCTAssertEqual(out.count, 8)
        for (k, v) in out {
            if k.lowercased().contains("sethtmlunsafe"), v == "missing" { continue }
            XCTAssertEqual(v, "blocked_path", k)
        }
        // Last, as it replaces the page: document.write on the loaded top
        // document, then frames[n].fetch.
        let write = try await js(web, """
            const t = async (f) => { try { await f(); return 'sent'; } catch (e) { return String(e && e.message || e).replace('mealio guard: ', ''); } };
            document.write('<body><iframe></iframe></body>');
            const r = await t(() => frames[0].fetch('/graphql', { method: 'POST', body: \(MealioScripts.jsStringLiteral(GuardBrowserTests.mutation)) }));
            document.close();
            return r;
            """)
        XCTAssertEqual(write, "blocked_operation")
        XCTAssertEqual(pages.reached.filter { $0.contains("checkout") || $0.contains("graphql") }, [])
    }

    // MARK: round 6: the guard decides with captured built-ins
    // Mirrors packages/core/test/round6.browser.test.ts (all but the popup
    // test, which needs a WKUIDelegate). Guard only: no block list.

    private static let placeOrder = #"{"operationName":"PlaceOrder","query":"mutation PlaceOrder { placeOrder { id } }"}"#

    /// `body` in the page, with round6.browser.test.ts's `t` and `PO`; it
    /// returns a value, which comes back as JSON.
    @MainActor
    private func run6(_ web: WKWebView, _ body: String) async throws -> JSONValue {
        let text = try await js(web, """
            const t = async (f) => { try { const r = await f(); return r === false ? 'false' : 'sent'; } catch (e) { return String(e && e.message || e).replace('mealio guard: ', ''); } };
            const PO = \(MealioScripts.jsStringLiteral(GuardBrowserTests.placeOrder));
            const result = await (async () => { \(body) })();
            return JSON.stringify(result);
            """)
        return try XCTUnwrap(JSONValue.parse(text), "not JSON: \(text)")
    }

    @MainActor
    func testDecidesWithTheBuiltInsItCapturedWhateverThePageReplacesLater() async throws {
        let pages = TestPages()
        let web = try await page(pages: pages)
        let poisons: [(String, String)] = [
            ("RegExp.prototype.test", "RegExp.prototype.test = function () { return false; }"),
            ("RegExp.prototype.exec", "RegExp.prototype.exec = function () { return null; }"),
            ("window.URL", "window.URL = function () { return { pathname: \"/ok\", search: \"\" }; }"),
            ("URL.prototype.pathname", "Object.defineProperty(URL.prototype, \"pathname\", { get: function () { return \"/ok\"; }, configurable: true })"),
            ("Blob.prototype.text", "Blob.prototype.text = function () { return Promise.resolve(\"\"); }"),
            ("String", "window.String = function () { return \"\"; }"),
            ("JSON.parse", "JSON.parse = function () { return {}; }"),
            ("Array.prototype.push", "Array.prototype.push = function () { return 0; }"),
            ("Promise.prototype.then", "Promise.prototype.then = function (ok) { ok(\"\"); }"),
        ]
        let want: JSONValue = ["path": "blocked_path", "json": "blocked_operation", "blob": "blocked_operation", "doc": "blocked_operation"]
        for (name, poison) in poisons {
            // Each call runs, and the original is put back, inside one evaluation.
            let got = try await run6(web, """
                const saved = { t: RegExp.prototype.test, x: RegExp.prototype.exec, U: window.URL, p: Object.getOwnPropertyDescriptor(URL.prototype, 'pathname'),
                  b: Blob.prototype.text, S: window.String, j: JSON.parse, i: String.prototype.indexOf, a: Array.prototype.push, th: Promise.prototype.then,
                  c: Function.prototype.call, ap: Function.prototype.apply };
                const go = (f) => { try { return f(); } catch (e) { return Promise.reject(e); } };
                const doc = 'query=' + encodeURIComponent('mutation { placeOrder { id } }'), blob = new Blob([PO]);
                \(poison);
                const out = {};
                const done = [];
                done[0] = go(() => fetch('/checkout/a', { method: 'POST' }));
                done[1] = go(() => fetch('/graphql', { method: 'POST', body: PO }));
                done[2] = go(() => fetch('/graphql', { method: 'POST', body: blob }));
                done[3] = go(() => fetch('/graphql', { method: 'POST', body: doc }));
                RegExp.prototype.test = saved.t; RegExp.prototype.exec = saved.x; window.URL = saved.U; Object.defineProperty(URL.prototype, 'pathname', saved.p);
                Blob.prototype.text = saved.b; window.String = saved.S; JSON.parse = saved.j; String.prototype.indexOf = saved.i; Array.prototype.push = saved.a;
                Promise.prototype.then = saved.th; Function.prototype.call = saved.c; Function.prototype.apply = saved.ap;
                out.path = await t(() => done[0]);
                out.json = await t(() => done[1]);
                out.blob = await t(() => done[2]);
                out.doc = await t(() => done[3]);
                return out;
                """)
            XCTAssertEqual(got, want, name)
        }
        XCTAssertEqual(pages.reached, [])
    }

    @MainActor
    func testNeverHandsThePageAnOriginalThroughFunctionPrototypeCallOrApply() async throws {
        let web = try await page()
        let leaked = try await run6(web, """
            const seen = [], C = Function.prototype.call, A = Function.prototype.apply, R = Reflect.apply;
            Function.prototype.call = function (self, ...args) { seen.push(this); return R(this, self, args); };
            Function.prototype.apply = function (self, args) { seen.push(this); return R(this, self, args || []); };
            const frame = document.createElement('iframe');
            let pending;
            try {
              pending = fetch('/graphql/ok', { method: 'POST', body: '{"operationName":"Search"}' });
              navigator.sendBeacon('/graphql/ok2', 'x=1');
              const x = new XMLHttpRequest(); x.open('POST', '/graphql/ok3'); x.send('x=1');
              document.body.appendChild(frame); void frame.contentWindow;
            } finally { Function.prototype.call = C; Function.prototype.apply = A; }
            try { await pending; } catch (e) {}
            const originals = [];
            for (const f of seen) {
              if (typeof f !== 'function' || !/\\[native code\\]/.test(Function.prototype.toString.call(f))) continue;
              if (f === window.fetch || f === navigator.sendBeacon || f === XMLHttpRequest.prototype.send || f === XMLHttpRequest.prototype.open) continue;
              if (/^(fetch|sendBeacon|send|open|get contentWindow|appendChild)$/.test(f.name)) originals.push(f.name);
            }
            return originals;
            """)
        XCTAssertEqual(leaked, [])
    }

    @MainActor
    func testReadsAStringObjectOrAnObjectWithToStringAsItsTextInFetchXHRAndBeacons() async throws {
        let pages = TestPages()
        let web = try await page(pages: pages)
        let got = try await run6(web, """
            const H = { 'content-type': 'application/json' };
            return {
              fetchString: await t(() => fetch('/graphql/1', { method: 'POST', headers: H, body: new String(PO) })),
              fetchObject: await t(() => fetch('/graphql/2', { method: 'POST', headers: H, body: { toString: () => PO } })),
              xhr: await t(() => new Promise((ok, no) => { const x = new XMLHttpRequest(); x.open('POST', '/graphql/3'); x.onload = ok; x.onerror = no; x.send(new String(PO)); })),
              beacon: await t(() => navigator.sendBeacon('/graphql/4', new String(PO))),
              innocent: await t(() => fetch('/graphql/5', { method: 'POST', headers: H, body: new String('{"operationName":"Search"}') })),
            };
            """)
        XCTAssertEqual(got, ["fetchString": "blocked_operation", "fetchObject": "blocked_operation", "xhr": "blocked_operation",
                             "beacon": "false", "innocent": "sent"])
        XCTAssertEqual(pages.reached, ["/graphql/5"])
    }

    @MainActor
    func testJudgesFormSubmissionsSubmitRequestSubmitAndAButtonClick() async throws {
        let pages = TestPages()
        let web = try await page(pages: pages)
        let got = try await run6(web, """
            const frame = document.createElement('iframe'); frame.name = 'tgt'; document.body.appendChild(frame);
            const form = (action, field) => {
              const f = document.createElement('form'); f.method = 'POST'; f.action = action; f.target = 'tgt';
              const i = document.createElement('input'); i.name = field[0]; i.value = field[1]; f.appendChild(i);
              const b = document.createElement('button'); b.type = 'submit'; f.appendChild(b);
              document.body.appendChild(f); return f;
            };
            const out = {};
            out.submitPath = await t(() => form('/checkout/f1', ['x', '1']).submit());
            out.submitBody = await t(() => form('/graphql/f2', ['operationName', 'PlaceOrder']).submit());
            out.requestSubmit = await t(() => form('/checkout/f3', ['x', '1']).requestSubmit());
            const f4 = form('/graphql/f4', ['query', 'mutation { submitOrder { id } }']);
            let seen = 'no event'; f4.addEventListener('submit', (e) => { seen = e.defaultPrevented ? 'prevented' : 'went'; });
            f4.querySelector('button').click();
            out.click = seen;
            const f5 = form('/graphql/f5', ['x', '1']);
            f5.querySelector('button').setAttribute('formaction', '/checkout/f5');
            out.formaction = await t(() => f5.requestSubmit(f5.querySelector('button')));
            out.innocent = await t(() => form('/search', ['q', 'milk']).submit());
            await new Promise((res) => setTimeout(res, 500));
            return out;
            """)
        // The click's event never reached the page's own listener: the guard stopped it first.
        XCTAssertEqual(got, ["submitPath": "blocked_path", "submitBody": "blocked_operation", "requestSubmit": "blocked_path",
                             "click": "no event", "formaction": "blocked_path", "innocent": "sent"])
        for _ in 0..<300 where !pages.reached.contains("/search") {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(pages.reached, ["/search"])
    }

    @MainActor
    func testArmingArmsAFrameThatSitsInAnOpenShadowRoot() async throws {
        let pages = TestPages()
        let web = try await page(pages: pages, arm: false)
        // The store, before arming: a widget whose frames live in nested open shadow roots.
        _ = try await js(web, """
            await new Promise((done) => {
              const host = document.createElement('div'); document.body.appendChild(host);
              const outer = host.attachShadow({ mode: 'open' });
              const inner = document.createElement('div'); outer.appendChild(inner);
              const deep = inner.attachShadow({ mode: 'open' });
              const a = document.createElement('iframe'); a.src = '/frame'; a.onload = () => done(); outer.appendChild(a);
              const b = document.createElement('iframe'); deep.appendChild(b);
              window.__w = [a.contentWindow, b.contentWindow];
              setTimeout(done, 3000);
            });
            return 'ok';
            """)
        try await arm(web)
        let got = try await run6(web, """
            const out = [];
            for (const w of window.__w) {
              let r; try { await w.fetch('/checkout/s', { method: 'POST' }); r = 'sent'; } catch (e) { r = e.message; }
              out.push(w.__mealioArmed() + ' ' + r);
            }
            return out;
            """)
        XCTAssertEqual(got, ["true mealio guard: blocked_path", "true mealio guard: blocked_path"])
        XCTAssertEqual(pages.reached, [])
    }

    // MARK: round 6: the network block list (NetworkBlock.swift)

    @MainActor
    func testTheNetworkBlockListCompilesInWebKit() async throws {
        let list = try await BlockedPathRules.shared.list()
        XCTAssertEqual(list.identifier, NetworkBlock.identifier)
    }

    /// Page code has replaced RegExp.prototype.test and window.URL, which the
    /// in-page guard reads. A fetch, an XHR, a form posted into an iframe and
    /// a frame navigated to a checkout path still never reach the handler:
    /// WebKit refuses them outside the page. The same four to an ordinary
    /// path do reach it, so the handler would have seen them. Run with the
    /// guard unarmed (the store's own code, which the guard never judges)
    /// and armed.
    @MainActor
    func testTheNetworkBlockStopsCheckoutRequestsThePageGuardCannotEvenWhenPageCodeTamperedWithIt() async throws {
        for armed in [false, true] {
            let pages = TestPages()
            let web = try await page(pages: pages, arm: armed, rules: true)
            let tag = armed ? "armed" : "unarmed"
            _ = try await run(web, """
                RegExp.prototype.test = function () { return false; };
                window.URL = function () { return { pathname: '/', search: '', protocol: 'https:', href: location.href }; };
                // An innocent body: these test the path alone.
                const B = '{"operationName":"cartItemsV2"}';
                const xhr = (u) => new Promise((res) => {
                  const x = new XMLHttpRequest();
                  x.onload = () => res('loaded'); x.onerror = () => res('error');
                  try { x.open('POST', u); x.send(B); } catch (e) { res('threw'); }
                  setTimeout(() => res('late'), 1500);
                });
                const post = (action, sink) => {
                  const f = document.createElement('iframe'); f.name = sink; document.body.appendChild(f);
                  const form = document.createElement('form'); form.method = 'POST'; form.action = action; form.target = sink;
                  const i = document.createElement('input'); i.name = 'operationName'; i.value = 'cartItemsV2'; form.appendChild(i);
                  document.body.appendChild(form);
                  HTMLFormElement.prototype.submit.call(form);
                };
                const navigate = async (to) => {
                  const g = document.createElement('iframe'); g.src = '/frame'; document.body.appendChild(g);
                  await Promise.race([new Promise((res) => g.addEventListener('load', res)), wait(2000)]);
                  g.contentWindow.location.href = to;
                };
                for (const [base, n] of [['/checkout/\(tag)', 'blocked'], ['/api/\(tag)', 'open']]) {
                  r[n + 'Fetch'] = await t(() => fetch(base + '-fetch', { method: 'POST', body: B }));
                  r[n + 'Xhr'] = await xhr(base + '-xhr');
                  post(base + '-form', n + 'sink');
                  await navigate(base + '-nav');
                }
                """)
            // The ordinary four arrive (bounded wait); the blocked four have had as long.
            let open = ["fetch", "xhr", "form", "nav"].map { "/api/\(tag)-\($0)" }
            for _ in 0..<300 where !open.allSatisfy({ pages.reached.contains($0) }) {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertEqual(open.filter { !pages.reached.contains($0) }, [], "\(tag): the handler never saw \(pages.reached)")
            XCTAssertEqual(pages.reached.filter { $0.contains("checkout") }, [], tag)
        }
    }

    /// The block list judges the path and query, never the host, and reads
    /// a path a server would decode: %63heckout is checkout.
    @MainActor
    func testTheNetworkBlockReadsThePathNotTheHostAndRefusesEncodedLetters() async throws {
        let pages = TestPages()
        let web = try await page(pages: pages, arm: false, rules: true)
        _ = try await run(web, """
            // A frame, not a fetch: a cross-origin fetch to a custom scheme may be refused before it is sent.
            { const f = document.createElement('iframe'); f.src = '\(TestPages.scheme)://checkout.heb.com/api/host'; document.body.appendChild(f); }
            r.encoded = await t(() => fetch('/%63heckout/encoded', { method: 'POST', body: '{}' }));
            r.twice = await t(() => fetch('/%2563heckout/twice', { method: 'POST', body: '{}' }));
            r.query = await t(() => fetch('/api/q?next=%2Fcart&q=green%20beans', { method: 'POST', body: '{}' }));
            """)
        for _ in 0..<300 where !(["checkout.heb.com/api/host", "/api/q"].allSatisfy { pages.reached.contains($0) }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(pages.reached.contains("checkout.heb.com/api/host"), "\(pages.reached)")
        XCTAssertTrue(pages.reached.contains("/api/q"), "\(pages.reached)")
        XCTAssertEqual(pages.reached.filter { $0.contains("encoded") || $0.contains("twice") }, [])
    }
}
#endif
