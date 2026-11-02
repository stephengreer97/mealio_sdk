// The drop-in: ONE sheet that runs the whole add-to-cart flow over the
// partner's app. Loading, store sign-in, choosing a store, the list, adding,
// done.
// Mirrors packages/react-native/src/MealioCartFlow.tsx.
//
// The list shows EVERY item, every time. Remembered products come back
// pre-selected. Unchecking an item leaves it out of this run only: its
// remembered choice stays for next time. There is no skip button.

#if canImport(SwiftUI) && canImport(UIKit) && canImport(WebKit)
import Combine
import SwiftUI
import WebKit

// MARK: - Presenting

public extension View {
    /// Present the whole cart flow in one sheet.
    ///
    ///     .mealioCartFlow(isPresented: $showCart, recipe: recipe, store: "heb")
    ///
    /// `store` is optional: without it the user's default store is used, or
    /// they pick one in the sheet. `onClose` gets the result when something
    /// was added, nil otherwise.
    @MainActor
    func mealioCartFlow(isPresented: Binding<Bool>,
                        recipe: Recipe,
                        store: String? = nil,
                        zip: String? = nil,
                        onAdded: ((AddResult) -> Void)? = nil,
                        onError: ((Error) -> Void)? = nil,
                        onClose: ((AddResult?) -> Void)? = nil) -> some View {
        // VERIFY: the sheet content closure is not @MainActor in the iOS 15
        // SDK; it is formed in a @MainActor function, so Swift 5 mode infers
        // main-actor isolation for it and the MealioCartFlow init call is fine.
        sheet(isPresented: isPresented) {
            MealioCartFlow(recipe: recipe, store: store, zip: zip,
                           onAdded: onAdded, onError: onError,
                           onClose: { result in onClose?(result) })
        }
    }
}

// MARK: - The flow sheet

/// The sheet's content. Present it with `.mealioCartFlow(isPresented:...)`,
/// `MealioCartButton`, or your own `.sheet { MealioCartFlow(...) }`.
@MainActor
public struct MealioCartFlow: View {
    private let recipe: Recipe
    private let store: String?
    private let zip: String?
    private let onAdded: ((AddResult) -> Void)?
    private let onError: ((Error) -> Void)?
    private let onClose: (AddResult?) -> Void

    @StateObject private var model = MealioFlowModel()
    @Environment(\.dismiss) private var dismiss

    /// - Parameters:
    ///   - recipe: The recipe to cart.
    ///   - store: Store id from GET /api/v1/stores, e.g. "heb". Optional:
    ///     without it the user's default store is used, or they pick one.
    ///   - zip: 5-digit zip. Needed for Kroger family stores.
    ///   - onAdded: Called after the cart is filled, before the user taps Done.
    ///   - onError: Called when preparing or adding fails. The sheet shows it too.
    ///   - onClose: Called once when the sheet goes away; the result when
    ///     something was added, nil otherwise.
    public init(recipe: Recipe, store: String? = nil, zip: String? = nil,
                onAdded: ((AddResult) -> Void)? = nil,
                onError: ((Error) -> Void)? = nil,
                onClose: @escaping (AddResult?) -> Void = { _ in }) {
        self.recipe = recipe
        self.store = store
        self.zip = zip
        self.onAdded = onAdded
        self.onError = onError
        self.onClose = onClose
    }

    private var t: MealioTheme { MealioCart.theme }
    private var storeName: String {
        model.cart?.storeName ?? model.store.map { mealioStoreLabel($0) } ?? "your store"
    }

