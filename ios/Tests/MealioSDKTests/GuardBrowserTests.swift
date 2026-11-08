// The guard in a real WKWebView: same-origin frames get it, and workers made
// from blob: or data: URLs are refused. Mirrors packages/core/test/guard.browser.test.ts.
// iOS only: run with xcodebuild, not `swift test`.

#if canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit
import XCTest
@testable import MealioSDK

final class GuardBrowserTests: XCTestCase {

    @MainActor
    private func page() async throws -> WKWebView {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        web.loadHTMLString("<html><body></body></html>", baseURL: URL(string: "https://www.heb.com/")!)
        for _ in 0..<300 {
            try await Task.sleep(nanoseconds: 10_000_000)
            if !web.isLoading { break }
        }
        _ = try await web.evaluateJavaScript(MealioScripts.guardScript)
        return web
    }

    @MainActor
    private func run(_ web: WKWebView, _ body: String) async throws -> String {
        let out = try await web.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page)
        return (out as? String) ?? "\(String(describing: out))"
    }

    @MainActor
    func testTheGuardGoesIntoASameOriginIframeAndChecksItsFetch() async throws {
        let web = try await page()
        let got = try await run(web, """
            var f = document.createElement('iframe');
            document.body.appendChild(f);
            var framed = !!(f.contentWindow && f.contentWindow.__mealioGuard);
            var sent = 'sent';
            try { await f.contentWindow.fetch('/checkout', { method: 'POST' }); } catch (e) { sent = String(e.message); }
            return framed + '|' + sent;
            """)
        XCTAssertEqual(got, "true|mealio guard: blocked_path")
    }

    @MainActor
    func testTheGuardRefusesWorkersFromBlobAndDataUrls() async throws {
        let web = try await page()
        let got = try await run(web, """
            function tryWorker(url) {
              try { new Worker(url); return 'made'; } catch (e) { return String(e.message); }
            }
            return tryWorker(URL.createObjectURL(new Blob(['1']))) + '|' + tryWorker('data:text/javascript,1');
            """)
        XCTAssertEqual(got, "mealio guard: blocked_worker|mealio guard: blocked_worker")
    }
}
#endif
