// MealioClient.warm(): the login check run before the tap, and the one-time
// hint it hands the next prepare. Mirrors the TS "warm-up" tests in
// packages/core/test/core.test.ts.

import XCTest
@testable import MealioSDK

final class WarmTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    /// `warm` is what /api/v1/sdk/warm answers; carts always come back done.
    private func serve(warm: JSONValue, rec: Recorder) {
        let cart: JSONValue = JSONValue.parse(ClientTests.newCartJSON)!
        let cartEnv = TestSigner.envelope(TestSigner.payload(seq: 1, instructions: [["op": "done", "id": "d1", "result": cart]], job: "job_cart"))
        StubURLProtocol.handler = { req, body in
            rec.record(req, body: body)
            if req.url?.path == "/api/v1/sdk/warm" { return (200, jsonData(warm)) }
            return (200, jsonData(["job": "job_cart", "envelope": try! JSONValue(encoding: cartEnv)]))
        }
    }

    private func warmDone(signedIn: JSONValue) -> JSONValue {
        let env = TestSigner.envelope(TestSigner.payload(seq: 1, instructions: [
            ["op": "done", "id": "d1", "result": ["store": "heb", "signedIn": signedIn]],
        ], job: "job_warm"))
        return ["job": "job_warm", "envelope": try! JSONValue(encoding: env)]
    }

    @MainActor
    private func makeClient() -> MealioClient {
        let config = MealioClientConfig(publishableKey: "pk_test", sessionTokenProvider: { "tok" },
                                        baseURL: URL(string: "https://mealio.test/")!,
                                        epochProvider: { 0 }, keys: TestSigner.keys,
                                        urlSession: StubURLProtocol.session(), sdkVersion: "0")
        return MealioClient(config: config, host: FakeHost())
    }

    private let recipe = Recipe(id: "r1", ingredients: [])

    @MainActor
    func testHandsASignedInWarmUpToTheNextPrepareOnce() async throws {
        let rec = Recorder()
        serve(warm: warmDone(signedIn: true), rec: rec)
        let client = makeClient()
        await client.warm()
        _ = try await client.prepareCart(recipe: recipe)
        XCTAssertEqual(rec.body("/api/v1/sdk/carts")?["warm"], .string("job_warm"))
        _ = try await client.prepareCart(recipe: recipe)
        XCTAssertNil(rec.body("/api/v1/sdk/carts")?["warm"])
    }

    @MainActor
    func testNoHintWhenSignedOutOrNothingToWarm() async throws {
        for warm in [warmDone(signedIn: false), ["warm": .null] as JSONValue] {
            let rec = Recorder()
            serve(warm: warm, rec: rec)
            let client = makeClient()
            await client.warm()
            _ = try await client.prepareCart(recipe: recipe)
            XCTAssertNil(rec.body("/api/v1/sdk/carts")?["warm"])
        }
    }

    @MainActor
    func testNoHintForAnotherStore() async throws {
        let rec = Recorder()
        serve(warm: warmDone(signedIn: true), rec: rec)
        let client = makeClient()
        await client.warm()
        _ = try await client.prepareCart(store: "walmart", recipe: recipe)
        XCTAssertNil(rec.body("/api/v1/sdk/carts")?["warm"])
    }

    @MainActor
    func testRunsAtMostOnceEveryFewMinutesAndNeverThrows() async throws {
        let rec = Recorder()
        StubURLProtocol.handler = { req, body in
            rec.record(req, body: body)
            return (500, jsonData(["error": ["code": "server", "message": "boom"]]))
        }
        let client = makeClient()
        await client.warm()
        await client.warm()
        XCTAssertEqual(rec.paths.filter { $0 == "/api/v1/sdk/warm" }.count, 1)
        client.clearWarm()
        await client.warm()
        XCTAssertEqual(rec.paths.filter { $0 == "/api/v1/sdk/warm" }.count, 2)
    }
}
