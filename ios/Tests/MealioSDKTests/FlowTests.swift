// 0.6 in the drop-in and the WebView host: closing cancels, nothing closes
// while adding, Try again keeps picks, the location step, users, the button's
// warm-up, and the host's waits. Mirrors packages/react-native/test/flow.test.tsx
// where the two meet. iOS only, as the drop-in is: run with xcodebuild, not `swift test`.

#if canImport(SwiftUI) && canImport(UIKit) && canImport(WebKit)
import SwiftUI
import UIKit
import XCTest
@testable import MealioSDK

final class FlowTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.handler = nil
        StubURLProtocol.hangs = false
        super.tearDown()
    }

    private let recipe = Recipe(id: "r1", ingredients: [])
    private let cartsPath = "/api/v1/sdk/carts"

    @MainActor
    private func reset() {
        MealioCart.client = nil
        MealioCart.host = nil
        MealioCart.onEvent = nil
        MealioCart.onSignInRequired = nil
        MealioCart.users.reset()
    }

    @MainActor
    private func configure(_ given: MealioHost? = nil) {
        let host: MealioHost = given ?? ScriptedHost()
        let config = MealioClientConfig(publishableKey: "pk_test", sessionTokenProvider: { "tok" },
                                        baseURL: URL(string: "https://mealio.test/")!,
                                        epochProvider: { 0 }, keys: TestSigner.keys,
                                        urlSession: StubURLProtocol.session(), sdkVersion: "0")
        MealioCart.client = MealioClient(config: config, host: host)
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
    private func tick() async throws {
        try await Task.sleep(nanoseconds: 30_000_000)
    }

    private func problem(_ code: String, status: Int = 400) -> (Int, Data) {
        (status, jsonData(["error": ["code": .string(code), "message": "No"]]))
    }

    private func newCart() throws -> JSONValue {
        try XCTUnwrap(JSONValue.parse(ClientTests.newCartJSON))
    }

    // MARK: closing

    @MainActor
    func testClosingCancelsThePrepareAndNeverShowsSignIn() async throws {
        defer { reset() }
        let server = JobServer()
        StubURLProtocol.handler = { req, body in
            server.rec.record(req, body: body)
            return server.start([jobsOpen("o"), jobsLogin, jobsDone(jobsCart)])
        }
        let gate = Gate()
        let host = ScriptedHost()
        host.open = { url in
            await gate.wait()
            return PageOpenOutcome(ok: true, finalUrl: url)
        }
        configure(host)
        var errors = 0
        let model = MealioFlowModel()
        model.open(recipes: [recipe], store: "heb", zip: nil, onAdded: nil, onError: { _ in errors += 1 })
        try await waitFor { host.log.order == ["open"] }
        model.close { _ in }
        gate.release()
        try await tick()
        XCTAssertEqual(host.log.order, ["open"])
        XCTAssertEqual(server.paths, ["/carts"])
        XCTAssertEqual(errors, 0)
    }

    @MainActor
    func testNothingClosesTheSheetWhileAdding() async throws {
        defer { reset() }
        let server = JobServer()
        let hold = DispatchSemaphore(value: 0)
        let cart = try newCart()
        let added: JSONValue = ["cartId": "c/2", "store": "heb", "added": [], "skipped": [], "failed": []]
        StubURLProtocol.handler = { req, body in
            server.rec.record(req, body: body)
            if req.url?.path.hasSuffix("/add") == true {
                hold.wait()
                return server.start([jobsDone(added)])
            }
            return server.start([jobsDone(cart)])
        }
        configure()
        let model = MealioFlowModel()
        model.open(recipes: [recipe], store: "heb", zip: nil, onAdded: nil, onError: nil)
        try await waitFor { model.phase == .list }
        XCTAssertTrue(model.canClose)
        model.add()
        XCTAssertEqual(model.phase, .adding)
        XCTAssertFalse(model.canClose)
        // A second tap starts nothing.
        model.add()
        hold.signal()
        try await waitFor { model.phase == .done }
        XCTAssertTrue(model.canClose)
        XCTAssertEqual(server.paths.filter { $0.hasSuffix("/add") }.count, 1)
        model.close { _ in }
    }

    @MainActor
    func testAButtonReportsOnCloseAtOnceAndTheDoneActionWhenTheSheetHasGone() async throws {
        defer { reset() }
        let model = MealioFlowModel()
        model.open(recipes: [], store: nil, zip: nil, onAdded: nil, onError: nil)
        var order: [String] = []
        model.afterClose { order.append("action") }
        model.closeFromButton { _ in order.append("onClose") }
        XCTAssertEqual(order, ["onClose"])
        // The sheet goes away: onDisappear.
        model.close { _ in order.append("again") }
        XCTAssertEqual(order, ["onClose", "action"])
    }

    // MARK: hidden mid-add, cancelled prepares (0.6 round 2)

    @MainActor
    func testAnAddThePartnerHidRunsOnAndReportsThroughOnAddedAndOnClose() async throws {
        defer { reset() }
        let server = JobServer()
        let hold = DispatchSemaphore(value: 0)
        let cart = try newCart()
        let added: JSONValue = ["cartId": "c/2", "store": "heb", "added": [], "skipped": [], "failed": []]
        StubURLProtocol.handler = { req, body in
            server.rec.record(req, body: body)
            if req.url?.path.hasSuffix("/add") == true {
                hold.wait()
                return server.start([jobsDone(added)])
            }
            return server.start([jobsDone(cart)])
        }
        configure()
        var heard: [String] = []
        var closedWith: AddResult?
        let model = MealioFlowModel()
        model.open(recipes: [recipe], store: "heb", zip: nil,
                   onAdded: { _ in heard.append("onAdded") }, onError: { _ in heard.append("onError") })
        try await waitFor { model.phase == .list }
        model.add()
        try await waitFor { server.paths.contains { $0.hasSuffix("/add") } }
        // The partner sets isPresented = false: onDisappear.
        model.close { r in
            heard.append("onClose")
            closedWith = r
        }
        XCTAssertEqual(heard, [])
        hold.signal()
        try await waitFor { heard.count == 2 }
        XCTAssertEqual(heard, ["onAdded", "onClose"])
        XCTAssertEqual(closedWith?.cartId, "c/2")
        // Gone already: a second close reports nothing.
        model.close { _ in heard.append("again") }
        try await tick()
        XCTAssertEqual(heard, ["onAdded", "onClose"])
    }

    @MainActor
    func testAnAddThePartnerHidThatFailsReportsOnErrorAndOnCloseWithNothing() async throws {
        defer { reset() }
        let server = JobServer()
        let hold = DispatchSemaphore(value: 0)
        let cart = try newCart()
        let failed = problem("boom")
        StubURLProtocol.handler = { req, body in
            server.rec.record(req, body: body)
            if req.url?.path.hasSuffix("/add") == true {
                hold.wait()
                return failed
            }
            return server.start([jobsDone(cart)])
        }
        configure()
        var heard: [String] = []
        let model = MealioFlowModel()
        model.open(recipes: [recipe], store: "heb", zip: nil,
                   onAdded: { _ in heard.append("onAdded") }, onError: { _ in heard.append("onError") })
        try await waitFor { model.phase == .list }
        model.add()
        try await waitFor { server.paths.contains { $0.hasSuffix("/add") } }
        model.close { r in heard.append(r == nil ? "onClose(nil)" : "onClose(result)") }
        hold.signal()
        try await waitFor { heard.count == 2 }
        XCTAssertEqual(heard, ["onError", "onClose(nil)"])
    }

    @MainActor
    func testAPrepareCancelledFromOutsideTheSheetLoadsAgainWhileTheSheetIsOpenAndReportsNoError() async throws {
        defer { reset() }
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
        configure(host)
        var errors = 0
        let model = MealioFlowModel()
        model.open(recipes: [recipe], store: "heb", zip: nil, onAdded: nil, onError: { _ in errors += 1 })
        try await waitFor { host.log.order == ["open"] }
        // As signOutOfStore does.
        MealioCart.client?.cancelJobs()
        gate.release()
        try await waitFor { model.phase == .list }
        XCTAssertEqual(server.paths, ["/carts", "/carts"])
        XCTAssertEqual(errors, 0)
        XCTAssertNil(model.error)
        model.close { _ in }
    }

    @MainActor
    func testOutsideCancelsRestartAtMostThreeTimesInARowThenTryAgainShowsAndWorks() async throws {
        defer { reset() }
        let server = JobServer()
        StubURLProtocol.handler = { req, body in
            server.rec.record(req, body: body)
            return server.start([jobsOpen("o"), jobsDone(jobsCart)])
        }
        let host = ScriptedHost()
        var cancels = 0
        host.open = { url in
            if cancels < 4 {
                cancels += 1
                // As signOutOfStore does, every time.
                MealioCart.client?.cancelJobs()
            }
            return PageOpenOutcome(ok: true, finalUrl: url)
        }
        configure(host)
        var errors = 0
        let model = MealioFlowModel()
        model.open(recipes: [recipe], store: "heb", zip: nil, onAdded: nil, onError: { _ in errors += 1 })
        try await waitFor { model.phase == .error }
        // The first prepare and three restarts; the fourth cancel shows the error.
        XCTAssertEqual(server.paths.filter { $0 == "/carts" }.count, 4)
        XCTAssertEqual(model.error?.code, MealioError.Code.cancelled)
        XCTAssertEqual(errors, 1)
        XCTAssertFalse(model.closeRequested)
        // Try again resets the count, and the sheet loads.
        model.retry()
        try await waitFor { model.phase == .list }
        XCTAssertEqual(model.restarts, 0)
        model.close { _ in }
    }

    @MainActor
    func testTheRestartCountResetsAfterAPrepareThatWorks() async throws {
        defer { reset() }
        let server = JobServer()
        StubURLProtocol.handler = { req, body in
            server.rec.record(req, body: body)
            return server.start([jobsOpen("o"), jobsDone(jobsCart)])
        }
        let host = ScriptedHost()
        var cancelNext = 2
        host.open = { url in
            if cancelNext > 0 {
                cancelNext -= 1
                MealioCart.client?.cancelJobs()
            }
            return PageOpenOutcome(ok: true, finalUrl: url)
        }
        configure(host)
        let model = MealioFlowModel()
        model.open(recipes: [recipe], store: "heb", zip: nil, onAdded: nil, onError: nil)
        try await waitFor { model.phase == .list }
        XCTAssertEqual(model.restarts, 0)
        // Three more in a row from here are still restarts, not an error.
        cancelNext = 3
        model.pick("heb")
        try await waitFor { model.phase == .list }
        XCTAssertNil(model.error)
        model.close { _ in }
    }

    // MARK: after a failed add

    @MainActor
    func testTryAgainAfterAFailedAddKeepsWhatTheUserPickedAndSaysToCheckTheCart() async throws {
        defer { reset() }
        let server = JobServer()
        let cart = try newCart()
        let failed = problem("boom")
        StubURLProtocol.handler = { req, body in
            server.rec.record(req, body: body)
            if req.url?.path.hasSuffix("/add") == true { return failed }
            return server.start([jobsDone(cart)])
        }
        configure()
        let model = MealioFlowModel()
        model.open(recipes: [recipe], store: "heb", zip: nil, onAdded: nil, onError: nil)
        try await waitFor { model.phase == .list }
        let first = try XCTUnwrap(model.cart)
        first.deselect(key: "onion")
        try first.select(key: "garlic", productId: "g1")
        model.add()
        try await waitFor { model.phase == .error }
        XCTAssertTrue(model.failedAdd === first)

        model.retry()
        try await waitFor { model.phase == .list }
        let again = try XCTUnwrap(model.cart)
        XCTAssertFalse(again === first)
        XCTAssertFalse(again.isSelected("onion"))
        XCTAssertEqual(again.selectedId(for: "garlic"), "g1")
        XCTAssertNil(model.failedAdd)
        model.close { _ in }
    }

    /// Round 4: restorePicks never throws, so the flow checks its token. A
    /// cancel from outside the sheet while it ran restarts like any other.
    @MainActor
    func testAnOutsideCancelDuringRestorePicksRestartsTheCartAndThePickStillComesBack() async throws {
        defer { reset() }
        let server = JobServer()
        let cart = try newCart()
        let failed = problem("boom")
        let found: JSONValue = ["key": "garlic", "query": "jar", "options": [["id": "s1", "name": "Jar"]]]
        StubURLProtocol.handler = { req, body in
            server.rec.record(req, body: body)
            let path = req.url?.path ?? ""
            if path.hasSuffix("/add") { return failed }
            if path.hasSuffix("/search") { return server.start([jobsOpen("o"), jobsDone(found)]) }
            return server.start([jobsDone(cart)])
        }
        let host = ScriptedHost()
        var opens = 0
        host.open = { url in
            opens += 1
            // The second search is restorePicks' own, after Try again: cancel
            // it from outside, as signOutOfStore does.
            if opens == 2 { MealioCart.client?.cancelJobs() }
            return PageOpenOutcome(ok: true, finalUrl: url)
        }
        configure(host)
        var errors = 0
        let model = MealioFlowModel()
        model.open(recipes: [recipe], store: "heb", zip: nil, onAdded: nil, onError: { _ in errors += 1 })
        try await waitFor { model.phase == .list }
        let first = try XCTUnwrap(model.cart)
        _ = try await first.search(key: "garlic", query: "jar")
        try first.select(key: "garlic", productId: "s1")
        model.add()
        try await waitFor { model.phase == .error }
        let errorsBefore = errors

        model.retry()
        try await waitFor { model.phase == .list && opens >= 3 }
        // Prepared three times: the first, Try again, and the restart.
        XCTAssertEqual(server.paths.filter { $0 == "/carts" }.count, 3)
        XCTAssertEqual(server.paths.filter { $0.hasSuffix("/search") }.count, 3)
        XCTAssertEqual(model.cart?.selectedId(for: "garlic"), "s1")
        XCTAssertNil(model.failedAdd)
        XCTAssertEqual(model.restarts, 0)
        XCTAssertEqual(errors, errorsBefore)
        model.close { _ in }
    }

    @MainActor
    func testTheAddFailedNoteIsInTheStrings() {
        XCTAssertEqual(MealioCart.text.tr(.addFailedNote), "Some items may already be in your cart. Check it before adding again.")
    }

    // MARK: details

    @MainActor
    func testAnOptionTapThatTicksAnItemSaysItemChecked() throws {
        defer { reset() }
        configure()
        let cart = try JSONDecoder().decode(PreparedCart.self, from: Data(ClientTests.newCartJSON.utf8))
        let session = CartSession(client: try XCTUnwrap(MealioCart.client), cart: cart)
        let log = HostLog()
        MealioCart.onEvent = { log.order.append($0.type) }
        let item = try XCTUnwrap(cart.items.first { $0.key == "garlic" })
        let row = MealioItemRow(cart: session, item: item, t: .default, storeName: "H-E-B", isOpen: true,
                                disabled: false, onToggleOpen: {})
        let garlic = try XCTUnwrap(item.options.first)
        row.pick(garlic, preferenceId: nil)
        row.pick(garlic, preferenceId: nil)
        XCTAssertTrue(session.isSelected("garlic"))
        XCTAssertEqual(log.order, ["item_checked"])
    }

    @MainActor
    func testALocationSavedAfterTheUserLeftTheStepStartsNothing() async throws {
        defer { reset() }
        let rec = Recorder()
        let reply = problem("location_required", status: 409)
        StubURLProtocol.handler = { req, body in rec.record(req, body: body); return reply }
        configure()
        let model = MealioFlowModel()
        model.open(recipes: [recipe], store: "kroger", zip: nil, onAdded: nil, onError: nil)
        try await waitFor { model.phase == .location }
        let visit = model.locationVisit
        // Back, while the save is still on its way.
        model.openStores(from: .location)
        model.locationPicked(visit: visit)
        XCTAssertEqual(model.phase, .stores)
        // Back on the step, a save from the earlier visit still starts nothing.
        model.openLocation(from: .stores)
        model.locationPicked(visit: visit)
        XCTAssertEqual(model.phase, .location)
        XCTAssertEqual(rec.paths.filter { $0 == cartsPath }.count, 1)
        model.close { _ in }
    }

    @MainActor
    func testAStoreChangeWhileLoadingMovesTheCartToIt() async throws {
        defer { reset() }
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
        configure(host)
        let model = MealioFlowModel()
        model.open(recipes: [recipe], store: "heb", zip: nil, onAdded: nil, onError: nil)
        try await waitFor { host.log.order == ["open"] }
        model.storeChanged("walmart")
        gate.release()
        try await waitFor { model.phase == .list }
        XCTAssertEqual(server.rec.body(cartsPath)?["store"], .string("walmart"))
        model.close { _ in }
    }

    @MainActor
    func testAStoreListThatFailedLoadsAgainNextTime() async throws {
        defer { reset() }
        let rec = Recorder()
        let down = problem("store_unavailable", status: 503)
        StubURLProtocol.handler = { req, body in rec.record(req, body: body); return down }
        configure()
        let model = MealioFlowModel()
        model.open(recipes: [recipe], store: "heb", zip: nil, onAdded: nil, onError: nil)
        try await waitFor { model.phase == .error }
        model.openStores(from: .error)
        try await waitFor { model.stores != nil }
        XCTAssertEqual(model.stores, [])
        model.openStores(from: .error)
        try await waitFor { rec.paths.filter { $0 == "/api/v1/stores" }.count == 2 }
        model.close { _ in }
    }

    @MainActor
    func testTheLatestCallbacksAreTheOnesCalled() async throws {
        defer { reset() }
        let reply = problem("boom")
        StubURLProtocol.handler = { _, _ in reply }
        configure()
        var heard: [String] = []
        let model = MealioFlowModel()
        model.open(recipes: [recipe], store: "heb", zip: nil, onAdded: nil, onError: { _ in heard.append("first") })
        model.latest(onAdded: nil, onError: { _ in heard.append("latest") })
        try await waitFor { model.phase == .error }
        XCTAssertEqual(heard, ["latest"])
        model.close { _ in }
    }

    // MARK: users

    @MainActor
    func testANewUserClosesTheSheet() async throws {
        defer { reset() }
        let cart = try newCart()
        let server = JobServer()
        StubURLProtocol.handler = { req, body in
            server.rec.record(req, body: body)
            return server.start([jobsDone(cart)])
        }
        configure()
        MealioCart.users.set("a")
        let model = MealioFlowModel()
        model.open(recipes: [recipe], store: "heb", zip: nil, onAdded: nil, onError: nil)
        try await waitFor { model.phase == .list }
        XCTAssertFalse(model.closeRequested)
        MealioCart.users.set("b")
        XCTAssertTrue(model.closeRequested)
        model.close { _ in }
    }

    @MainActor
    func testWithNobodySignedInTheButtonAsksForSignInOrIsDisabled() {
        defer { reset() }
        MealioCart.users.set(nil)
        var asked = 0
        let button = MealioCartButton(recipe: recipe, onSignInRequired: { asked += 1 })
        XCTAssertFalse(button.disabled)
        button.tap()
        XCTAssertEqual(asked, 1)
        XCTAssertFalse(button.warmKey.on)
        XCTAssertTrue(MealioCartButton(recipe: recipe).disabled)
        MealioCart.onSignInRequired = { asked += 1 }
        XCTAssertFalse(MealioCartButton(recipe: recipe).disabled)
    }

    @MainActor
    func testTheButtonWarmsWhenItBecomesEnabled() {
        defer { reset() }
        let off = MealioCartButton(recipe: recipe, store: "heb", disabled: true)
        let on = MealioCartButton(recipe: recipe, store: "heb", disabled: false)
        XCTAssertFalse(off.warmKey.on)
        XCTAssertTrue(on.warmKey.on)
        XCTAssertNotEqual(off.warmKey, on.warmKey)
        // A new user warms again too.
        let before = on.warmKey
        MealioCart.users.set("a")
        XCTAssertNotEqual(MealioCartButton(recipe: recipe, store: "heb").warmKey, before)
    }

    // MARK: the host

    @MainActor
    func testTheHiddenPageFailsClosedBeforeConfigure() {
        let host = WebViewHost()
        XCTAssertFalse(host.hiddenNavigationPolicy("heb", "https://evil.example/"))
        XCTAssertFalse(host.hiddenNavigationPolicy("no_such_store", "https://www.heb.com/"))
        XCTAssertTrue(host.hiddenNavigationPolicy("heb", "https://www.heb.com/"))
    }

    @MainActor
    func testAWaiterIsSettledOnceAndItsOwnTimerGoesWithIt() async throws {
        let waiter = JobWaiter<String>()
        let t = Task { await waiter.wait { waiter.timer = after(10_000) { _ = waiter.settle("late") } } }
        try await tick()
        XCTAssertTrue(waiter.settle("superseded"))
        XCTAssertFalse(waiter.settle("again"))
        XCTAssertNil(waiter.timer)
        let got = await t.value
        XCTAssertEqual(got, "superseded")
    }

    @MainActor
    func testResettingThePageAnswersAScriptStillWaiting() async throws {
        let host = WebViewHost()
        let wait = ScriptWait(until: [])
        host.scriptWait = wait
        let t = Task { () -> String? in
            let outcome = await wait.waiter.wait {}
            return outcome.error
        }
        try await tick()
        host.resetHiddenPage()
        let got = await t.value
        XCTAssertEqual(got, "page_reset")
        XCTAssertNil(host.scriptWait)
    }

    @MainActor
    func testASignInIsClosedWhenItsJobIsCancelled() async throws {
        let cancel = CancelToken()
        let request = LoginRequest(store: "heb", url: "https://www.heb.com/login", title: "Sign in", guardScript: "",
                                   check: nil, doneWhen: [], doneWhenUrl: nil, timeoutMs: 60_000,
                                   allowNavigation: { _ in true }, cancel: cancel)
        let sheet = LoginSheet(request: request)
        let log = HostLog()
        let url = try XCTUnwrap(URL(string: request.url))
        let t = Task { () -> Bool in
            let outcome = await sheet.run(url: url, mode: .inline({ shown in log.order.append(shown == nil ? "down" : "up") }))
            return outcome.outcome == .cancelled
        }
        try await waitFor { log.order == ["up"] }
        cancel.cancel()
        let cancelled = await t.value
        XCTAssertTrue(cancelled)
        XCTAssertEqual(log.order, ["up", "down"])
    }

    @MainActor
    func testASignInThatCannotBePresentedFailsAtOnce() async throws {
        let host = WebViewHost(presenter: { UIViewController() })
        let request = LoginRequest(store: "heb", url: "https://www.heb.com/login", title: "Sign in", guardScript: "",
                                   check: nil, doneWhen: [], doneWhenUrl: nil, timeoutMs: 600_000,
                                   allowNavigation: { _ in true })
        do {
            _ = try await host.showLogin(request)
            XCTFail("expected the sign-in to fail")
        } catch let e as MealioError {
            XCTAssertEqual(e.code, MealioError.Code.unsupported)
        }
    }

    @MainActor
    func testReconfiguringTearsDownTheOldHost() throws {
        defer { reset() }
        MealioCart.configure(publishableKey: "pk_test", sessionTokenProvider: { "tok" })
        let old = try XCTUnwrap(MealioCart.host)
        _ = old.fetchSession
        XCTAssertNotNil(old.madeFetchSession)
        MealioCart.configure(publishableKey: "pk_test", sessionTokenProvider: { "tok" })
        XCTAssertNil(old.madeFetchSession)
        XCTAssertFalse(old === MealioCart.host)
    }

    @MainActor
    func testABlockedRedirectIsSaidSoAndStoreCookiesNeverGoBack() throws {
        let from = try XCTUnwrap(URL(string: "https://www.heb.com/api/cart"))
        XCTAssertTrue(RedirectGuard.stopped(status: 302, location: "https://evil.example/x", from: from))
        XCTAssertTrue(RedirectGuard.stopped(status: 301, location: "/checkout", from: from))
        XCTAssertFalse(RedirectGuard.stopped(status: 302, location: "/api/cart/2", from: from))
        XCTAssertFalse(RedirectGuard.stopped(status: 200, location: "https://evil.example/x", from: from))
        XCTAssertEqual(WebViewHost.privateHeaders, ["set-cookie", "set-cookie2"])
    }
}
#endif
