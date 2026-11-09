// The sheet's events. The names run everywhere; the flow is driven through its
// model against a stubbed server, iOS only as the drop-in is: run with
// xcodebuild, not `swift test`.

import XCTest
@testable import MealioSDK

final class EventNameTests: XCTestCase {
    func testNamesMatchCore() {
        let events: [MealioEvent] = [
            .sheetOpened(recipes: 1), .storePicked(store: "heb"), .locationAsked(store: "heb"),
            .signinShown(store: nil), .listShown(store: "heb", items: 1), .itemUnchecked(key: "k"),
            .itemChecked(key: "k"), .addStarted(items: 1), .cartAdded(store: "heb", added: 1, failed: 0),
            .error(code: "c", step: .list), .sheetClosed(step: .list, added: 0),
        ]
        XCTAssertEqual(events.map(\.type), [
            "sheet_opened", "store_picked", "location_asked", "signin_shown", "list_shown", "item_unchecked",
            "item_checked", "add_started", "cart_added", "error", "sheet_closed",
        ])
    }

    func testStepNamesMatchCore() {
        XCTAssertEqual(MealioSheetStep.allCases.map(\.rawValue),
                       ["loading", "stores", "location", "signin", "list", "adding", "done", "error"])
    }
}

#if canImport(SwiftUI) && canImport(UIKit) && canImport(WebKit)
final class EventsTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    private let recipe = Recipe(id: "r1", ingredients: [])
    private let cartsPath = "/api/v1/sdk/carts"

    /// Listens, and returns what was heard so far each time it is read.
    private final class Log { var events: [MealioEvent] = [] }

    @MainActor
    private func listen() -> Log {
        let log = Log()
        MealioCart.onEvent = { log.events.append($0) }
        return log
    }

    @MainActor
    private func makeClient() -> MealioClient {
        let config = MealioClientConfig(publishableKey: "pk_test", sessionTokenProvider: { "tok" },
                                        baseURL: URL(string: "https://mealio.test/")!,
                                        epochProvider: { 0 }, keys: TestSigner.keys,
                                        urlSession: StubURLProtocol.session(), sdkVersion: "0")
        return MealioClient(config: config, host: FakeHost())
    }

    @MainActor
    private func reset() {
        MealioCart.client = nil
        MealioCart.onEvent = nil
    }

    private func problem(_ code: String, status: Int = 400) -> (Int, Data) {
        (status, jsonData(["error": ["code": .string(code), "message": "No"]]))
    }

    private func done(_ result: JSONValue) throws -> (Int, Data) {
        let env = TestSigner.envelope(TestSigner.payload(seq: 1, instructions: [["op": "done", "id": "d1", "result": result]]))
        return (200, jsonData(["job": "job_test", "envelope": try JSONValue(encoding: env)]))
    }

    private func cartReply() throws -> (Int, Data) {
        try done(try XCTUnwrap(JSONValue.parse(ClientTests.newCartJSON)))
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
    func testConfigureKeepsTheListenerWhenLeftOut() {
        defer { reset() }
        var heard = 0
        MealioCart.configure(onEvent: { _ in heard += 1 })
        MealioCart.configure(strings: [:])
        MealioCart.emit(.sheetOpened(recipes: 1))
        XCTAssertEqual(heard, 1)
    }

    @MainActor
    func testNoListenerIsFine() {
        MealioCart.onEvent = nil
        MealioCart.emit(.sheetOpened(recipes: 1))
    }

    @MainActor
    func testOpenToListThenCloseFromTheList() async throws {
        defer { reset() }
        let reply = try cartReply()
        StubURLProtocol.handler = { _, _ in reply }
        MealioCart.client = makeClient()
        let log = listen()
        let model = MealioFlowModel()
        model.open(recipes: [recipe, recipe], store: "heb", zip: nil, onAdded: nil, onError: nil)
        try await waitFor { model.phase == .list }
        model.openLocation(from: .list)
        model.backToList()
        model.close { _ in }
        XCTAssertEqual(log.events, [
            .sheetOpened(recipes: 2),
            .listShown(store: "heb", items: 4),
            .locationAsked(store: "heb"),
            .sheetClosed(step: .list, added: 0),
        ])
    }

    @MainActor
    func testLocationRequiredAsksAndClosesThere() async throws {
        defer { reset() }
        let reply = problem("location_required", status: 409)
        StubURLProtocol.handler = { _, _ in reply }
        MealioCart.client = makeClient()
        let log = listen()
        let model = MealioFlowModel()
        model.open(recipes: [recipe], store: "kroger", zip: nil, onAdded: nil, onError: nil)
        try await waitFor { model.phase == .location }
        model.close { _ in }
        XCTAssertEqual(log.events, [
            .sheetOpened(recipes: 1),
            .locationAsked(store: "kroger"),
            .sheetClosed(step: .location, added: 0),
        ])
    }

    @MainActor
    func testPickingAStore() async throws {
        defer { reset() }
        let rec = Recorder()
        let first = problem("store_required", status: 409)
        let second = try cartReply()
        let path = cartsPath
        StubURLProtocol.handler = { req, body in
            rec.record(req, body: body)
            return rec.paths.filter { $0 == path }.count <= 1 ? first : second
        }
        MealioCart.client = makeClient()
        let log = listen()
        let model = MealioFlowModel()
        model.open(recipes: [recipe], store: nil, zip: nil, onAdded: nil, onError: nil)
        try await waitFor { model.phase == .stores }
        model.pick("heb")
        try await waitFor { model.phase == .list }
        model.close { _ in }
        XCTAssertEqual(log.events, [
            .sheetOpened(recipes: 1),
            .storePicked(store: "heb"),
            .listShown(store: "heb", items: 4),
            .sheetClosed(step: .list, added: 0),
        ])
    }

    @MainActor
    func testPrepareFailing() async throws {
        defer { reset() }
        let reply = problem("boom")
        StubURLProtocol.handler = { _, _ in reply }
        MealioCart.client = makeClient()
        let log = listen()
        let model = MealioFlowModel()
        model.open(recipes: [recipe], store: "heb", zip: nil, onAdded: nil, onError: nil)
        try await waitFor { model.phase == .error }
        model.close { _ in }
        XCTAssertEqual(log.events, [
            .sheetOpened(recipes: 1),
            .error(code: "boom", step: .loading),
            .sheetClosed(step: .error, added: 0),
        ])
    }

    @MainActor
    func testAddingThenClosingOnDone() async throws {
        defer { reset() }
        let prepared = try cartReply()
        let added = try done([
            "cartId": "c/2", "store": "heb",
            "added": [["key": "onion", "productId": "o1", "name": "Onion", "quantity": 2]],
            "skipped": [],
            "failed": [["key": "steak", "productId": "s1", "name": "Ribeye", "reason": "out_of_stock"]],
            "storeCartUrl": .null,
        ])
        StubURLProtocol.handler = { req, _ in
            req.url?.path.hasSuffix("/add") == true ? added : prepared
        }
        MealioCart.client = makeClient()
        let log = listen()
        let model = MealioFlowModel()
        model.open(recipes: [recipe], store: "heb", zip: nil, onAdded: nil, onError: nil)
        try await waitFor { model.phase == .list }
        let count = try XCTUnwrap(model.cart).estimate().count
        model.add()
        try await waitFor { model.phase == .done }
        model.close { _ in }
        XCTAssertEqual(log.events, [
            .sheetOpened(recipes: 1),
            .listShown(store: "heb", items: 4),
            .addStarted(items: count),
            .cartAdded(store: "heb", added: 1, failed: 1),
            .sheetClosed(step: .done, added: 1),
        ])
    }

    @MainActor
    func testAddFailingSaysAdding() async throws {
        defer { reset() }
        let prepared = try cartReply()
        let failed = problem("boom")
        StubURLProtocol.handler = { req, _ in
            req.url?.path.hasSuffix("/add") == true ? failed : prepared
        }
        MealioCart.client = makeClient()
        let log = listen()
        let model = MealioFlowModel()
        model.open(recipes: [recipe], store: "heb", zip: nil, onAdded: nil, onError: nil)
        try await waitFor { model.phase == .list }
        model.add()
        try await waitFor { model.phase == .error }
        model.close { _ in }
        XCTAssertEqual(log.events.suffix(2), [
            .error(code: "boom", step: .adding),
            .sheetClosed(step: .error, added: 0),
        ])
    }

    /// 0.6.1: signed out of the saved store, the user picks another from the
    /// sign-in page. The cart that asked for the sign-in stops, the sign-in
    /// goes, and the stores show. Never while adding.
    @MainActor
    func testADifferentStoreFromSignInStopsTheCartAndShowsTheStores() async throws {
        defer { reset(); StubURLProtocol.hangs = false }
        StubURLProtocol.hangs = true
        MealioCart.client = makeClient()
        let log = listen()
        let model = MealioFlowModel()
        model.open(recipes: [recipe], store: "heb", zip: nil, onAdded: nil, onError: nil)
        XCTAssertEqual(model.phase, .loading)
        let request = LoginRequest(store: "heb", url: "https://www.heb.com/login", title: "Sign in",
                                   guardScript: "", check: nil, doneWhen: [], doneWhenUrl: nil, timeoutMs: 1000,
                                   allowNavigation: { _ in true })
        model.loginChanged(LoginSheet(request: request))
        XCTAssertEqual(model.sheetStep, .signin)
        model.storeFromSignIn()
        XCTAssertNil(model.login)
        XCTAssertEqual(model.phase, .stores)
        XCTAssertEqual(model.sheetStep, .stores)
        model.pick("aldi")
        XCTAssertEqual(model.store, "aldi")
        XCTAssertEqual(model.phase, .loading)
        XCTAssertEqual(log.events, [.sheetOpened(recipes: 1), .signinShown(store: "heb"), .storePicked(store: "aldi")])

        // Mid-add, a sign-in belongs to the add: the link does nothing.
        model.phase = .adding
        model.loginChanged(LoginSheet(request: request))
        model.storeFromSignIn()
        XCTAssertEqual(model.phase, .adding)
        XCTAssertNotNil(model.login)
        model.loginChanged(nil)
    }

    @MainActor
    func testSignInAppearingOnceAndClosingFromIt() async throws {
        defer { reset() }
        let reply = problem("location_required", status: 409)
        StubURLProtocol.handler = { _, _ in reply }
        MealioCart.client = makeClient()
        let log = listen()
        let model = MealioFlowModel()
        model.open(recipes: [recipe], store: "kroger", zip: nil, onAdded: nil, onError: nil)
        try await waitFor { model.phase == .location }

        let request = LoginRequest(store: "kroger", url: "https://www.kroger.com/signin", title: "Sign in",
                                   guardScript: "", check: nil, doneWhen: [], doneWhenUrl: nil, timeoutMs: 1000,
                                   allowNavigation: { _ in true })
        model.loginChanged(LoginSheet(request: request))
        model.loginChanged(LoginSheet(request: request))
        model.close { _ in }
        XCTAssertEqual(log.events, [
            .sheetOpened(recipes: 1),
            .locationAsked(store: "kroger"),
            .signinShown(store: "kroger"),
            .sheetClosed(step: .signin, added: 0),
        ])
    }

    @MainActor
    func testRowCheckboxReportsOnlyRealChanges() throws {
        defer { reset() }
        let cart = try JSONDecoder().decode(PreparedCart.self, from: Data(ClientTests.newCartJSON.utf8))
        let session = CartSession(client: makeClient(), cart: cart)
        let log = listen()
        func row(_ key: String, disabled: Bool = false, onOpen: @escaping () -> Void = {}) throws -> MealioItemRow {
            let item = try XCTUnwrap(cart.items.first { $0.key == key })
            return MealioItemRow(cart: session, item: item, t: .default, storeName: "H-E-B", isOpen: false,
                                 disabled: disabled, onToggleOpen: onOpen)
        }

        try row("onion").toggle(on: true)
        XCTAssertFalse(session.isSelected("onion"))
        try row("onion").toggle(on: false)
        XCTAssertTrue(session.isSelected("onion"))
        try row("onion", disabled: true).toggle(on: true)

        // Nothing remembered: the row opens, and nothing has been checked yet.
        var opened = 0
        try row("garlic", onOpen: { opened += 1 }).toggle(on: false)
        XCTAssertEqual(opened, 1)

        XCTAssertEqual(log.events, [.itemUnchecked(key: "onion"), .itemChecked(key: "onion")])
    }
}
#endif
