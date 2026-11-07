// Every word the drop-in shows, in one table, and the helpers that fill it in.
// Partners change or translate any of them with
// `MealioCart.configure(strings: [.done: "Fertig"])`. {store}-style placeholders
// are filled in at runtime. A key ending _one or _other is the singular or
// plural of the same message.
//
// protocol/strings.json is the source. Every SDK carries the same table, and
// StringsTests checks this one against a copy of that file.
// Mirrors packages/core/src/strings.ts.
//
// This file is platform-neutral, so `swift test` covers it on a Mac.

import Foundation

public enum MealioStringKey: String, CaseIterable {
    case addToCart
    case addToCartShort
    case close
    case somethingWrong
    case somethingWrongSentence
    case couldNotAdd
    case signInClosed
    case tryAgain
    case yourStore
    case meals
    case titleInCartPlain
    case titleInCart
    case titleLoadingPlain
    case titleLoading
    case titleStores
    case titleLocation
    case titleList
    case titleSettings
    case loginNote
    case loadingNote
    case stepSignIn
    case stepFinding_one
    case stepFinding_other
    case change
    case choose
    case done
    case current
    case selectedCount
    case rememberNote
    case pendingOptions_one
    case pendingOptions_other
    case total
    case estimatedTotal
    case pricesAtCheckout
    case aboutPrice
    case addItems_one
    case addItems_other
    case selectItems
    case notFoundAt
    case nothingFound
    case searchFailed
    case searchPlaceholder
    case search
    case yourUsual
    case notAddingThisTime
    case usualOutOfStock
    case options_one
    case options_other
    case chooseProduct
    case chooseOne
    case weight
    case quantity
    case usualNotAvailableNamed
    case usualNotAvailable
    case usualOutNamed
    case usualOut
    case outOfStock
    case crowdFavorite
    case itemsAdded_one
    case itemsAdded_other
    case nothingAdded
    case cartUnchanged
    case leftOut
    case neededOption
    case uncheckedThisTime
    case notChosen
    case reasonNotConfirmed
    case reasonWeight
    case reasonOutOfStock
    case reasonNoAnswer
    case reasonRefused
    case pricePerLb
    case priceEstimate
    case forRecipes
    case and
    case or
    case backToList
    case backToStores
    case differentStore
    case couldNotLoadStores
    case couldNotLoadYourStores
    case couldNotLookUp
    case couldNotSaveStore
    case zipPrompt
    case zipCode
    case findStores
    case noStoresNear
    case a11yLeaveOut
    case a11yAdd
    case a11yLess
    case a11yMore
    case a11yChangeLocation
    case a11yChangeStore
    case pantryHint
}

/// Your words, by key. Keys you leave out keep the default text.
public typealias MealioStrings = [MealioStringKey: String]

