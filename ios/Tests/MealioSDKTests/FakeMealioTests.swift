// The testing kit, used as a partner would: plain `import MealioSDK` (no
// @testable), the real client, a scripted fake Mealio. Mirrors the
// "testing kit (item 9)" block of packages/core/test/round3.test.ts.

import Foundation
import MealioSDK
import XCTest

/// "code" or "code/reason", like the TS tests' codeOf.
@MainActor
func fakeCodeOf<T>(_ body: () async throws -> T) async -> String {
    do {
        _ = try await body()
        return "ok"
    } catch let e as MealioError {
        return e.reason.map { "\(e.code)/\($0.rawValue)" } ?? e.code
    } catch {
        return "other"
    }
}

final class FakeMealioTests: XCTestCase {

    private let recipe = Recipe(id: "r1", title: "Tacos", ingredients: [RecipeIngredient(name: "garlic")])

    private let items: JSONValue = [
        ["key": "salmon", "remembered": "f1", "weightLb": 1,
         "options": [["id": "f1", "name": "Salmon", "soldByWeight": true, "pricePerLb": 10, "estimated": true, "weightOptions": [0.5, 1, 1.5]]]],
        ["key": "garlic", "options": [["id": "g1", "name": "Garlic", "unitPrice": 0.5], ["id": "g2", "name": "Garlic 3 pack", "unitPrice": 1.5]]],
        ["key": "ham", "remembered": "h1", "rememberedPreferenceId": "sliced",
         "options": [["id": "h1", "name": "Deli ham", "unitPrice": 6, "preferences": [["id": "sliced", "label": "Sliced"]]]]],
        ["key": "salt", "remembered": "s1", "startUnchecked": true, "options": [["id": "s1", "name": "Salt", "unitPrice": 2]]],
        ["key": "herbs", "options": [["id": "x1", "name": "Herbs"]]],
        ["key": "saffron", "unavailable": "not_found"],
    ]

    private func script(_ extra: [String: JSONValue] = [:]) -> JSONValue {
        var o: [String: JSONValue] = ["items": items]
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }

    @MainActor
    private func tick() async throws {
        try await Task.sleep(nanoseconds: 30_000_000)
    }

    @MainActor
    func testLoadsWithTheTestKeyOnlyWhenAskedADefaultClientRefusesTheFakesEnvelopes() async throws {
        let fake = FakeMealio(script: script())
        XCTAssertEqual(Array(FakeMealio.testKeys.keys), ["ktest"])
        var config = fake.config()
        config.keys = MealioKeys.all
        let prod = MealioClient(config: config, host: fake.host)
        let got = await fakeCodeOf { try await prod.prepareCart(recipe: self.recipe) }
        XCTAssertEqual(got, MealioError.Code.badEnvelope)
    }

    @MainActor
    func testRememberedPicksStartUncheckedPreferencesWeightUnavailableWarnings() async throws {
        let fake = FakeMealio(script: script(["warnings": [["code": "servings_ignored", "message": "x"]]]))
        let cart = try await fake.client().prepareCart(recipe: recipe)
        XCTAssertEqual(cart.items.map { "\($0.key) \($0.status.rawValue) \($0.selectedId ?? "nil")" }, [
            "salmon remembered f1", "garlic choose nil", "ham remembered h1",
            "salt remembered s1", "herbs choose nil", "saffron unavailable nil",
        ])
        XCTAssertEqual(cart.selectedId(for: "salmon"), "f1")
        XCTAssertEqual(cart.preferenceId(for: "ham"), "sliced")
        XCTAssertFalse(cart.isSelected("salt"))
        XCTAssertEqual(cart.weight(for: "salmon"), 1)
        XCTAssertEqual(cart.warnings.map(\.code), ["servings_ignored"])
        XCTAssertEqual(cart.estimate(), CartEstimate(total: 16, count: 2, estimated: true, unpriced: 0))
    }

    @MainActor
    func testAStartUncheckedItemWithNothingRememberedHasSelectedIdNull() async throws {
        let fake = FakeMealio(script: ["items": [["key": "oil", "startUnchecked": true, "options": [["id": "o1", "name": "Oil", "unitPrice": 4]]]]])
        let cart = try await fake.client().prepareCart(recipe: recipe)
        XCTAssertTrue(cart.items[0].startUnchecked)
        XCTAssertNil(cart.items[0].selectedId)
        XCTAssertEqual(cart.items[0].status, .choose)
        XCTAssertNil(cart.selectedId(for: "oil"))
    }