    public var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(t.border)
                .frame(width: 36, height: 5)
                .padding(.top, 8)
                .accessibilityHidden(true)
            MealioFlowHeader(t: t, recipeTitle: recipe.title,
                             title: model.login?.title ?? headerTitle,
                             onClose: { dismiss() })
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(t.background.ignoresSafeArea())
        .interactiveDismissDisabled(model.phase == .adding)
        .onAppear {
            model.open(recipe: recipe, store: store, zip: zip, onAdded: onAdded, onError: onError)
        }
        .onDisappear {
            // Close button, Done, or a swipe: all end here, exactly once.
            model.close(onClose)
        }
    }

    private var headerTitle: String {
        switch model.phase {
        case .done: return "All set"
        case .loading: return storeName == "your store" ? "Getting your cart ready" : "Getting your \(storeName) cart ready"
        case .error: return "Something went wrong"
        case .stores: return "Choose your store"
        case .list, .adding: return "Your \(storeName) list"
        }
    }

    @ViewBuilder
    private var content: some View {
        if let login = model.login {
            VStack(alignment: .leading, spacing: 0) {
                Text("Sign in on \(storeName)\u{2019}s own page. Mealio never sees your password.")
                    .font(t.font(13))
                    .foregroundColor(t.muted)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                MealioLoginWebView(webView: login.webView)
                    .id(ObjectIdentifier(login))
                    .overlay(alignment: .top) { Rectangle().fill(t.border).frame(height: 0.5) }
                    .accessibilityLabel(login.title)
            }
        } else {
            switch model.phase {
            case .loading:
                MealioLoadingView(t: t, step: model.step, storeName: storeName, count: recipe.ingredients.count)
            case .stores:
                MealioStorePicker(t: t, stores: model.stores, current: model.store,
                                  onPick: { model.pick($0) },
                                  onBack: model.canGoBackToList ? { model.backToList() } : nil)
            case .list, .adding:
                if let cart = model.cart {
                    MealioCartList(cart: cart, storeName: storeName, theme: t, busy: model.phase == .adding,
                                   onChangeStore: { model.openStores(from: .list) },
                                   onAdd: { model.add() })
                } else {
                    MealioLoadingView(t: t, step: model.step, storeName: storeName, count: recipe.ingredients.count)
                }
            case .done:
                if let cart = model.cart, let result = model.result {
                    MealioDoneView(t: t, cart: cart, result: result, storeName: storeName, onDone: { dismiss() })
                } else {
                    MealioErrorView(t: t, error: model.error, onRetry: { model.start() }, onClose: { dismiss() })
                }
            case .error:
                MealioErrorView(t: t, error: model.error, onRetry: { model.start() }, onClose: { dismiss() })
            }
        }
    }
}

// MARK: - State

@MainActor
final class MealioFlowModel: ObservableObject {
    enum Phase: Equatable { case loading, list, adding, done, error, stores }

    @Published var phase: Phase = .loading
    @Published var step: Step = .connecting
    @Published var cart: CartSession?
    @Published var result: AddResult?
    @Published var error: MealioError?
    /// The store sign-in to draw in this sheet, from the WebViewHost.
    @Published var login: LoginSheet?
    /// The store id in use: the one asked for, then the one the server chose.
    @Published var store: String?
    /// Stores for the picker; nil until loaded.
    @Published var stores: [StoreInfo]?

    private var run = 0
    private var hosting = false
    private weak var host: WebViewHost?
    private var loginSub: AnyCancellable?
    private var recipe = Recipe(id: "", ingredients: [])
    private var backTo: Phase = .list
    private var zip: String?
    private var onAdded: ((AddResult) -> Void)?
    private var onError: ((Error) -> Void)?

    // VERIFY: nonisolated so @StateObject's default value can build it; every
    // property default above is a plain constant.
    nonisolated init() {}

    func open(recipe: Recipe, store: String?, zip: String?,
              onAdded: ((AddResult) -> Void)?, onError: ((Error) -> Void)?) {
        guard !hosting else { return }
        hosting = true
        self.recipe = recipe
        self.store = store
        self.zip = zip
        self.onAdded = onAdded
        self.onError = onError
        if let host = MealioCart.host {
            self.host = host
            host.hostLogin(true)
            login = host.login
            // VERIFY: the sink closure is formed in this @MainActor method and
            // is not @Sendable, so it is main-actor isolated; WebViewHost only
            // sets `login` on the main actor, so values arrive there.
            loginSub = host.$login.sink { [weak self] value in self?.login = value }
        }
        start()
    }

    func start() {
        run += 1
        let id = run
        phase = .loading
        step = .connecting
        cart = nil
        result = nil
        error = nil
        let store = self.store, recipe = self.recipe, zip = self.zip
        Task { [weak self] in
            do {
                let c = try await MealioCart.prepareCart(store: store, recipe: recipe, zip: zip, onStep: { s, _ in
                    guard let self = self, self.run == id else { return }
                    self.step = s
                })
                guard let self = self, self.run == id else { return }
                self.store = c.store
                self.cart = c
                self.phase = .list
            } catch {
                guard let self = self, self.run == id else { return }
                if (error as? MealioError)?.code == MealioError.Code.storeRequired {
                    // No store given and no default yet: let the user pick.
                    self.openStores(from: .error)
                    return
                }
                self.fail(error)
            }
        }
    }