/// The default text of every key. Same as protocol/strings.json.
public let DEFAULT_STRINGS: MealioStrings = [
    .addToCart: "Add to my grocery cart",
    .addToCartShort: "Add to cart",
    .close: "Close",
    .somethingWrong: "Something went wrong",
    .somethingWrongSentence: "Something went wrong.",
    .couldNotAdd: "Could not add to your cart.",
    .signInClosed: "Sign-in was closed before it finished.",
    .tryAgain: "Try again",
    .yourStore: "your store",
    .meals: "{count} meals",
    .titleInCartPlain: "In your cart",
    .titleInCart: "In your {store} cart",
    .titleLoadingPlain: "Getting your cart ready",
    .titleLoading: "Getting your {store} cart ready",
    .titleStores: "Choose your store",
    .titleLocation: "Find your {store}",
    .titleList: "Your {store} list",
    .titleSettings: "Your grocery store",
    .loginNote: "Sign in on {store}'s own page. Mealio never sees your password.",
    .loadingNote: "Checking prices and stock at {store}.",
    .stepSignIn: "Checking your {store} sign-in",
    .stepFinding_one: "Finding your {count} ingredient",
    .stepFinding_other: "Finding your {count} ingredients",
    .change: "Change",
    .choose: "Choose",
    .done: "Done",
    .current: "Current",
    .selectedCount: "{count} of {total} selected",
    .rememberNote: "Pick a product for each item and Mealio will remember your preferences.",
    .pendingOptions_one: "1 checked item needs an option chosen before adding.",
    .pendingOptions_other: "{count} checked items need an option chosen before adding.",
    .total: "Total",
    .estimatedTotal: "Estimated total",
    .pricesAtCheckout: "Prices at checkout",
    .aboutPrice: "about {price}",
    .addItems_one: "Add 1 item to {store}",
    .addItems_other: "Add {count} items to {store}",
    .selectItems: "Select items to add",
    .notFoundAt: "Not found at {store}",
    .nothingFound: "Nothing found for \"{query}\".",
    .searchFailed: "Search failed. Try again.",
    .searchPlaceholder: "Search {store} for something else",
    .search: "Search",
    .yourUsual: "Your usual",
    .notAddingThisTime: "Not adding this time",
    .usualOutOfStock: "Your usual is out of stock",
    .options_one: "1 option",
    .options_other: "{count} options",
    .chooseProduct: "Choose a product",
    .chooseOne: "Choose one: {options}",
    .weight: "Weight",
    .quantity: "Quantity",
    .usualNotAvailableNamed: "Your usual, {name}, is not available today. Pick another this time. It stays your usual.",
    .usualNotAvailable: "Your usual is not available today. Pick another this time. It stays your usual.",
    .usualOutNamed: "Your usual, {name}, is out of stock today. Pick another this time. It stays your usual.",
    .usualOut: "Your usual is out of stock today. Pick another this time. It stays your usual.",
    .outOfStock: "Out of stock",
    .crowdFavorite: "Crowd favorite",
    .itemsAdded_one: "1 item added",
    .itemsAdded_other: "{count} items added",
    .nothingAdded: "Nothing was added",
    .cartUnchanged: "Your cart did not change.",
    .leftOut: "Left out this time",
    .neededOption: "Needed an option chosen",
    .uncheckedThisTime: "Unchecked this time",
    .notChosen: "Not chosen",
    .reasonNotConfirmed: "not confirmed in your cart",
    .reasonWeight: "sold by weight, which this store cannot take here",
    .reasonOutOfStock: "out of stock",
    .reasonNoAnswer: "the store did not answer",
    .reasonRefused: "the store refused it",
    .pricePerLb: "{price}/lb est.",
    .priceEstimate: "{price} est.",
    .forRecipes: "For {recipes}",
    .and: "and",
    .or: "or",
    .backToList: "Back to your list",
    .backToStores: "Back to your stores",
    .differentStore: "Choose a different store",
    .couldNotLoadStores: "Could not load stores. Close and try again.",
    .couldNotLoadYourStores: "Could not load your stores.",
    .couldNotLookUp: "Could not look up stores. Try again.",
    .couldNotSaveStore: "Could not save that store. Try again.",
    .zipPrompt: "Enter your zip code to see {store} stores near you.",
    .zipCode: "Zip code",
    .findStores: "Find stores",
    .noStoresNear: "No {store} stores near {zip}. Try another zip code.",
    .a11yLeaveOut: "Leave out {item}",
    .a11yAdd: "Add {item}",
    .a11yLess: "Less {item}",
    .a11yMore: "More {item}",
    .a11yChangeLocation: "Store location: {name}. Change location",
    .a11yChangeStore: "Store: {store}. Change store",
    .pantryHint: "You may already have this",
]

/// Fill {placeholders} in one pass, so a value that itself holds "{store}" is
/// left alone. One with no value stays as written, so a typo shows.
public func mealioFillText(_ template: String, _ vars: [String: String] = [:]) -> String {
    func isWord(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber || c == "_") }
    var out = ""
    var rest = Substring(template)
    while let open = rest.firstIndex(of: "{") {
        out.append(contentsOf: rest[..<open])
        let name = rest.index(after: open)
        if let close = rest[name...].firstIndex(where: { !isWord($0) }),
           close > name, rest[close] == "}",
           let value = vars[String(rest[name..<close])] {
            out += value
            rest = rest[rest.index(after: close)...]
        } else {
            out.append("{")
            rest = rest[name...]
        }
    }
    out.append(contentsOf: rest)
    return out
}

