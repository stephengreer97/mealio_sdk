// MealioClient and CartSession against a stubbed Mealio server.

import XCTest
@testable import MealioSDK

final class ClientTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    @MainActor
    private func makeClient(keys: [String: String], token: @escaping () async throws -> String = { "tok" },
                            epoch: @escaping () -> Int = { 0 }, host: MealioHost? = nil) -> MealioClient {
        let config = MealioClientConfig(publishableKey: "pk_test", sessionTokenProvider: token,
                                        baseURL: URL(string: "https://mealio.test/")!,
                                        epochProvider: epoch, keys: keys,
                                        urlSession: StubURLProtocol.session(), sdkVersion: "0")
        return MealioClient(config: config, host: host ?? FakeHost())
    }

    // Same as the TS "drives a job to done through step calls" test.
    @MainActor
    func testDrivesAJobToDoneThroughStepCalls() async throws {
        let v = try Fixtures.vectors()
        let cases = try XCTUnwrap(v["cases"]?.arrayValue)
        let c1 = try XCTUnwrap(cases[0]["envelope"])
        let c2 = try XCTUnwrap(cases[1]["envelope"])
        let rec = Recorder()
        StubURLProtocol.handler = { req, body in
            rec.record(req, body: body)
            let path = req.url?.path ?? ""
            if path.hasSuffix("/hello") { return (200, jsonData(["ok": true])) }
            if path.hasSuffix("/carts") { return (200, jsonData(["job": "job_test", "envelope": c1])) }
            if path.hasSuffix("/step") { return (200, jsonData(["envelope": c2])) }
            return (404, Data())
        }
        let client = makeClient(keys: try Fixtures.keys(v), epoch: { 7 })

        // The done result is not a PreparedCart here; the point is the loop.
        do {
            _ = try await client.prepareCart(store: "heb", recipe: Recipe(id: "r1", ingredients: []))
            XCTFail("expected the result to be refused as a cart")
        } catch let e as MealioError {
            XCTAssertEqual(e.code, MealioError.Code.server)
        }
        XCTAssertEqual(rec.paths, ["/api/v1/sdk/hello", "/api/v1/sdk/carts", "/api/v1/sdk/jobs/job_test/step"])

        let step = try XCTUnwrap(rec.body("/api/v1/sdk/jobs/job_test/step"))
        XCTAssertEqual(step["seq"], .int(1))
        XCTAssertEqual(step["results"]?.arrayValue?.count, 2)
        XCTAssertEqual(step["results"]?.arrayValue?[1]["messages"]?.arrayValue?.first?["type"], .string("HEB_SESSION"))

        let hello = try XCTUnwrap(rec.body("/api/v1/sdk/hello"))
        XCTAssertEqual(hello["epoch"], .int(7))
        XCTAssertEqual(hello["sdk"]?["platform"], .string("ios"))
        XCTAssertEqual(hello["sdk"]?["ops"]?.arrayValue?.compactMap { $0.stringValue }, SUPPORTED_OPS)

        let carts = try XCTUnwrap(rec.body("/api/v1/sdk/carts"))
        XCTAssertEqual(carts["store"], .string("heb"))
        XCTAssertNil(carts["zip"])

        let first = try XCTUnwrap(rec.requests.first)
        XCTAssertEqual(first.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(first.value(forHTTPHeaderField: "X-Mealio-Publishable-Key"), "pk_test")
        XCTAssertEqual(first.value(forHTTPHeaderField: "X-Mealio-SDK"), "ios/0")
        XCTAssertEqual(first.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    // Same as the TS "retries once with a fresh token on 401" test.
    @MainActor
    func testRetriesOnceWithAFreshTokenOn401() async throws {
        let rec = Recorder()
        StubURLProtocol.handler = { req, body in
            rec.record(req, body: body)
            return rec.paths.count == 1 ? (401, jsonData([:])) : (200, jsonData(["ok": true]))
        }
        var tokens = 0
        let client = makeClient(keys: TestSigner.keys, token: { tokens += 1; return "t\(tokens)" })
        try await client.hello()
        XCTAssertEqual(tokens, 2)
        XCTAssertEqual(rec.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer t2")
    }

    @MainActor
    func testTwo401sRaiseSessionExpired() async throws {
        StubURLProtocol.handler = { _, _ in (401, jsonData([:])) }
        let client = makeClient(keys: TestSigner.keys)
        do {
            try await client.hello()
            XCTFail("expected session_expired")
        } catch let e as MealioError {
            XCTAssertEqual(e.code, MealioError.Code.sessionExpired)
        }
    }

    @MainActor
    func testServerErrorsCarryTheServerCode() async throws {
        StubURLProtocol.handler = { _, _ in
            (503, jsonData(["error": ["code": "store_unavailable", "message": "H-E-B is down"]]))
        }
        let client = makeClient(keys: TestSigner.keys)
        do {
            try await client.hello()
            XCTFail("expected an error")
        } catch let e as MealioError {
            XCTAssertEqual(e.code, "store_unavailable")
            XCTAssertEqual(e.message, "H-E-B is down")
        }
    }

    @MainActor
    func testBadEnvelopeStopsTheRun() async throws {
        let v = try Fixtures.vectors()
        let tampered = try XCTUnwrap(v["cases"]?.arrayValue?.first { $0["name"]?.stringValue == "tampered_payload" }?["envelope"])
        StubURLProtocol.handler = { req, _ in
            if req.url?.path.hasSuffix("/hello") == true { return (200, jsonData(["ok": true])) }
            return (200, jsonData(["job": "job_test", "envelope": tampered]))
        }
        let client = makeClient(keys: try Fixtures.keys(v))
        do {
            _ = try await client.prepareCart(store: "heb", recipe: Recipe(id: "r1", ingredients: []))
            XCTFail("expected bad_envelope")
        } catch let e as MealioError {
            XCTAssertEqual(e.code, MealioError.Code.badEnvelope)
            XCTAssertEqual(e.message, "bad_envelope: signature")
        }
    }

    @MainActor
    func testFailInstructionBecomesAnError() async throws {
        let fail: JSONValue = ["op": "fail", "id": "i1", "code": "store_unavailable", "message": "Not now"]
        let env = TestSigner.envelope(TestSigner.payload(seq: 1, instructions: [fail]))
        StubURLProtocol.handler = { req, _ in
            if req.url?.path.hasSuffix("/hello") == true { return (200, jsonData(["ok": true])) }
            return (200, jsonData(["job": "job_test", "envelope": try! JSONValue(encoding: env)]))
        }
        let client = makeClient(keys: TestSigner.keys)
        do {
            _ = try await client.prepareCart(store: "heb", recipe: Recipe(id: "r1", ingredients: []))
            XCTFail("expected store_unavailable")
        } catch let e as MealioError {
            XCTAssertEqual(e, MealioError(code: "store_unavailable", message: "Not now"))
        }
    }

    @MainActor
    func testHelloWidensTheAllowlistOnlyFromAVerifiedEnvelope() async throws {
        let allow: JSONValue = [
            "v": 1, "kind": "allowlist", "exp": 4_102_444_800,
            "stores": ["heb": ["hosts": ["api.heb.com", "heb-cdn.net"]]],
        ]
        let good = TestSigner.envelope(TestSigner.json(allow))
        StubURLProtocol.handler = { _, _ in (200, jsonData(["ok": true, "allowlist": try! JSONValue(encoding: good)])) }
        let client = makeClient(keys: TestSigner.keys)
        try await client.hello()
        XCTAssertTrue(client.allowlist.hostsFor("heb")!.hosts.contains("api.heb.com"))
        XCTAssertFalse(client.allowlist.hostsFor("heb")!.hosts.contains("heb-cdn.net"))

        // Same payload, bad signature: ignored, the bundled list stands.
        let bad = Envelope(payload: good.payload, sig: TestSigner.envelope("other").sig, kid: "ktest")
        StubURLProtocol.handler = { _, _ in (200, jsonData(["ok": true, "allowlist": try! JSONValue(encoding: bad)])) }
        let other = makeClient(keys: TestSigner.keys)
        try await other.hello()
        XCTAssertEqual(other.allowlist.hostsFor("heb")?.hosts, ["heb.com"])
    }

    // MARK: CartSession

    private static let cartJSON = #"""
    {"cartId":"c/1","store":"heb",
     "ready":[{"key":"a","ingredient":"Milk","quantity":1,"chosen":{"id":"p1","name":"Milk 1 gal"}}],
     "needsChoice":[{"key":"b","ingredient":"Eggs","quantity":2,"options":[
        {"id":"p2","name":"Eggs 12 ct","price":"$3.10","badge":"popular"},
        {"id":"p3","name":"Turkey","preferences":[{"id":"sliced","label":"Sliced"},{"id":"shaved","label":"Shaved"}]}]}],
     "unavailable":[{"key":"c","ingredient":"Saffron","quantity":1,"reason":"no_results"}]}
    """#

    @MainActor
    private func makeSession(_ client: MealioClient) throws -> CartSession {
        let cart = try JSONDecoder().decode(PreparedCart.self, from: Data(ClientTests.cartJSON.utf8))
        return CartSession(client: client, cart: cart)
    }

    @MainActor
    func testCartSessionPicksAndValidation() throws {
        let session = try makeSession(makeClient(keys: TestSigner.keys))
        XCTAssertEqual(session.selections(), [Selection(key: "a", productId: "p1", quantity: 1, remember: true)])
        XCTAssertEqual(session.pending().map(\.key), ["b"])

        XCTAssertThrowsError(try session.choose(key: "zzz", productId: "p1")) { error in
            XCTAssertEqual((error as? MealioError)?.code, MealioError.Code.unknownItem)
        }
        XCTAssertThrowsError(try session.choose(key: "b", productId: "p1")) { error in
            XCTAssertEqual((error as? MealioError)?.code, MealioError.Code.unknownProduct)
        }

        try session.choose(key: "b", productId: "p3", preferenceId: "shaved")
        XCTAssertEqual(session.pending().count, 0)
        session.skip(key: "a")
        XCTAssertEqual(session.selections().map(\.key), ["a", "b"])
        XCTAssertEqual(session.selection(for: "a")?.productId, nil)
        XCTAssertEqual(session.selection(for: "b"), Selection(key: "b", productId: "p3", quantity: 2, remember: true, preferenceId: "shaved"))

        let skip = try JSONValue(encoding: session.selection(for: "a")!)
        XCTAssertEqual(skip, ["key": "a", "productId": .null, "remember": false])
    }

    @MainActor
    func testAddToCartSendsSelectionsAndReturnsTheResult() async throws {
        let result: JSONValue = [
            "cartId": "c/1", "store": "heb",
            "added": [["key": "a", "productId": "p1", "name": "Milk 1 gal", "quantity": 1]],
            "skipped": [["key": "b", "reason": "user_skipped"]],
            "failed": [],
            "storeCartUrl": "https://www.heb.com/cart",
        ]
        let done: JSONValue = ["op": "done", "id": "i1", "result": result]
        let env = TestSigner.envelope(TestSigner.payload(seq: 1, instructions: [done], job: "job_add"))
        let rec = Recorder()
        StubURLProtocol.handler = { req, body in
            rec.record(req, body: body)
            if req.url?.path.hasSuffix("/hello") == true { return (200, jsonData(["ok": true])) }
            return (200, jsonData(["job": "job_add", "envelope": try! JSONValue(encoding: env)]))
        }
        let session = try makeSession(makeClient(keys: TestSigner.keys))
        session.skip(key: "b")
        let added = try await session.addToCart()
        XCTAssertEqual(added.added.first?.productId, "p1")
        XCTAssertEqual(added.skipped.first?.reason, "user_skipped")
        XCTAssertEqual(added.storeCartUrl, "https://www.heb.com/cart")

        // The cart id is escaped like encodeURIComponent.
        let addRequest = try XCTUnwrap(rec.requests.last)
        XCTAssertEqual(addRequest.url?.absoluteString, "https://mealio.test/api/v1/sdk/carts/c%2F1/add")
        let body = try XCTUnwrap(rec.body(addRequest.url?.path ?? ""))
        XCTAssertEqual(body["selections"]?.arrayValue?.count, 2)
        XCTAssertEqual(body["selections"]?.arrayValue?[1], ["key": "b", "productId": .null, "remember": false])
    }
}
