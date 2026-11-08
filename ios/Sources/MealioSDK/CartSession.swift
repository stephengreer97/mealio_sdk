// A prepared cart the app can show and edit before filling the store cart.
// Mirrors CartSession in packages/core/src/client.ts.
//
// Every item is shown every run. Remembered products start selected; the user
// can select another option, search for something else, or deselect an item
// to leave it out of THIS run (its remembered choice is kept for next time).

import Combine
import Foundation

/// The weight step (lb) for a sold-by-weight item whose store lists no weights.
public let WEIGHT_STEP: Double = 0.25
/// The most a selection may ask for, in lb. The server refuses more.
public let MAX_WEIGHT_LB: Double = 20

/// The index of the option nearest `v`. The first wins a tie.
private func nearestIndex(_ opts: [Double], _ v: Double) -> Int {
    var best = 0
    for (i, o) in opts.enumerated() where abs(o - v) < abs(opts[best] - v) - 1e-9 {
        best = i
    }
    return best
}

/// A total: of the selected items (`estimate()`) or of what the store took
/// (`addedTotal(_:)`). Mirrors `Estimate` in client.ts.
public struct CartEstimate: Equatable {
    /// Unit price times quantity over the counted items (price per lb times
    /// the weight for a sold-by-weight item), rounded to cents. Nil when any
    /// counted item has no price (`unpriced` > 0): no partial totals, so show
    /// no number then ("Prices at checkout").
    public let total: Double?
    /// Counted items.
    public let count: Int
    /// True when any counted item is sold by weight or has no price: show
    /// the total as "about".
    public let estimated: Bool
    /// Counted items with no price.
    public let unpriced: Int

    public init(total: Double?, count: Int, estimated: Bool, unpriced: Int) {
        self.total = total
        self.count = count
        self.estimated = estimated
        self.unpriced = unpriced
    }
}

/// What one added line cost. Mirrors the return of `addedPrice` in client.ts.
public struct AddedPrice: Equatable {
    /// Rounded to cents.
    public let amount: Double
    /// Show it as "about": a weight item, or a store estimate.
    public let estimated: Bool

    public init(amount: Double, estimated: Bool) {
        self.amount = amount
        self.estimated = estimated
    }
}

/// What one added line cost, or nil when its price is unknown. By weight:
/// price per lb times the pounds, else the package price once. Otherwise unit
/// price times quantity. `fallback` is the chosen Product, for servers whose
/// added entries carry no prices. Mirrors `addedPrice` in client.ts.
public func addedPrice(_ a: AddedItem, fallback: Product? = nil) -> AddedPrice? {
    priceOfAdded(a, fallback)
}

// The body of addedPrice, under a name CartSession.addedPrice does not shadow.
private func priceOfAdded(_ a: AddedItem, _ fallback: Product?) -> AddedPrice? {
    priceOfLine(quantity: a.quantity, weightLb: a.weightLb, unitPrice: a.unitPrice, pricePerLb: a.pricePerLb,
                estimated: a.estimated, fallback)
}

/// One line's price, from its own fields, else from `fallback`. The list
/// total and the done total both price lines with this, so the two agree.
private func priceOfLine(quantity: Int, weightLb: Double?, unitPrice: Double?, pricePerLb: Double?,
                         estimated: Bool?, _ fallback: Product?) -> AddedPrice? {
    let perLb = pricePerLb ?? fallback?.pricePerLb
    let unit = unitPrice ?? fallback?.unitPrice
    let est = estimated ?? fallback?.estimated ?? false
    func round(_ n: Double) -> Double { (n * 100).rounded() / 100 }
    if let lb = weightLb {
        if let perLb = perLb { return AddedPrice(amount: round(perLb * lb), estimated: true) }
        if let unit = unit { return AddedPrice(amount: round(unit), estimated: true) }
        return nil
    }
    guard let unit = unit else { return nil }
    return AddedPrice(amount: round(unit * Double(max(1, quantity))), estimated: est)
}