    @MainActor
    func testTotalIsNullWhileAnyTickedItemHasNoPriceAndTheAddReportsWhatTheStoreTook() async throws {
        let fake = FakeMealio(script: script())
        let cart = try await fake.client().prepareCart(recipe: recipe)
        try cart.select(key: "herbs", productId: "x1")
        XCTAssertNil(cart.estimate().total)
        XCTAssertEqual(cart.estimate().unpriced, 1)
        cart.deselect(key: "herbs")
        let r = try await cart.addToCart()
        XCTAssertEqual(r.added.map(\.key), ["salmon", "ham"])
        XCTAssertEqual(cart.addedTotal(r).total, 16)
    }

    @MainActor
    func testCancelOnUnmountAHeldPrepareFailsAsCancelledClosedAndSendsNothingMore() async throws {
        let fake = FakeMealio(script: script())
        let release = fake.hold(.prepare)
        let unmount = CancelToken()
        let client = fake.client()
        let recipe = self.recipe
        let p = Task { () -> String in
            await fakeCodeOf { try await client.prepareCart(recipe: recipe, cancel: unmount) }
        }
        try await tick()
        unmount.cancel(reason: .closed)
        release()
        let got = await p.value
        XCTAssertEqual(got, "cancelled/closed")
        XCTAssertEqual(fake.requests.filter { $0.kind == .step }, [])
        XCTAssertEqual(fake.hostCalls, [])
    }

    @MainActor
    func testUserSwitchTheOldPrepareEndsUserChangedTheNextOneUsesTheNewSession() async throws {
        var user = "u1"
        let fake = FakeMealio(script: script())
        let client = fake.client(token: { "tok_\(user)" })
        client.setUser("u1")
        let release = fake.hold(.prepare)
        let recipe = self.recipe
        let p = Task { () -> String in
            await fakeCodeOf { try await client.prepareCart(recipe: recipe) }
        }
        try await tick()
        user = "u2"
        client.setUser("u2")
        release()
        let got = await p.value
        XCTAssertEqual(got, "cancelled/user_changed")
        _ = try await client.prepareCart(recipe: recipe)
        XCTAssertEqual(fake.requests.filter { $0.kind == .prepare }.map(\.token), ["tok_u1", "tok_u2"])
    }

    @MainActor
    func testSignInRequiredErrorsByCodeStorePreferences() async throws {
        let fake = FakeMealio(script: script(["signIn": "signed_in"]))
        let client = fake.client()
        _ = try await client.prepareCart(recipe: recipe)
        XCTAssertTrue(fake.hostCalls.contains("login"))
        fake.set("signIn", "cancelled")
        let cancelled = await fakeCodeOf { try await client.prepareCart(recipe: self.recipe) }
        XCTAssertEqual(cancelled, MealioError.Code.loginCancelled)
        fake.set("signIn", nil)
        fake.set("errors", ["prepare": ["code": "location_required", "status": 400]])
        let location = await fakeCodeOf { try await client.prepareCart(store: "kroger", recipe: self.recipe) }
        XCTAssertEqual(location, MealioError.Code.locationRequired)
        fake.set("errors", [:])
        let set = try await client.setStore("safeway")
        XCTAssertEqual(set.defaultStore, "safeway")
        let prefs = try await client.storePreferences()
        XCTAssertEqual(prefs.defaultStore, "safeway")
        fake.set("errors", ["session": "boom"])
        let session = await fakeCodeOf { try await fake.client().prepareCart(recipe: self.recipe) }
        XCTAssertEqual(session, MealioError.Code.sessionFailed)
    }

    @MainActor
    func testAKrogerFamilyCartSignsInThroughKrogerWithNoPageOfItsOwn() async throws {
        let fake = FakeMealio(script: script(["store": "kroger", "signIn": "signed_in"]))
        let cart = try await fake.client().prepareCart(recipe: recipe)
        XCTAssertEqual(cart.store, "kroger")
        XCTAssertEqual(fake.hostCalls, ["login"])
    }

