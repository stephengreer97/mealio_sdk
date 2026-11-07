// 0.6: one job at a time, cancelling, users, bounded waits, and the cart fixes.
// Mirrors packages/core/test/jobs.test.ts. Platform-neutral: runs with `swift test`.

import Foundation
import XCTest
@testable import MealioSDK

/// Opens and closes once. Jobs in these tests wait on it.
@MainActor
final class Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in waiting.append(c) }
    }

    func release() {
        isOpen = true
        let list = waiting
        waiting = []
        for c in list { c.resume() }
    }
}

/// What the host did, in order. Only touched on the main actor.
final class HostLog {
    var order: [String] = []
}

/// A Host whose every call can be replaced, like the TS tests' `setup(answer, host)`.
@MainActor
final class ScriptedHost: MealioHost {
    let log = HostLog()
    var open: (@MainActor (String) async -> PageOpenOutcome)?
    var script: (@MainActor () async -> ScriptOutcome)?
    var login: (@MainActor (LoginRequest) async -> LoginOutcome)?

    func openPage(store: String, url: String, timeoutMs: Int) async throws -> PageOpenOutcome {
        log.order.append("open")
        if let open = open { return await open(url) }
        return PageOpenOutcome(ok: true, finalUrl: url)
    }

    func runScript(store: String, guardScript: String, script: String, until: [Matcher], timeoutMs: Int) async throws -> ScriptOutcome {
        log.order.append("script")
        if let s = self.script { return await s() }
        return ScriptOutcome(messages: [], timedOut: false)
    }

    func showLogin(_ request: LoginRequest) async throws -> LoginOutcome {
        log.order.append("login")
        if let login = login { return await login(request) }
        return LoginOutcome(outcome: .signedIn, messages: [])
    }

    func fetch(store: String, request: FetchRequest, timeoutMs: Int, maxBytes: Int) async throws -> FetchOutcome {
        log.order.append("fetch")
        return FetchOutcome(ok: true, status: 200, body: "")
    }
}

/// The stub server's side: numbered jobs, signed envelopes, and what was sent.
final class JobServer: @unchecked Sendable {
    private let lock = NSLock()
    private var jobs = 0
    let rec = Recorder()

    /// A new job whose first envelope carries `instructions`.
    func start(_ instructions: [JSONValue]) -> (Int, Data) {
        lock.lock()
        jobs += 1
        let job = "job\(jobs)"
        lock.unlock()
        return JobServer.envelope(job: job, seq: 1, instructions, withJob: true)
    }

    /// The next envelope of `job`, for a step call.
    func step(job: String, seq: Int, _ instructions: [JSONValue]) -> (Int, Data) {
        JobServer.envelope(job: job, seq: seq, instructions, withJob: false)
    }

    private static func envelope(job: String, seq: Int, _ instructions: [JSONValue], withJob: Bool) -> (Int, Data) {
        let env = TestSigner.envelope(TestSigner.payload(seq: seq, instructions: instructions, job: job))
        var body: [String: JSONValue] = ["envelope": try! JSONValue(encoding: env)]
        if withJob { body["job"] = .string(job) }
        return (200, jsonData(.object(body)))
    }

    /// Paths without the /api/v1/sdk prefix, like the TS `paths`.
    var paths: [String] { rec.paths.map { $0.replacingOccurrences(of: "/api/v1/sdk", with: "") } }
    var auths: [String?] { rec.requests.map { $0.value(forHTTPHeaderField: "Authorization") } }
}

let jobsCart: JSONValue = ["cartId": "c", "store": "heb", "items": [], "ready": [], "needsChoice": [], "unavailable": []]
func jobsDone(_ result: JSONValue) -> JSONValue { ["op": "done", "id": "d", "result": result] }
func jobsOpen(_ id: String, timeoutMs: Int = 1000) -> JSONValue {
    ["op": "page_open", "id": .string(id), "url": "https://www.heb.com/robots.txt", "timeoutMs": .int(timeoutMs)]
}
let jobsLogin: JSONValue = ["op": "show_login", "id": "l", "url": "https://www.heb.com/login", "title": "Sign in", "doneWhen": [], "timeoutMs": 1000]