/// Whole cents, so adding lines up stays exact.
private func cents(_ amount: Double) -> Int {
    Int((amount * 100).rounded())
}

/// "For Tacos and Pasta": which recipes call for an item, on a cart made from
/// two or more recipes. Nil on a one-recipe cart, from older servers, or when
/// none of the item's recipes has a title. Mirrors `forRecipes` in the React
/// Native drop-in. Pass `text` for the partner's words.
public func mealioForRecipes(_ cart: PreparedCart, key: String, text: MealioText = MealioText()) -> String? {
    guard (cart.recipes ?? []).count >= 2 else { return nil }
    let item = cart.items.first { $0.key == key }
    let names = (item?.recipes ?? []).compactMap { r -> String? in
        guard let t = r.title, !t.isEmpty else { return nil }
        return t
    }
    return names.isEmpty ? nil : text.tr(.forRecipes, ["recipes": text.listAnd(names)])
}

/// "A", "A and B", "A, B and C".
func mealioListAnd(_ xs: [String]) -> String {
    MealioText().listAnd(xs)
}

/// The photos at the top of the drop-in's sheet: https only, at most three.
func mealioRecipePhotos(_ recipes: [Recipe]) -> [URL] {
    let urls = recipes.compactMap { recipe -> URL? in
        guard let s = recipe.photoUrl, s.hasPrefix("https://") else { return nil }
        return URL(string: s)
    }
    return Array(urls.prefix(3))
}

/// True for a 5-digit US zip, the only thing the store lookup takes.
func mealioIsZip(_ z: String) -> Bool {
    z.utf8.count == 5 && z.utf8.allSatisfy { (48...57).contains($0) }
}

/// What the zip box keeps of what was typed: digits, at most five.
func mealioCleanZip(_ z: String) -> String {
    String(z.filter { $0.isASCII && $0.isNumber }.prefix(5))
}

@MainActor
public final class CartSession: ObservableObject {
    struct Pick: Equatable {
        let productId: String
        let preferenceId: String?
    }

    public let cart: PreparedCart
    private let client: MealioClient

    /// The user's picks, by item key. Remembered items start picked, unless
    /// the server marked them `startUnchecked`.
    @Published private var picks: [String: Pick] = [:]
    /// Options found with `search`, by item key, newest first.
    @Published private var extra: [String: [Product]] = [:]
    /// Per item, the search that found each product (product id -> query),
    /// so a retry on a new cart can run the search that found the user's pick.
    private var foundBy: [String: [String: String]] = [:]
    /// Quantities the user changed, by item key.
    @Published private var qty: [String: Int] = [:]
    /// Weights (lb) the user changed, by item key.
    @Published private var lb: [String: Double] = [:]
    /// An add is under way. A second call waits for its result.
    private var adding = false
    private var addWaiters: [CheckedContinuation<Result<AddResult, Error>, Never>] = []
    /// The searches under way, so closing the sheet can stop them.
    @Published private var searches: [ObjectIdentifier: CancelToken] = [:]

    init(client: MealioClient, cart: PreparedCart) {
        self.client = client
        self.cart = cart
        for item in cart.items {
            if let id = item.selectedId, !item.startUnchecked {
                picks[item.key] = Pick(productId: id, preferenceId: item.rememberedPreferenceId)
            }
        }
    }

