// The drop-in's location step, driven through its model against a stubbed
// server. iOS only, as the drop-in is: run with xcodebuild, not `swift test`.

#if canImport(SwiftUI) && canImport(UIKit) && canImport(WebKit)
import XCTest
@testable import MealioSDK

final class FlowLocationTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    private let recipe = Recipe(id: "r1", ingredients: [])
    private let cartsPath = "/api/v1/sdk/carts"

    @MainActor
    private func configure() {
        let config = MealioClientConfig(publishableKey: "pk_test", sessionTokenProvider: { "tok" },
                                        baseURL: URL(string: "https://mealio.test/")!,
                                        epochProvider: { 0 }, keys: TestSigner.keys,
                                        urlSession: StubURLProtocol.session(), sdkVersion: "0")
        MealioCart.client = MealioClient(config: config, host: FakeHost())
    }

    private func locationRequired() -> (Int, Data) {
        (409, jsonData(["error": ["code": "location_required", "message": "Choose"]]))
    }

    /// A finished job whose cart is at location `k2`.
    private func cartStart() throws -> (Int, Data) {
        var cart = try XCTUnwrap(JSONValue.parse(ClientTests.newCartJSON)?.objectValue)
        cart["location"] = ["id": "k2", "name": "Kroger Oak", "address": "3 Oak St", "zip": "75202"]
        let env = TestSigner.envelope(TestSigner.payload(seq: 1, instructions: [["op": "done", "id": "d1", "result": .object(cart)]]))
        return (200, jsonData(["job": "job_test", "envelope": try JSONValue(encoding: env)]))
    }

    @MainActor
    private func waitFor(_ done: () -> Bool) async throws {
        for _ in 0..<300 {
            if done() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out")
    }

    @MainActor
    func testLocationRequiredShowsTheLocationStepAndNeverSendsZip() async throws {
        let rec = Recorder()
        let reply = locationRequired()
        StubURLProtocol.handler = { req, body in rec.record(req, body: body); return reply }
        configure()
        defer { MealioCart.client = nil }
        var errors = 0
        let model = MealioFlowModel()
        model.open(recipes: [recipe], store: "kroger", zip: "75202", onAdded: nil, onError: { _ in errors += 1 })
        try await waitFor { model.phase == .location }

        XCTAssertNil(try XCTUnwrap(rec.body(cartsPath))["zip"])
        XCTAssertEqual(model.locationZip, "75202")
        XCTAssertFalse(model.canGoBackToList)
        XCTAssertEqual(errors, 0)
        model.close { _ in }
    }

    @MainActor
    func testLocationRequiredWithNoStoreShowsTheStorePicker() async throws {
        let reply = locationRequired()
        StubURLProtocol.handler = { _, _ in reply }
        configure()
        defer { MealioCart.client = nil }
        let model = MealioFlowModel()
        model.open(recipes: [recipe], store: nil, zip: nil, onAdded: nil, onError: nil)
        try await waitFor { model.phase == .stores }
        model.close { _ in }
    }

    @MainActor
    func testPickedLocationRestartsTheCartAndTheListCanChangeIt() async throws {
        let rec = Recorder()
        let first = locationRequired()
        let second = try cartStart()
        StubURLProtocol.handler = { req, body in
            rec.record(req, body: body)
            return rec.paths.count == 1 ? first : second
        }
        configure()
        defer { MealioCart.client = nil }
        let model = MealioFlowModel()
        model.open(recipes: [recipe], store: "kroger", zip: nil, onAdded: nil, onError: nil)
        try await waitFor { model.phase == .location }

        model.locationPicked()
        try await waitFor { model.phase == .list }
        XCTAssertEqual(model.cart?.location?.id, "k2")

        // From the list: back to the list, and the box starts at the cart's zip.
        model.openLocation(from: .list)
        XCTAssertEqual(model.phase, .location)
        XCTAssertTrue(model.canGoBackToList)
        XCTAssertEqual(model.locationZip, "75202")
        model.backToList()
        XCTAssertEqual(model.phase, .list)
        model.close { _ in }
    }

    @MainActor
    func testPickAfterTheSheetClosedStartsNothing() async throws {
        let rec = Recorder()
        let reply = locationRequired()
        StubURLProtocol.handler = { req, body in rec.record(req, body: body); return reply }
        configure()
        defer { MealioCart.client = nil }
        let model = MealioFlowModel()
        model.open(recipes: [recipe], store: "kroger", zip: nil, onAdded: nil, onError: nil)
        try await waitFor { model.phase == .location }
        model.close { _ in }

        model.locationPicked()
        XCTAssertEqual(model.phase, .location)
        XCTAssertEqual(rec.paths.count, 1)
    }
}
#endif