    @MainActor
    func testRestorePicksSearchesAgainOnTheNewCartAndSendsOnlyWhatThatCartOffered() async throws {
        let garlic: JSONValue = ["key": "garlic", "remembered": "g1", "options": [["id": "g1", "name": "Garlic bulb", "unitPrice": 0.5]]]
        let fake = FakeMealio(script: ["items": [garlic], "search": ["minced garlic": [["id": "jar9", "name": "Minced garlic jar", "unitPrice": 3]]],
                                       "add": ["fail": "store_unavailable"]])
        let client = fake.client()
        let a = try await client.prepareCart(recipe: recipe)
        _ = try await a.search(key: "garlic", query: "minced garlic")
        try a.select(key: "garlic", productId: "jar9")
        a.setQuantity(key: "garlic", to: 2)
        let failed = await fakeCodeOf { try await a.addToCart() }
        XCTAssertEqual(failed, "store_unavailable")
        fake.set("add", nil)
        let b = try await client.prepareCart(recipe: recipe)
        await b.restorePicks(from: a)
        XCTAssertEqual(fake.requests.filter { $0.kind == .search }.map(\.path),
                       ["/api/v1/sdk/carts/\(a.cartId)/search", "/api/v1/sdk/carts/\(b.cartId)/search"])
        XCTAssertEqual(b.selections(), [Selection(key: "garlic", productId: "jar9", quantity: 2, remember: true, preferenceId: nil)])
        let r = try await b.addToCart()
        XCTAssertTrue(r.failed.isEmpty)
        XCTAssertEqual(r.added.map { "\($0.productId) \($0.quantity)" }, ["jar9 2"])
    }

    @MainActor
    func testKeepsTheNewCartsOwnPickWhenTheSearchDoesNotBringTheProductBack() async throws {
        let garlic: JSONValue = ["key": "garlic", "remembered": "g1", "options": [["id": "g1", "name": "Garlic bulb", "unitPrice": 0.5]]]
        let fake = FakeMealio(script: ["items": [garlic], "search": ["minced garlic": [["id": "jar9", "name": "Minced garlic jar", "unitPrice": 3]]]])
        let client = fake.client()
        let a = try await client.prepareCart(recipe: recipe)
        _ = try await a.search(key: "garlic", query: "minced garlic")
        try a.select(key: "garlic", productId: "jar9")
        fake.set("search", [:])
        let b = try await client.prepareCart(recipe: recipe)
        await b.restorePicks(from: a)
        XCTAssertEqual(b.selectedId(for: "garlic"), "g1")
        XCTAssertEqual(b.options(for: "garlic").map(\.id), ["g1"])
        let offered = Set(fake.offered(b.cartId).map(\.id))
        for s in b.selections() { if let id = s.productId { XCTAssertTrue(offered.contains(id)) } }
    }

    func testAScriptCanBeSharedJSONText() throws {
        let fake = try FakeMealio(json: #"{"store":"heb","items":[{"key":"k","remembered":"p","options":[{"id":"p","name":"P"}]}]}"#)
        XCTAssertEqual(fake.script["store"], "heb")
    }

    // MARK: round 4: one shared script, holds that block no thread

    /// protocol/fake-script.json: every platform's kit loads each case's
    /// script with its JSON loader and runs the same steps.
    @MainActor
    func testRunsEveryCaseOfTheSharedFakeScript() async throws {
        let file = try XCTUnwrap(JSONValue.parse(try Fixtures.data("fake-script", "json")))
        let recipe = try XCTUnwrap(file["recipe"]).decode(Recipe.self)
        let cases = try XCTUnwrap(file["cases"]?.arrayValue)
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let name = c["name"]?.stringValue ?? "?"
            let text = try XCTUnwrap(String(data: try JSONEncoder().encode(try XCTUnwrap(c["script"])), encoding: .utf8))
            let fake = try FakeMealio(json: text)
            let client = fake.client()
            var carts: [String: CartSession] = [:]
            for (n, step) in (c["steps"]?.arrayValue ?? []).enumerated() {
                let what = step["do"]?.stringValue ?? ""
                let at = "\(name) step \(n) \(what)"
                let expect = step["expect"]
                let wantError = expect?["error"]?.stringValue
                let named = step["cart"]?.stringValue ?? "a"
                let key = step["key"]?.stringValue ?? ""
                var failure: String?
                do {
                    switch what {
                    case "prepare":
                        let cart = try await client.prepareCart(recipe: recipe)
                        carts[named] = cart
                        if let e = expect { checkCart(cart, e, at) }
                    case "search":
                        let cart = try XCTUnwrap(carts[named], at)
                        let found = try await cart.search(key: key, query: step["query"]?.stringValue ?? "")
                        if let ids = expect?["options"]?.arrayValue {
                            XCTAssertEqual(found.map(\.id), ids.compactMap(\.stringValue), at)
                        }
                    case "select":
                        let cart = try XCTUnwrap(carts[named], at)
                        try cart.select(key: key, productId: step["productId"]?.stringValue ?? "")
                        if let id = expect?["selectedId"] { XCTAssertEqual(cart.selectedId(for: key), id.stringValue, at) }
                    case "add":
                        let cart = try XCTUnwrap(carts[named], at)
                        let r = try await cart.addToCart()
                        if let e = expect, wantError == nil {
                            XCTAssertEqual(r.added.map(\.key), keys(e["added"]), at)
                            XCTAssertEqual(r.skipped.map(\.key), keys(e["skipped"]), at)
                            XCTAssertEqual(r.failed.map(\.key), keys(e["failed"]), at)
                            if let want = e["addedTotal"]?.doubleValue {
                                let got = try XCTUnwrap(cart.addedTotal(r).total, at)
                                XCTAssertEqual((got * 100).rounded(), (want * 100).rounded(), at)
                            }
                        }
                    case "restorePicks":
                        let cart = try XCTUnwrap(carts[named], at)
                        let from = try XCTUnwrap(carts[step["from"]?.stringValue ?? ""], at)
                        await cart.restorePicks(from: from)
                        if let e = expect { checkCart(cart, e, at) }
                    case "setScript":
                        for (k, v) in step["set"]?.objectValue ?? [:] { fake.set(k, v == .null ? nil : v) }
                    case "requests":
                        XCTAssertEqual(fake.requests.map(\.kind.rawValue), keys(expect), at)
                    case "searches":
                        let queries = fake.requests.filter { $0.kind == .search }.compactMap { $0.body?["query"]?.stringValue }
                        XCTAssertEqual(queries, keys(expect), at)
                    default:
                        XCTFail("\(at): unknown step")
                    }
                } catch let e as MealioError {
                    failure = e.code
                }
                XCTAssertEqual(failure, wantError, at)
            }
        }
    }

