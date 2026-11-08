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
}