    /// Show the store picker. Loads the stores the first time.
    func openStores(from: Phase) {
        backTo = from
        phase = .stores
        guard stores == nil else { return }
        Task { [weak self] in
            let list: [StoreInfo]
            do { list = try await MealioCart.stores() } catch { list = [] }
            self?.stores = list
        }
    }

    /// Prepare the cart again at another store.
    func pick(_ id: String) {
        store = id
        start()
    }

    var canGoBackToList: Bool { cart != nil && backTo == .list }

    func backToList() {
        if cart != nil { phase = .list }
    }

    func add() {
        guard let cart = cart, phase == .list else { return }
        let id = run
        phase = .adding
        Task { [weak self] in
            do {
                let r = try await cart.addToCart()
                guard let self = self, self.run == id else { return }
                self.result = r
                self.phase = .done
                self.onAdded?(r)
            } catch {
                guard let self = self, self.run == id else { return }
                self.fail(error)
            }
        }
    }

    /// The sheet went away. Stops listening, cancels an open sign-in, and
    /// reports once: the result when the cart was filled, nil otherwise.
    func close(_ report: (AddResult?) -> Void) {
        guard hosting else { return }
        hosting = false
        run += 1
        let outcome = phase == .done ? result : nil
        login?.cancel()
        loginSub?.cancel()
        loginSub = nil
        login = nil
        host?.hostLogin(false)
        report(outcome)
    }

    private func fail(_ e: Error) {
        error = (e as? MealioError) ?? MealioError(code: "error", message: e.localizedDescription)
        phase = .error
        onError?(e)
    }
}

// MARK: - Pieces

/// "heb" -> "H-E-B" until the server's storeName arrives.
func mealioStoreLabel(_ id: String) -> String {
    let known = ["heb": "H-E-B", "aldi": "ALDI", "kroger": "Kroger", "safeway": "Safeway", "wegmans": "Wegmans"]
    if let k = known[id] { return k }
    return id.replacingOccurrences(of: "_", with: " ")
        .split(separator: " ")
        .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        .joined(separator: " ")
}

/// The visible store sign-in WebView, drawn in the flow sheet.
struct MealioLoginWebView: UIViewRepresentable {
    let webView: WKWebView

    // VERIFY: the WKWebView is created (and starts loading) by LoginSheet
    // before SwiftUI asks for it; returning that existing instance here is
    // what keeps its session and navigation delegate.
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

@MainActor
struct MealioFlowHeader: View {
    let t: MealioTheme
    let recipeTitle: String?
    let title: String
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let kicker = recipeTitle, !kicker.isEmpty {
                    Text(kicker)
                        .font(t.font(13, .medium))
                        .foregroundColor(t.muted)
                        .lineLimit(1)
                }
                Text(title)
                    .font(t.font(22, .bold))
                    .foregroundColor(t.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(t.text)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(t.surface))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
}

@MainActor
struct MealioLoadingView: View {
    let t: MealioTheme
    let step: Step
    let storeName: String
    let count: Int

    private var labels: [String] {
        ["Checking your \(storeName) sign-in",
         "Finding your \(count) ingredient\(count == 1 ? "" : "s")"]
    }