    private func keys(_ v: JSONValue?) -> [String] {
        (v?.arrayValue ?? []).compactMap(\.stringValue)
    }

    /// The parts of a cart a script step names: store, storeName, recipes, items.
    @MainActor
    private func checkCart(_ cart: CartSession, _ e: JSONValue, _ at: String) {
        if let v = e["store"] { XCTAssertEqual(cart.store, v.stringValue, at) }
        if let v = e["storeName"] { XCTAssertEqual(cart.storeName, v.stringValue, at) }
        if let v = e["recipes"]?.arrayValue {
            XCTAssertEqual(cart.recipes, v.map { CartRecipe(id: $0["id"]?.stringValue ?? "", title: $0["title"]?.stringValue) }, at)
        }
        for (key, want) in e["items"]?.objectValue ?? [:] {
            let item = cart.items.first { $0.key == key }
            XCTAssertNotNil(item, "\(at): no item \(key)")
            if let v = want["status"] { XCTAssertEqual(item?.status.rawValue, v.stringValue, "\(at) \(key)") }
            if let v = want["selectedId"] { XCTAssertEqual(cart.selectedId(for: key), v.stringValue, "\(at) \(key)") }
            if let v = want["quantity"]?.intValue { XCTAssertEqual(cart.quantity(for: key), v, "\(at) \(key)") }
        }
    }

    func testCoversEveryStepKindTheOtherPlatformsMustInterpret() throws {
        let file = try XCTUnwrap(JSONValue.parse(try Fixtures.data("fake-script", "json")))
        let kinds = Set((file["cases"]?.arrayValue ?? []).flatMap { ($0["steps"]?.arrayValue ?? []).compactMap { $0["do"]?.stringValue } })
        XCTAssertEqual(kinds.sorted(), ["add", "prepare", "requests", "restorePicks", "search", "searches", "select", "setScript"])
    }

    // MARK: restorePicks (round 4; packages/core/test/round4.test.ts)

    private let r4Recipe = Recipe(id: "r1", title: "T", ingredients: [RecipeIngredient(name: "garlic"), RecipeIngredient(name: "milk")])
    private let r4Garlic: JSONValue = ["key": "garlic", "options": [["id": "g1", "name": "Garlic", "unitPrice": 0.5]], "remembered": "g1"]
    private let r4Milk: JSONValue = ["key": "milk", "options": [["id": "m1", "name": "Milk", "unitPrice": 3]], "remembered": "m1"]