/// "$31.20": two decimals. The default for `formatMoney`.
func mealioMoney(_ n: Double) -> String {
    String(format: "$%.2f", n)
}

/// The drop-in's words and prices: the table with your strings laid over it,
/// and your `formatMoney`. `MealioCart.text` is the one in force.
public struct MealioText {
    private let strings: MealioStrings
    private let formatMoney: ((Double) -> String)?

    public init(strings: MealioStrings = [:], formatMoney: ((Double) -> String)? = nil) {
        self.strings = strings
        self.formatMoney = formatMoney
    }

    /// True when the partner set formatMoney, so prices are built from numbers,
    /// not the store's text.
    public var customMoney: Bool { formatMoney != nil }

    /// The text for a key, filled in.
    public func tr(_ key: MealioStringKey, _ vars: [String: String] = [:]) -> String {
        mealioFillText(strings[key] ?? DEFAULT_STRINGS[key] ?? key.rawValue, vars)
    }

    /// base_one for 1, base_other otherwise. `count` is filled in for you.
    public func plural(_ base: String, _ count: Int, _ vars: [String: String] = [:]) -> String {
        let name = "\(base)_\(count == 1 ? "one" : "other")"
        guard let key = MealioStringKey(rawValue: name) else { return name }
        return tr(key, vars.merging(["count": String(count)]) { mine, _ in mine })
    }

    /// An amount as prices read.
    public func money(_ amount: Double) -> String {
        if let format = formatMoney { return format(amount) }
        return mealioMoney(amount)
    }

    /// "$31.20", or "about $31.20" when it is an estimate.
    func amount(_ amount: Double, estimated: Bool) -> String {
        let price = money(amount)
        return estimated ? tr(.aboutPrice, ["price": price]) : price
    }

    /// The price as a row shows it. Sold by the pound: "$9.99/lb est.".
    func price(_ p: Product) -> String {
        if p.soldByWeight == true, let perLb = p.pricePerLb {
            return tr(.pricePerLb, ["price": money(perLb)])
        }
        // The store's own text, unless the partner set how prices read.
        var price = p.price ?? ""
        if customMoney, let unit = p.unitPrice { price = money(unit) }
        return p.estimated && !price.isEmpty ? tr(.priceEstimate, ["price": price]) : price
    }

    /// A failed add's reason in plain words.
    func reason(_ r: String) -> String {
        if r == "not_confirmed" { return tr(.reasonNotConfirmed) }
        if r == "weight_not_supported" { return tr(.reasonWeight) }
        if r.contains("stock") { return tr(.reasonOutOfStock) }
        if r.contains("timeout") || r.contains("no_answer") { return tr(.reasonNoAnswer) }
        return tr(.reasonRefused)
    }

    /// "A", "A and B", "A, B and C".
    func listAnd(_ xs: [String]) -> String { list(xs, joiner: tr(.and)) }

    /// "A", "A or B", "A, B or C".
    func listOr(_ xs: [String]) -> String { list(xs, joiner: tr(.or)) }

    private func list(_ xs: [String], joiner: String) -> String {
        guard xs.count > 1, let last = xs.last else { return xs.first ?? "" }
        return "\(xs.dropLast().joined(separator: ", ")) \(joiner) \(last)"
    }
}

/// The message of an error, or `fallback` when it has none of its own.
func mealioProblem(_ e: Error, _ fallback: String) -> String {
    if let m = (e as? MealioError)?.message, !m.isEmpty { return m }
    return fallback
}

/// How tall the sheet is.
public enum MealioSheetHeight: Equatable {
    /// The ordinary tall sheet.
    case auto
    /// Fills the screen.
    case full
    /// A share of the screen, clamped to 0.5...1.
    case fraction(Double)

    /// The clamped share, for `.fraction`.
    var share: Double? {
        guard case .fraction(let x) = self else { return nil }
        return min(1, max(0.5, x))
    }
}
