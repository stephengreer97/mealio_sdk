// The one-view integration: MealioCartButton(recipe: recipe, store: "heb"),
// or MealioCartButton(recipes: [tacos, pasta]) to fill one cart from several meals.
// It draws a themed button and runs the whole flow in one sheet.
// Mirrors packages/react-native/src/MealioCartButton.tsx.

#if canImport(SwiftUI) && canImport(UIKit) && canImport(WebKit)
import SwiftUI

@MainActor
public struct MealioCartButton: View {
    private let recipes: [Recipe]
    private let store: String?
    private let zip: String?
    private let label: String
    private let isDisabled: Bool
    private let onAdded: ((AddResult) -> Void)?
    private let onClose: ((AddResult?) -> Void)?
    private let onError: ((Error) -> Void)?
    @State private var open = false

    /// - Parameters:
    ///   - recipe: The recipe to cart.
    ///   - store: Store id, e.g. "heb". Optional: without it the user's
    ///     default store is used, or they pick one in the sheet.
    ///   - zip: 5-digit zip. Needed for Kroger family stores.
    ///   - label: Defaults to "Add to my grocery cart".
    ///   - disabled: Fades the button and ignores taps.
    ///   - onAdded: Called after the cart is filled, before the user taps Done.
    ///   - onClose: Called when the sheet closes; the result when something
    ///     was added, nil otherwise.
    ///   - onError: Called when preparing or adding fails. The sheet shows it too.
    public init(recipe: Recipe,
                store: String? = nil,
                zip: String? = nil,
                label: String = "Add to my grocery cart",
                disabled: Bool = false,
                onAdded: ((AddResult) -> Void)? = nil,
                onClose: ((AddResult?) -> Void)? = nil,
                onError: ((Error) -> Void)? = nil) {
        self.init(recipes: [recipe], store: store, zip: zip, label: label, disabled: disabled,
                  onAdded: onAdded, onClose: onClose, onError: onError)
    }

    /// One cart from several recipes (at most `MAX_RECIPES`). Ingredients they
    /// share become one item, and each item says which recipes it is for.
    /// Other parameters as in `init(recipe:...)`.
    public init(recipes: [Recipe],
                store: String? = nil,
                zip: String? = nil,
                label: String = "Add to my grocery cart",
                disabled: Bool = false,
                onAdded: ((AddResult) -> Void)? = nil,
                onClose: ((AddResult?) -> Void)? = nil,
                onError: ((Error) -> Void)? = nil) {
        self.recipes = recipes
        self.store = store
        self.zip = zip
        self.label = label
        self.isDisabled = disabled
        self.onAdded = onAdded
        self.onClose = onClose
        self.onError = onError
    }

    public var body: some View {
        let t = MealioCart.theme
        return Button(action: { open = true }) {
            Text(label)
                .font(t.font(16, .bold))
                .foregroundColor(t.onAccent)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(RoundedRectangle(cornerRadius: t.radius).fill(t.accent))
                .opacity(isDisabled ? 0.5 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        // WARM THE LOGIN CHECK while the user reads the recipe. Only for a known
        // user with a store on file: the server answers "nothing to warm"
        // otherwise. The client runs it at most once every few minutes.
        .task(id: store) {
            if !isDisabled { await MealioCart.warm(store: store) }
        }
        .mealioCartFlow(isPresented: $open, recipes: recipes, store: store, zip: zip,
                        onAdded: onAdded, onError: onError, onClose: onClose)
    }
}
#endif