    public var cartId: String { cart.cartId }
    public var store: String { cart.store }
    /// Display name, e.g. "H-E-B", when the server sent one.
    public var storeName: String? { cart.storeName }
    /// The exact store, on a Kroger family cart. The user can change it.
    public var location: StoreLocation? { cart.location }
    /// Every item, in recipe order (older servers: rebuilt from the 0.1 groupings).
    public var items: [CartItem] { cart.items }
    /// The item the list opens with: the first that needs a choice. A pantry
    /// or optional item can wait until the user checks it.
    var firstToOpen: String? {
        items.first { !$0.startUnchecked && ($0.status == .choose || $0.status == .rememberedUnavailable) }?.key
    }
    /// True while an item the user is buying has no saved product yet.
    var showsRememberNote: Bool {
        items.contains { $0.status == .choose && !$0.startUnchecked }
    }
    /// The recipes this cart was made from. Older servers: none listed.
    public var recipes: [CartRecipe] { cart.recipes ?? [] }
    /// What the server changed or ignored in what you sent. Empty from older servers.
    public var warnings: [CartWarning] { cart.warnings ?? [] }
    /// The recipes that call for an item, for a "For Tacos and Pasta" line.
    /// Empty from older servers.
    public func recipes(for key: String) -> [ItemRecipe] { find(key)?.recipes ?? [] }
    /// "For Tacos and Pasta" for an item on a cart from two or more recipes,
    /// nil otherwise. Pass `text` for the partner's words. See `mealioForRecipes`.
    public func recipesLabel(for key: String, text: MealioText = MealioText()) -> String? {
        mealioForRecipes(cart, key: key, text: text)
    }

    @available(*, deprecated, message: "Use items")
    public var ready: [CartItem] { cart.ready }
    @available(*, deprecated, message: "Use items")
    public var needsChoice: [CartItem] { cart.needsChoice }
    @available(*, deprecated, message: "Use items")
    public var unavailable: [CartItem] { cart.unavailable }

    /// Options for an item, including any found with `search`, without duplicates.
    public func options(for key: String) -> [Product] {
        let base = find(key)?.options ?? []
        var seen = Set(base.map(\.id))
        var out = base
        for p in extra[key] ?? [] where !seen.contains(p.id) {
            seen.insert(p.id)
            out.append(p)
        }
        return out
    }

    public func selectedId(for key: String) -> String? { picks[key]?.productId }
    /// The preference picked with the selected product, if any.
    public func preferenceId(for key: String) -> String? { picks[key]?.preferenceId }
    /// Packages to add for an item: the recipe's quantity until the user
    /// changes it, never over the selected product's cap. What this returns is
    /// what is sent.
    public func quantity(for key: String) -> Int {
        min(qty[key] ?? max(1, find(key)?.quantity ?? 1), maxQuantity(for: key))
    }

    /// The most the user can add: the selected product's store cap, else 99.
    public func maxQuantity(for key: String) -> Int {
        if let cap = selected(for: key)?.maxQuantity, cap > 0 { return min(99, cap) }
        return 99
    }

    /// Set the quantity, clamped to 1 and the store's cap. Returns what was set.
    @discardableResult
    public func setQuantity(key: String, to n: Int) -> Int {
        let v = max(1, min(maxQuantity(for: key), n))
        qty[key] = v
        return v
    }

    /// True when the selected product is sold by weight: use `weight(for:)`,
    /// not `quantity(for:)`.
    public func isWeight(_ key: String) -> Bool { selected(for: key)?.soldByWeight == true }

    /// The lightest and heaviest weight (lb) the user can pick for the
    /// selected product: its first and last weight option, else 0.25 to 20.
    public func weightRange(for key: String) -> ClosedRange<Double> {
        let opts = weightOptions(for: key)
        guard let first = opts.first, let last = opts.last else { return WEIGHT_STEP...MAX_WEIGHT_LB }
        return first...min(MAX_WEIGHT_LB, last)
    }

    /// Pounds to add for a sold-by-weight item: the user's, else the recipe's
    /// own weight, else the store's first weight option, else 0.25. Always a
    /// weight the selected product can be bought in (see `setWeight`). 0 for
    /// count items.
    public func weight(for key: String) -> Double {
        guard isWeight(key) else { return 0 }
        if let set = lb[key] { return snapWeight(key, set) }
        if let recipe = find(key)?.weightLb, recipe > 0 { return snapWeight(key, recipe) }
        return weightOptions(for: key).first ?? WEIGHT_STEP
    }