    private func searchQueries(_ fake: FakeMealio) -> [String] {
        fake.requests.filter { $0.kind == .search }.compactMap { $0.body?["query"]?.stringValue }
    }

    @MainActor
    func testReRunsTheSearchThatFoundThePickNotTheItemsLastSearch() async throws {
        let fake = FakeMealio(script: ["items": [r4Garlic, r4Milk],
                                       "search": ["minced": [["id": "jar", "name": "Jar", "unitPrice": 3]], "peeled": [["id": "pl", "name": "Peeled"]]],
                                       "add": ["fail": "store_unavailable"]])
        let c = fake.client()
        let a = try await c.prepareCart(recipe: r4Recipe)
        _ = try await a.search(key: "garlic", query: "minced")
        try a.select(key: "garlic", productId: "jar")
        _ = try await a.search(key: "garlic", query: "peeled") // looked again, kept the jar
        let failed = await fakeCodeOf { try await a.addToCart() }
        XCTAssertEqual(failed, "store_unavailable")
        fake.set("add", nil)
        let b = try await c.prepareCart(recipe: r4Recipe)
        await b.restorePicks(from: a)
        XCTAssertEqual(b.selectedId(for: "garlic"), "jar")
        XCTAssertEqual(searchQueries(fake), ["minced", "peeled", "minced"])
    }

    @MainActor
    func testAPickFromALaterSearchIsReRunWithThatLaterQuery() async throws {
        let fake = FakeMealio(script: ["items": [r4Garlic],
                                       "search": ["minced": [["id": "jar", "name": "Jar"]], "peeled": [["id": "pl", "name": "Peeled"]]]])
        let c = fake.client()
        let a = try await c.prepareCart(recipe: r4Recipe)
        _ = try await a.search(key: "garlic", query: "minced")
        _ = try await a.search(key: "garlic", query: "peeled")
        try a.select(key: "garlic", productId: "pl")
        let b = try await c.prepareCart(recipe: r4Recipe)
        await b.restorePicks(from: a)
        XCTAssertEqual(b.selectedId(for: "garlic"), "pl")
        XCTAssertEqual(searchQueries(fake), ["minced", "peeled", "peeled"])
    }

    @MainActor
    func testAnOutsideCancelMidSearchEndsKeepsWhatItHadAndTheCallersTokenSaysCancelled() async throws {
        let fake = FakeMealio(script: ["items": [r4Garlic, r4Milk], "search": ["minced": [["id": "jar", "name": "Jar"]]]])
        let c = fake.client()
        let a = try await c.prepareCart(recipe: r4Recipe)
        _ = try await a.search(key: "garlic", query: "minced")
        try a.select(key: "garlic", productId: "jar")
        a.deselect(key: "milk")
        let b = try await c.prepareCart(recipe: r4Recipe)
        let release = fake.hold(.search)
        let tok = CancelToken()
        let restoring = Task { await b.restorePicks(from: a, cancel: tok) }
        try await tick()
        c.cancelJobs()
        // This client does not abort a request in flight: let the held one answer.
        release()
        await restoring.value
        XCTAssertTrue(tok.cancelled)
        XCTAssertEqual(tok.reason, .cancelled)
        XCTAssertEqual(b.selectedId(for: "garlic"), "g1") // the cart's own pick stays
        XCTAssertFalse(b.isSelected("milk")) // what was done before the search stays done
    }

    @MainActor
    func testNeverThrowsAFailingSearchAnotherStoreOrAnItemTheNewCartLacks() async throws {
        let fake = FakeMealio(script: ["items": [r4Garlic, r4Milk], "search": ["minced": [["id": "jar", "name": "Jar"]]]])
        let c = fake.client()
        let a = try await c.prepareCart(recipe: r4Recipe)
        _ = try await a.search(key: "garlic", query: "minced")
        try a.select(key: "garlic", productId: "jar")
        fake.set("errors", ["search": "store_unavailable"])
        let b = try await c.prepareCart(recipe: r4Recipe)
        await b.restorePicks(from: a)
        XCTAssertEqual(b.selectedId(for: "garlic"), "g1")
        fake.set("items", [r4Milk])
        let d = try await c.prepareCart(recipe: r4Recipe)
        await d.restorePicks(from: a)
        XCTAssertEqual(d.selectedId(for: "milk"), "m1")
        let other = try await c.prepareCart(store: "safeway", recipe: r4Recipe)
        await other.restorePicks(from: a)
        XCTAssertEqual(other.store, "safeway")
    }

