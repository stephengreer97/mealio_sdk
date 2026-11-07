// The one-view integration: MealioCartButton(recipe: recipe, store: "heb"),
// or MealioCartButton(recipes: [tacos, pasta]) to fill one cart from several meals.
// It draws a themed button and runs the whole flow in one sheet.
// Mirrors packages/react-native/src/MealioCartButton.tsx.

#if canImport(SwiftUI) && canImport(UIKit) && canImport(WebKit)
import SwiftUI

public enum MealioButtonVariant: String, CaseIterable {
    /// The accent filled, full width. The default.
    case solid
    /// An accent border, full width.
    case outline
    /// Small, for a recipe card. Its label defaults to the `addToCartShort` string.
    case compact
    /// A round 48pt cart button. The label is its accessibility label.
    case icon
}

@MainActor
public struct MealioCartButton: View {
    private let recipes: [Recipe]
    private let store: String?
    private let zip: String?
    private let label: String?
    private let variant: MealioButtonVariant
    private let isDisabled: Bool
    private let onAdded: ((AddResult) -> Void)?
    private let onClose: ((AddResult?) -> Void)?
    private let onError: ((Error) -> Void)?
    private let doneMessage: String?
    private let doneAction: MealioDoneAction?
    /// The partner's own button. AnyView keeps MealioCartButton a plain type,
    /// so code that names it still compiles.
    private let custom: ((@escaping () -> Void, Bool, String) -> AnyView)?
    private let onSignInRequired: (() -> Void)?
    @ObservedObject private var users: MealioUsers
    @State private var open = false
    @Environment(\.colorScheme) private var systemScheme

    /// - Parameters:
    ///   - recipe: The recipe to cart.
    ///   - store: Store id, e.g. "heb". Optional: without it the user's
    ///     default store is used, or they pick one in the sheet.
    ///   - zip: 5-digit zip, if you know it. Fills the zip box when a Kroger
    ///     family store asks the user which store they shop at. Without it,
    ///     they type it in.
    ///   - label: Defaults to the `addToCart` string, or `addToCartShort` on a
    ///     compact button.
    ///   - variant: `.solid` (the default), `.outline`, `.compact` or `.icon`.
    ///   - disabled: Fades the button and ignores taps.
    ///   - onAdded: Called after the cart is filled, before the user taps Done.
    ///   - onClose: Called when the sheet closes; the result when something
    ///     was added, nil otherwise.
    ///   - onError: Called when preparing or adding fails. The sheet shows it too.
    ///   - doneMessage: A line of your own on the done screen.
    ///   - doneAction: A button of your own on the done screen. Tapping it
    ///     closes the sheet, then calls its handler.
    public init(recipe: Recipe,
                store: String? = nil,
                zip: String? = nil,
                label: String? = nil,
                variant: MealioButtonVariant = .solid,
                disabled: Bool = false,
                onAdded: ((AddResult) -> Void)? = nil,
                onClose: ((AddResult?) -> Void)? = nil,
                onError: ((Error) -> Void)? = nil,
                doneMessage: String? = nil,
                doneAction: MealioDoneAction? = nil,
                onSignInRequired: (() -> Void)? = nil) {
        self.init(recipes: [recipe], store: store, zip: zip, label: label, variant: variant, disabled: disabled,
                  onAdded: onAdded, onClose: onClose, onError: onError,
                  doneMessage: doneMessage, doneAction: doneAction, onSignInRequired: onSignInRequired)
    }

    /// One cart from several recipes (at most `MAX_RECIPES`). Ingredients they
    /// share become one item, and each item says which recipes it is for.
    /// Other parameters as in `init(recipe:...)`.
    public init(recipes: [Recipe],
                store: String? = nil,
                zip: String? = nil,
                label: String? = nil,
                variant: MealioButtonVariant = .solid,
                disabled: Bool = false,
                onAdded: ((AddResult) -> Void)? = nil,
                onClose: ((AddResult?) -> Void)? = nil,
                onError: ((Error) -> Void)? = nil,
                doneMessage: String? = nil,
                doneAction: MealioDoneAction? = nil,
                onSignInRequired: (() -> Void)? = nil) {
        self.init(recipes: recipes, store: store, zip: zip, label: label, variant: variant, disabled: disabled,
                  onAdded: onAdded, onClose: onClose, onError: onError,
                  doneMessage: doneMessage, doneAction: doneAction, onSignInRequired: onSignInRequired, custom: nil)
    }

    /// Draw your own button. It keeps the whole flow and the warm-up.
    ///
    ///     MealioCartButton(recipe: recipe) { action, disabled, label in
    ///         MyButton(title: label, action: action).disabled(disabled)
    ///     }
    ///
    /// `action` opens the sheet, and does nothing while `disabled` is true.
    /// `label` is your `label:` or the `addToCart` string. Other parameters as
    /// in `init(recipe:...)`.
    public init<Content: View>(recipe: Recipe,
                               store: String? = nil,
                               zip: String? = nil,
                               label: String? = nil,
                               disabled: Bool = false,
                               onAdded: ((AddResult) -> Void)? = nil,
                               onClose: ((AddResult?) -> Void)? = nil,
                               onError: ((Error) -> Void)? = nil,
                               doneMessage: String? = nil,
                               doneAction: MealioDoneAction? = nil,
                               onSignInRequired: (() -> Void)? = nil,
                               @ViewBuilder button: @escaping (_ action: @escaping () -> Void, _ disabled: Bool, _ label: String) -> Content) {
        self.init(recipes: [recipe], store: store, zip: zip, label: label, disabled: disabled,
                  onAdded: onAdded, onClose: onClose, onError: onError,
                  doneMessage: doneMessage, doneAction: doneAction, onSignInRequired: onSignInRequired, button: button)
    }

