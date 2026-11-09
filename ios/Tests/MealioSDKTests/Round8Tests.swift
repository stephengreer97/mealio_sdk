// 0.6 round 8: native blocking timing (on from a job's first script until the
// job ends, told to the host once per job however it ends) and the resource
// types the block list covers. Platform-neutral: runs with `swift test`. The
// list in a real WKWebView is in GuardBrowserTests.

import Foundation
import XCTest
@testable import MealioSDK

/// Records what the runner asked of it, `end` for each MealioHost.endJob.
@MainActor
private final class EndRecordingHost: MealioHost {
    var order: [String] = []
    var onOpen: (@MainActor () -> Void)?

    func openPage(store: String, url: String, timeoutMs: Int) async throws -> PageOpenOutcome {
        order.append("open")
        onOpen?()
        return PageOpenOutcome(ok: true, finalUrl: url)
    }

    func runScript(store: String, guardScript: String, script: String, until: [Matcher], timeoutMs: Int) async throws -> ScriptOutcome {
        order.append("script")
        return ScriptOutcome(messages: [], timedOut: false)
    }

    func showLogin(_ request: LoginRequest) async throws -> LoginOutcome {
        order.append("login")
        return LoginOutcome(outcome: .signedIn, messages: [])
    }

    func fetch(store: String, request: FetchRequest, timeoutMs: Int, maxBytes: Int) async throws -> FetchOutcome {
        order.append("fetch")
        return FetchOutcome(ok: true, status: 200, body: "")
    }

    func endJob() {
        order.append("end")
    }
}

final class Round8Tests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.handler = nil
        StubURLProtocol.hangs = false
        super.tearDown()
    }

    private let recipe = Recipe(id: "r", ingredients: [])
    private static let script: JSONValue = ["op": "page_script", "id": "s", "script": "true;", "until": [], "timeoutMs": 1000]
    private static let fail: JSONValue = ["op": "fail", "id": "f", "code": "store_unavailable", "message": "Not now"]

    @MainActor
    private func makeClient(_ host: MealioHost) -> MealioClient {
        let config = MealioClientConfig(publishableKey: "pk", sessionTokenProvider: { "tok" },
                                        baseURL: URL(string: "https://mealio.test/")!,
                                        epochProvider: { 0 }, keys: TestSigner.keys,
                                        urlSession: StubURLProtocol.session(), sdkVersion: "0")
        return MealioClient(config: config, host: host)
    }

    @MainActor
    private func code<T>(_ body: () async throws -> T) async -> String? {
        do {
            _ = try await body()
            return nil
        } catch let e as MealioError {
            return e.code
        } catch {
            return "not a MealioError: \(error)"
        }
    }

    // MARK: the host hears once per job, after the job's last call

    @MainActor
    func testAJobThatEndsDoneTellsTheHostOnceAfterItsLastCall() async throws {
        let server = JobServer()
        StubURLProtocol.handler = { req, body in
            server.rec.record(req, body: body)
            if req.url?.path.hasSuffix("/warm") == true { return (200, jsonData(["warm": .null])) }
            return server.start([jobsOpen("o"), Round8Tests.script, jobsOpen("o2"), jobsDone(jobsCart)])
        }
        let host = EndRecordingHost()
        let client = makeClient(host)
        _ = try await client.prepareCart(recipe: recipe)
        // No end between the two loads: the block stays on across navigations.
        XCTAssertEqual(host.order, ["open", "script", "open", "end"])
    }

    @MainActor
    func testAJobThatFailsOrIsCancelledTellsTheHostOnce() async throws {
        let server = JobServer()
        StubURLProtocol.handler = { req, body in
            server.rec.record(req, body: body)
            if req.url?.path.hasSuffix("/warm") == true { return (200, jsonData(["warm": .null])) }
            return server.start([jobsOpen("o"), Round8Tests.script, Round8Tests.fail])
        }
        let host = EndRecordingHost()
        let client = makeClient(host)
        let recipe = self.recipe
        let failed = await code { try await client.prepareCart(recipe: recipe) }
        XCTAssertEqual(failed, "store_unavailable")
        XCTAssertEqual(host.order, ["open", "script", "end"])

        host.order = []
        let cancel = CancelToken()
        host.onOpen = { cancel.cancel() }
        let cancelled = await code { try await client.prepareCart(recipe: recipe, cancel: cancel) }
        XCTAssertEqual(cancelled, MealioError.Code.cancelled)
        XCTAssertEqual(host.order, ["open", "end"])
    }

    @MainActor
    func testEachOfTwoJobsInARowEndsBeforeTheNextStarts() async throws {
        let server = JobServer()
        StubURLProtocol.handler = { req, body in
            server.rec.record(req, body: body)
            if req.url?.path.hasSuffix("/warm") == true { return (200, jsonData(["warm": .null])) }
            return server.start([Round8Tests.script, jobsDone(jobsCart)])
        }
        let host = EndRecordingHost()
        let client = makeClient(host)
        let recipe = self.recipe
        let a = Task { @MainActor in _ = try await client.prepareCart(recipe: recipe) }
        let b = Task { @MainActor in _ = try await client.prepareCart(recipe: recipe) }
        try await a.value
        try await b.value
        XCTAssertEqual(host.order, ["script", "end", "script", "end"])
    }

    // MARK: resource types

    /// Fetch, XHR, frames and pages, popups. Never the store's images,
    /// style sheets, scripts, fonts or media.
    func testTheListBlocksRequestsAndDocumentsNeverPageAssets() {
        for legacy in [false, true] {
            let data = Data(NetworkBlock.ruleListJSON(hosts: ["heb.com"], legacy: legacy).utf8)
            let rules = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
            XCTAssertFalse(rules.isEmpty)
            for r in rules {
                let types = ((r["trigger"] as? [String: Any])?["resource-type"] as? [String]) ?? []
                XCTAssertEqual(Set(types), Set(legacy ? ["raw", "document", "popup"] : ["fetch", "raw", "document", "popup"]))
                for asset in ["image", "style-sheet", "script", "font", "media", "svg-document"] {
                    XCTAssertFalse(types.contains(asset), asset)
                }
            }
        }
    }
}
