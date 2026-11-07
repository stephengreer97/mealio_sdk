// 0.1 compatibility: the list screen on its own, in a navigation bar, with an
// add callback. New integrations use MealioCartButton or .mealioCartFlow,
// which run the whole flow (sign-in, list, adding, done) in one sheet.
// Mirrors packages/react-native/src/MealioCartSheet.tsx.

#if canImport(SwiftUI) && canImport(UIKit) && canImport(WebKit)
import SwiftUI

@MainActor
public struct MealioCartSheet: View {
    @ObservedObject private var session: CartSession
    private let accentColor: Color?
    private let title: String?
    private let onFinished: (AddResult) -> Void
    private let onError: (Error) -> Void
    private let onCancel: (() -> Void)?

    @State private var adding = false
    @State private var errorText: String?
    @Environment(\.colorScheme) private var systemScheme

    /// - Parameters:
    ///   - session: From `MealioCart.prepareCart`.
    ///   - accentColor: Overrides the theme's accent for this sheet.
    ///   - title: The navigation title. Defaults to the `addToCartShort` string.
    ///   - onFinished: Called with the result after the store cart is filled.
    ///   - onError: Called when filling the cart fails. The sheet also shows it.
    ///   - onCancel: Shows a Cancel button when set.
    public init(session: CartSession,
                accentColor: Color? = nil,
                title: String? = nil,
                onFinished: @escaping (AddResult) -> Void,
                onError: @escaping (Error) -> Void = { _ in },
                onCancel: (() -> Void)? = nil) {
        self._session = ObservedObject(wrappedValue: session)
        self.accentColor = accentColor
        self.title = title
        self.onFinished = onFinished
        self.onError = onError
        self.onCancel = onCancel
    }

    private var theme: MealioTheme {
        var t = MealioCart.resolvedTheme(for: systemScheme)
        if let a = accentColor { t.accent = a }
        return t
    }

    private var ui: MealioText { MealioCart.text }

    public var body: some View {
        let t = theme
        return NavigationView {
            MealioCartList(cart: session, theme: t, busy: adding, onAdd: add)
                .padding(.top, 8)
                .background(t.background.ignoresSafeArea())
                .safeAreaInset(edge: .top) {
                    if let text = errorText {
                        MealioWarnBox(t: t, text: text)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                    }
                }
                .navigationTitle(title ?? ui.tr(.addToCartShort))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        if let onCancel = onCancel {
                            Button(ui.tr(.close)) { onCancel() }
                                .disabled(adding)
                        }
                    }
                }
        }
        .navigationViewStyle(.stack)
        .tint(t.accent)
    }

    private func add() {
        guard !adding else { return }
        adding = true
        errorText = nil
        Task { @MainActor in
            do {
                let result = try await session.addToCart()
                adding = false
                onFinished(result)
            } catch {
                adding = false
                errorText = mealioProblem(error, error is MealioError ? ui.tr(.couldNotAdd) : error.localizedDescription)
                onError(error)
            }
        }
    }
}
#endif
