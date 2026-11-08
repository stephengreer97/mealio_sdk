// The guard in a real WKWebView, set up as WebViewHost sets up its pages (the
// guard as a document-start user script in every frame). Mirrors
// packages/core/test/guard.browser.test.ts. iOS only: run with xcodebuild,
// not `swift test`.
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
        let html = pages[path]
        if html == nil { reached.append(path) }
        let type = html == nil ? "application/json" : "text/html"
        if let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type]) {
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

    private static let mutation = #"{"query":"mutation { placeOrder { id } }"}"#

    /// A page set up like WebViewHost's (the guard in every frame at document
    /// start), or with the guard only in the main frame's own markup.
    @MainActor
    private func page(allFrames: Bool = true, pages given: TestPages? = nil) async throws -> WKWebView {
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
        // Bounded: 3 seconds at most.
        for _ in 0..<300 {
            try await Task.sleep(nanoseconds: 10_000_000)
            if !web.isLoading { break }
        }
        XCTAssertFalse(web.isLoading, "the test page did not load in 3s")
        return web
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
    /// guard into every frame at document start.
    @MainActor
    func testNeedsTheDocumentStartInjectionInEveryFrameForAFramesOwnFirstScript() async throws {
        func first(allFrames: Bool) async throws -> String {
            let pages = TestPages()
            let top = allFrames ? "" : "<script>\(MealioScripts.guardScript)</script>" // main frame only
            pages.pages = [
                "/": "<html><head>\(top)</head><body><iframe src=\"/hop\"></iframe></body></html>",
                // A second navigation: the first one reuses the frame's about:blank window.
                "/hop": "<script>location.replace('/inner')</script>",
                "/inner": "<script>window.__first = window.__mealioGuard ? 'guarded' : 'bare';</script>",
            ]
            let web = try await page(allFrames: allFrames, pages: pages)
            return try await js(web, """
                for (let i = 0; i < 30; i++) {
                  const f = window.frames[0];
                  if (f && f.__first) return f.__first;
                  await new Promise((res) => setTimeout(res, 100));
                }
                return 'no frame';
                """)
        }
        let bare = try await first(allFrames: false)
        XCTAssertEqual(bare, "bare")
        let guarded = try await first(allFrames: true)
        XCTAssertEqual(guarded, "guarded")
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
}
#endif