    /// Your own button for a cart from several recipes.
    /// See `init(recipe:...button:)`.
    public init<Content: View>(recipes: [Recipe],
                               store: String? = nil,
                               zip: String? = nil,
                               label: String? = nil,
                               disabled: Bool = false,
                               onAdded: ((AddResult) -> Void)? = nil,
                               onClose: ((AddResult?) -> Void)? = nil,
                               onError: ((Error) -> Void)? = nil,
                               doneMessage: String? = nil,
                               doneAction: MealioDoneAction? = nil,
                               onSignInRequired: (() -> Void)? = nil,
                               @ViewBuilder button: @escaping (_ action: @escaping () -> Void, _ disabled: Bool, _ label: String) -> Content) {
        self.init(recipes: recipes, store: store, zip: zip, label: label, variant: .solid, disabled: disabled,
                  onAdded: onAdded, onClose: onClose, onError: onError,
                  doneMessage: doneMessage, doneAction: doneAction, onSignInRequired: onSignInRequired,
                  custom: { action, disabled, label in AnyView(button(action, disabled, label)) })
    }

    private init(recipes: [Recipe],
                 store: String?,
                 zip: String?,
                 label: String?,
                 variant: MealioButtonVariant,
                 disabled: Bool,
                 onAdded: ((AddResult) -> Void)?,
                 onClose: ((AddResult?) -> Void)?,
                 onError: ((Error) -> Void)?,
                 doneMessage: String?,
                 doneAction: MealioDoneAction?,
                 onSignInRequired: (() -> Void)?,
                 custom: ((@escaping () -> Void, Bool, String) -> AnyView)?) {
        self.recipes = recipes
        self.store = store
        self.zip = zip
        self.label = label
        self.variant = variant
        self.isDisabled = disabled
        self.onAdded = onAdded
        self.onClose = onClose
        self.onError = onError
        self.doneMessage = doneMessage
        self.doneAction = doneAction
        self.custom = custom
        self.onSignInRequired = onSignInRequired
        self._users = ObservedObject(wrappedValue: MealioCart.users)
    }

    private var shownLabel: String {
        if let label = label, !label.isEmpty { return label }
        return MealioCart.text.tr(variant == .compact ? .addToCartShort : .addToCart)
    }

    /// Who to tell when the button is tapped while nobody is signed in.
    private var signIn: (() -> Void)? {
        users.hasUser ? nil : (onSignInRequired ?? MealioCart.onSignInRequired)
    }

    /// Off when the partner says so, or while nobody is signed in and there
    /// is no sign-in to send them to.
    var disabled: Bool { isDisabled || (!users.hasUser && signIn == nil) }

    /// What a tap does: open the sheet, or ask the app to sign the user in.
    func tap() {
        if disabled { return }
        if let signIn = signIn {
            signIn()
        } else if users.hasUser {
            open = true
        }
    }

    /// The warm-up runs again when any of these change, so a button that
    /// becomes enabled, or a new user, warms too.
    struct WarmKey: Equatable {
        let store: String?
        let on: Bool
        let user: Int
    }

    var warmKey: WarmKey { WarmKey(store: store, on: !disabled && users.hasUser, user: users.generation) }

    public var body: some View {
        let key = warmKey
        return button(MealioCart.resolvedTheme(for: systemScheme), shownLabel)
            // WARM THE LOGIN CHECK while the user reads the recipe. Only for a known
            // user with a store on file: the server answers "nothing to warm"
            // otherwise. The client runs it at most once every few minutes.
            .task(id: key) {
                if key.on { await MealioCart.warm(store: key.store) }
            }
            .mealioCartFlow(isPresented: $open, recipes: recipes, store: store, zip: zip,
                            onAdded: onAdded, onError: onError, onClose: onClose,
                            doneMessage: doneMessage, doneAction: doneAction)
    }

    @ViewBuilder
    private func button(_ t: MealioTheme, _ text: String) -> some View {
        if let custom = custom {
            custom({ tap() }, disabled, text)
        } else {
            Button(action: { tap() }) {
                face(t, text)
                    .opacity(disabled ? 0.5 : 1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .accessibilityLabel(text)
        }
    }

    @ViewBuilder
    private func face(_ t: MealioTheme, _ text: String) -> some View {
        switch variant {
        case .solid:
            Text(text)
                .font(t.font(16, .bold))
                .foregroundColor(t.onAccent)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(RoundedRectangle(cornerRadius: t.radius).fill(t.accent))
        case .outline:
            Text(text)
                .font(t.font(16, .bold))
                .foregroundColor(t.accent)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(RoundedRectangle(cornerRadius: t.radius).strokeBorder(t.accent, lineWidth: 2))
        case .compact:
            Text(text)
                .font(t.font(14, .bold))
                .foregroundColor(t.onAccent)
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
                .background(RoundedRectangle(cornerRadius: t.radius).fill(t.accent))
        case .icon:
            Image(systemName: "cart")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(t.onAccent)
                .frame(width: 48, height: 48)
                .background(Circle().fill(t.accent))
        }
    }
}
#endif