final class JobsTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.handler = nil
        StubURLProtocol.hangs = false
        super.tearDown()
    }

    private let recipe = Recipe(id: "r", ingredients: [])

    @MainActor
    private func makeClient(_ host: MealioHost, token: @escaping () async throws -> String = { "tok" },
                            timeoutMs: Int? = nil) -> MealioClient {
        var config = MealioClientConfig(publishableKey: "pk", sessionTokenProvider: token,
                                        baseURL: URL(string: "https://mealio.test/")!,
                                        epochProvider: { 0 }, keys: TestSigner.keys,
                                        urlSession: StubURLProtocol.session(), sdkVersion: "0")
        if let ms = timeoutMs { config.requestTimeoutMs = ms }
        return MealioClient(config: config, host: host)
    }

    @MainActor
    private func waitFor(_ ready: () -> Bool) async throws {
        for _ in 0..<300 {
            if ready() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out")
    }

    @MainActor
    private func tick(_ ms: UInt64 = 20) async throws {
        try await Task.sleep(nanoseconds: ms * 1_000_000)
    }

    /// The code of the error `body` throws, or nil if it does not throw.
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

    // MARK: one job at a time

    @MainActor
    func testASecondPrepareWaitsForTheFirstToEnd() async throws {
        let server = JobServer()
        StubURLProtocol.handler = { req, body in
            server.rec.record(req, body: body)
            return server.start([jobsOpen("o"), jobsDone(jobsCart)])
        }
        let gate = Gate()
        let host = ScriptedHost()
        let log = host.log
        host.open = { url in
            await gate.wait()
            log.order.append("opened")
            return PageOpenOutcome(ok: true, finalUrl: url)
        }
        let client = makeClient(host)
        let recipe = self.recipe
        let a = Task { try await client.prepareCart(recipe: recipe) }
        let b = Task { try await client.prepareCart(recipe: recipe) }
        try await waitFor { log.order == ["open"] }
        try await tick()
        XCTAssertEqual(log.order, ["open"])
        XCTAssertEqual(server.paths, ["/carts"])
        gate.release()
        _ = try await a.value
        _ = try await b.value
        XCTAssertEqual(log.order, ["open", "opened", "open", "opened"])
    }

    @MainActor
    func testAHostThatNeverAnswersEndsTheStepAtItsTimeoutPlusTheGrace() async throws {
        let server = JobServer()
        let script: JSONValue = ["op": "page_script", "id": "s", "script": "", "until": [], "timeoutMs": 100]
        StubURLProtocol.handler = { req, body in
            server.rec.record(req, body: body)
            if req.url?.path.hasSuffix("/step") == true { return server.step(job: "job1", seq: 2, [jobsDone(jobsCart)]) }
            return server.start([script])
        }
        let never = Gate()
        let host = ScriptedHost()
        host.script = {
            await never.wait()
            return ScriptOutcome(messages: [], timedOut: false)
        }
        let client = makeClient(host)
        client.runner.hostGraceMs = 50
        _ = try await client.prepareCart(recipe: recipe)
        let seen = try XCTUnwrap(server.rec.body("/api/v1/sdk/jobs/job1/step")?["results"]?.arrayValue?.first)
        XCTAssertEqual(seen["id"], .string("s"))
        XCTAssertEqual(seen["timedOut"], .bool(true))
        XCTAssertEqual(seen["messages"]?.arrayValue?.count, 0)
    }

    @MainActor
    func testAfterAHungJobEndsAWarmUpRunsAgain() async throws {
        let server = JobServer()
        StubURLProtocol.handler = { req, body in
            server.rec.record(req, body: body)
            let path = req.url?.path ?? ""
            if path.hasSuffix("/warm") { return (200, jsonData(["warm": .null])) }
            if path.hasSuffix("/step") { return server.step(job: "job1", seq: 2, [jobsDone(jobsCart)]) }
            return server.start([jobsOpen("o", timeoutMs: 100)])
        }
        let never = Gate()
        let host = ScriptedHost()
        host.open = { _ in
            await never.wait()
            return PageOpenOutcome(ok: true)
        }
        let client = makeClient(host)
        client.runner.hostGraceMs = 50
        _ = try await client.prepareCart(recipe: recipe)
        await client.warm()
        XCTAssertTrue(server.paths.contains("/warm"))
    }

    @MainActor
    func testRunExclusiveWaitsForTheJobOnThePage() async throws {
        let server = JobServer()
        StubURLProtocol.handler = { req, body in
            server.rec.record(req, body: body)
            return server.start([jobsOpen("o"), jobsDone(jobsCart)])
        }
        let gate = Gate()
        let host = ScriptedHost()
        let log = host.log
        host.open = { url in
            await gate.wait()
            log.order.append("opened")
            return PageOpenOutcome(ok: true, finalUrl: url)
        }
        let client = makeClient(host)
        let recipe = self.recipe
        let a = Task { try await client.prepareCart(recipe: recipe) }
        try await waitFor { log.order == ["open"] }
        let b = Task { try await client.runExclusive { log.order.append("exclusive") } }
        try await tick()
        XCTAssertEqual(log.order, ["open"])
        gate.release()
        _ = try await a.value
        try await b.value
        XCTAssertEqual(log.order, ["open", "opened", "exclusive"])
    }

    // MARK: bounded requests

    @MainActor
    func testARequestWithNoAnswerFailsAsNetworkAfterTheTimeout() async throws {
        StubURLProtocol.hangs = true
        let client = makeClient(ScriptedHost(), timeoutMs: 200)
        let got = await code { try await client.storePreferences() }
        XCTAssertEqual(got, MealioError.Code.network)
    }

    @MainActor
    func testA200ThatIsNotJSONIsAServerError() async throws {
        StubURLProtocol.handler = { _, _ in (200, Data("<html>portal</html>".utf8)) }
        let client = makeClient(ScriptedHost())
        let recipe = self.recipe
        let prepared = await code { try await client.prepareCart(recipe: recipe) }
        XCTAssertEqual(prepared, MealioError.Code.server)
        let stores = await code { try await client.stores() }
        XCTAssertEqual(stores, MealioError.Code.server)
    }

    @MainActor
    func testAFailedStoreListThrowsInsteadOfReadingAsNoStores() async throws {
        StubURLProtocol.handler = { _, _ in
            (503, jsonData(["error": ["code": "store_unavailable", "message": "down"]]))
        }
        let client = makeClient(ScriptedHost())
        let got = await code { try await client.stores() }
        XCTAssertEqual(got, "store_unavailable")
    }

    // MARK: session function

    private struct Down: LocalizedError {
        var errorDescription: String? { "your server is down" }
    }

    @MainActor
    func testAFailingSessionFunctionRaisesSessionFailedWithItsMessage() async throws {
        StubURLProtocol.handler = { _, _ in (200, jsonData([:])) }
        let client = makeClient(ScriptedHost(), token: { throw Down() })
        do {
            _ = try await client.storePreferences()
            XCTFail("expected session_failed")
        } catch let e as MealioError {
            XCTAssertEqual(e.code, MealioError.Code.sessionFailed)
            XCTAssertEqual(e.message, "your server is down")
        }
    }

    @MainActor
    func testASessionFunctionThatNeverAnswersRaisesSessionFailed() async throws {
        StubURLProtocol.handler = { _, _ in (200, jsonData([:])) }
        let client = makeClient(ScriptedHost(), token: {
            try await Task.sleep(nanoseconds: 10_000_000_000)
            return "late"
        }, timeoutMs: 200)
        let got = await code { try await client.storePreferences() }
        XCTAssertEqual(got, MealioError.Code.sessionFailed)
    }

    // MARK: cancelling

    @MainActor
    func testCancellingStopsAfterTheCurrentStepWithNoSignInAndNothingMoreSent() async throws {
        let server = JobServer()
        StubURLProtocol.handler = { req, body in
            server.rec.record(req, body: body)
            if req.url?.path.hasSuffix("/warm") == true { return (200, jsonData(["warm": .null])) }
            return server.start([jobsOpen("o"), jobsLogin])
        }
        let cancel = CancelToken()
        let host = ScriptedHost()
        host.open = { url in
            cancel.cancel()
            return PageOpenOutcome(ok: true, finalUrl: url)
        }
        let client = makeClient(host)
        let recipe = self.recipe
        let got = await code { try await client.prepareCart(recipe: recipe, cancel: cancel) }
        XCTAssertEqual(got, MealioError.Code.cancelled)
        XCTAssertEqual(server.paths, ["/carts"])
        XCTAssertFalse(host.log.order.contains("login"))
        // The queue is free again.
        await client.warm()
        XCTAssertEqual(server.paths, ["/carts", "/warm"])
    }

    @MainActor
    func testACancelledJobWaitingInTheQueueNeverStarts() async throws {
        let server = JobServer()
        StubURLProtocol.handler = { req, body in
            server.rec.record(req, body: body)
            return server.start([jobsOpen("o"), jobsDone(jobsCart)])
        }
        let gate = Gate()
        let host = ScriptedHost()
        host.open = { url in
            await gate.wait()
            return PageOpenOutcome(ok: true, finalUrl: url)
        }
        let client = makeClient(host)
        let recipe = self.recipe
        let a = Task { try await client.prepareCart(recipe: recipe) }
        try await waitFor { host.log.order == ["open"] }
        let cancel = CancelToken()
        let b = Task { () -> String? in
            do {
                _ = try await client.prepareCart(recipe: recipe, cancel: cancel)
                return nil
            } catch {
                return (error as? MealioError)?.code
            }
        }
        try await tick()
        cancel.cancel()
        gate.release()
        _ = try await a.value
        let got = await b.value
        XCTAssertEqual(got, MealioError.Code.cancelled)
        XCTAssertEqual(server.paths, ["/carts"])
    }

    @MainActor
    func testASignInOpenWhenItIsCancelledIsToldToClose() async throws {
        let server = JobServer()
        StubURLProtocol.handler = { req, body in
            server.rec.record(req, body: body)
            return server.start([jobsLogin])
        }
        let host = ScriptedHost()
        host.login = { request in
            await withCheckedContinuation { (c: CheckedContinuation<LoginOutcome, Never>) in
                request.cancel?.onCancel { c.resume(returning: LoginOutcome(outcome: .cancelled, messages: [])) }
            }
        }
        let cancel = CancelToken()
        let client = makeClient(host)
        let recipe = self.recipe
        let p = Task { () -> String? in
            do {
                _ = try await client.prepareCart(recipe: recipe, cancel: cancel)
                return nil
            } catch {
                return (error as? MealioError)?.code
            }
        }
        try await waitFor { host.log.order.contains("login") }
        cancel.cancel()
        let got = await p.value
        XCTAssertEqual(got, MealioError.Code.cancelled)
    }

    // MARK: users

    @MainActor
    func testWhileNobodyIsSignedInNoSessionIsAskedForAndWarmDoesNothing() async throws {
        let rec = Recorder()
        StubURLProtocol.handler = { req, body in
            rec.record(req, body: body)
            return (200, jsonData(["warm": .null]))
        }
        var asked = 0
        let client = makeClient(ScriptedHost(), token: { asked += 1; return "t" })
        client.setUser(nil)
        await client.warm()
        let recipe = self.recipe
        let got = await code { try await client.prepareCart(recipe: recipe) }
        XCTAssertEqual(got, MealioError.Code.notSignedIn)
        XCTAssertEqual(asked, 0)
        XCTAssertEqual(rec.paths, [])
    }

    @MainActor
    func testANewUserCancelsAPrepareResetsTheSessionAndSaysToSignOutOfStores() async throws {
        let server = JobServer()
        StubURLProtocol.handler = { req, body in
            server.rec.record(req, body: body)
            if req.url?.path.hasSuffix("/carts") == true { return server.start([jobsOpen("o"), jobsDone(jobsCart)]) }
            return (200, jsonData(["defaultStore": .null]))
        }
        var tokens = ["alice", "bob"]
        let host = ScriptedHost()
        host.open = { url in
            try? await Task.sleep(nanoseconds: 50_000_000)
            return PageOpenOutcome(ok: true, finalUrl: url)
        }
        let client = makeClient(host, token: { tokens.removeFirst() })
        XCTAssertFalse(client.setUser("a"))
        let recipe = self.recipe
        let p = Task { () -> String? in
            do {
                _ = try await client.prepareCart(recipe: recipe)
                return nil
            } catch {
                return (error as? MealioError)?.code
            }
        }
        try await waitFor { host.log.order.contains("open") }
        XCTAssertTrue(client.setUser("b"))
        let got = await p.value
        XCTAssertEqual(got, MealioError.Code.cancelled)
        _ = try await client.storePreferences()
        XCTAssertEqual(server.auths, ["Bearer alice", "Bearer bob"])
        XCTAssertFalse(client.setUser("b"))
        XCTAssertTrue(client.setUser(nil))
        XCTAssertFalse(client.setUser("c"))
    }

    @MainActor
    func testAnAddRunsOnUnderTheSessionItStartedWith() async throws {
        let server = JobServer()
        let added: JSONValue = ["cartId": "c", "store": "heb", "added": [], "skipped": [], "failed": []]
        StubURLProtocol.handler = { req, body in
            server.rec.record(req, body: body)
            if req.url?.path.hasSuffix("/add") == true { return server.start([jobsOpen("o")]) }
            return server.step(job: "job1", seq: 2, [jobsDone(added)])
        }
        var tokens = ["alice", "bob"]
        let gate = Gate()
        let host = ScriptedHost()
        host.open = { url in
            await gate.wait()
            return PageOpenOutcome(ok: true, finalUrl: url)
        }
        let client = makeClient(host, token: { tokens.removeFirst() })
        client.setUser("a")
        let p = Task { () -> String in
            let r = try await client.addToCart(cartId: "c", selections: [])
            return r.cartId
        }
        try await waitFor { host.log.order.contains("open") }
        client.setUser("b")
        gate.release()
        _ = try await p.value
        XCTAssertEqual(server.auths, ["Bearer alice", "Bearer alice"])
    }

    @MainActor
    func testAWarmUpThatEndsAfterAResetIsNotOfferedToTheNextPrepare() async throws {
        let server = JobServer()
        let hold = DispatchSemaphore(value: 0)
        let warmEnv = TestSigner.envelope(TestSigner.payload(seq: 1, instructions: [jobsDone(["store": "heb", "signedIn": true])], job: "w"))
        StubURLProtocol.handler = { req, body in
            server.rec.record(req, body: body)
            if req.url?.path.hasSuffix("/warm") == true {
                hold.wait()
                return (200, jsonData(["job": "w", "envelope": try! JSONValue(encoding: warmEnv)]))
            }
            return server.start([jobsDone(jobsCart)])
        }
        let client = makeClient(ScriptedHost())
        let w = Task { await client.warm() }
        try await waitFor { server.paths.contains("/warm") }
        client.resetSession()
        hold.signal()
        await w.value
        _ = try await client.prepareCart(store: "heb", recipe: recipe)
        let carts = try XCTUnwrap(server.rec.body("/api/v1/sdk/carts"))
        XCTAssertNil(carts["warm"])
    }

    // MARK: cart session

    @MainActor
    private func session(_ items: [JSONValue], store: String = "heb", warnings: JSONValue? = nil,
                         client: MealioClient? = nil) throws -> CartSession {
        var cart: [String: JSONValue] = ["cartId": "c", "store": .string(store), "items": .array(items),
                                         "ready": [], "needsChoice": [], "unavailable": []]
        if let w = warnings { cart["warnings"] = w }
        let decoded = try JSONValue.object(cart).decode(PreparedCart.self)
        return CartSession(client: client ?? makeClient(ScriptedHost()), cart: decoded)
    }

    private func prod(_ id: String = "p", _ extra: [String: JSONValue] = [:]) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "name": "P"]
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }

    private func item(_ key: String = "k", selectedId: String = "p", quantity: Int = 1,
                      options: [JSONValue], _ extra: [String: JSONValue] = [:]) -> JSONValue {
        var o: [String: JSONValue] = ["key": .string(key), "ingredient": "x", "quantity": .int(quantity),
                                      "status": "remembered", "options": .array(options),
                                      "selectedId": .string(selectedId), "remembered": .null]
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }

    @MainActor
    func testShowsTheQuantityItSendsUnderTheCapAlsoAfterSwitchingProduct() throws {
        let c = try session([item(quantity: 8, options: [prod("p", ["unitPrice": 2, "maxQuantity": 5])])])
        XCTAssertEqual(c.quantity(for: "k"), 5)
        XCTAssertEqual(c.selections()[0].quantity, 5)
        let d = try session([item(selectedId: "a", options: [prod("a", ["unitPrice": 2]), prod("b", ["unitPrice": 2, "maxQuantity": 3])])])
        d.setQuantity(key: "k", to: 10)
        try d.select(key: "k", productId: "b")
        XCTAssertEqual(d.quantity(for: "k"), 3)
        XCTAssertEqual(d.selections()[0].quantity, 3)
        XCTAssertEqual(d.setQuantity(key: "k", to: d.quantity(for: "k") - 1), 2)
    }

    @MainActor
    func testTheListTotalAndTheDoneTotalAgreeToTheCent() throws {
        let lb: (String) -> JSONValue = { key in
            self.item(key, options: [self.prod("p", ["soldByWeight": true, "pricePerLb": 3.33])], ["weightLb": 0.25])
        }
        let c = try session([lb("a"), lb("b")])
        let addedJSON: JSONValue = ["cartId": "c", "store": "heb", "skipped": [], "failed": [], "added": [
            ["key": "a", "productId": "p", "name": "P", "quantity": 1, "weightLb": 0.25, "pricePerLb": 3.33],
            ["key": "b", "productId": "p", "name": "P", "quantity": 1, "weightLb": 0.25, "pricePerLb": 3.33],
        ]]
        let added = try addedJSON.decode(AddResult.self)
        XCTAssertEqual(c.estimate().total, 1.66)
        XCTAssertEqual(c.addedTotal(added).total, 1.66)
    }

    @MainActor
    func testASecondAddWhileOneRunsReturnsTheSameResult() async throws {
        let server = JobServer()
        let hold = DispatchSemaphore(value: 0)
        let added: JSONValue = ["cartId": "c", "store": "heb", "added": [], "skipped": [], "failed": []]
        StubURLProtocol.handler = { req, body in
            server.rec.record(req, body: body)
            hold.wait()
            return server.start([jobsDone(added)])
        }
        let c = try session([])
        let a = Task { () -> String in
            let r = try await c.addToCart()
            return r.cartId
        }
        try await waitFor { server.paths.contains("/carts/c/add") }
        let b = Task { () -> String in
            let r = try await c.addToCart()
            return r.cartId
        }
        try await tick()
        hold.signal()
        let first = try await a.value
        let second = try await b.value
        XCTAssertEqual(first, "c")
        XCTAssertEqual(second, "c")
        XCTAssertEqual(server.paths.filter { $0.hasSuffix("/add") }.count, 1)
    }

    @MainActor
    func testKnowsWhenASearchRunsAndCancelsIt() async throws {
        let server = JobServer()
        let hold = DispatchSemaphore(value: 0)
        StubURLProtocol.handler = { req, body in
            server.rec.record(req, body: body)
            hold.wait()
            return server.start([jobsDone(["key": "k", "query": "milk", "options": []])])
        }
        let c = try session([item(options: [prod()])])
        let p = Task { () -> String? in
            do {
                _ = try await c.search(key: "k", query: "milk")
                return nil
            } catch {
                return (error as? MealioError)?.code
            }
        }
        try await waitFor { c.searching }
        try await waitFor { server.paths.contains("/carts/c/search") }
        c.cancelSearches()
        hold.signal()
        let got = await p.value
        XCTAssertEqual(got, MealioError.Code.cancelled)
        XCTAssertFalse(c.searching)
    }

    @MainActor
    func testRestoresPicksFromAFailedAddWhereTheProductIsStillOffered() throws {
        let opts = [prod("p1", ["maxQuantity": 9, "preferences": [["id": "sl", "label": "Sliced"]]]), prod("p2")]
        let old = try session([item("a", selectedId: "p1", options: opts), item("b", selectedId: "p1", options: opts),
                               item("c", selectedId: "gone", options: [prod("gone")])])
        try old.select(key: "a", productId: "p2")
        old.setQuantity(key: "a", to: 4)
        old.deselect(key: "b")
        try old.select(key: "c", productId: "gone")
        let fresh = try session([item("a", selectedId: "p1", options: opts), item("b", selectedId: "p1", options: opts),
                                 item("c", selectedId: "new", options: [prod("new")])])
        fresh.restorePicks(from: old)
        XCTAssertEqual(fresh.selectedId(for: "a"), "p2")
        XCTAssertEqual(fresh.quantity(for: "a"), 4)
        XCTAssertFalse(fresh.isSelected("b"))
        XCTAssertEqual(fresh.selectedId(for: "c"), "new")
        let elsewhere = try session([item("a", selectedId: "p1", options: opts)], store: "walmart")
        elsewhere.restorePicks(from: old)
        XCTAssertEqual(elsewhere.selectedId(for: "a"), "p1")
    }

    @MainActor
    func testExposesServerWarningsAndNoneFromOlderServers() throws {
        let c = try session([], warnings: [["code": "lines_dropped", "message": "Two lines were empty."]])
        XCTAssertEqual(c.warnings, [CartWarning(code: "lines_dropped", message: "Two lines were empty.")])
        XCTAssertEqual(try session([]).warnings, [])
    }

    // MARK: blocked mutations

    func testNamesEveryFieldOfAMutationAndNothingOfAQuery() {
        XCTAssertEqual(Allowlist.mutationNames(#"mutation Go($a: ID!) { x: placeOrder(id: $a, note: "checkout") { ... on Err { message } } } # payment"#),
                       ["Go", "x", "placeOrder", "message"])
        XCTAssertEqual(Allowlist.mutationNames("query Q { paymentMethods { id } }"), [])
    }

    func testTheNewOrderPathsAreBlockedAndTheirReadingNeighborsAreNot() {
        XCTAssertTrue(Allowlist.isBlockedPath("/place_order"))
        XCTAssertTrue(Allowlist.isBlockedPath("/orders/place?x=1"))
        XCTAssertTrue(Allowlist.isBlockedPath("/purchase/review"))
        XCTAssertFalse(Allowlist.isBlockedPath("/orders/placed"))
        XCTAssertFalse(Allowlist.isBlockedPath("/my-account/purchases"))
    }

    @MainActor
    func testTheFetchOpRefusesABlockedFormEncodedBody() async throws {
        let body = "operationName=Search&query=mutation+Go+%7B+placeOrder+%7B+id+%7D+%7D"
        let fetch: JSONValue = ["op": "fetch", "id": "f", "request": ["method": "POST", "url": "https://www.heb.com/graphql", "body": .string(body)],
                                "timeoutMs": 1000, "maxBytes": 1000]
        let env = TestSigner.envelope(TestSigner.payload(seq: 1, instructions: [fetch]))
        let host = ScriptedHost()
        let runner = Runner(host: host, allowlist: Allowlist(), keys: TestSigner.keys)
        let out = try await runner.run(env, job: "job_test", lastSeq: 0)
        XCTAssertEqual(out.results.first?.error, "blocked")
        XCTAssertEqual(host.log.order, [])
    }
}