    /// A held request waits without blocking a thread: the same session
    /// answers another call meanwhile. Releasing twice does nothing.
    @MainActor
    func testAHoldBlocksNoThreadTheSameSessionAnswersOtherCallsMeanwhile() async throws {
        let fake = FakeMealio(script: script())
        let release = fake.hold(.search)
        let base = fake.baseURL.absoluteString
        var search = URLRequest(url: try XCTUnwrap(URL(string: base + "/api/v1/sdk/carts/c1/search")))
        search.httpMethod = "POST"
        search.httpBody = Data(#"{"key":"garlic","query":"jar"}"#.utf8)
        let session = fake.urlSession
        let request = search
        let held = Task { () -> Int in
            let (_, r) = try await session.data(for: request)
            return (r as? HTTPURLResponse)?.statusCode ?? 0
        }
        try await tick()
        let (data, r) = try await session.data(from: try XCTUnwrap(URL(string: base + "/api/v1/stores")))
        XCTAssertEqual((r as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertNotNil(JSONValue.parse(data)?["stores"])
        XCTAssertEqual(fake.requests.map(\.kind), [.search, .stores])
        release()
        release()
        let status = try await held.value
        XCTAssertEqual(status, 200)
    }

    /// When the fake goes away, a held request is let go (it fails) instead of
    /// waiting for ever.
    @MainActor
    func testDroppingTheFakeReleasesItsHolds() async throws {
        var fake: FakeMealio? = FakeMealio(script: script())
        _ = fake?.hold(.prepare)
        let client = try XCTUnwrap(fake).client()
        let recipe = self.recipe
        let p = Task { await fakeCodeOf { try await client.prepareCart(recipe: recipe) } }
        try await tick()
        XCTAssertEqual(fake?.requests.map(\.kind), [.prepare])
        fake = nil
        let got = await p.value
        XCTAssertNotEqual(got, "ok")
    }

    // MARK: round 5

    /// A cancel while a Mealio request is in flight aborts it at once and
    /// reports cancelled, instead of waiting for the answer (or its timeout).
    @MainActor
    func testCancelAbortsAnInFlightMealioRequestAndReportsCancelled() async throws {
        let fake = FakeMealio(script: script())
        let release = fake.hold(.prepare)
        defer { release() }
        let client = fake.client()
        let cancel = CancelToken()
        let recipe = self.recipe
        let p = Task { () -> String in
            await fakeCodeOf { try await client.prepareCart(recipe: recipe, cancel: cancel) }
        }
        try await tick()
        XCTAssertEqual(fake.requests.map(\.kind), [.prepare])
        let start = Date()
        cancel.cancel()
        let got = await p.value
        XCTAssertEqual(got, "cancelled/cancelled")
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertEqual(fake.hostCalls, [])
    }

    /// An add takes its place in line when it is called, then fetches its
    /// session token: a search called while that token is on its way runs
    /// after the add, not before it.
    @MainActor
    func testAnAddJoinsTheQueueBeforeFetchingItsToken() async throws {
        let fake = FakeMealio(script: script())
        let gate = AsyncGate()
        var slow = false
        let client = fake.client(token: { () async throws -> String in
            if slow {
                slow = false
                await gate.wait()
            }
            return "tok"
        })
        let cart = try await client.prepareCart(recipe: recipe)
        let cartId = cart.cartId
        let selections = cart.selections()
        // The next token fetch (the add's) is held until the gate opens.
        client.resetSession()
        slow = true
        let add = Task { await fakeCodeOf { try await client.addToCart(cartId: cartId, selections: selections) } }
        try await tick()
        let search = Task { await fakeCodeOf { try await client.search(cartId: cartId, key: "garlic", query: "jar") } }
        try await tick()
        XCTAssertEqual(fake.requests.filter { $0.kind == .add || $0.kind == .search }.map(\.kind), [])
        gate.open()
        let added = await add.value
        let searched = await search.value
        XCTAssertEqual(added, "ok")
        XCTAssertEqual(searched, "ok")
        XCTAssertEqual(fake.requests.filter { $0.kind == .add || $0.kind == .search }.map(\.kind), [.add, .search])
    }
}

/// Opens once; every wait before that resumes then, every wait after at once.
@MainActor
final class AsyncGate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in waiting.append(k) }
    }

    func open() {
        isOpen = true
        let list = waiting
        waiting = []
        for k in list { k.resume() }
    }
}