    /// Set the weight in lb. Snapped to the nearest weight option when the
    /// store lists them, else to 0.25 lb steps, and clamped to
    /// `weightRange(for:)`. Returns what was set.
    @discardableResult
    public func setWeight(key: String, to pounds: Double) -> Double {
        let v = snapWeight(key, pounds.isFinite ? pounds : 0)
        lb[key] = v
        return v
    }

    /// One step heavier (`by: 1`) or lighter (`by: -1`): the next weight
    /// option, else 0.25 lb. Returns the new weight.
    @discardableResult
    public func stepWeight(key: String, by dir: Int) -> Double {
        let d = dir.signum()
        let cur = weight(for: key)
        let opts = weightOptions(for: key)
        if opts.isEmpty { return setWeight(key: key, to: cur + Double(d) * WEIGHT_STEP) }
        let i = nearestIndex(opts, cur)
        return setWeight(key: key, to: opts[max(0, min(opts.count - 1, i + d))])
    }

    private func weightOptions(for key: String) -> [Double] {
        let raw = selected(for: key)?.weightOptions ?? []
        return Array(Set(raw.filter { $0.isFinite && $0 > 0 && $0 <= MAX_WEIGHT_LB })).sorted()
    }

    private func snapWeight(_ key: String, _ pounds: Double) -> Double {
        let range = weightRange(for: key)
        let opts = weightOptions(for: key)
        let v = max(range.lowerBound, min(range.upperBound, pounds))
        if !opts.isEmpty { return opts[nearestIndex(opts, v)] }
        return max(range.lowerBound, min(range.upperBound, (v / WEIGHT_STEP).rounded() * WEIGHT_STEP))
    }

    public func isSelected(_ key: String) -> Bool { picks[key] != nil }

    /// True when the item is ticked but its product offers preferences (H-E-B
    /// deli slicing, for example) and none is chosen. Such an item stays out
    /// of `selections()` and `estimate()` until one is, the same rule as the
    /// Mealio app: a missing preference is a different request from "No
    /// preference".
    public func needsPreference(_ key: String) -> Bool {
        guard let pick = picks[key] else { return false }
        guard let prefs = selected(for: key)?.preferences, !prefs.isEmpty else { return false }
        return pick.preferenceId?.isEmpty ?? true
    }

    /// Keys of ticked items still waiting on a preference, in recipe order.
    public func pendingPreferences() -> [String] {
        items.filter { needsPreference($0.key) }.map(\.key)
    }
    public var selectedCount: Int { picks.count }

    /// The selected product for an item, from its options.
    public func selected(for key: String) -> Product? {
        guard let id = selectedId(for: key) else { return nil }
        return options(for: key).first { $0.id == id }
    }

    /// Select a product for an item. It must be one of `options(for:)`.
    /// Pass `preferenceId` when the product has `preferences`.
    public func select(key: String, productId: String, preferenceId: String? = nil) throws {
        guard find(key) != nil else {
            throw MealioError(code: MealioError.Code.unknownItem, message: "No item \(key)")
        }
        guard options(for: key).contains(where: { $0.id == productId }) else {
            throw MealioError(code: MealioError.Code.unknownProduct, message: "Product \(productId) was not offered for \(key)")
        }
        picks[key] = Pick(productId: productId, preferenceId: preferenceId)
    }

    /// Leave the item out of this run. Its remembered choice is kept on the server.
    public func deselect(key: String) {
        picks[key] = nil
    }

