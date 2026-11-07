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

    // Same as the TS "drives a job to done through step calls" test. Who is
    // calling rides on the first call: there is no separate hello round trip.
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
        XCTAssertEqual(rec.paths, ["/api/v1/sdk/carts", "/api/v1/sdk/jobs/job_test/step"])

        let step = try XCTUnwrap(rec.body("/api/v1/sdk/jobs/job_test/step"))
        XCTAssertEqual(step["seq"], .int(1))
        XCTAssertEqual(step["results"]?.arrayValue?.count, 2)
        XCTAssertEqual(step["results"]?.arrayValue?[1]["messages"]?.arrayValue?.first?["type"], .string("HEB_SESSION"))
        XCTAssertNil(step["sdk"])

        let carts = try XCTUnwrap(rec.body("/api/v1/sdk/carts"))
        XCTAssertEqual(carts["store"], .string("heb"))
        XCTAssertNil(carts["zip"])
        XCTAssertEqual(carts["epoch"], .int(7))
        XCTAssertEqual(carts["sdk"]?["platform"], .string("ios"))
        XCTAssertEqual(carts["sdk"]?["version"], .string("0"))
        XCTAssertEqual(carts["sdk"]?["core"], .string(SDK_CORE_VERSION))
        XCTAssertEqual(carts["sdk"]?["ops"]?.arrayValue?.compactMap { $0.stringValue }, SUPPORTED_OPS)

        let first = try XCTUnwrap(rec.requests.first)
        XCTAssertEqual(first.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(first.value(forHTTPHeaderField: "X-Mealio-Publishable-Key"), "pk_test")
        XCTAssertEqual(first.value(forHTTPHeaderField: "X-Mealio-SDK"), "ios/0")
        XCTAssertEqual(first.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    /// Answers every job-starting call with one signed envelope whose `done`
    /// carries `result`, and records what was sent.
    private func serveDone(_ result: JSONValue, job: String = "job_test", rec: Recorder,
                           before: [JSONValue] = []) {
        let env = TestSigner.envelope(TestSigner.payload(seq: 1, instructions: before + [["op": "done", "id": "d1", "result": result]], job: job))
        StubURLProtocol.handler = { req, body in
            rec.record(req, body: body)
            return (200, jsonData(["job": .string(job), "envelope": try! JSONValue(encoding: env)]))
        }
    }

    @MainActor
    func testPrepareCartReadsTheNewShapeAndReportsSteps() async throws {
        let cart: JSONValue = try XCTUnwrap(JSONValue.parse(ClientTests.newCartJSON))
        let rec = Recorder()
        serveDone(cart, rec: rec, before: [
            ["op": "fetch", "id": "session-1", "request": ["method": "GET", "url": "https://www.heb.com/api/session"], "timeoutMs": 1000, "maxBytes": 1000],
            ["op": "fetch", "id": "search-1", "request": ["method": "GET", "url": "https://www.heb.com/api/search"], "timeoutMs": 1000, "maxBytes": 1000],
        ])
        let client = makeClient(keys: TestSigner.keys, epoch: { 3 })
        var steps: [Step] = []
        let session = try await client.prepareCart(recipe: Recipe(id: "r1", ingredients: []), zip: "78701",
                                                   onStep: { step, _ in steps.append(step) })
        XCTAssertEqual(steps, [.checkingSignIn, .searching])
        XCTAssertEqual(session.storeName, "H-E-B")
        XCTAssertEqual(session.items.map(\.key), ["onion", "garlic", "steak", "saffron"])

        // store is optional and left out when nil; zip and the caller ride along.
        let body = try XCTUnwrap(rec.body("/api/v1/sdk/carts"))
        XCTAssertNil(body["store"])
        XCTAssertEqual(body["zip"], .string("78701"))
        XCTAssertEqual(body["epoch"], .int(3))
        XCTAssertEqual(body["sdk"]?["platform"], .string("ios"))
    }

    @MainActor
    func testStoreRequiredComesBackAsItsCode() async throws {
        let fail: JSONValue = ["op": "fail", "id": "f1", "code": "store_required", "message": "Pick a store"]
        let env = TestSigner.envelope(TestSigner.payload(seq: 1, instructions: [fail]))
        StubURLProtocol.handler = { _, _ in (200, jsonData(["job": "job_test", "envelope": try! JSONValue(encoding: env)])) }
        let client = makeClient(keys: TestSigner.keys)
        do {
            _ = try await client.prepareCart(recipe: Recipe(id: "r1", ingredients: []))
            XCTFail("expected store_required")
        } catch let e as MealioError {
            XCTAssertEqual(e.code, MealioError.Code.storeRequired)
        }
    }

    @MainActor
    func testStoresIsAPublicGet() async throws {
        let rec = Recorder()
        StubURLProtocol.handler = { req, body in
            rec.record(req, body: body)
            return (200, jsonData(["stores": [
                ["id": "heb", "name": "H-E-B", "via": "device"],
                ["id": "kroger", "name": "Kroger", "via": "kroger_api"],
            ]]))
        }
        var tokens = 0
        let client = makeClient(keys: TestSigner.keys, token: { tokens += 1; return "tok" })
        let stores = try await client.stores()
        XCTAssertEqual(stores, [StoreInfo(id: "heb", name: "H-E-B", via: "device"), StoreInfo(id: "kroger", name: "Kroger", via: "kroger_api")])
        let req = try XCTUnwrap(rec.requests.first)
        XCTAssertEqual(req.url?.absoluteString, "https://mealio.test/api/v1/stores")
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(tokens, 0)
    }

    // Same as the TS "retries once with a fresh token on 401" test.
    @MainActor
    func testRetriesOnceWithAFreshTokenOn401() async throws {
        let rec = Recorder()
        let env = try XCTUnwrap(Fixtures.vectors()["cases"]?.arrayValue?[1]["envelope"])
        StubURLProtocol.handler = { req, body in
            rec.record(req, body: body)
            return rec.paths.count == 1 ? (401, jsonData([:])) : (200, jsonData(["job": "job_test", "envelope": env]))
        }
        var tokens = 0
        let client = makeClient(keys: TestSigner.keys, token: { tokens += 1; return "t\(tokens)" })
        // The envelope fails its checks after the retry; the point is the token.
        _ = try? await client.addToCart(cartId: "c1", selections: [])
        XCTAssertEqual(tokens, 2)
        XCTAssertEqual(rec.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer t2")
    }

    // Same as the TS "gives the next user a new token" test.
    @MainActor
    func testResetSessionGivesTheNextUserANewToken() async throws {
        let rec = Recorder()
        StubURLProtocol.handler = { req, body in
            rec.record(req, body: body)
            return (200, jsonData([:]))
        }
        var users = ["alice", "bob"]
        let client = makeClient(keys: TestSigner.keys, token: { users.removeFirst() })
        _ = try? await client.storePreferences()
        client.resetSession()
        _ = try? await client.storePreferences()
        XCTAssertEqual(rec.requests.map { $0.value(forHTTPHeaderField: "Authorization") }, ["Bearer alice", "Bearer bob"])
    }

    // Same as the TS "drops a token that arrives after the reset" test.
    @MainActor
    func testATokenThatArrivesAfterTheResetIsDropped() async throws {
        let rec = Recorder()
        StubURLProtocol.handler = { req, body in
            rec.record(req, body: body)
            return (200, jsonData([:]))
        }
        var asked = 0
        var client: MealioClient?
        client = makeClient(keys: TestSigner.keys, token: {
            asked += 1
            if asked == 1 {
                // The user changes while their token is on its way.
                await MainActor.run { client?.resetSession() }
                return "alice"
            }
            return "bob"
        })
        _ = try? await client?.storePreferences()
        XCTAssertEqual(rec.requests.map { $0.value(forHTTPHeaderField: "Authorization") }, ["Bearer bob"])
    }

    @MainActor
    func testTwo401sRaiseSessionExpired() async throws {
        StubURLProtocol.handler = { _, _ in (401, jsonData([:])) }
        let client = makeClient(keys: TestSigner.keys)
        do {
            _ = try await client.addToCart(cartId: "c1", selections: [])
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
            _ = try await client.prepareCart(store: "heb", recipe: Recipe(id: "r1", ingredients: []))
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
        StubURLProtocol.handler = { _, _ in (200, jsonData(["job": "job_test", "envelope": tampered])) }
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
        StubURLProtocol.handler = { _, _ in (200, jsonData(["job": "job_test", "envelope": try! JSONValue(encoding: env)])) }
        let client = makeClient(keys: TestSigner.keys)
        do {
            _ = try await client.prepareCart(store: "heb", recipe: Recipe(id: "r1", ingredients: []))
            XCTFail("expected store_unavailable")
        } catch let e as MealioError {
            XCTAssertEqual(e, MealioError(code: "store_unavailable", message: "Not now"))
        }
    }

    @MainActor
    func testWidenAllowlistOnlyFromAVerifiedEnvelope() async throws {
        let allow: JSONValue = [
            "v": 1, "kind": "allowlist", "exp": 4_102_444_800,
            "stores": ["heb": ["hosts": ["api.heb.com", "heb-cdn.net"]]],
        ]
        let good = TestSigner.envelope(TestSigner.json(allow))
        let client = makeClient(keys: TestSigner.keys)
        client.widenAllowlist(good)
        XCTAssertTrue(client.allowlist.hostsFor("heb")!.hosts.contains("api.heb.com"))
        XCTAssertFalse(client.allowlist.hostsFor("heb")!.hosts.contains("heb-cdn.net"))

        // Same payload, bad signature: ignored, the bundled list stands.
        let bad = Envelope(payload: good.payload, sig: TestSigner.envelope("other").sig, kid: "ktest")
        let other = makeClient(keys: TestSigner.keys)
        other.widenAllowlist(bad)
        XCTAssertEqual(other.allowlist.hostsFor("heb")?.hosts, ["heb.com"])
    }

    // MARK: store locations

    private static let oak: JSONValue = ["id": "k2", "name": "Kroger Oak", "address": "3 Oak St, Dallas, TX 75202", "zip": "75202"]

    // Same as the TS "lists stores near a zip" test.
    @MainActor
    func testStoreLocationsListsStoresNearAZip() async throws {
        let rec = Recorder()
        StubURLProtocol.handler = { req, body in
            rec.record(req, body: body)
            return (200, jsonData(["locations": [ClientTests.oak, ["id": "k3", "name": "Kroger Elm", "address": "4 Elm St", "zip": nil]]]))
        }
        let client = makeClient(keys: TestSigner.keys)
        let found = try await client.storeLocations(store: "kroger", zip: "75202")
        XCTAssertEqual(found, [
            StoreLocation(id: "k2", name: "Kroger Oak", address: "3 Oak St, Dallas, TX 75202", zip: "75202"),
            StoreLocation(id: "k3", name: "Kroger Elm", address: "4 Elm St"),
        ])
        XCTAssertEqual(rec.paths, ["/api/v1/sdk/locations"])
        XCTAssertEqual(rec.requests.first?.httpMethod, "POST")
        XCTAssertEqual(rec.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(rec.body("/api/v1/sdk/locations"), ["store": "kroger", "zip": "75202"])
    }

    @MainActor
    func testStoreLocationsWithNoListIsEmpty() async throws {
        StubURLProtocol.handler = { _, _ in (200, jsonData([:])) }
        let client = makeClient(keys: TestSigner.keys)
        let found = try await client.storeLocations(store: "kroger", zip: "75202")
        XCTAssertEqual(found, [])
    }

    // Same as the TS test: {} reads, {store, locationId?} writes.
    @MainActor
    func testPreferencesReadsAndWrites() async throws {
        let rec = Recorder()
        var seen: [JSONValue] = []
        StubURLProtocol.handler = { req, body in
            rec.record(req, body: body)
            return (200, jsonData(["defaultStore": "kroger", "location": ClientTests.oak]))
        }
        let client = makeClient(keys: TestSigner.keys)
        let path = "/api/v1/sdk/preferences"

        let read = try await client.storePreferences()
        XCTAssertEqual(read.defaultStore, "kroger")
        XCTAssertEqual(read.location?.id, "k2")
        seen.append(try XCTUnwrap(rec.body(path)))

        try await client.setStore("kroger", locationId: "k2")
        seen.append(try XCTUnwrap(rec.body(path)))

        try await client.setStore("heb")
        seen.append(try XCTUnwrap(rec.body(path)))

        XCTAssertEqual(seen, [[:], ["store": "kroger", "locationId": "k2"], ["store": "heb"]])
    }

    @MainActor
    func testPreferencesWithNoStoreYet() async throws {
        StubURLProtocol.handler = { _, _ in (200, jsonData(["defaultStore": nil, "location": nil])) }
        let client = makeClient(keys: TestSigner.keys)
        let read = try await client.storePreferences()
        XCTAssertEqual(read, StorePreferences())
    }

    // Same as the TS "a cart with no store chosen fails with location_required" test.
    @MainActor
    func testLocationRequiredComesBackAsItsCode() async throws {
        StubURLProtocol.handler = { _, _ in
            (409, jsonData(["error": ["code": "location_required", "message": "Choose"]]))
        }
        let client = makeClient(keys: TestSigner.keys)
        do {
            _ = try await client.prepareCart(store: "kroger", recipe: Recipe(id: "r1", ingredients: []))
            XCTFail("expected location_required")
        } catch let e as MealioError {
            XCTAssertEqual(e.code, MealioError.Code.locationRequired)
        }
    }

    func testPreparedCartLocationIsOptional() throws {
        // A server from before store locations leaves it out.
        let old = try JSONDecoder().decode(PreparedCart.self, from: Data(ClientTests.newCartJSON.utf8))
        XCTAssertNil(old.location)

        let plain = try JSONDecoder().decode(PreparedCart.self, from: Data(#"{"cartId":"c","store":"heb","location":null,"items":[]}"#.utf8))
        XCTAssertNil(plain.location)

        let kroger = try JSONDecoder().decode(PreparedCart.self, from: Data(#"{"cartId":"c","store":"kroger","location":{"id":"k2","name":"Kroger Oak","address":"3 Oak St","zip":null},"items":[]}"#.utf8))
        XCTAssertEqual(kroger.location, StoreLocation(id: "k2", name: "Kroger Oak", address: "3 Oak St"))
    }

    @MainActor
    func testCartSessionCarriesTheLocation() async throws {
        var cart = try XCTUnwrap(JSONValue.parse(ClientTests.newCartJSON)?.objectValue)
        cart["location"] = ClientTests.oak
        serveDone(.object(cart), rec: Recorder())
        let client = makeClient(keys: TestSigner.keys)
        let session = try await client.prepareCart(recipe: Recipe(id: "r1", ingredients: []))
        XCTAssertEqual(session.location?.name, "Kroger Oak")
    }

    func testZipBox() {
        XCTAssertTrue(mealioIsZip("75202"))
        XCTAssertFalse(mealioIsZip("7520"))
        XCTAssertFalse(mealioIsZip("752021"))
        XCTAssertFalse(mealioIsZip("7520a"))
        XCTAssertFalse(mealioIsZip(""))
        XCTAssertEqual(mealioCleanZip("75-202 9"), "75202")
        XCTAssertEqual(mealioCleanZip("abc"), "")
        XCTAssertEqual(mealioCleanZip("\u{0663}12"), "12")
    }

    // MARK: stepOf

    func testStepOfMapsInstructionIdsToProgressSteps() {
        func ins(_ op: String, _ id: String) -> Instruction {
            switch op {
            case "show_login": return Instruction(json: ["op": "show_login", "id": .string(id), "url": "https://www.heb.com/login"])
            default: return Instruction(json: ["op": "page_open", "id": .string(id), "url": "https://www.heb.com/"])
            }
        }
        XCTAssertEqual(stepOf(ins("page_open", "open-1")), .connecting)
        XCTAssertEqual(stepOf(ins("page_open", "session-1")), .checkingSignIn)
        XCTAssertEqual(stepOf(ins("page_open", "resession-2")), .checkingSignIn)
        XCTAssertEqual(stepOf(ins("page_open", "search-3")), .searching)
        XCTAssertEqual(stepOf(ins("page_open", "add-4")), .adding)
        XCTAssertEqual(stepOf(ins("page_open", "login-check")), .connecting)
        // show_login is signing in whatever its id says.
        XCTAssertEqual(stepOf(ins("show_login", "search-9")), .signingIn)
        XCTAssertEqual(Step.checkingSignIn.rawValue, "checking_sign_in")
        XCTAssertEqual(Step.signingIn.rawValue, "signing_in")
    }

    // MARK: CartSession

    /// A 0.1 payload: groupings only, no items / status / selectedId.
    private static let cartJSON = #"""
    {"cartId":"c/1","store":"heb",
     "ready":[{"key":"a","ingredient":"Milk","quantity":1,"chosen":{"id":"p1","name":"Milk 1 gal"}}],
     "needsChoice":[{"key":"b","ingredient":"Eggs","quantity":2,"options":[
        {"id":"p2","name":"Eggs 12 ct","price":"$3.10","badge":"popular"},
        {"id":"p3","name":"Turkey","preferences":[{"id":"sliced","label":"Sliced"},{"id":"shaved","label":"Shaved"}]}]}],
     "unavailable":[{"key":"c","ingredient":"Saffron","quantity":1,"reason":"no_results"}]}
    """#

    /// The 0.2 shape: every item in order, with status and pre-selection.
    static let newCartJSON = #"""
    {"cartId":"c/2","store":"heb","storeName":"H-E-B",
     "items":[
      {"key":"onion","ingredient":"onion","quantity":2,"status":"remembered","selectedId":"o1",
       "remembered":{"id":"o1","name":"Onion","price":"$1.25","unitPrice":1.25},
       "rememberedPreferenceId":null,
       "options":[{"id":"o1","name":"Onion","price":"$1.25","unitPrice":1.25},{"id":"o2","name":"Red Onion","unitPrice":1.5}]},
      {"key":"garlic","ingredient":"garlic","quantity":1,"status":"choose","selectedId":null,"remembered":null,
       "options":[{"id":"g1","name":"Garlic","unitPrice":0.5}]},
      {"key":"steak","ingredient":"steak","quantity":1,"status":"remembered","selectedId":"s1",
       "remembered":{"id":"s1","name":"Ribeye","unitPrice":12.99,"estimated":true,"preferences":[{"id":"thin","label":"Thin"}]},
       "rememberedPreferenceId":"thin",
       "options":[{"id":"s1","name":"Ribeye","unitPrice":12.99,"estimated":true,"preferences":[{"id":"thin","label":"Thin"}]},
                  {"id":"s2","name":"Sirloin"}]},
      {"key":"saffron","ingredient":"saffron","quantity":1,"status":"unavailable","selectedId":null,"remembered":null,"options":[],"reason":"no_results"}
     ],
     "ready":[],"needsChoice":[],"unavailable":[]}
    """#

    @MainActor
    private func makeSession(_ client: MealioClient, json: String = ClientTests.cartJSON) throws -> CartSession {
        let cart = try JSONDecoder().decode(PreparedCart.self, from: Data(json.utf8))
        return CartSession(client: client, cart: cart)
    }

    func testOldPayloadsStillDecode() throws {
        let cart = try JSONDecoder().decode(PreparedCart.self, from: Data(ClientTests.cartJSON.utf8))
        XCTAssertEqual(cart.items.map(\.key), ["a", "b", "c"])
        XCTAssertNil(cart.storeName)
        XCTAssertEqual(cart.items.map(\.status), [.remembered, .choose, .unavailable])
        XCTAssertEqual(cart.items[0].selectedId, "p1")
        XCTAssertEqual(cart.items[0].remembered?.id, "p1")
        XCTAssertEqual(cart.items[0].options.map(\.id), ["p1"])
        XCTAssertNil(cart.items[1].selectedId)
        XCTAssertEqual(cart.items[1].options.first?.estimated, false)
        XCTAssertNil(cart.items[1].options.first?.unitPrice)
        XCTAssertEqual(cart.items[2].reason, "no_results")

        // An AddResult from before `verified` existed.
        let add = try JSONDecoder().decode(AddResult.self, from: Data(#"{"cartId":"c","store":"heb","added":[],"skipped":[],"failed":[],"storeCartUrl":null}"#.utf8))
        XCTAssertNil(add.verified)
    }

    func testNewFieldsDecode() throws {
        let cart = try JSONDecoder().decode(PreparedCart.self, from: Data(ClientTests.newCartJSON.utf8))
        XCTAssertEqual(cart.storeName, "H-E-B")
        XCTAssertEqual(cart.items.map(\.status), [.remembered, .choose, .remembered, .unavailable])
        XCTAssertEqual(cart.items[2].rememberedPreferenceId, "thin")
        XCTAssertEqual(cart.items[2].remembered?.estimated, true)
        XCTAssertEqual(cart.items[0].options[1].unitPrice, 1.5)
        let unknown = try JSONDecoder().decode(CartItem.self, from: Data(#"{"key":"x","ingredient":"x","quantity":1,"status":"something_new","options":[{"id":"x1","name":"X"}]}"#.utf8))
        XCTAssertEqual(unknown.status, .choose)

        let add = try JSONDecoder().decode(AddResult.self, from: Data(#"""
        {"cartId":"c","store":"heb","added":[],"skipped":[],"verified":false,
         "failed":[{"key":"a","productId":"p1","name":"Milk","reason":"not_confirmed"}],"storeCartUrl":null}
        """#.utf8))
        XCTAssertEqual(add.verified, false)
        XCTAssertEqual(add.failed.first?.reason, "not_confirmed")
    }

    // Same as the TS "starts with remembered items selected, and deselecting
    // leaves them out without forgetting" test.
    @MainActor
    func testRememberedItemsStartSelectedAndDeselectLeavesThemOut() throws {
        let session = try makeSession(makeClient(keys: TestSigner.keys), json: ClientTests.newCartJSON)
        XCTAssertTrue(session.isSelected("onion"))
        XCTAssertTrue(session.isSelected("steak"))
        XCTAssertFalse(session.isSelected("garlic"))
        XCTAssertFalse(session.isSelected("saffron"))
        XCTAssertEqual(session.selectedId(for: "onion"), "o1")
        XCTAssertEqual(session.preferenceId(for: "steak"), "thin")
        XCTAssertEqual(session.selected(for: "steak")?.name, "Ribeye")

        try session.select(key: "garlic", productId: "g1")
        session.deselect(key: "onion")
        XCTAssertEqual(session.selections(), [
            Selection(key: "onion", productId: nil, remember: false),
            Selection(key: "garlic", productId: "g1", quantity: 1, remember: true),
            Selection(key: "steak", productId: "s1", quantity: 1, remember: true, preferenceId: "thin"),
            Selection(key: "saffron", productId: nil, remember: false),
        ])
        // On the wire a left-out item is productId null, remember false, no quantity.
        let left = try JSONValue(encoding: session.selections()[0])
        XCTAssertEqual(left, ["key": "onion", "productId": .null, "remember": false])

        XCTAssertThrowsError(try session.select(key: "zzz", productId: "g1")) { error in
            XCTAssertEqual((error as? MealioError)?.code, MealioError.Code.unknownItem)
        }
        XCTAssertThrowsError(try session.select(key: "garlic", productId: "nope")) { error in
            XCTAssertEqual((error as? MealioError)?.code, MealioError.Code.unknownProduct)
        }
    }

    // Same as the TS "keeps a quantity per item, clamped to 1 and the store
    // cap, in selections and the total" test.
    @MainActor
    func testKeepsAQuantityPerItemClampedToOneAndTheStoreCap() throws {
        let json = #"""
        {"cartId":"c1","store":"heb",
         "items":[
          {"key":"onion","ingredient":"onion","quantity":2,"status":"remembered","selectedId":"o1",
           "remembered":{"id":"o1","name":"Onion","unitPrice":1.5,"maxQuantity":3},
           "options":[{"id":"o1","name":"Onion","unitPrice":1.5,"maxQuantity":3},{"id":"o2","name":"Red Onion"}]},
          {"key":"garlic","ingredient":"garlic","quantity":1,"status":"choose","selectedId":null,"remembered":null,
           "options":[{"id":"g1","name":"Garlic"}]},
          {"key":"saffron","ingredient":"saffron","quantity":1,"status":"unavailable","selectedId":null,"remembered":null,"options":[],"reason":"no_results"}
         ],
         "ready":[],"needsChoice":[],"unavailable":[]}
        """#
        let session = try makeSession(makeClient(keys: TestSigner.keys), json: json)
        XCTAssertEqual(session.quantity(for: "onion"), 2)
        XCTAssertEqual(session.setQuantity(key: "onion", to: 9), 3)
        XCTAssertEqual(session.setQuantity(key: "onion", to: 0), 1)
        session.setQuantity(key: "onion", to: 3)
        XCTAssertEqual(session.selections()[0], Selection(key: "onion", productId: "o1", quantity: 3, remember: true))
        XCTAssertEqual(try XCTUnwrap(session.estimate().total), 4.5, accuracy: 0.001)
        try session.select(key: "onion", productId: "o2")
        XCTAssertEqual(session.maxQuantity(for: "onion"), 99)
        XCTAssertEqual(session.quantity(for: "onion"), 3)
    }

    func testQuantityFieldsDecodeAndAreOptional() throws {
        let p = try JSONDecoder().decode(Product.self, from: Data(#"{"id":"f1","name":"Salmon","maxQuantity":4,"soldByWeight":true,"weightOptions":[0.5,1,1.5]}"#.utf8))
        XCTAssertEqual(p.maxQuantity, 4)
        XCTAssertEqual(p.soldByWeight, true)
        XCTAssertEqual(p.weightOptions, [0.5, 1, 1.5])
        let old = try JSONDecoder().decode(Product.self, from: Data(#"{"id":"o1","name":"Onion","maxQuantity":null}"#.utf8))
        XCTAssertNil(old.maxQuantity)
        XCTAssertNil(old.soldByWeight)
        XCTAssertNil(old.weightOptions)
    }

    @MainActor
    func testEstimateTotalsSelectedItemsAndFlagsEstimates() throws {
        let session = try makeSession(makeClient(keys: TestSigner.keys), json: ClientTests.newCartJSON)
        // onion 1.25 x 2 + steak 12.99 (sold by weight).
        XCTAssertEqual(session.estimate(), CartEstimate(total: 15.49, count: 2, estimated: true, unpriced: 0))

        // Without the steak nothing is estimated: an exact total.
        session.deselect(key: "steak")
        try session.select(key: "garlic", productId: "g1")
        XCTAssertEqual(session.estimate(), CartEstimate(total: 3.0, count: 2, estimated: false, unpriced: 0))

        // A selected product with no unit price: no partial totals, so no total.
        try session.select(key: "steak", productId: "s2")
        XCTAssertEqual(session.estimate(), CartEstimate(total: nil, count: 3, estimated: true, unpriced: 1))

        session.deselect(key: "onion")
        session.deselect(key: "garlic")
        session.deselect(key: "steak")
        XCTAssertEqual(session.estimate(), CartEstimate(total: 0, count: 0, estimated: false, unpriced: 0))
    }

    // Same as the TS "adds searched products to an item and lets the user pick one" test.
    @MainActor
    func testSearchMergesOptionsAndSendsTheQuery() async throws {
        let rec = Recorder()
        serveDone(["key": "garlic", "query": "jar", "options": [
            ["id": "g9", "name": "Minced Garlic Jar", "unitPrice": 2.5],
            ["id": "g1", "name": "Garlic"],
        ]], rec: rec)
        let session = try makeSession(makeClient(keys: TestSigner.keys, epoch: { 4 }), json: ClientTests.newCartJSON)
        let found = try await session.search(key: "garlic", query: "jar")
        XCTAssertEqual(found.map(\.id), ["g9", "g1"])
        // Base options first, then new ones, no duplicates.
        XCTAssertEqual(session.options(for: "garlic").map(\.id), ["g1", "g9"])
        XCTAssertEqual(session.options(for: "onion").map(\.id), ["o1", "o2"])
        try session.select(key: "garlic", productId: "g9")
        XCTAssertEqual(session.selectedId(for: "garlic"), "g9")
        XCTAssertThrowsError(try session.select(key: "garlic", productId: "nope"))

        let req = try XCTUnwrap(rec.requests.first)
        XCTAssertEqual(req.url?.absoluteString, "https://mealio.test/api/v1/sdk/carts/c%2F2/search")
        let body = try XCTUnwrap(rec.body(req.url?.path ?? ""))
        XCTAssertEqual(body["key"], .string("garlic"))
        XCTAssertEqual(body["query"], .string("jar"))
        XCTAssertEqual(body["epoch"], .int(4))
        XCTAssertEqual(body["sdk"]?["platform"], .string("ios"))
    }

    @MainActor
    func testDeprecatedNamesStillWork() throws {
        let session = try makeSession(makeClient(keys: TestSigner.keys))
        XCTAssertEqual(session.pending().map(\.key), ["b"])
        try session.choose(key: "b", productId: "p3", preferenceId: "shaved")
        XCTAssertEqual(session.pending().count, 0)
        session.skip(key: "a")
        XCTAssertEqual(session.selections().map(\.key), ["a", "b", "c"])
        XCTAssertNil(session.selection(for: "a")?.productId)
        XCTAssertEqual(session.selection(for: "b"), Selection(key: "b", productId: "p3", quantity: 2, remember: true, preferenceId: "shaved"))
        XCTAssertEqual(session.selection(for: "c"), Selection(key: "c", productId: nil, remember: false))
    }

    @MainActor
    func testAddToCartSendsEverySelectionAndReturnsTheResult() async throws {
        let result: JSONValue = [
            "cartId": "c/1", "store": "heb",
            "added": [["key": "a", "productId": "p1", "name": "Milk 1 gal", "quantity": 1]],
            "skipped": [["key": "b", "reason": "deselected"]],
            "failed": [],
            "storeCartUrl": "https://www.heb.com/cart",
            "verified": true,
        ]
        let rec = Recorder()
        serveDone(result, job: "job_add", rec: rec, before: [
            ["op": "fetch", "id": "add-1", "request": ["method": "GET", "url": "https://www.heb.com/api/search"], "timeoutMs": 1000, "maxBytes": 1000],
        ])
        let session = try makeSession(makeClient(keys: TestSigner.keys, epoch: { 9 }))
        var steps: [Step] = []
        let added = try await session.addToCart(onStep: { step, _ in steps.append(step) })
        XCTAssertEqual(steps, [.adding])
        XCTAssertEqual(added.added.first?.productId, "p1")
        XCTAssertEqual(added.skipped.first?.reason, "deselected")
        XCTAssertEqual(added.storeCartUrl, "https://www.heb.com/cart")
        XCTAssertEqual(added.verified, true)

        // The cart id is escaped like encodeURIComponent.
        let addRequest = try XCTUnwrap(rec.requests.last)
        XCTAssertEqual(addRequest.url?.absoluteString, "https://mealio.test/api/v1/sdk/carts/c%2F1/add")
        let body = try XCTUnwrap(rec.body(addRequest.url?.path ?? ""))
        XCTAssertEqual(body["selections"]?.arrayValue?.count, 3)
        XCTAssertEqual(body["selections"]?.arrayValue?[0], ["key": "a", "productId": "p1", "quantity": 1, "remember": true])
        XCTAssertEqual(body["selections"]?.arrayValue?[1], ["key": "b", "productId": .null, "remember": false])
        XCTAssertEqual(body["epoch"], .int(9))
        XCTAssertEqual(body["sdk"]?["ops"]?.arrayValue?.count, SUPPORTED_OPS.count)
    }

    // MARK: Sold by weight
    // Same as the TS "cart session > sold by weight" tests.

    private static let turkeyJSON = #"{"id":"t1","name":"Deli Turkey","soldByWeight":true,"estimated":true,"pricePerLb":10,"unitPrice":10,"weightOptions":[0.25,0.5,0.75,1,1.25]}"#
    private static let salmonJSON = #"{"id":"s1","name":"Salmon","soldByWeight":true,"estimated":true,"pricePerLb":12,"unitPrice":12}"#
    private static let brisketJSON = #"{"id":"b1","name":"Brisket, Avg. 4 lbs","soldByWeight":true,"estimated":true,"pricePerLb":null,"unitPrice":32}"#

    /// The turkey item, with `weightLb` when given, and a count item (onion x2 at $1).
    private static func weightCartJSON(weightLb: Double? = nil) -> String {
        let w = weightLb.map { #""weightLb":\#($0),"# } ?? ""
        return #"""
        {"cartId":"c1","store":"heb","ready":[],"needsChoice":[],"unavailable":[],
         "items":[
          {"key":"turkey","ingredient":"deli turkey","quantity":1,\#(w)"status":"remembered","selectedId":"t1",
           "remembered":\#(turkeyJSON),"options":[\#(turkeyJSON),\#(salmonJSON),\#(brisketJSON)]},
          {"key":"onion","ingredient":"onion","quantity":2,"status":"remembered","selectedId":"o1","remembered":null,
           "options":[{"id":"o1","name":"Onion","unitPrice":1}]}
         ]}
        """#
    }

    @MainActor
    private func weightSession(weightLb: Double? = nil) throws -> CartSession {
        try makeSession(makeClient(keys: TestSigner.keys), json: ClientTests.weightCartJSON(weightLb: weightLb))
    }

    @MainActor
    func testWeightStartsAtTheRecipeWeightElseTheFirstOptionElseAQuarterPound() throws {
        XCTAssertEqual(try weightSession(weightLb: 0.75).weight(for: "turkey"), 0.75)
        // A recipe weight the store does not sell becomes the nearest one it does.
        XCTAssertEqual(try weightSession(weightLb: 0.6).weight(for: "turkey"), 0.5)
        XCTAssertEqual(try weightSession().weight(for: "turkey"), 0.25)
        let cs = try weightSession()
        try cs.select(key: "turkey", productId: "s1")
        XCTAssertEqual(cs.weight(for: "turkey"), 0.25)
        XCTAssertEqual(cs.weight(for: "onion"), 0)
        XCTAssertTrue(cs.isWeight("turkey"))
        XCTAssertFalse(cs.isWeight("onion"))
    }

    @MainActor
    func testSetWeightSnapsToTheOptionsAndClampsToTheirRange() throws {
        let cs = try weightSession()
        XCTAssertEqual(cs.setWeight(key: "turkey", to: 0.8), 0.75)
        XCTAssertEqual(cs.setWeight(key: "turkey", to: 9), 1.25)
        XCTAssertEqual(cs.setWeight(key: "turkey", to: 0), 0.25)
        XCTAssertEqual(cs.weightRange(for: "turkey"), 0.25...1.25)
        XCTAssertEqual(cs.weight(for: "turkey"), 0.25)
    }

    @MainActor
    func testWithNoOptionsWeightStepsAQuarterPoundFromAQuarterTo20() throws {
        let cs = try weightSession()
        try cs.select(key: "turkey", productId: "s1")
        XCTAssertEqual(cs.setWeight(key: "turkey", to: 1.1), 1)
        XCTAssertEqual(cs.setWeight(key: "turkey", to: 1.13), 1.25)
        XCTAssertEqual(cs.setWeight(key: "turkey", to: 0.01), 0.25)
        XCTAssertEqual(cs.setWeight(key: "turkey", to: 99), 20)
        XCTAssertEqual(cs.weightRange(for: "turkey"), 0.25...20)
        cs.setWeight(key: "turkey", to: 1)
        XCTAssertEqual(cs.stepWeight(key: "turkey", by: 1), 1.25)
        XCTAssertEqual(cs.stepWeight(key: "turkey", by: -1), 1)
    }

    @MainActor
    func testStepWeightWalksTheOptionsAndStopsAtTheEnds() throws {
        let cs = try weightSession()
        XCTAssertEqual(cs.stepWeight(key: "turkey", by: -1), 0.25)
        XCTAssertEqual(cs.stepWeight(key: "turkey", by: 1), 0.5)
        cs.setWeight(key: "turkey", to: 1.25)
        XCTAssertEqual(cs.stepWeight(key: "turkey", by: 1), 1.25)
        XCTAssertEqual(cs.stepWeight(key: "turkey", by: -1), 1)
    }

    @MainActor
    func testSwitchingProductReSnapsTheWeightToTheNewProduct() throws {
        let cs = try weightSession()
        try cs.select(key: "turkey", productId: "s1")
        cs.setWeight(key: "turkey", to: 3)
        try cs.select(key: "turkey", productId: "t1")
        XCTAssertEqual(cs.weight(for: "turkey"), 1.25)
    }

    @MainActor
    func testSelectionsSendWeightLbForWeightItemsOnly() throws {
        let cs = try weightSession(weightLb: 1)
        XCTAssertEqual(cs.selections(), [
            Selection(key: "turkey", productId: "t1", quantity: 1, weightLb: 1, remember: true),
            Selection(key: "onion", productId: "o1", quantity: 2, remember: true),
        ])
        let wire = try JSONValue(encoding: cs.selections())
        XCTAssertEqual(wire.arrayValue?[0], ["key": "turkey", "productId": "t1", "quantity": 1, "weightLb": 1, "remember": true])
        XCTAssertEqual(wire.arrayValue?[1], ["key": "onion", "productId": "o1", "quantity": 2, "remember": true])
    }

    @MainActor
    func testWeightEstimateIsPricePerLbTimesTheWeightAndMarkedEstimated() throws {
        let cs = try weightSession()
        cs.setWeight(key: "turkey", to: 1.25)
        let est = cs.estimate()
        XCTAssertEqual(try XCTUnwrap(est.total), 14.5, accuracy: 0.001)
        XCTAssertTrue(est.estimated)
        XCTAssertEqual(est.count, 2)
        // A package-priced weight item counts its price once, whatever the weight.
        try cs.select(key: "turkey", productId: "b1")
        cs.setWeight(key: "turkey", to: 3)
        XCTAssertEqual(try XCTUnwrap(cs.estimate().total), 34, accuracy: 0.001)
        XCTAssertTrue(cs.estimate().estimated)
    }

    func testWeightFieldsDecodeAndAreOptional() throws {
        let item = try JSONDecoder().decode(CartItem.self, from: Data(#"{"key":"t","ingredient":"turkey","quantity":1,"weightLb":1.25,"status":"choose","options":[\#(ClientTests.turkeyJSON),\#(ClientTests.brisketJSON)]}"#.utf8))
        XCTAssertEqual(item.weightLb, 1.25)
        XCTAssertEqual(item.options[0].pricePerLb, 10)
        XCTAssertNil(item.options[1].pricePerLb)
        let old = try JSONDecoder().decode(CartItem.self, from: Data(#"{"key":"o","ingredient":"onion","quantity":1,"status":"choose","options":[{"id":"o1","name":"Onion"}]}"#.utf8))
        XCTAssertNil(old.weightLb)
        XCTAssertNil(old.options[0].pricePerLb)

        let add = try JSONDecoder().decode(AddResult.self, from: Data(#"""
        {"cartId":"c","store":"heb","skipped":[],"failed":[],"storeCartUrl":null,
         "added":[{"key":"t","productId":"t1","name":"Deli Turkey","quantity":1,"weightLb":1.25},
                  {"key":"o","productId":"o1","name":"Onion","quantity":2}]}
        """#.utf8))
        XCTAssertEqual(add.added[0].weightLb, 1.25)
        XCTAssertNil(add.added[1].weightLb)
    }

    // MARK: No partial totals
    // Same as the TS "cart session > no partial totals" tests.

    /// Onion x2 at $1, deli turkey 0.5 lb at $12/lb (overridable), and an
    /// unselected chipotle with no price.
    private static func pricedCartJSON(turkey: String = #""pricePerLb":12,"unitPrice":12"#) -> String {
        #"""
        {"cartId":"c1","store":"heb","ready":[],"needsChoice":[],"unavailable":[],
         "items":[
          {"key":"onion","ingredient":"onion","quantity":2,"status":"remembered","selectedId":"o1","remembered":null,
           "options":[{"id":"o1","name":"Onion","unitPrice":1}]},
          {"key":"turkey","ingredient":"deli turkey","quantity":1,"weightLb":0.5,"status":"remembered","selectedId":"t1","remembered":null,
           "options":[{"id":"t1","name":"Deli Turkey","soldByWeight":true,"estimated":true,\#(turkey)}]},
          {"key":"chipotle","ingredient":"chipotle in adobo","quantity":1,"status":"choose","selectedId":null,"remembered":null,
           "options":[{"id":"c1","name":"Chipotle Peppers","unitPrice":null}]}
         ]}
        """#
    }

    @MainActor
    private func pricedSession(turkey: String? = nil) throws -> CartSession {
        let json = turkey.map { ClientTests.pricedCartJSON(turkey: $0) } ?? ClientTests.pricedCartJSON()
        return try makeSession(makeClient(keys: TestSigner.keys), json: json)
    }

    private static func result(_ added: [AddedItem]) -> AddResult {
        AddResult(cartId: "c1", store: "heb", added: added, skipped: [], failed: [], storeCartUrl: nil, verified: true)
    }

    @MainActor
    func testTotalsWhenEverySelectedItemHasAPriceAndAWeightItemPricedPerLbCounts() throws {
        XCTAssertEqual(try pricedSession().estimate(), CartEstimate(total: 8, count: 2, estimated: true, unpriced: 0))
    }

    @MainActor
    func testTotalIsNilWhenEvenOneSelectedItemHasNoPrice() throws {
        let cs = try pricedSession()
        try cs.select(key: "chipotle", productId: "c1")
        XCTAssertEqual(cs.estimate(), CartEstimate(total: nil, count: 3, estimated: true, unpriced: 1))
        // A weight item with neither a per-lb nor a package price is unpriced too.
        let w = try pricedSession(turkey: #""pricePerLb":null,"unitPrice":null"#)
        XCTAssertNil(w.estimate().total)
        XCTAssertEqual(w.estimate().unpriced, 1)
        // Deselecting the unpriced item brings the number back.
        cs.deselect(key: "chipotle")
        XCTAssertEqual(cs.estimate().total, 8)
    }

    func testPricesAddedItemsFromTheirOwnFields() {
        XCTAssertEqual(addedPrice(AddedItem(key: "a", productId: "1", name: "Onion", quantity: 2, unitPrice: 0.37)),
                       AddedPrice(amount: 0.74, estimated: false))
        XCTAssertEqual(addedPrice(AddedItem(key: "b", productId: "2", name: "Salmon", quantity: 1, weightLb: 1.25,
                                            unitPrice: 10.9, pricePerLb: 10.9, estimated: true)),
                       AddedPrice(amount: 13.63, estimated: true))
        XCTAssertEqual(addedPrice(AddedItem(key: "c", productId: "3", name: "Brisket", quantity: 1, weightLb: 4,
                                            unitPrice: 32, estimated: true)),
                       AddedPrice(amount: 32, estimated: true))
        XCTAssertNil(addedPrice(AddedItem(key: "d", productId: "4", name: "Chipotle", quantity: 1)))
    }

    @MainActor
    func testAddedTotalReadsTheEntriesFallsBackToTheSessionAndIsNilWhenAnyIsUnpriced() throws {
        let cs = try pricedSession()
        let full = ClientTests.result([
            AddedItem(key: "onion", productId: "o1", name: "Onion", quantity: 2, imageUrl: "https://img/o.jpg",
                      ingredient: "2 onions", unitPrice: 1.25),
            AddedItem(key: "turkey", productId: "t1", name: "Deli Turkey", quantity: 1, weightLb: 0.5,
                      pricePerLb: 12, estimated: true),
        ])
        XCTAssertEqual(cs.addedTotal(full), CartEstimate(total: 8.5, count: 2, estimated: true, unpriced: 0))
        // An older server: no prices on the entries, the selected products stand in.
        let old = ClientTests.result([
            AddedItem(key: "onion", productId: "o1", name: "Onion", quantity: 2),
            AddedItem(key: "turkey", productId: "t1", name: "Deli Turkey", quantity: 1, weightLb: 0.5),
        ])
        XCTAssertEqual(cs.addedTotal(old), CartEstimate(total: 8, count: 2, estimated: true, unpriced: 0))
        try cs.select(key: "chipotle", productId: "c1")
        let withChipotle = ClientTests.result(full.added + [AddedItem(key: "chipotle", productId: "c1", name: "Chipotle Peppers", quantity: 1)])
        XCTAssertEqual(cs.addedTotal(withChipotle), CartEstimate(total: nil, count: 3, estimated: true, unpriced: 1))
        XCTAssertEqual(cs.addedPrice(full.added[0]), AddedPrice(amount: 2.5, estimated: false))
    }

    func testAddedEntryFieldsDecodeAndAreOptional() throws {
        let add = try JSONDecoder().decode(AddResult.self, from: Data(#"""
        {"cartId":"c","store":"heb","skipped":[],"failed":[],"storeCartUrl":null,"verified":true,
         "added":[{"key":"t","productId":"t1","name":"Deli Turkey","quantity":1,"weightLb":0.5,
                   "imageUrl":"https://img/t.jpg","ingredient":"1/2 lb deli turkey","unitPrice":12,"pricePerLb":12,"estimated":true},
                  {"key":"o","productId":"o1","name":"Onion","quantity":2}]}
        """#.utf8))
        XCTAssertEqual(add.added[0], AddedItem(key: "t", productId: "t1", name: "Deli Turkey", quantity: 1, weightLb: 0.5,
                                               imageUrl: "https://img/t.jpg", ingredient: "1/2 lb deli turkey",
                                               unitPrice: 12, pricePerLb: 12, estimated: true))
        XCTAssertEqual(add.added[1], AddedItem(key: "o", productId: "o1", name: "Onion", quantity: 2))
    }

    // MARK: Preferences

    // Same as the TS "holds an item back from the add and the total until its
    // preference is chosen" test.
    @MainActor
    func testHoldsAnItemBackFromTheAddAndTheTotalUntilItsPreferenceIsChosen() throws {
        let json = #"""
        {"cartId":"c1","store":"heb","ready":[],"needsChoice":[],"unavailable":[],
         "items":[
          {"key":"onion","ingredient":"onion","quantity":1,"status":"remembered","selectedId":"o1","remembered":{"id":"o1","name":"Onion"},
           "options":[{"id":"o1","name":"Onion"},{"id":"o2","name":"Red Onion"}]},
          {"key":"garlic","ingredient":"garlic","quantity":1,"status":"choose","selectedId":null,"remembered":null,
           "options":[{"id":"g1","name":"Deli Turkey","unitPrice":6,"preferences":[{"id":"thin","label":"Thin"},{"id":"none","label":"No preference"}]}]},
          {"key":"saffron","ingredient":"saffron","quantity":1,"status":"unavailable","selectedId":null,"remembered":null,"options":[],"reason":"no_results"}
         ]}
        """#
        let cs = try makeSession(makeClient(keys: TestSigner.keys), json: json)
        try cs.select(key: "garlic", productId: "g1")
        XCTAssertTrue(cs.needsPreference("garlic"))
        XCTAssertFalse(cs.needsPreference("onion"))
        XCTAssertFalse(cs.needsPreference("saffron"))
        XCTAssertEqual(cs.pendingPreferences(), ["garlic"])
        XCTAssertEqual(cs.selections()[1], Selection(key: "garlic", productId: nil, remember: false))
        XCTAssertEqual(cs.estimate().count, 1)
        try cs.select(key: "garlic", productId: "g1", preferenceId: "thin")
        XCTAssertFalse(cs.needsPreference("garlic"))
        XCTAssertEqual(cs.pendingPreferences(), [])
        XCTAssertEqual(cs.preferenceId(for: "garlic"), "thin")
        XCTAssertEqual(cs.selections()[1], Selection(key: "garlic", productId: "g1", quantity: 1, remember: true, preferenceId: "thin"))
        XCTAssertEqual(cs.estimate().count, 2)
    }

    // MARK: Recipe details

    private static let pantryProduct = Product(id: "9", name: "Salt", unitPrice: 1)

    /// Same as the TS "pantry and optional items" cart: salt is remembered and
    /// starts unchecked, onion is remembered and does not.
    private static func pantryCart(saltStatus: ItemStatus = .remembered) -> PreparedCart {
        func item(_ key: String, _ status: ItemStatus, startUnchecked: Bool) -> CartItem {
            CartItem(key: key, ingredient: key, status: status, options: [pantryProduct],
                     selectedId: status == .remembered ? "9" : nil,
                     remembered: status == .remembered ? pantryProduct : nil, startUnchecked: startUnchecked)
        }
        return PreparedCart(cartId: "c", store: "heb", items: [
            item("salt", saltStatus, startUnchecked: true),
            item("onion", .remembered, startUnchecked: false),
        ])
    }

    @MainActor
    func testARememberedProductStaysUncheckedUntilTheUserChecksIt() throws {
        let session = CartSession(client: makeClient(keys: TestSigner.keys), cart: ClientTests.pantryCart())
        XCTAssertFalse(session.isSelected("salt"))
        XCTAssertTrue(session.isSelected("onion"))
        XCTAssertEqual(session.selections()[0], Selection(key: "salt", productId: nil, remember: false))

        try session.select(key: "salt", productId: "9")
        XCTAssertTrue(session.isSelected("salt"))
        XCTAssertEqual(session.selections()[0], Selection(key: "salt", productId: "9", quantity: 1, remember: true))
    }

    @MainActor
    func testAStartUncheckedItemIsLeftOutOfTheEstimateUntilThen() throws {
        let session = CartSession(client: makeClient(keys: TestSigner.keys), cart: ClientTests.pantryCart())
        XCTAssertEqual(session.estimate().count, 1)
        try session.select(key: "salt", productId: "9")
        XCTAssertEqual(session.estimate().count, 2)
    }

    @MainActor
    func testAStartUncheckedItemNeitherOpensNorRaisesTheRememberNote() throws {
        let client = makeClient(keys: TestSigner.keys)
        let choose = CartSession(client: client, cart: ClientTests.pantryCart(saltStatus: .choose))
        XCTAssertNil(choose.firstToOpen)
        XCTAssertFalse(choose.showsRememberNote)
        let gone = CartSession(client: client, cart: ClientTests.pantryCart(saltStatus: .rememberedUnavailable))
        XCTAssertNil(gone.firstToOpen)

        // The same cart without the mark does both.
        let plain = try makeSession(client, json: ClientTests.newCartJSON)
        XCTAssertEqual(plain.firstToOpen, "garlic")
        XCTAssertTrue(plain.showsRememberNote)
    }

    func testStartUncheckedDecodesAndIsFalseFromOlderServers() throws {
        let marked = try JSONDecoder().decode(CartItem.self, from: Data(#"{"key":"x","ingredient":"x","quantity":1,"status":"choose","startUnchecked":true}"#.utf8))
        XCTAssertTrue(marked.startUnchecked)
        let old = try JSONDecoder().decode(PreparedCart.self, from: Data(ClientTests.newCartJSON.utf8))
        XCTAssertFalse(try XCTUnwrap(old.items.first).startUnchecked)
    }

    @MainActor
    func testRecipeDetailsGoInThePrepareBodyOnlyWhenSet() async throws {
        let cart: JSONValue = try XCTUnwrap(JSONValue.parse(ClientTests.multiCartJSON))
        let client = makeClient(keys: TestSigner.keys)

        let set = Recorder()
        serveDone(cart, rec: set)
        _ = try await client.prepareCart(recipe: Recipe(id: "r1", ingredients: [
            RecipeIngredient(name: "salt", pantry: true),
            RecipeIngredient(name: "cilantro", optional: true),
        ], servings: 4, makeServings: 2, photoUrl: "https://img.test/a.jpg"))
        let recipe = try XCTUnwrap(set.body("/api/v1/sdk/carts")?["recipe"])
        XCTAssertEqual(recipe["servings"]?.doubleValue, 4)
        XCTAssertEqual(recipe["makeServings"]?.doubleValue, 2)
        XCTAssertEqual(recipe["photoUrl"], .string("https://img.test/a.jpg"))
        let ingredients = try XCTUnwrap(recipe["ingredients"]?.arrayValue)
        XCTAssertEqual(ingredients[0]["pantry"], .bool(true))
        XCTAssertNil(ingredients[0]["optional"])
        XCTAssertEqual(ingredients[1]["optional"], .bool(true))
        XCTAssertNil(ingredients[1]["pantry"])

        let unset = Recorder()
        serveDone(cart, rec: unset)
        _ = try await client.prepareCart(recipe: ClientTests.recipe("r1"))
        let plain = try XCTUnwrap(unset.body("/api/v1/sdk/carts")?["recipe"])
        for key in ["servings", "makeServings", "photoUrl"] { XCTAssertNil(plain[key], key) }
        let line = try XCTUnwrap(plain["ingredients"]?.arrayValue?.first)
        for key in ["pantry", "optional"] { XCTAssertNil(line[key], key) }
    }

    func testRecipePhotosAreHttpsOnlyAtMostThreeInOrder() {
        func recipe(_ url: String?) -> Recipe { Recipe(id: "r", ingredients: [], photoUrl: url) }
        let urls = (1...4).map { "https://img.test/\($0).jpg" }
        let photos = mealioRecipePhotos([recipe(nil), recipe("http://img.test/no.jpg"), recipe(""), recipe("data:image/png;base64,AA==")]
                                        + urls.map { recipe($0) })
        XCTAssertEqual(photos.map(\.absoluteString), Array(urls.prefix(3)))
        XCTAssertEqual(mealioRecipePhotos([]), [])
    }

    // MARK: Multi-recipe carts

    /// A cart from four recipes: ingredients they share merged into one item.
    static let multiCartJSON = #"""
    {"cartId":"c/3","store":"heb","storeName":"H-E-B",
     "recipes":[{"id":"tacos","title":"Tacos"},{"id":"pasta","title":"Pasta"},{"id":"soup","title":null},{"id":"salad","title":"Salad"}],
     "items":[
      {"key":"onion","ingredient":"onion","quantity":3,"status":"choose","selectedId":null,"remembered":null,
       "options":[{"id":"o1","name":"Onion"}],
       "recipes":[{"id":"tacos","title":"Tacos","quantity":1},{"id":"pasta","title":"Pasta","quantity":2}]},
      {"key":"garlic","ingredient":"garlic","quantity":3,"status":"choose","selectedId":null,"remembered":null,
       "options":[{"id":"g1","name":"Garlic"}],
       "recipes":[{"id":"tacos","title":"Tacos","quantity":1},{"id":"pasta","title":"Pasta","quantity":1},{"id":"salad","title":"Salad","quantity":1}]},
      {"key":"stock","ingredient":"stock","quantity":1,"status":"choose","selectedId":null,"remembered":null,
       "options":[{"id":"st1","name":"Stock"}],
       "recipes":[{"id":"soup","title":null,"quantity":1}]},
      {"key":"lime","ingredient":"lime","quantity":1,"status":"choose","selectedId":null,"remembered":null,
       "options":[{"id":"l1","name":"Lime"}],
       "recipes":[{"id":"tacos","title":"Tacos"}]}
     ]}
    """#

    private static func recipe(_ id: String, _ title: String? = nil) -> Recipe {
        Recipe(id: id, title: title, ingredients: [RecipeIngredient(name: "onion")])
    }

    @MainActor
    func testOneRecipeIsSentAsRecipeAndSeveralAsRecipes() async throws {
        let cart: JSONValue = try XCTUnwrap(JSONValue.parse(ClientTests.multiCartJSON))
        let client = makeClient(keys: TestSigner.keys)

        // One recipe, either overload: `recipe`, so older servers still understand it.
        let one = Recorder()
        serveDone(cart, rec: one)
        _ = try await client.prepareCart(recipe: ClientTests.recipe("r1", "Tacos"))
        let b1 = try XCTUnwrap(one.body("/api/v1/sdk/carts"))
        XCTAssertEqual(b1["recipe"]?["id"], .string("r1"))
        XCTAssertEqual(b1["recipe"]?["title"], .string("Tacos"))
        XCTAssertNil(b1["recipes"])

        let oneList = Recorder()
        serveDone(cart, rec: oneList)
        _ = try await client.prepareCart(recipes: [ClientTests.recipe("r1")])
        let b2 = try XCTUnwrap(oneList.body("/api/v1/sdk/carts"))
        XCTAssertEqual(b2["recipe"]?["id"], .string("r1"))
        XCTAssertNil(b2["recipes"])

        // Several: `recipes`, in order, with store and zip alongside.
        let many = Recorder()
        serveDone(cart, rec: many)
        let session = try await client.prepareCart(store: "heb", recipes: [ClientTests.recipe("r1"), ClientTests.recipe("r2")],
                                                   zip: "78701")
        let b3 = try XCTUnwrap(many.body("/api/v1/sdk/carts"))
        XCTAssertNil(b3["recipe"])
        XCTAssertEqual(b3["recipes"]?.arrayValue?.compactMap { $0["id"]?.stringValue }, ["r1", "r2"])
        XCTAssertEqual(b3["store"], .string("heb"))
        XCTAssertEqual(b3["zip"], .string("78701"))
        XCTAssertEqual(b3["sdk"]?["platform"], .string("ios"))
        XCTAssertEqual(session.recipes.map(\.id), ["tacos", "pasta", "soup", "salad"])

        // The limit itself is fine.
        let ten = Recorder()
        serveDone(cart, rec: ten)
        _ = try await client.prepareCart(recipes: (0..<MAX_RECIPES).map { ClientTests.recipe("r\($0)") })
        XCTAssertEqual(ten.body("/api/v1/sdk/carts")?["recipes"]?.arrayValue?.count, MAX_RECIPES)
    }

    @MainActor
    func testNoRecipesOrTooManyThrowBeforeAnyRequest() async throws {
        let rec = Recorder()
        StubURLProtocol.handler = { req, body in
            rec.record(req, body: body)
            return (500, Data())
        }
        let client = makeClient(keys: TestSigner.keys)
        do {
            _ = try await client.prepareCart(recipes: [])
            XCTFail("expected bad_recipe")
        } catch let e as MealioError {
            XCTAssertEqual(e.code, MealioError.Code.badRecipe)
            XCTAssertEqual(e.code, "bad_recipe")
        }
        do {
            _ = try await client.prepareCart(recipes: (0...MAX_RECIPES).map { ClientTests.recipe("r\($0)") })
            XCTFail("expected too_many_recipes")
        } catch let e as MealioError {
            XCTAssertEqual(e.code, MealioError.Code.tooManyRecipes)
            XCTAssertEqual(e.code, "too_many_recipes")
        }
        XCTAssertEqual(rec.paths, [])
        XCTAssertEqual(MAX_RECIPES, 10)
    }

    func testMultiRecipeFieldsDecode() throws {
        let cart = try JSONDecoder().decode(PreparedCart.self, from: Data(ClientTests.multiCartJSON.utf8))
        XCTAssertEqual(cart.recipes, [CartRecipe(id: "tacos", title: "Tacos"), CartRecipe(id: "pasta", title: "Pasta"),
                                      CartRecipe(id: "soup", title: nil), CartRecipe(id: "salad", title: "Salad")])
        XCTAssertEqual(cart.items[0].quantity, 3)
        XCTAssertEqual(cart.items[0].recipes, [ItemRecipe(id: "tacos", title: "Tacos", quantity: 1),
                                               ItemRecipe(id: "pasta", title: "Pasta", quantity: 2)])
        XCTAssertEqual(cart.items[2].recipes, [ItemRecipe(id: "soup", title: nil, quantity: 1)])
        // A share with no quantity counts as 1.
        XCTAssertEqual(cart.items[3].recipes?.first?.quantity, 1)
    }

    func testCartsFromOlderServersHaveNoRecipes() throws {
        let cart = try JSONDecoder().decode(PreparedCart.self, from: Data(ClientTests.newCartJSON.utf8))
        XCTAssertNil(cart.recipes)
        XCTAssertNil(cart.items[0].recipes)
        let old = try JSONDecoder().decode(PreparedCart.self, from: Data(ClientTests.cartJSON.utf8))
        XCTAssertNil(old.recipes)
        XCTAssertTrue(old.items.allSatisfy { $0.recipes == nil })
        XCTAssertNil(mealioForRecipes(cart, key: "onion"))
    }

    @MainActor
    func testSessionListsRecipesAndTheRecipesForEachItem() throws {
        let client = makeClient(keys: TestSigner.keys)
        let multi = try makeSession(client, json: ClientTests.multiCartJSON)
        XCTAssertEqual(multi.recipes.map(\.id), ["tacos", "pasta", "soup", "salad"])
        XCTAssertEqual(multi.recipes(for: "onion").map(\.id), ["tacos", "pasta"])
        XCTAssertEqual(multi.recipes(for: "onion").map(\.quantity), [1, 2])
        XCTAssertEqual(multi.recipes(for: "nope"), [])
        XCTAssertEqual(multi.recipesLabel(for: "onion"), "For Tacos and Pasta")

        let old = try makeSession(client, json: ClientTests.newCartJSON)
        XCTAssertEqual(old.recipes, [])
        XCTAssertEqual(old.recipes(for: "onion"), [])
        XCTAssertNil(old.recipesLabel(for: "onion"))
    }

    func testForRecipesLabel() throws {
        let cart = try JSONDecoder().decode(PreparedCart.self, from: Data(ClientTests.multiCartJSON.utf8))
        XCTAssertEqual(mealioForRecipes(cart, key: "onion"), "For Tacos and Pasta")
        XCTAssertEqual(mealioForRecipes(cart, key: "garlic"), "For Tacos, Pasta and Salad")
        XCTAssertEqual(mealioForRecipes(cart, key: "lime"), "For Tacos")
        // Untitled recipes are left out; with no names left there is no line.
        XCTAssertNil(mealioForRecipes(cart, key: "stock"))
        XCTAssertNil(mealioForRecipes(cart, key: "nope"))

        // A one-recipe cart never shows the line.
        let single = PreparedCart(cartId: "c", store: "heb",
                                  items: [CartItem(key: "a", ingredient: "a", status: .choose,
                                                   recipes: [ItemRecipe(id: "tacos", title: "Tacos")])],
                                  recipes: [CartRecipe(id: "tacos", title: "Tacos")])
        XCTAssertNil(mealioForRecipes(single, key: "a"))

        // Empty titles count as untitled.
        let blank = PreparedCart(cartId: "c", store: "heb",
                                 items: [CartItem(key: "a", ingredient: "a", status: .choose,
                                                  recipes: [ItemRecipe(id: "x", title: ""), ItemRecipe(id: "y", title: "Soup")])],
                                 recipes: [CartRecipe(id: "x", title: ""), CartRecipe(id: "y", title: "Soup")])
        XCTAssertEqual(mealioForRecipes(blank, key: "a"), "For Soup")

        XCTAssertEqual(mealioListAnd([]), "")
        XCTAssertEqual(mealioListAnd(["A"]), "A")
        XCTAssertEqual(mealioListAnd(["A", "B"]), "A and B")
        XCTAssertEqual(mealioListAnd(["A", "B", "C", "D"]), "A, B, C and D")
    }
}
