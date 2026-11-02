// A prepared cart the app can show and edit before filling the store cart.
// Mirrors CartSession in packages/core/src/client.ts.
//
// Every item is shown every run. Remembered products start selected; the user
// can select another option, search for something else, or deselect an item
// to leave it out of THIS run (its remembered choice is kept for next time).

import Combine
import Foundation

/// The estimated total of the selected items. Mirrors `estimate()` in client.ts.
public struct CartEstimate: Equatable {
    /// Unit price times quantity over the selected items, rounded to cents.
    public let total: Double
    /// Selected items.
    public let count: Int
    /// True when any selected item is sold by weight or has no price: show
    /// the total as "about".
    public let estimated: Bool
    /// Selected items with no unit price.
    public let unpriced: Int

    public init(total: Double, count: Int, estimated: Bool, unpriced: Int) {
        self.total = total
        self.count = count
        self.estimated = estimated
        self.unpriced = unpriced
    }
}

@MainActor
public final class CartSession: ObservableObject {
    struct Pick: Equatable {
        let productId: String
        let preferenceId: String?
    }

    public let cart: PreparedCart
    private let client: MealioClient

    /// The user's picks, by item key. Remembered items start picked.
    @Published private var picks: [String: Pick] = [:]
    /// Options found with `search`, by item key, newest first.
    @Published private var extra: [String: [Product]] = [:]

    init(client: MealioClient, cart: PreparedCart) {
        self.client = client
        self.cart = cart
        for item in cart.items {
            if let id = item.selectedId {
                picks[item.key] = Pick(productId: id, preferenceId: item.rememberedPreferenceId)
            }
        }
    }

    public var cartId: String { cart.cartId }
    public var store: String { cart.store }
    /// Display name, e.g. "H-E-B", when the server sent one.
    public var storeName: String? { cart.storeName }
    /// Every item, in recipe order (older servers: rebuilt from the 0.1 groupings).
    public var items: [CartItem] { cart.items }

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
    public func isSelected(_ key: String) -> Bool { picks[key] != nil }
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

    /// Search the store for something else and add the results to this item's options.
    @discardableResult
    public func search(key: String, query: String, onStep: StepListener? = nil) async throws -> [Product] {
        let r = try await client.search(cartId: cart.cartId, key: key, query: query, onStep: onStep)
        let prev = extra[key] ?? []
        let seen = Set(prev.map(\.id))
        extra[key] = r.options.filter { !seen.contains($0.id) } + prev
        return r.options
    }

    /// One selection for EVERY item, in recipe order. Selected: the product,
    /// quantity, `remember: true` and the preference. Not selected:
    /// `productId: nil, remember: false` (left out this run, not forgotten).
    public func selections() -> [Selection] {
        items.map { (it: CartItem) -> Selection in
            if let p = picks[it.key] {
                return Selection(key: it.key, productId: p.productId, quantity: it.quantity, remember: true, preferenceId: p.preferenceId)
            }
            return Selection(key: it.key, productId: nil, remember: false)
        }
    }

    /// The selection this item will send.
    public func selection(for key: String) -> Selection? {
        selections().first { $0.key == key }
    }

    /// Estimated total of the selected items: unit price times quantity.
    public func estimate() -> CartEstimate {
        var total = 0.0
        var count = 0
        var unpriced = 0
        var estimated = false
        for it in items {
            guard let p = selected(for: it.key) else { continue }
            count += 1
            if let unit = p.unitPrice {
                total += unit * Double(it.quantity > 0 ? it.quantity : 1)
            } else {
                unpriced += 1
            }
            if p.estimated { estimated = true }
        }
        return CartEstimate(total: (total * 100).rounded() / 100, count: count,
                            estimated: estimated || unpriced > 0, unpriced: unpriced)
    }

    /// Fill the store cart with the current selections.
    public func addToCart(onStep: StepListener? = nil) async throws -> AddResult {
        try await client.addToCart(cartId: cart.cartId, selections: selections(), onStep: onStep)
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