    /// Take the user's picks from an earlier cart, after a failed add. Works
    /// by item key, on the same store: what they unticked stays unticked, and
    /// a product this cart offers comes back with its quantity, weight and
    /// preference.
    ///
    /// The server only knows a searched product on the cart it was found in,
    /// so a pick the user found with `search` is never sent here as it was:
    /// the search that found that product runs again on this cart (it counts
    /// toward the search cap), and the same product is picked if it comes
    /// back. If it does not, or the search fails, the item keeps this cart's
    /// own pick.
    ///
    /// It never throws: it ends with whatever it could restore. Pass `cancel`
    /// to stop the searches (no more run once it fires); `cancelSearches`
    /// stops them too. Check `cancel.cancelled` afterwards to tell a stop
    /// from the end.
    public func restorePicks(from old: CartSession, cancel: CancelToken? = nil, onStep: StepListener? = nil) async {
        guard old.store == store else { return }
        var again: [(key: String, productId: String, query: String)] = []
        for it in items {
            guard old.find(it.key) != nil else { continue }
            guard let productId = old.selectedId(for: it.key) else {
                deselect(key: it.key)
                continue
            }
            if restore(it.key, productId, from: old) { continue }
            // Not offered here. Found with search there: run that search here.
            if let q = old.foundBy[it.key]?[productId] { again.append((key: it.key, productId: productId, query: q)) }
        }
        for (key, productId, query) in again {
            if cancel?.cancelled == true { return }
            do {
                _ = try await search(key: key, query: query, cancel: cancel, onStep: onStep)
            } catch {
                continue
            }
            _ = restore(key, productId, from: old)
        }
    }

    /// Pick `productId` for `key` as the old cart had it, if this cart offers
    /// it. Returns false (and changes nothing) when it does not.
    private func restore(_ key: String, _ productId: String, from old: CartSession) -> Bool {
        guard let product = options(for: key).first(where: { $0.id == productId }) else { return false }
        let pref = old.preferenceId(for: key)
        let keep = (product.preferences ?? []).contains { $0.id == pref }
        try? select(key: key, productId: productId, preferenceId: keep ? pref : nil)
        if let n = old.qty[key] { setQuantity(key: key, to: n) }
        if let w = old.lb[key] { setWeight(key: key, to: w) }
        return true
    }

    /// True while a search runs. Keep Add disabled until it ends.
    public var searching: Bool { !searches.isEmpty }

    /// Stop every search of this cart. Closing the sheet does this.
    public func cancelSearches() {
        for c in Array(searches.values) { c.cancel() }
    }

    /// Search the store for something else and add the results to this item's
    /// options. Pass `cancel` to stop it; `cancelSearches` stops it too.
    @discardableResult
    public func search(key: String, query: String, cancel: CancelToken? = nil,
                       onStep: StepListener? = nil) async throws -> [Product] {
        let token = cancel ?? CancelToken()
        let id = ObjectIdentifier(token)
        searches[id] = token
        defer { searches[id] = nil }
        let r = try await client.search(cartId: cart.cartId, key: key, query: query, cancel: token, onStep: onStep)
        var found = foundBy[key] ?? [:]
        // The first search that found a product is the one restorePicks reruns.
        for p in r.options where found[p.id] == nil { found[p.id] = query }
        foundBy[key] = found
        let prev = extra[key] ?? []
        let seen = Set(prev.map(\.id))
        extra[key] = r.options.filter { !seen.contains($0.id) } + prev
        return r.options
    }

    /// One selection for EVERY item, in recipe order. Selected: the product,
    /// quantity, `remember: true` and the preference; a sold-by-weight item
    /// sends quantity 1 and `weightLb`. Not selected, or still waiting on a
    /// preference (`needsPreference`): `productId: nil, remember: false`
    /// (left out this run, not forgotten).
    public func selections() -> [Selection] {
        items.map { (it: CartItem) -> Selection in
            guard let p = picks[it.key], !needsPreference(it.key) else {
                return Selection(key: it.key, productId: nil, remember: false)
            }
            if isWeight(it.key) {
                return Selection(key: it.key, productId: p.productId, quantity: 1, weightLb: weight(for: it.key), remember: true, preferenceId: p.preferenceId)
            }
            return Selection(key: it.key, productId: p.productId, quantity: quantity(for: it.key), remember: true, preferenceId: p.preferenceId)
        }
    }