    /// Which row is active; -1 when the step belongs to neither (as findIndex).
    private var at: Int {
        switch step {
        case .connecting, .checkingSignIn, .signingIn: return 0
        case .searching: return 1
        case .adding: return -1
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Checking prices and stock at \(storeName).")
                .font(t.font(14))
                .foregroundColor(t.muted)
            VStack(alignment: .leading, spacing: 18) {
                ForEach(0..<2, id: \.self) { i in
                    HStack(spacing: 12) {
                        dot(i)
                        Text(labels[i])
                            .font(t.font(15, i == at ? .bold : .regular))
                            .foregroundColor(i > at ? t.muted : t.text)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(i < at ? "Done" : (i == at ? "In progress" : ""))
                }
            }
            .padding(.vertical, 12)
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: t.radius + 2)
                    .fill(t.surface)
                    .frame(height: 72)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    @ViewBuilder
    private func dot(_ i: Int) -> some View {
        if i < at {
            ZStack {
                Circle().fill(t.accent)
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundColor(t.onAccent)
            }
            .frame(width: 24, height: 24)
        } else if i == at {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(t.accent)
                .frame(width: 24, height: 24)
        } else {
            Circle()
                .strokeBorder(t.border, lineWidth: 2)
                .frame(width: 24, height: 24)
        }
    }
}

// MARK: - The list

/// The list screen on its own, for partners who host it in their own sheet.
@MainActor
public struct MealioCartList: View {
    @ObservedObject private var cart: CartSession
    private let storeNameOverride: String?
    private let themeOverride: MealioTheme?
    private let busy: Bool
    private let onChangeStore: (() -> Void)?
    private let onAdd: () -> Void
    @State private var open: String?

    /// - Parameters:
    ///   - cart: From `MealioCart.prepareCart`.
    ///   - storeName: Display name; defaults to the server's.
    ///   - theme: Defaults to `MealioCart.theme`.
    ///   - busy: Adding is in progress (spinner on the button, list locked).
    ///   - onChangeStore: When set, a tappable store chip sits above the list.
    ///   - onAdd: The Add button was tapped. Call `cart.addToCart()`.
    public init(cart: CartSession, storeName: String? = nil, theme: MealioTheme? = nil,
                busy: Bool = false, onChangeStore: (() -> Void)? = nil, onAdd: @escaping () -> Void) {
        self._cart = ObservedObject(wrappedValue: cart)
        self.storeNameOverride = storeName
        self.themeOverride = theme
        self.busy = busy
        self.onChangeStore = onChangeStore
        self.onAdd = onAdd
        // The first item needing a choice starts expanded.
        self._open = State(initialValue: cart.items.first {
            $0.status == .choose || $0.status == .rememberedUnavailable
        }?.key)
    }

    private var t: MealioTheme { themeOverride ?? MealioCart.theme }
    private var storeName: String { storeNameOverride ?? cart.storeName ?? mealioStoreLabel(cart.store) }

    public var body: some View {
        let est = cart.estimate()
        let selectable = cart.items.filter { $0.status != .unavailable }.count
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let change = onChangeStore {
                    Button(action: change) {
                        HStack(spacing: 8) {
                            Text(storeName)
                                .font(t.font(13, .semibold))
                                .foregroundColor(t.text)
                                .lineLimit(1)
                            Text("Change")
                                .font(t.font(13, .semibold))
                                .foregroundColor(t.accent)
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 36)
                        .background(Capsule().fill(t.surface))
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                    .accessibilityLabel("Store: \(storeName). Change store")
                }
                Text("\(est.count) of \(selectable) selected")
                    .font(t.font(14))
                    .foregroundColor(t.muted)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(cart.items) { item in
                        MealioItemRow(cart: cart, item: item, t: t, storeName: storeName,
                                      isOpen: open == item.key, disabled: busy,
                                      onToggleOpen: {
                                          withAnimation(.easeInOut(duration: 0.2)) {
                                              open = (open == item.key) ? nil : item.key
                                          }
                                      })
                    }
                    Text("Unchecked items are left out this time only. Your usual picks stay saved for next time. Prices from \(storeName).")
                        .font(t.font(12))
                        .foregroundColor(t.muted)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            footer(est)
        }
    }

    private func footer(_ est: CartEstimate) -> some View {
        let off = busy || est.count == 0
        let label = est.count > 0
            ? "Add \(est.count) item\(est.count == 1 ? "" : "s") to \(storeName)"
            : "Select items to add"
        let pending = cart.pendingPreferences().count
        return VStack(spacing: 8) {
            if pending > 0 {
                Text("\(pending == 1 ? "1 checked item needs" : "\(pending) checked items need") an option chosen before adding.")
                    .font(t.font(12))
                    .foregroundColor(t.warnText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 6)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(est.estimated ? "Estimated total" : "Total")
                    .font(t.font(14))
                    .foregroundColor(t.muted)
                Spacer()
                Text((est.estimated ? "about " : "") + mealioMoney(est.total))
                    .font(t.font(18, .bold))
                    .foregroundColor(t.text)
            }
            .accessibilityElement(children: .combine)
            MealioCTA(t: t, title: label, busy: busy, enabled: !off, action: onAdd)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(t.background)
        .overlay(alignment: .top) { Rectangle().fill(t.border).frame(height: 1) }
    }
}

@MainActor
struct MealioItemRow: View {
    @ObservedObject private var cart: CartSession
    private let item: CartItem
    private let t: MealioTheme
    private let storeName: String
    private let isOpen: Bool
    private let disabled: Bool
    private let onToggleOpen: () -> Void
    @State private var query = ""
    @State private var searching = false
    @State private var searchNote: String?

    init(cart: CartSession, item: CartItem, t: MealioTheme, storeName: String, isOpen: Bool,
         disabled: Bool, onToggleOpen: @escaping () -> Void) {
        self._cart = ObservedObject(wrappedValue: cart)
        self.item = item
        self.t = t
        self.storeName = storeName
        self.isOpen = isOpen
        self.disabled = disabled
        self.onToggleOpen = onToggleOpen
    }

    private var cardShape: RoundedRectangle { RoundedRectangle(cornerRadius: t.radius + 2) }

    var body: some View {
        if item.status == .unavailable {
            unavailableCard
        } else {
            card
        }
    }

    private var unavailableCard: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(t.border, lineWidth: 2)
                .frame(width: 24, height: 24)
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.ingredient)
                    .font(t.font(12, .medium))
                    .foregroundColor(t.muted)
                    .lineLimit(1)
                Text("Not found at \(storeName)")
                    .font(t.font(14))
                    .foregroundColor(t.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .padding(.trailing, 6)
        .background(t.background)
        .clipShape(cardShape)
        .overlay(cardShape.strokeBorder(t.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var card: some View {
        let on = cart.isSelected(item.key)
        let picked = cart.selected(for: item.key)
        let options = cart.options(for: item.key)
        let shown = picked ?? (item.status == .remembered ? item.remembered : nil)
        let changeLabel = isOpen ? "Done" : ((on || item.status == .remembered) ? "Change" : "Choose")

        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: { toggle(on: on) }) {
                    ZStack {
                        if on {
                            RoundedRectangle(cornerRadius: 7).fill(t.accent)
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .heavy))
                                .foregroundColor(t.onAccent)
                        } else {
                            RoundedRectangle(cornerRadius: 7).strokeBorder(t.muted, lineWidth: 2)
                        }
                    }
                    .frame(width: 24, height: 24)
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(disabled)
                .accessibilityLabel((on ? "Leave out " : "Add ") + item.ingredient)
                .accessibilityValue(on ? "Checked" : "Not checked")
                .accessibilityAddTraits(on ? .isSelected : [])

                MealioThumb(t: t, product: shown ?? options.first, dim: !on, big: false)

                Button(action: onToggleOpen) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.ingredient)
                            .font(t.font(12, .medium))
                            .foregroundColor(t.muted)
                            .lineLimit(1)
                        Text(shown?.name ?? "Choose a product")
                            .font(t.font(15, .semibold))
                            .foregroundColor(on ? t.text : t.muted)
                            // Struck through ONLY when the user unchecked their usual.
                            .strikethrough(!on && shown != nil, color: t.muted)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(meta(on: on, picked: picked, options: options))
                            .font(t.font(12))
                            .foregroundColor(t.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows the options")

                Button(action: onToggleOpen) {
                    Text(changeLabel)
                        .font(t.font(14, .semibold))
                        .foregroundColor(t.accent)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(isOpen ? "Hides the options" : "Shows the options")
            }
            .padding(.vertical, 10)
            .padding(.trailing, 6)

            if on, let picked = picked, cart.needsPreference(item.key) {
                Text("Choose one: \(mealioListOr((picked.preferences ?? []).map(\.label)))")
                    .font(t.font(13, .semibold))
                    .foregroundColor(t.accent)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            if on, let picked = picked {
                quantityRow(picked: picked)
            }

            if item.status == .rememberedUnavailable && !on {
                MealioWarnBox(t: t, text: rememberedUnavailableText)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }

            if isOpen {
                expanded(picked: picked, options: options)
            }
        }
        .background(t.background)
        .clipShape(cardShape)
        .overlay(cardShape.strokeBorder(isOpen ? t.muted : t.border, lineWidth: 1))
    }

    /// Sold by weight: the stepper is pounds, stepping through the store's
    /// weights (else 0.25 lb). Otherwise a count, clamped to the store cap.
    private func quantityRow(picked: Product) -> some View {
        let byWeight = picked.soldByWeight == true
        let range = cart.weightRange(for: item.key)
        let lb = byWeight ? cart.weight(for: item.key) : 0
        let n = cart.quantity(for: item.key)
        let atMin = byWeight ? lb <= range.lowerBound : n <= 1
        let atMax = byWeight ? lb >= range.upperBound : n >= cart.maxQuantity(for: item.key)
        let step: (Int) -> Void = { dir in
            if byWeight {
                _ = cart.stepWeight(key: item.key, by: dir)
            } else {
                _ = cart.setQuantity(key: item.key, to: n + dir)
            }
        }
        return HStack {
            Text(byWeight ? "Weight" : "Quantity")
                .font(t.font(12))
                .foregroundColor(t.muted)
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                stepButton("\u{2212}", label: "Less \(item.ingredient)", off: atMin) { step(-1) }
                Text(byWeight ? mealioLbText(lb) : "\(n)")
                    .font(t.font(16, .bold))
                    .foregroundColor(t.text)
                    .frame(minWidth: byWeight ? 64 : 28)
                    .multilineTextAlignment(.center)
                    .accessibilityLabel(byWeight ? "Weight \(mealioLbText(lb))" : "Quantity \(n)")
                stepButton("+", label: "More \(item.ingredient)", off: atMax) { step(1) }
            }
        }
        .padding(.leading, 58)
        .padding(.trailing, 12)
        .padding(.bottom, 10)
    }

    private func stepButton(_ glyph: String, label: String, off: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(glyph)
                .font(t.font(20, .semibold))
                .foregroundColor(t.text)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 10).fill(t.surface))
                .contentShape(Rectangle())
                .opacity(off ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled || off)
        .accessibilityLabel(label)
    }

