// Dark mode, the look's defaults and the done action's order. iOS only, as the
// drop-in is: run with xcodebuild, not `swift test`.

#if canImport(SwiftUI) && canImport(UIKit) && canImport(WebKit)
import SwiftUI
import XCTest
@testable import MealioSDK

final class LookTests: XCTestCase {
    private let light = MealioTheme(accent: .red, radius: 22, fontName: "Avenir Next")

    private func resolve(_ scheme: MealioColorScheme, _ system: ColorScheme, dark: MealioDarkTheme = .default) -> MealioTheme {
        mealioResolveTheme(light: light, dark: dark, scheme: scheme, system: system)
    }

    func testLightIsTheDefaultAndIgnoresThePhone() {
        XCTAssertEqual(resolve(.light, .dark).accent, .red)
    }

    func testAutoFollowsThePhone() {
        XCTAssertEqual(resolve(.auto, .light).accent, .red)
        XCTAssertEqual(resolve(.auto, .dark).accent, Color(mealioHex: 0x5FBF8F))
    }

    func testDarkIgnoresThePhone() {
        XCTAssertEqual(resolve(.dark, .light).background, Color(mealioHex: 0x1B1B1A))
    }

    func testDefaultDarkColorsMatchTheReference() {
        let d = MealioDarkTheme.default
        XCTAssertEqual(d.accent, Color(mealioHex: 0x5FBF8F))
        XCTAssertEqual(d.onAccent, Color(mealioHex: 0x0E1A14))
        XCTAssertEqual(d.background, Color(mealioHex: 0x1B1B1A))
        XCTAssertEqual(d.surface, Color(mealioHex: 0x2A2A28))
        XCTAssertEqual(d.text, Color(mealioHex: 0xF2F1EE))
        XCTAssertEqual(d.muted, Color(mealioHex: 0xB4B2AC))
        XCTAssertEqual(d.border, Color(mealioHex: 0x3A3A37))
        XCTAssertEqual(d.warnBackground, Color(mealioHex: 0x3B2A10))
        XCTAssertEqual(d.warnText, Color(mealioHex: 0xF5C27A))
    }

    func testRadiusAndFontCarryOverUnlessDarkSetsThem() {
        let carried = resolve(.dark, .dark)
        XCTAssertEqual(carried.radius, 22)
        XCTAssertEqual(carried.fontName, "Avenir Next")

        let own = resolve(.dark, .dark, dark: MealioDarkTheme(accent: .blue, radius: 8, fontName: "Menlo"))
        XCTAssertEqual(own.accent, .blue)
        XCTAssertEqual(own.radius, 8)
        XCTAssertEqual(own.fontName, "Menlo")
        // A color left out is Mealio's dark one, not the light theme's.
        XCTAssertEqual(own.background, Color(mealioHex: 0x1B1B1A))
    }

    func testSheetOptionDefaults() {
        let o = MealioSheetOptions()
        XCTAssertTrue(o.showTotal)
        XCTAssertEqual(o.height, .auto)
        XCTAssertNil(o.logo)
    }

    @MainActor
    func testConfigureKeepsWhatYouLeaveOut() {
        defer {
            MealioCart.colorScheme = .light
            MealioCart.strings = [:]
            MealioCart.formatMoney = nil
        }
        MealioCart.configure(colorScheme: .auto, strings: [.done: "Fertig"], formatMoney: { _ in "x" })
        MealioCart.configure(theme: .default)
        XCTAssertEqual(MealioCart.colorScheme, .auto)
        XCTAssertEqual(MealioCart.text.tr(.done), "Fertig")
        XCTAssertEqual(MealioCart.text.money(1), "x")
    }

    @MainActor
    func testAnUncheckedPantryItemSaysSoAndACheckedOneShowsItsPrice() throws {
        let salt = Product(id: "9", name: "Salt", price: "$1.00", unitPrice: 1)
        let item = CartItem(key: "salt", ingredient: "salt", status: .remembered, options: [salt],
                            selectedId: "9", remembered: salt, startUnchecked: true)
        let config = MealioClientConfig(publishableKey: "pk_test", sessionTokenProvider: { "tok" },
                                        keys: TestSigner.keys, sdkVersion: "0")
        let cart = CartSession(client: MealioClient(config: config, host: FakeHost()),
                               cart: PreparedCart(cartId: "c", store: "heb", items: [item]))
        let row = MealioItemRow(cart: cart, item: item, t: .default, storeName: "H-E-B", isOpen: false,
                                disabled: false, onToggleOpen: {})
        XCTAssertEqual(row.meta(on: false, picked: nil, options: [salt]), "You may already have this")

        try cart.select(key: "salt", productId: "9")
        XCTAssertEqual(row.meta(on: true, picked: cart.selected(for: "salt"), options: [salt]), "$1.00 \u{00B7} Your usual")
    }

    @MainActor
    func testDoneActionRunsAfterTheSheetCloses() {
        let model = MealioFlowModel()
        model.open(recipes: [], store: nil, zip: nil, onAdded: nil, onError: nil)
        var order: [String] = []
        model.afterClose { order.append("first") }
        model.afterClose { order.append("second tap") }
        XCTAssertEqual(order, [])
        model.close { _ in order.append("onClose") }
        XCTAssertEqual(order, ["onClose", "first"])
        model.close { _ in order.append("again") }
        XCTAssertEqual(order, ["onClose", "first"])
    }
}
#endif