    /// The selection this item will send.
    public func selection(for key: String) -> Selection? {
        selections().first { $0.key == key }
    }

    /// Estimated total of the selected items: unit price times quantity, and
    /// for a sold-by-weight item price per lb times the weight (one package
    /// price when the store prices it as a package). Items waiting on a
    /// preference are left out.
    ///
    /// `total` is nil when even one selected item has no price (`unpriced` >
    /// 0): a total that leaves an item out is wrong, so show no number at all
    /// ("Prices at checkout"). A weight item priced per lb counts as priced.
    public func estimate() -> CartEstimate {
        var total = 0
        var count = 0
        var unpriced = 0
        var estimated = false
        for it in items {
            guard let p = selected(for: it.key), !needsPreference(it.key) else { continue }
            count += 1
            // Priced line by line as the done screen will price it, so the two agree.
            let byWeight = p.soldByWeight == true
            if byWeight { estimated = true }
            guard let line = priceOfLine(quantity: quantity(for: it.key), weightLb: byWeight ? weight(for: it.key) : nil,
                                         unitPrice: nil, pricePerLb: nil, estimated: nil, p) else {
                unpriced += 1
                continue
            }
            total += cents(line.amount)
            if line.estimated { estimated = true }
        }
        return CartEstimate(total: unpriced > 0 ? nil : Double(total) / 100, count: count,
                            estimated: estimated || unpriced > 0, unpriced: unpriced)
    }

    /// The total of what the store took, for the finished-run screen. Same
    /// rule as `estimate()`: `total` is nil when any added item has no price.
    /// Prices come from the added entries, else (an older server) from the
    /// product selected in this session.
    public func addedTotal(_ result: AddResult) -> CartEstimate {
        var total = 0
        var unpriced = 0
        var estimated = false
        for a in result.added {
            guard let p = priceOfAdded(a, selected(for: a.key)) else {
                unpriced += 1
                continue
            }
            total += cents(p.amount)
            if p.estimated { estimated = true }
        }
        return CartEstimate(total: unpriced > 0 ? nil : Double(total) / 100, count: result.added.count,
                            estimated: estimated || unpriced > 0, unpriced: unpriced)
    }

    /// One added line's price (see `addedPrice(_:fallback:)`), with this
    /// session's product as the fallback.
    public func addedPrice(_ a: AddedItem) -> AddedPrice? {
        priceOfAdded(a, selected(for: a.key))
    }

    /// Fill the store cart with the current selections. A second call while
    /// one is running waits for that same add.
    public func addToCart(onStep: StepListener? = nil) async throws -> AddResult {
        if adding {
            let shared = await withCheckedContinuation { (c: CheckedContinuation<Result<AddResult, Error>, Never>) in
                addWaiters.append(c)
            }
            return try shared.get()
        }
        adding = true
        let result: Result<AddResult, Error>
        do {
            let added = try await client.addToCart(cartId: cart.cartId, selections: selections(), onStep: onStep)
            result = .success(added)
        } catch {
            result = .failure(error)
        }
        adding = false
        let waiters = addWaiters
        addWaiters = []
        for w in waiters { w.resume(returning: result) }
        return try result.get()
    }

    // MARK: 0.1 names

    @available(*, deprecated, message: "Use select(key:productId:preferenceId:)")
    public func choose(key: String, productId: String, quantity: Int? = nil, remember: Bool = true, preferenceId: String? = nil) throws {
        try select(key: key, productId: productId, preferenceId: preferenceId)
    }

    @available(*, deprecated, message: "Use deselect(key:)")
    public func skip(key: String) {
        deselect(key: key)
    }

    /// Items that can still be picked and are not selected.
    @available(*, deprecated, message: "Every item is shown; use isSelected(_:)")
    public func pending() -> [CartItem] {
        items.filter { $0.status != .unavailable && picks[$0.key] == nil }
    }

    private func find(_ key: String) -> CartItem? {
        items.first { $0.key == key }
    }
}