    private var rememberedUnavailableText: String {
        let name = item.remembered.map { ", \($0.name)," } ?? ""
        let state = item.reason == "not_found" ? "not available" : "out of stock"
        return "Your usual\(name) is \(state) today. Pick another for this run. It stays your usual."
    }

    private func meta(on: Bool, picked: Product?, options: [Product]) -> String {
        if let p = picked {
            let parts: [String?] = [mealioPriceText(p), p.id == item.remembered?.id ? "Your usual" : nil]
            return parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
        }
        switch item.status {
        case .remembered: return "Not adding this time"
        case .rememberedUnavailable: return "Your usual is out of stock"
        default: return "\(options.count) option\(options.count == 1 ? "" : "s")"
        }
    }

    private func expanded(picked: Product?, options: [Product]) -> some View {
        let placeholder = "Search \(storeName) for something else"
        return VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(options) { o in
                        optionCard(o, selected: picked?.id == o.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
            }

            if let picked = picked, let prefs = picked.preferences, !prefs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(prefs) { pref in
                            let sel = cart.preferenceId(for: item.key) == pref.id
                            Button(action: { pick(picked, preferenceId: pref.id) }) {
                                Text(pref.label)
                                    .font(t.font(13))
                                    .foregroundColor(sel ? t.onAccent : t.text)
                                    .padding(.horizontal, 12)
                                    .frame(minHeight: 36)
                                    .background(Capsule().fill(sel ? t.accent : t.surface))
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(disabled)
                            .accessibilityAddTraits(sel ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }

            HStack(spacing: 8) {
                ZStack(alignment: .leading) {
                    if query.isEmpty {
                        Text(placeholder)
                            .font(t.font(14))
                            .foregroundColor(t.muted)
                            .lineLimit(1)
                            .accessibilityHidden(true)
                    }
                    TextField("", text: $query)
                        .font(t.font(14))
                        .foregroundColor(t.text)
                        .submitLabel(.search)
                        .onSubmit { runSearch() }
                        .disableAutocorrection(true)
                        .disabled(disabled)
                        .accessibilityLabel(placeholder)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(RoundedRectangle(cornerRadius: max(0, t.radius - 2)).fill(t.surface))

                Button(action: runSearch) {
                    ZStack {
                        if searching {
                            ProgressView().progressViewStyle(.circular).tint(.white)
                        } else {
                            Text("Search")
                                .font(t.font(14, .semibold))
                                .foregroundColor(.white)
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(minWidth: 76, minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: max(0, t.radius - 2)).fill(t.text))
                }
                .buttonStyle(.plain)
                .disabled(searching || disabled)
                .accessibilityLabel(searching ? "Searching" : "Search")
            }
            .padding(.horizontal, 12)

            if let note = searchNote {
                Text(note)
                    .font(t.font(12))
                    .foregroundColor(t.muted)
                    .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Rectangle().fill(t.border).frame(height: 1) }
    }

    private func optionCard(_ o: Product, selected sel: Bool) -> some View {
        let usual = o.id == item.remembered?.id
        let price = o.outOfStock == true ? "Out of stock" : mealioPriceText(o)
        let shape = RoundedRectangle(cornerRadius: t.radius)
        return Button(action: { pick(o, preferenceId: nil) }) {
            VStack(alignment: .leading, spacing: 6) {
                MealioThumb(t: t, product: o, dim: false, big: true)
                Text(o.name)
                    .font(t.font(13, .medium))
                    .foregroundColor(o.outOfStock == true ? t.muted : t.text)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(price)
                    .font(t.font(13, .semibold))
                    .foregroundColor(t.text)
                if usual {
                    Text("Your usual").font(t.font(11, .bold)).foregroundColor(t.accent)
                } else if o.badge == "popular" {
                    Text("Popular").font(t.font(11, .bold)).foregroundColor(t.muted)
                }
            }
            .padding(10)
            .frame(width: 136, alignment: .topLeading)
            .background(shape.fill(t.background))
            .overlay(shape.strokeBorder(sel ? t.accent : t.border, lineWidth: sel ? 2 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(sel ? [.isButton, .isSelected] : .isButton)
    }

    private func toggle(on: Bool) {
        guard !disabled else { return }
        if on {
            cart.deselect(key: item.key)
        } else if item.status == .remembered, let id = item.selectedId {
            try? cart.select(key: item.key, productId: id, preferenceId: item.rememberedPreferenceId)
        } else if !isOpen {
            onToggleOpen()
        }
    }

    private func pick(_ p: Product, preferenceId: String?) {
        guard !disabled else { return }
        try? cart.select(key: item.key, productId: p.id, preferenceId: preferenceId)
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2, !searching else { return }
        searching = true
        searchNote = nil
        let cart = self.cart
        let key = item.key
        Task { @MainActor in
            do {
                let found = try await cart.search(key: key, query: q)
                searchNote = found.isEmpty ? "Nothing found for \"\(q)\"." : nil
                query = ""
            } catch {
                searchNote = (error as? MealioError)?.message ?? "Search failed. Try again."
            }
            searching = false
        }
    }
}

@MainActor
struct MealioThumb: View {
    let t: MealioTheme
    let product: Product?
    let dim: Bool
    let big: Bool

    var body: some View {
        Group {
            if let s = product?.imageUrl, let url = URL(string: s) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Color.white
                }
                .background(Color.white)
            } else {
                t.surface
            }
        }
        .frame(width: big ? nil : 48, height: big ? 72 : 48)
        .frame(maxWidth: big ? .infinity : nil)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .opacity(dim ? 0.45 : 1)
        .accessibilityHidden(true)
    }
}

@MainActor
struct MealioWarnBox: View {
    let t: MealioTheme
    let text: String

    var body: some View {
        Text(text)
            .font(t.font(13))
            .foregroundColor(t.warnText)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(t.warnBackground))
    }
}

/// The big button: accent fill, spinner when busy, faded when off.
@MainActor
struct MealioCTA: View {
    let t: MealioTheme
    let title: String
    var busy = false
    var enabled = true
    var quiet = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if busy {
                    ProgressView().progressViewStyle(.circular).tint(t.onAccent)
                } else {
                    Text(title)
                        .font(t.font(16, .bold))
                        .foregroundColor(quiet ? t.text : t.onAccent)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(RoundedRectangle(cornerRadius: t.radius).fill(quiet ? t.surface : t.accent))
            .opacity(enabled || busy ? 1 : 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled || busy)
        .accessibilityLabel(busy ? "Adding" : title)
    }
}

// MARK: - Done

@MainActor
struct MealioDoneView: View {
    @ObservedObject var cart: CartSession
    let t: MealioTheme
    let result: AddResult
    let storeName: String
    let onDone: () -> Void

    init(t: MealioTheme, cart: CartSession, result: AddResult, storeName: String, onDone: @escaping () -> Void) {
        self._cart = ObservedObject(wrappedValue: cart)
        self.t = t
        self.result = result
        self.storeName = storeName
        self.onDone = onDone
    }

    private var title: String {
        let n = result.added.count
        return n > 0 ? "Added \(n) item\(n == 1 ? "" : "s") to \(storeName)" : "Nothing was added to \(storeName)"
    }

    private var failedText: String {
        let n = result.failed.count
        let list = result.failed.map { "\($0.name) (\(mealioReasonText($0.reason)))" }.joined(separator: ", ")
        return "\(n) item\(n == 1 ? "" : "s") could not be added: \(list)."
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(spacing: 12) {
                        ZStack {
                            Circle().fill(t.surface)
                            Image(systemName: "checkmark")
                                .font(.system(size: 28, weight: .heavy))
                                .foregroundColor(t.accent)
                        }
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                        Text(title)
                            .font(t.font(22, .bold))
                            .foregroundColor(t.text)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)

                    if !result.failed.isEmpty {
                        MealioWarnBox(t: t, text: failedText)
                    }

                    ForEach(result.added, id: \.key) { a in
                        row(name: a.name + (a.weightLb.map { ", \(mealioLbText($0))" } ?? ""),
                            value: cart.selected(for: a.key).map(mealioPriceText) ?? "", muted: false)
                    }
                    ForEach(result.skipped.filter { $0.reason == "deselected" }, id: \.key) { s in
                        row(name: cart.items.first { $0.key == s.key }?.ingredient ?? s.key, value: "Left out", muted: true)
                    }
                }
                .padding(20)
            }
            MealioCTA(t: t, title: "Done", action: onDone)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 12)
                .overlay(alignment: .top) { Rectangle().fill(t.border).frame(height: 1) }
        }
    }

    private func row(name: String, value: String, muted: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(name)
                .font(t.font(14))
                .foregroundColor(muted ? t.muted : t.text)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(value)
                .font(muted ? t.font(14) : t.font(14, .bold))
                .foregroundColor(muted ? t.muted : t.text)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(t.border).frame(height: 0.5) }
        .accessibilityElement(children: .combine)
    }
}

/// A failed add's reason in plain words.
func mealioReasonText(_ r: String) -> String {
    if r == "not_confirmed" { return "not confirmed in your cart" }
    if r == "weight_not_supported" { return "sold by weight, which this store cannot take here" }
    if r.contains("stock") { return "out of stock" }
    if r.contains("timeout") || r.contains("no_answer") { return "the store did not answer" }
    return "the store refused it"
}

/// "0.75 lb", "1 lb": at most two decimals, no trailing zeros.
func mealioLbText(_ lb: Double) -> String {
    var s = String(format: "%.2f", lb)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return "\(s) lb"
}

/// The price as a row shows it. Sold by the pound: "$9.99/lb est.".
func mealioPriceText(_ p: Product) -> String {
    if p.soldByWeight == true, let perLb = p.pricePerLb { return "\(mealioMoney(perLb))/lb est." }
    return "\(p.price ?? "")\(p.estimated ? " est." : "")".trimmingCharacters(in: .whitespaces)
}

/// "A, B or C".
func mealioListOr(_ xs: [String]) -> String {
    guard xs.count > 1, let last = xs.last else { return xs.first ?? "" }
    return "\(xs.dropLast().joined(separator: ", ")) or \(last)"
}

// MARK: - Store picker

@MainActor
struct MealioStorePicker: View {
    let t: MealioTheme
    let stores: [StoreInfo]?
    let current: String?
    let onPick: (String) -> Void
    let onBack: (() -> Void)?

