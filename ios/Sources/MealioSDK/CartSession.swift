// A prepared cart the app can show and edit before filling the store cart.
// Mirrors CartSession in packages/core/src/client.ts.

import Combine
import Foundation

@MainActor
public final class CartSession: ObservableObject {
    public let cart: PreparedCart
    private let client: MealioClient

    /// The user's picks, by item key. Ready items start picked.
    @Published public private(set) var picks: [String: Selection] = [:]
    /// Keys in the order they were first picked, so `selections()` is stable.
    private var order: [String] = []

    init(client: MealioClient, cart: PreparedCart) {
        self.client = client
        self.cart = cart
        for item in cart.ready {
            if let chosen = item.chosen {
                set(Selection(key: item.key, productId: chosen.id, quantity: item.quantity, remember: true))
            }
        }
    }

    public var cartId: String { cart.cartId }
    public var store: String { cart.store }
    public var ready: [CartItem] { cart.ready }
    public var needsChoice: [CartItem] { cart.needsChoice }
    public var unavailable: [CartItem] { cart.unavailable }

    /// Items still waiting on the user.
    public func pending() -> [CartItem] {
        cart.needsChoice.filter { picks[$0.key] == nil }
    }

    /// The current pick for an item, if any. `productId` nil means skipped.
    public func selection(for key: String) -> Selection? {
        picks[key]
    }

    /// Pick a product for an item. The product must be one the server offered.
    /// Pass `preferenceId` when the product has `preferences`.
    public func choose(key: String, productId: String, quantity: Int? = nil, remember: Bool = true, preferenceId: String? = nil) throws {
        guard let item = find(key) else {
            throw MealioError(code: MealioError.Code.unknownItem, message: "No item \(key)")
        }
        let offered = ([item.chosen].compactMap { $0 } + (item.options ?? [])).contains { $0.id == productId }
        guard offered else {
            throw MealioError(code: MealioError.Code.unknownProduct, message: "Product \(productId) was not offered for \(key)")
        }
        set(Selection(key: key, productId: productId, quantity: quantity ?? item.quantity, remember: remember, preferenceId: preferenceId))
    }

    /// Leave an item out of the cart.
    public func skip(key: String) {
        set(Selection(key: key, productId: nil, remember: false))
    }

    /// Every pick, in the order the items were first picked.
    public func selections() -> [Selection] {
        order.compactMap { picks[$0] }
    }

    /// Fill the store cart with the current picks.
    public func addToCart() async throws -> AddResult {
        try await client.addToCart(cartId: cart.cartId, selections: selections())
    }

    private func set(_ s: Selection) {
        if picks[s.key] == nil { order.append(s.key) }
        picks[s.key] = s
    }

    private func find(_ key: String) -> CartItem? {
        (cart.ready + cart.needsChoice).first { $0.key == key }
    }
}
