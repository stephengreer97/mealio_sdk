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

    /// The run's first page load has happened (it may take longer).
    @MainActor private static var firstLoadDone = false

    private static let mutation = #"{"query":"mutation { placeOrder { id } }"}"#

    /// A page set up like WebViewHost's (the guard in every frame at document
    /// start), or with the guard only in the main frame's own markup. `arm`:
    /// then inject the per-script copy, as the runner does before a script.
    @MainActor
    private func page(allFrames: Bool = true, pages given: TestPages? = nil, arm: Bool = true) async throws -> WKWebView {
        let pages = given ?? TestPages()
        let config: WKWebViewConfiguration
        if allFrames {
            config = WebViewHost.makeConfiguration(handler: ScriptHandler())
        } else {
            config = WKWebViewConfiguration()
        }
        config.setURLSchemeHandler(pages, forURLScheme: TestPages.scheme)
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: config)
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
}
#endif
