// The word table against protocol/strings.json, and the helpers that fill it.
// Platform-neutral: runs with `swift test`.

import XCTest
@testable import MealioSDK

final class StringsTests: XCTestCase {

    func testTableMatchesProtocolStrings() throws {
        let shared = try Fixtures.strings()
        XCTAssertGreaterThan(shared.count, 90)
        XCTAssertEqual(Set(MealioStringKey.allCases.map(\.rawValue)), Set(shared.keys))
        XCTAssertEqual(DEFAULT_STRINGS.count, shared.count)
        for key in MealioStringKey.allCases {
            let want = try XCTUnwrap(shared[key.rawValue]?.stringValue, key.rawValue)
            XCTAssertEqual(DEFAULT_STRINGS[key], want, key.rawValue)
        }
    }

    func testEveryPluralTheDropInAsksForHasBothForms() {
        for base in ["stepFinding", "pendingOptions", "addItems", "options", "itemsAdded"] {
            XCTAssertNotNil(MealioStringKey(rawValue: "\(base)_one"), base)
            XCTAssertNotNil(MealioStringKey(rawValue: "\(base)_other"), base)
        }
    }

    func testFillLeavesAnUnknownPlaceholderVisible() {
        XCTAssertEqual(mealioFillText("Add {item} to {store}", ["item": "milk"]), "Add milk to {store}")
        XCTAssertEqual(mealioFillText("{} { x} {{store}}", ["store": "H-E-B"]), "{} { x} {H-E-B}")
        XCTAssertEqual(mealioFillText("no braces"), "no braces")
        XCTAssertEqual(mealioFillText("open {store", ["store": "x"]), "open {store")
    }

    func testFillIsOnePass() {
        // A recipe or a search can hold braces, and a price can hold a dollar sign.
        XCTAssertEqual(mealioFillText("{a} {b}", ["a": "{b}", "b": "$1"]), "{b} $1")
    }

    func testOverridesLayOverTheTable() {
        let ui = MealioText(strings: [.done: "Fertig", .titleList: "Liste {store}"])
        XCTAssertEqual(ui.tr(.done), "Fertig")
        XCTAssertEqual(ui.tr(.titleList, ["store": "ALDI"]), "Liste ALDI")
        XCTAssertEqual(ui.tr(.close), "Close")
    }

    func testPlural() {
        let ui = MealioText()
        XCTAssertEqual(ui.plural("addItems", 1, ["store": "ALDI"]), "Add 1 item to ALDI")
        XCTAssertEqual(ui.plural("addItems", 3, ["store": "ALDI"]), "Add 3 items to ALDI")
        XCTAssertEqual(ui.plural("addItems", 0, ["store": "ALDI"]), "Add 0 items to ALDI")
        XCTAssertEqual(ui.plural("stepFinding", 1), "Finding your 1 ingredient")
        XCTAssertEqual(ui.plural("nope", 2), "nope_other")
    }

    func testLists() {
        let ui = MealioText(strings: [.and: "y", .or: "o"])
        XCTAssertEqual(ui.listAnd(["A", "B", "C"]), "A, B y C")
        XCTAssertEqual(ui.listOr(["A", "B"]), "A o B")
        XCTAssertEqual(ui.listOr(["A"]), "A")
        XCTAssertEqual(ui.listOr([]), "")
    }

    func testRecipesLabelTakesThePartnersWords() throws {
        let cart = try JSONDecoder().decode(PreparedCart.self, from: Data(ClientTests.multiCartJSON.utf8))
        let ui = MealioText(strings: [.forRecipes: "Para {recipes}", .and: "y"])
        XCTAssertEqual(mealioForRecipes(cart, key: "onion", text: ui), "Para Tacos y Pasta")
        XCTAssertEqual(mealioForRecipes(cart, key: "onion"), "For Tacos and Pasta")
    }

    func testDefaultMoney() {
        let ui = MealioText()
        XCTAssertFalse(ui.customMoney)
        XCTAssertEqual(ui.money(12.5), "$12.50")
        XCTAssertEqual(ui.amount(31.2, estimated: true), "about $31.20")
        XCTAssertEqual(ui.amount(31.2, estimated: false), "$31.20")
    }

    func testPriceUsesTheStoresTextByDefault() {
        let ui = MealioText()
        XCTAssertEqual(ui.price(Product(id: "a", name: "A", price: "2 for $5", unitPrice: 2.5)), "2 for $5")
        XCTAssertEqual(ui.price(Product(id: "a", name: "A", price: "$3.00", estimated: true)), "$3.00 est.")
        XCTAssertEqual(ui.price(Product(id: "a", name: "A", estimated: true)), "")
    }

    func testFormatMoneyBuildsPricesFromNumbers() {
        let ui = MealioText(formatMoney: { String(format: "%.2f EUR", $0) })
        XCTAssertTrue(ui.customMoney)
        XCTAssertEqual(ui.price(Product(id: "a", name: "A", price: "$2.50", unitPrice: 2.5)), "2.50 EUR")
        XCTAssertEqual(ui.price(Product(id: "a", name: "A", price: "$3", unitPrice: 3, estimated: true)), "3.00 EUR est.")
        // No number to format: the store's text is all there is.
        XCTAssertEqual(ui.price(Product(id: "a", name: "A", price: "$3.00")), "$3.00")
        XCTAssertEqual(ui.amount(4, estimated: true), "about 4.00 EUR")
    }

    func testSoldByWeightPrice() {
        let p = Product(id: "a", name: "A", price: "$9.99", unitPrice: 5, estimated: true,
                        soldByWeight: true, pricePerLb: 9.99)
        XCTAssertEqual(MealioText().price(p), "$9.99/lb est.")
        XCTAssertEqual(MealioText(formatMoney: { "\($0) EUR" }).price(p), "9.99 EUR/lb est.")
    }

    func testReasons() {
        let ui = MealioText()
        XCTAssertEqual(ui.reason("not_confirmed"), "not confirmed in your cart")
        XCTAssertEqual(ui.reason("weight_not_supported"), "sold by weight, which this store cannot take here")
        XCTAssertEqual(ui.reason("out_of_stock"), "out of stock")
        XCTAssertEqual(ui.reason("add_timeout"), "the store did not answer")
        XCTAssertEqual(ui.reason("no_answer"), "the store did not answer")
        XCTAssertEqual(ui.reason("other"), "the store refused it")
    }

    func testProblemFallsBack() {
        XCTAssertEqual(mealioProblem(MealioError(code: "x", message: "Mine"), "Fallback"), "Mine")
        XCTAssertEqual(mealioProblem(MealioError(code: "x", message: ""), "Fallback"), "Fallback")
        XCTAssertEqual(mealioProblem(URLError(.badURL), "Fallback"), "Fallback")
    }

    func testSheetHeightClamps() {
        XCTAssertEqual(MealioSheetHeight.fraction(0.2).share, 0.5)
        XCTAssertEqual(MealioSheetHeight.fraction(0.7).share, 0.7)
        XCTAssertEqual(MealioSheetHeight.fraction(4).share, 1)
        XCTAssertEqual(MealioSheetHeight.fraction(.nan).share, 0.5)
        XCTAssertNil(MealioSheetHeight.auto.share)
        XCTAssertNil(MealioSheetHeight.full.share)
    }
}