    var body: some View {
        if let stores = stores {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 10) {
                        if stores.isEmpty {
                            Text("Could not load stores. Close and try again.")
                                .font(t.font(14))
                                .foregroundColor(t.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(stores) { st in
                            row(st, isCurrent: st.id == current)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 2)
                    .padding(.bottom, 24)
                }
                if let back = onBack {
                    MealioCTA(t: t, title: "Back to your list", quiet: true, action: back)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .overlay(alignment: .top) { Rectangle().fill(t.border).frame(height: 1) }
                }
            }
        } else {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(t.accent)
                .frame(maxWidth: .infinity)
                .padding(20)
        }
    }

    private func row(_ st: StoreInfo, isCurrent: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: t.radius)
        return Button(action: { onPick(st.id) }) {
            HStack {
                Text(st.name)
                    .font(t.font(15, .semibold))
                    .foregroundColor(t.text)
                Spacer()
                if isCurrent {
                    Text("Current")
                        .font(t.font(12))
                        .foregroundColor(t.accent)
                }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(shape.fill(t.background))
            .overlay(shape.strokeBorder(isCurrent ? t.accent : t.border, lineWidth: isCurrent ? 2 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Error

@MainActor
struct MealioErrorView: View {
    let t: MealioTheme
    let error: MealioError?
    let onRetry: () -> Void
    let onClose: () -> Void

    private var message: String {
        if error?.code == MealioError.Code.loginCancelled { return "Sign-in was closed before it finished." }
        if let m = error?.message, !m.isEmpty { return m }
        return "Something went wrong."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(message)
                .font(t.font(15))
                .foregroundColor(t.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            MealioCTA(t: t, title: "Try again", action: onRetry)
            MealioCTA(t: t, title: "Close", quiet: true, action: onClose)
        }
        .padding(20)
    }
}
#endif
