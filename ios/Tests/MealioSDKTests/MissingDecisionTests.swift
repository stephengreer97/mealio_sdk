// A missing item needs a decision (2026-11-24). An item missing from the add
// (a usual out of stock or gone, an item never chosen, one the store does not
// have) must be picked or deselected before the drop-in adds, so nobody finds
// an ingredient missing at pickup they never chose to leave out.
// Mirrors packages/core/test/missing-decision.test.ts. The CartSession tests
// are platform-neutral; the row tests need SwiftUI on iOS.

import XCTest
@testable import MealioSDK

final class MissingDecisionTests: XCTestCase {

    static let preparedJSON = #"""
    {"cartId":"c","store":"heb",
     "items":[
      {"key":"onion","ingredient":"onion","quantity":1,"status":"remembered","selectedId":"onion-1",
       "remembered":{"id":"onion-1","name":"onion one"},"options":[{"id":"onion-1","name":"onion one"}]},
      {"key":"spinach","ingredient":"spinach","quantity":1,"status":"remembered_unavailable","selectedId":null,
       "remembered":{"id":"spinach-0","name":"Baby spinach"},"reason":"out_of_stock",
       "options":[{"id":"spinach-1","name":"spinach one"}]},
      {"key":"garlic","ingredient":"garlic","quantity":1,"status":"choose","selectedId":null,"remembered":null,
       "options":[{"id":"garlic-1","name":"garlic one"}]},
      {"key":"saffron","ingredient":"saffron","quantity":1,"status":"unavailable","selectedId":null,"remembered":null,
       "options":[]},
      {"key":"salt","ingredient":"salt","quantity":1,"status":"choose","selectedId":null,"remembered":null,
       "startUnchecked":true,"options":[{"id":"salt-1","name":"salt one"}]}
     ],
     "ready":[],"needsChoice":[],"unavailable":[]}
    """#

    @MainActor
    static func makeClient() -> MealioClient {
        let config = MealioClientConfig(publishableKey: "pk_test", sessionTokenProvider: { "tok" },
                                        baseURL: URL(string: "https://mealio.test/")!,
                                        epochProvider: { 0 }, keys: TestSigner.keys,
                                        urlSession: StubURLProtocol.session(), sdkVersion: "0")
        return MealioClient(config: config, host: FakeHost())
    }

    /// Pepper: a pantry item with a usual, so it starts unchecked though remembered.
    static let pepperJSON = #"""
    ,{"key":"pepper","ingredient":"pepper","quantity":1,"status":"remembered","selectedId":"pepper-1",
      "startUnchecked":true,"remembered":{"id":"pepper-1","name":"pepper one"},
      "options":[{"id":"pepper-1","name":"pepper one"}]}
    """#

    @MainActor
    static func prepared(cartId: String = "c", withPepper: Bool = false) throws -> CartSession {
        var json = preparedJSON.replacingOccurrences(of: #""cartId":"c""#, with: #""cartId":"\#(cartId)""#)
        if withPepper {
            json = json.replacingOccurrences(of: #""name":"salt one"}]}"#, with: #""name":"salt one"}]}"# + pepperJSON)
        }
        let cart = try JSONDecoder().decode(PreparedCart.self, from: Data(json.utf8))
        return CartSession(client: makeClient(), cart: cart)
    }

    @MainActor
    func testWaitsOnEveryUnpickedItemExceptARememberedOneAndAStartUncheckedOne() throws {
        let cs = try Self.prepared()
        XCTAssertEqual(cs.undecided(), ["spinach", "garlic", "saffron"])
        XCTAssertFalse(cs.needsDecision("onion"))
        XCTAssertFalse(cs.needsDecision("salt"))
        XCTAssertFalse(cs.needsDecision("nope"))
    }

    @MainActor
    func testDeselectSettlesAnItemAndUndoDeselectBringsItBack() throws {
        let cs = try Self.prepared()
        cs.deselect(key: "spinach")
        XCTAssertTrue(cs.isDeselected("spinach"))
        XCTAssertEqual(cs.undecided(), ["garlic", "saffron"])
        cs.undoDeselect(key: "spinach")
        XCTAssertFalse(cs.isDeselected("spinach"))
        XCTAssertEqual(cs.undecided(), ["spinach", "garlic", "saffron"])
    }

    @MainActor
    func testAPickSettlesAnItemAndClearsADeselect() throws {
        let cs = try Self.prepared()
        cs.deselect(key: "garlic")
        try cs.select(key: "garlic", productId: "garlic-1")
        XCTAssertFalse(cs.isDeselected("garlic"))
        XCTAssertFalse(cs.needsDecision("garlic"))
    }

    @MainActor
    func testUntickingAPickIsADecisionTooAndSendsNothingForTheItem() throws {
        let cs = try Self.prepared()
        try cs.select(key: "garlic", productId: "garlic-1")
        cs.deselect(key: "garlic")
        XCTAssertFalse(cs.needsDecision("garlic"))
        XCTAssertNil(try XCTUnwrap(cs.selections().first { $0.key == "garlic" }).productId)
    }

    @MainActor
    func testRestorePicksCarriesADeselectOverAndNothingTheUserDidNotDecide() async throws {
        let from = try Self.prepared()
        from.deselect(key: "spinach")
        let to = try Self.prepared(cartId: "c2")
        await to.restorePicks(from: from)
        XCTAssertTrue(to.isDeselected("spinach"))
        XCTAssertEqual(to.undecided(), ["garlic", "saffron"])
    }

    // items left off by default
    @MainActor
    func testListsStartUncheckedItemsNotSelectedInOrderAndDropsOneOnceSelected() throws {
        let cs = try Self.prepared(withPepper: true)
        XCTAssertEqual(cs.uncheckedByDefault(), ["salt", "pepper"])
        try cs.select(key: "pepper", productId: "pepper-1")
        XCTAssertEqual(cs.uncheckedByDefault(), ["salt"])
    }
}

#if canImport(SwiftUI) && canImport(UIKit) && canImport(WebKit)
final class MissingDecisionRowTests: XCTestCase {

    private final class Log { var events: [MealioEvent] = [] }

    @MainActor
    private func row(_ cs: CartSession, _ key: String, isOpen: Bool = false,
                     onOpen: @escaping () -> Void = {}) throws -> MealioItemRow {
        let item = try XCTUnwrap(cs.items.first { $0.key == key })
        return MealioItemRow(cart: cs, item: item, t: .default, storeName: "H-E-B", isOpen: isOpen,
                             disabled: false, onToggleOpen: onOpen)
    }

    @MainActor
    func testSkipThisTimeIsAnUncheckAndUndoBringsTheItemBack() throws {
        let log = Log()
        MealioCart.onEvent = { log.events.append($0) }
        defer { MealioCart.onEvent = nil }
        let cs = try MissingDecisionTests.prepared()

        try row(cs, "garlic").skip()
        XCTAssertEqual(log.events, [.itemUnchecked(key: "garlic")])
        XCTAssertTrue(try row(cs, "garlic").isSkipped)
        XCTAssertEqual(try row(cs, "garlic").meta(on: false, picked: nil, options: cs.options(for: "garlic")),
                       "Skipped this time")
        XCTAssertEqual(cs.undecided(), ["spinach", "saffron"])

        try row(cs, "garlic").undoSkip()
        XCTAssertFalse(try row(cs, "garlic").isSkipped)
        XCTAssertEqual(cs.undecided(), ["spinach", "garlic", "saffron"])
        // Undo is not a check: nothing more is reported.
        XCTAssertEqual(log.events, [.itemUnchecked(key: "garlic")])
    }

    @MainActor
    func testAUsualUntickedIsNotSkippedAndAPantryItemIsNeither() throws {
        let cs = try MissingDecisionTests.prepared()
        cs.deselect(key: "onion")
        XCTAssertFalse(try row(cs, "onion").isSkipped)
        XCTAssertEqual(try row(cs, "onion").meta(on: false, picked: nil, options: cs.options(for: "onion")),
                       "Not adding this time")
        cs.deselect(key: "salt")
        XCTAssertFalse(try row(cs, "salt").isSkipped)
        XCTAssertEqual(cs.undecided(), ["spinach", "garlic", "saffron"])
    }

    @MainActor
    func testAddThemChecksTheItemsLeftOffByDefaultThatHaveAUsual() throws {
        let log = Log()
        MealioCart.onEvent = { log.events.append($0) }
        defer { MealioCart.onEvent = nil }
        let cs = try MissingDecisionTests.prepared(withPepper: true)
        let list = MealioCartList(cart: cs, onAdd: {})
        XCTAssertEqual(list.offByDefault.map(\.key), ["salt", "pepper"])

        list.addOffByDefault()
        XCTAssertEqual(log.events, [.itemChecked(key: "pepper")])
        XCTAssertEqual(cs.selectedId(for: "pepper"), "pepper-1")
        // Salt has no usual, so it is still named until the user picks one.
        XCTAssertEqual(list.offByDefault.map(\.key), ["salt"])

        // Busy: nothing changes.
        cs.deselect(key: "pepper")
        MealioCartList(cart: cs, busy: true, onAdd: {}).addOffByDefault()
        XCTAssertFalse(cs.isSelected("pepper"))
    }

    @MainActor
    func testNothingIsLeftOffByDefaultWithoutAPantryItem() throws {
        let cart = try JSONDecoder().decode(PreparedCart.self, from: Data(ClientTests.newCartJSON.utf8))
        let cs = CartSession(client: MissingDecisionTests.makeClient(), cart: cart)
        XCTAssertTrue(MealioCartList(cart: cs, onAdd: {}).offByDefault.isEmpty)
    }

    @MainActor
    func testAnItemTheStoreDoesNotHaveCanBeSkipped() throws {
        let cs = try MissingDecisionTests.prepared()
        try row(cs, "saffron").skip()
        XCTAssertTrue(try row(cs, "saffron").isSkipped)
        XCTAssertFalse(cs.needsDecision("saffron"))
    }
}
#endif
