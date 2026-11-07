// The drop-in: ONE sheet that runs the whole add-to-cart flow over the
// partner's app. Loading, store sign-in, choosing a store and a Kroger family
// location, the list, adding, done.
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
    /// was added, nil otherwise. `doneMessage` and `doneAction` add a line and
    /// a button of your own to the done screen.
    @MainActor
    func mealioCartFlow(isPresented: Binding<Bool>,
                        recipe: Recipe,
                        store: String? = nil,
                        zip: String? = nil,
                        onAdded: ((AddResult) -> Void)? = nil,
                        onError: ((Error) -> Void)? = nil,
                        onClose: ((AddResult?) -> Void)? = nil,
                        doneMessage: String? = nil,
                        doneAction: MealioDoneAction? = nil) -> some View {
        mealioCartFlow(isPresented: isPresented, recipes: [recipe], store: store, zip: zip,
                       onAdded: onAdded, onError: onError, onClose: onClose,
                       doneMessage: doneMessage, doneAction: doneAction)
    }

    /// Present the whole cart flow for several recipes (at most `MAX_RECIPES`)
    /// in one sheet. Ingredients they share become one item, each item says
    /// which recipes it is for, and a pick is remembered under every one of them.
    ///
    ///     .mealioCartFlow(isPresented: $showCart, recipes: [tacos, pasta])
    @MainActor
    func mealioCartFlow(isPresented: Binding<Bool>,
                        recipes: [Recipe],
                        store: String? = nil,
                        zip: String? = nil,
                        onAdded: ((AddResult) -> Void)? = nil,
                        onError: ((Error) -> Void)? = nil,
                        onClose: ((AddResult?) -> Void)? = nil,
                        doneMessage: String? = nil,
                        doneAction: MealioDoneAction? = nil) -> some View {
        // VERIFY: the sheet content closure is not @MainActor in the iOS 15
        // SDK; it is formed in a @MainActor function, so Swift 5 mode infers
        // main-actor isolation for it and the MealioCartFlow init call is fine.
        mealioPresent(isPresented: isPresented) {
            MealioCartFlow(recipes: recipes, store: store, zip: zip,
                           onAdded: onAdded, onError: onError,
                           onClose: { result in onClose?(result) },
                           doneMessage: doneMessage, doneAction: doneAction)
        }
    }
}

// MARK: - The flow sheet

/// The sheet's content. Present it with `.mealioCartFlow(isPresented:...)`,
/// `MealioCartButton`, or your own `.sheet { MealioCartFlow(...) }`.
@MainActor
public struct MealioCartFlow: View {
    private let recipes: [Recipe]
    private let store: String?
    private let zip: String?
    private let onAdded: ((AddResult) -> Void)?
    private let onError: ((Error) -> Void)?
    private let onClose: (AddResult?) -> Void
    private let doneMessage: String?
    private let doneAction: MealioDoneAction?

    @StateObject private var model = MealioFlowModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var systemScheme

    /// - Parameters:
    ///   - recipe: The recipe to cart.
    ///   - store: Store id from GET /api/v1/stores, e.g. "heb". Optional:
    ///     without it the user's default store is used, or they pick one.
    ///   - zip: 5-digit zip, if you know it. Fills the zip box when a Kroger
    ///     family store asks the user which store they shop at. Without it,
    ///     they type it in.
    ///   - onAdded: Called after the cart is filled, before the user taps Done.
    ///   - onError: Called when preparing or adding fails. The sheet shows it too.
    ///   - onClose: Called once when the sheet goes away; the result when
    ///     something was added, nil otherwise.
    ///   - doneMessage: A line of your own on the done screen, like "Enjoy your meal!".
    ///   - doneAction: A button of your own on the done screen. It becomes the
    ///     main button. Tapping it closes the sheet, then calls its handler.
    public init(recipe: Recipe, store: String? = nil, zip: String? = nil,
                onAdded: ((AddResult) -> Void)? = nil,
                onError: ((Error) -> Void)? = nil,
                onClose: @escaping (AddResult?) -> Void = { _ in },
                doneMessage: String? = nil,
                doneAction: MealioDoneAction? = nil) {
        self.init(recipes: [recipe], store: store, zip: zip,
                  onAdded: onAdded, onError: onError, onClose: onClose,
                  doneMessage: doneMessage, doneAction: doneAction)
    }

    /// One cart from several recipes (at most `MAX_RECIPES`). Ingredients
    /// they share become one item, each item says which recipes it is for,
    /// and a pick is remembered under every one of them. Other parameters as
    /// in `init(recipe:...)`.
    public init(recipes: [Recipe], store: String? = nil, zip: String? = nil,
                onAdded: ((AddResult) -> Void)? = nil,
                onError: ((Error) -> Void)? = nil,
                onClose: @escaping (AddResult?) -> Void = { _ in },
                doneMessage: String? = nil,
                doneAction: MealioDoneAction? = nil) {
        self.recipes = recipes
        self.store = store
        self.zip = zip
        self.onAdded = onAdded
        self.onError = onError
        self.onClose = onClose
        self.doneMessage = doneMessage
        self.doneAction = doneAction
    }

    private var t: MealioTheme { MealioCart.resolvedTheme(for: systemScheme) }
    private var ui: MealioText { MealioCart.text }
    /// The recipe's title for one recipe, "3 meals" for several.
    private var kicker: String? {
        if recipes.count == 1 { return recipes[0].title }
        return recipes.count > 1 ? ui.tr(.meals, ["count": String(recipes.count)]) : nil
    }
    /// Ingredient lines across every recipe, for the loading screen.
    private var lineCount: Int { recipes.reduce(0) { $0 + $1.ingredients.count } }
    private var storeName: String {
        model.cart?.storeName ?? model.store.map { mealioStoreLabel($0) } ?? ui.tr(.yourStore)
    }
    /// False while there is only the "your store" stand-in.
    private var named: Bool { model.cart?.storeName != nil || model.store != nil }

    public var body: some View {
        let _ = model.latest(onAdded: onAdded, onError: onError)
        VStack(spacing: 0) {
            MealioGrabber(t: t)
            MealioFlowHeader(t: t, recipeTitle: kicker, photos: mealioRecipePhotos(recipes),
                             title: model.login?.title ?? headerTitle,
                             onClose: { requestClose() },
                             closeDisabled: model.phase == .adding && model.login == nil)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(t.background.ignoresSafeArea())
        .interactiveDismissDisabled(model.phase == .adding)
        .mealioSheetSize()
        .onAppear {
            model.open(recipes: recipes, store: store, zip: zip, onAdded: onAdded, onError: onError)
        }
        .onChange(of: store) { next in model.storeChanged(next) }
        .onChange(of: model.closeRequested) { asked in
            if asked { requestClose() }
        }
        .onDisappear {
            // A swipe, or the partner hiding the sheet, ends here. A button
            // reported already; this is then a no-op but for the done action.
            model.close(onClose)
        }
    }

    /// Every close button lands here. `onClose` fires now, from the button,
    /// so it fires even where `dismiss` does nothing (a UIKit host: dismiss
    /// your hosting controller in `onClose`). While adding nothing closes, but
    /// a sign-in the add asked for can still be dismissed.
    private func requestClose() {
        guard model.canClose else {
            model.login?.cancel()
            return
        }
        model.closeFromButton(onClose)
        dismiss()
    }

    private var headerTitle: String {
        let store = ["store": storeName]
        switch model.phase {
        case .done: return named ? ui.tr(.titleInCart, store) : ui.tr(.titleInCartPlain)
        case .loading: return named ? ui.tr(.titleLoading, store) : ui.tr(.titleLoadingPlain)
        case .error: return ui.tr(.somethingWrong)
        case .stores: return ui.tr(.titleStores)
        case .location: return ui.tr(.titleLocation, store)
        case .list, .adding: return ui.tr(.titleList, store)
        }
    }

    private var locationBack: MealioLocationPicker.Back {
        if model.canGoBackToList {
            return MealioLocationPicker.Back(label: ui.tr(.backToList), action: { model.backToList() })
        }
        return MealioLocationPicker.Back(label: ui.tr(.differentStore), action: { model.openStores(from: .error) })
    }

    @ViewBuilder
    private var content: some View {
        if let login = model.login {
            VStack(alignment: .leading, spacing: 0) {
                Text(ui.tr(.loginNote, ["store": storeName]))
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
                MealioLoadingView(t: t, step: model.step, storeName: storeName, count: lineCount)
            case .stores:
                MealioStorePicker(t: t, stores: model.stores, current: model.store,
                                  onPick: { model.pick($0) },
                                  onBack: model.canGoBackToList ? { model.backToList() } : nil)
            case .location:
                if let store = model.store {
                    let visit = model.locationVisit
                    MealioLocationPicker(t: t, store: store, storeName: storeName,
                                         zip: model.locationZip, current: model.cart?.location?.id,
                                         onPicked: { _ in model.locationPicked(visit: visit) },
                                         back: locationBack)
                } else {
                    MealioErrorView(t: t, error: model.error, onRetry: { model.start() }, onClose: { requestClose() })
                }
            case .list, .adding:
                if let cart = model.cart {
                    MealioCartList(cart: cart, storeName: storeName, theme: t, busy: model.phase == .adding,
                                   onChangeStore: { model.openStores(from: .list) },
                                   onChangeLocation: { model.openLocation(from: .list) },
                                   onAdd: { model.add() })
                } else {
                    MealioLoadingView(t: t, step: model.step, storeName: storeName, count: lineCount)
                }
            case .done:
                if let cart = model.cart, let result = model.result {
                    MealioDoneView(t: t, cart: cart, result: result, storeName: storeName, onDone: { requestClose() },
                                   message: doneMessage, actionLabel: doneAction?.label,
                                   onAction: {
                                       guard let action = doneAction else { return }
                                       model.afterClose { action.handler(result) }
                                       requestClose()
                                   })
                } else {
                    MealioErrorView(t: t, error: model.error, onRetry: { model.start() }, onClose: { requestClose() })
                }
            case .error:
                MealioErrorView(t: t, error: model.error,
                                note: model.failedAdd != nil ? ui.tr(.addFailedNote) : nil,
                                onRetry: { model.start() }, onClose: { requestClose() })
            }
        }
    }
}

// MARK: - State

@MainActor
final class MealioFlowModel: ObservableObject {
    enum Phase: Equatable { case loading, list, adding, done, error, stores, location }

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
    /// The cart of an add that failed, so Try again keeps the user's picks.
    @Published private(set) var failedAdd: CartSession?
    /// Set when the sheet should close itself (the user changed).
    @Published private(set) var closeRequested = false

    private var run = 0
    /// The prepare under way, so closing can stop it.
    private var preparing: CancelToken?
    /// Bumped each time the location step opens, so a save that finishes after
    /// the user left the step starts nothing.
    private(set) var locationVisit = 0
    /// The user the sheet was opened for (MealioCart's user generation).
    private var openedFor = 0
    private var userSub: AnyCancellable?
    /// The user changed during an add: close once it ends.
    private var closeAfterAdd = false
    private var hosting = false
    private weak var host: WebViewHost?
    private var loginSub: AnyCancellable?
    private var recipes: [Recipe] = []
    private var backTo: Phase = .list
    private var zip: String?
    private var onAdded: ((AddResult) -> Void)?
    private var onError: ((Error) -> Void)?
    private var runAfterClose: (() -> Void)?

    // VERIFY: nonisolated so @StateObject's default value can build it; every
    // property default above is a plain constant.
    nonisolated init() {}

    func open(recipes: [Recipe], store: String?, zip: String?,
              onAdded: ((AddResult) -> Void)?, onError: ((Error) -> Void)?) {
        guard !hosting else { return }
        hosting = true
        self.recipes = recipes
        self.store = store
        self.zip = zip
        self.onAdded = onAdded
        self.onError = onError
        failedAdd = nil
        closeRequested = false
        closeAfterAdd = false
        openedFor = MealioCart.users.generation
        // VERIFY: as loginSub below, formed in this @MainActor method.
        userSub = MealioCart.users.$generation.sink { [weak self] gen in self?.userChanged(gen) }
        MealioCart.emit(.sheetOpened(recipes: recipes.count))
        if let host = MealioCart.host {
            self.host = host
            host.hostLogin(true)
            loginChanged(host.login)
            // VERIFY: the sink closure is formed in this @MainActor method and
            // is not @Sendable, so it is main-actor isolated; WebViewHost only
            // sets `login` on the main actor, so values arrive there.
            loginSub = host.$login.sink { [weak self] value in self?.loginChanged(value) }
        }
        start()
    }

    /// Callbacks change with the partner's view: the latest are always the
    /// ones called. Nothing here is published, so it is safe from `body`.
    func latest(onAdded: ((AddResult) -> Void)?, onError: ((Error) -> Void)?) {
        self.onAdded = onAdded
        self.onError = onError
    }

    /// The partner's `store` changed while the sheet is up: a cart still
    /// loading moves to it, and Try again uses it. A finished list stays.
    func storeChanged(_ next: String?) {
        guard hosting else { return }
        if phase == .loading {
            store = next
            start()
        } else if phase == .error {
            store = next
        }
    }

    /// What is on screen was the old user's. An add finishes first.
    private func userChanged(_ gen: Int) {
        guard hosting, gen != openedFor else { return }
        failedAdd = nil
        if phase == .adding {
            closeAfterAdd = true
        } else {
            closeRequested = true
        }
    }

    /// False while adding: an add cannot be stopped, so the sheet stays.
    var canClose: Bool { phase != .adding }

    /// The sign-in coming up is the event. One replacing another is not.
    func loginChanged(_ value: LoginSheet?) {
        let shown = login == nil && value != nil
        login = value
        if shown { MealioCart.emit(.signinShown(store: store)) }
    }

    /// The step the user is on, for `error` and `sheet_closed`.
    var sheetStep: MealioSheetStep {
        if login != nil { return .signin }
        switch phase {
        case .loading: return .loading
        case .list: return .list
        case .adding: return .adding
        case .done: return .done
        case .error: return .error
        case .stores: return .stores
        case .location: return .location
        }
    }

    func start() {
        run += 1
        let id = run
        preparing?.cancel()
        let cancel = CancelToken()
        preparing = cancel
        phase = .loading
        step = .connecting
        cart = nil
        result = nil
        error = nil
        let store = self.store, recipes = self.recipes
        Task { [weak self] in
            do {
                // No zip: which store the user shops at is theirs to say, so the
                // partner's zip only fills the box on the location step.
                let c = try await MealioCart.prepareCart(store: store, recipes: recipes, cancel: cancel, onStep: { s, _ in
                    guard let self = self, self.run == id else { return }
                    self.step = s
                })
                guard let self = self, self.run == id else { return }
                if let old = self.failedAdd {
                    c.restorePicks(from: old)
                    self.failedAdd = nil
                }
                self.store = c.store
                self.cart = c
                self.phase = .list
                MealioCart.emit(.listShown(store: c.store, items: c.items.count))
            } catch {
                guard let self = self, self.run == id else { return }
                let code = (error as? MealioError)?.code
                // Stopped on purpose: nothing to report.
                if code == MealioError.Code.cancelled { return }
                if code == MealioError.Code.storeRequired || code == MealioError.Code.storeNotAllowed {
                    // No store given, or one this app does not offer: let the user pick.
                    self.store = nil
                    self.openStores(from: .error)
                    return
                }
                if code == MealioError.Code.locationRequired {
                    // Which store the user shops at is theirs to say. With no store
                    // named there is nothing to look up, so they pick the chain first.
                    if store != nil { self.openLocation(from: .error) } else { self.openStores(from: .error) }
                    return
                }
                self.fail(error, step: .loading)
            }
        }
    }

    /// Show the store picker. Loads the stores the first time, and again
    /// after a load that failed.
    func openStores(from: Phase) {
        backTo = from
        phase = .stores
        // An empty list is a load that failed: try again each time.
        if let loaded = stores, !loaded.isEmpty { return }
        stores = nil
        Task { [weak self] in
            let list: [StoreInfo]
            do { list = try await MealioCart.stores() } catch { list = [] }
            self?.stores = list
        }
    }

    /// Show the zip and location step for `store`.
    func openLocation(from: Phase) {
        if let store = store { MealioCart.emit(.locationAsked(store: store)) }
        backTo = from
        locationVisit += 1
        phase = .location
    }

    /// The zip the location step starts with.
    var locationZip: String? { cart?.location?.zip ?? zip }

    /// The user chose a store and it is saved: restart the cart there. Nothing
    /// to restart if the sheet closed, or the user left the location step,
    /// while the choice was saving. `visit` is the step the pick was made on.
    func locationPicked(visit: Int? = nil) {
        guard hosting, phase == .location, visit == nil || visit == locationVisit else { return }
        start()
    }

    /// Prepare the cart again at another store.
    func pick(_ id: String) {
        MealioCart.emit(.storePicked(store: id))
        store = id
        start()
    }

    var canGoBackToList: Bool { cart != nil && backTo == .list }

    func backToList() {
        if cart != nil { phase = .list }
    }

    func add() {
        guard let cart = cart, phase == .list, !cart.searching else { return }
        let id = run
        phase = .adding
        MealioCart.emit(.addStarted(items: cart.estimate().count))
        Task { [weak self] in
            do {
                let r = try await cart.addToCart()
                guard let self = self, self.run == id else { return }
                self.result = r
                self.phase = .done
                MealioCart.emit(.cartAdded(store: r.store, added: r.added.count, failed: r.failed.count))
                self.onAdded?(r)
                self.afterAdd()
            } catch {
                guard let self = self, self.run == id else { return }
                self.failedAdd = cart
                self.fail(error, step: .adding, fallback: MealioCart.text.tr(.couldNotAdd))
                self.afterAdd()
            }
        }
    }

    /// The user changed while adding: now the sheet can close.
    private func afterAdd() {
        guard closeAfterAdd else { return }
        closeAfterAdd = false
        failedAdd = nil
        closeRequested = true
    }

    /// Run `action` once the sheet has gone, after `onClose`. Waiting matters:
    /// a partner's handler may present something, and a sheet still sliding
    /// away would refuse it.
    func afterClose(_ action: @escaping () -> Void) {
        guard runAfterClose == nil else { return }
        runAfterClose = action
    }

    /// The sheet went away. Stops what can be stopped, cancels an open
    /// sign-in, reports once (the result when the cart was filled, nil
    /// otherwise), then runs the done action.
    func close(_ report: (AddResult?) -> Void) {
        closeNow(report)
        runPendingAfterClose()
    }

    /// A close button: report now, so `onClose` fires even where dismissing
    /// does nothing (a UIKit host). The done action waits for the sheet to go,
    /// or a second, whichever is first.
    func closeFromButton(_ report: (AddResult?) -> Void) {
        closeNow(report)
        if runAfterClose != nil {
            after(1000) { [weak self] in self?.runPendingAfterClose() }
        }
    }

    private func closeNow(_ report: (AddResult?) -> Void) {
        guard hosting else { return }
        hosting = false
        run += 1
        // Nothing it was doing reports afterwards. An add is not stopped.
        preparing?.cancel()
        preparing = nil
        cart?.cancelSearches()
        let outcome = phase == .done ? result : nil
        MealioCart.emit(.sheetClosed(step: sheetStep, added: outcome?.added.count ?? 0))
        login?.cancel()
        loginSub?.cancel()
        loginSub = nil
        userSub?.cancel()
        userSub = nil
        login = nil
        host?.hostLogin(false)
        report(outcome)
    }

    private func runPendingAfterClose() {
        let after = runAfterClose
        runAfterClose = nil
        after?()
    }

    private func fail(_ e: Error, step: MealioSheetStep, fallback: String? = nil) {
        var shown = (e as? MealioError) ?? MealioError(code: "error", message: e.localizedDescription)
        if shown.message.isEmpty, let fallback = fallback {
            shown = MealioError(code: shown.code, message: fallback)
        }
        error = shown
        phase = .error
        MealioCart.emit(.error(code: shown.code, step: step))
        onError?(e)
    }
}

// MARK: - Pieces

/// "heb" -> "H-E-B" until the server's storeName arrives.
func mealioStoreLabel(_ id: String) -> String {
    let known = ["heb": "H-E-B", "aldi": "ALDI", "kroger": "Kroger", "safeway": "Safeway", "wegmans": "Wegmans", "qfc": "QFC", "frys": "Fry's", "smiths": "Smith's", "bakers": "Baker's", "marianos": "Mariano's", "pick_n_save": "Pick 'n Save", "pay_less": "Pay-Less"]
    if let k = known[id] { return k }
    return id.replacingOccurrences(of: "_", with: " ")
        .split(separator: " ")
        .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        .joined(separator: " ")
}

/// The drag handle. A full screen cover has nothing to drag.
@MainActor
struct MealioGrabber: View {
    let t: MealioTheme

    var body: some View {
        if MealioCart.sheet.height != .full {
            Capsule()
                .fill(t.border)
                .frame(width: 36, height: 5)
                .padding(.top, 8)
                .accessibilityHidden(true)
        }
    }
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
    var photos: [URL] = []
    let title: String
    let onClose: () -> Void
    /// While adding, nothing closes the sheet.
    var closeDisabled = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let logo = MealioCart.sheet.logo {
                logo
                    .resizable()
                    .scaledToFit()
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityIgnoresInvertColors()
                    .accessibilityHidden(true)
            }
            if !photos.isEmpty {
                // By position: two recipes can share a photo.
                HStack(spacing: -18) {
                    ForEach(photos.indices, id: \.self) { i in
                        MealioRecipePhoto(t: t, url: photos[i])
                    }
                }
                .accessibilityHidden(true)
            }
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
            .disabled(closeDisabled)
            .opacity(closeDisabled ? 0.4 : 1)
            .accessibilityLabel(MealioCart.text.tr(.close))
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

    private var ui: MealioText { MealioCart.text }

    private var labels: [String] {
        [ui.tr(.stepSignIn, ["store": storeName]), ui.plural("stepFinding", count)]
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
            Text(ui.tr(.loadingNote, ["store": storeName]))
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
                    .accessibilityValue(i < at ? ui.tr(.done) : "")
                    .accessibilityAddTraits(i == at ? .isSelected : [])
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
    private let onChangeLocation: (() -> Void)?
    private let onAdd: () -> Void
    @State private var open: String?
    @Environment(\.colorScheme) private var systemScheme

    /// - Parameters:
    ///   - cart: From `MealioCart.prepareCart`.
    ///   - storeName: Display name; defaults to the server's.
    ///   - theme: Defaults to the theme in force, dark mode included.
    ///   - busy: Adding is in progress (spinner on the button, list locked).
    ///   - onChangeStore: When set, a tappable store chip sits above the list.
    ///   - onChangeLocation: When set, a Change link sits beside the exact
    ///     store, on a Kroger family cart.
    ///   - onAdd: The Add button was tapped. Call `cart.addToCart()`.
    public init(cart: CartSession, storeName: String? = nil, theme: MealioTheme? = nil,
                busy: Bool = false, onChangeStore: (() -> Void)? = nil,
                onChangeLocation: (() -> Void)? = nil, onAdd: @escaping () -> Void) {
        self._cart = ObservedObject(wrappedValue: cart)
        self.storeNameOverride = storeName
        self.themeOverride = theme
        self.busy = busy
        self.onChangeStore = onChangeStore
        self.onChangeLocation = onChangeLocation
        self.onAdd = onAdd
        // The first item needing a choice starts expanded.
        self._open = State(initialValue: cart.firstToOpen)
    }

    private var t: MealioTheme { themeOverride ?? MealioCart.resolvedTheme(for: systemScheme) }
    private var ui: MealioText { MealioCart.text }
    private var storeName: String { storeNameOverride ?? cart.storeName ?? mealioStoreLabel(cart.store) }

    public var body: some View {
        let est = cart.estimate()
        let selectable = cart.items.filter { $0.status != .unavailable }.count
        return VStack(spacing: 0) {
            if let location = cart.location {
                locationRow(location)
            }
            HStack(spacing: 10) {
                if let change = onChangeStore {
                    Button(action: change) {
                        HStack(spacing: 8) {
                            Text(storeName)
                                .font(t.font(13, .semibold))
                                .foregroundColor(t.text)
                                .lineLimit(1)
                            Text(ui.tr(.change))
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
                    .accessibilityLabel(ui.tr(.a11yChangeStore, ["store": storeName]))
                }
                Text(ui.tr(.selectedCount, ["count": String(est.count), "total": String(selectable)]))
                    .font(t.font(14))
                    .foregroundColor(t.muted)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
            // Said while any item has no saved product, which on a recipe's first
            // cart is every item: the run where nothing on screen shows it yet.
            if cart.showsRememberNote {
                Text(ui.tr(.rememberNote))
                    .font(t.font(13, .medium))
                    .foregroundColor(t.text)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(t.surface))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(t.border, lineWidth: 1))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .accessibilityIdentifier("mealio-remember-note")
            }
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
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            footer(est)
        }
    }

    private func locationRow(_ location: StoreLocation) -> some View {
        HStack(spacing: 10) {
            Text("\(location.name), \(location.address)")
                .font(t.font(12))
                .foregroundColor(t.muted)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let change = onChangeLocation {
                Button(action: change) {
                    Text(ui.tr(.change))
                        .font(t.font(12))
                        .foregroundColor(t.accent)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .accessibilityLabel(ui.tr(.a11yChangeLocation, ["name": location.name]))
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mealio-location")
    }

    private func footer(_ est: CartEstimate) -> some View {
        // Off while a search runs: what the user is looking for may change the list.
        let off = busy || est.count == 0 || cart.searching
        let label = est.count > 0
            ? ui.plural("addItems", est.count, ["store": storeName])
            : ui.tr(.selectItems)
        let pending = cart.pendingPreferences().count
        return VStack(spacing: 8) {
            if pending > 0 {
                Text(ui.plural("pendingOptions", pending))
                    .font(t.font(12))
                    .foregroundColor(t.warnText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 6)
            }
            // No partial totals: one unpriced item and there is no number to show.
            if MealioCart.sheet.showTotal {
                HStack(alignment: .firstTextBaseline) {
                    Text(ui.tr(est.total != nil && est.estimated ? .estimatedTotal : .total))
                        .font(t.font(14))
                        .foregroundColor(t.muted)
                    Spacer()
                    if let total = est.total {
                        Text(ui.amount(total, estimated: est.estimated))
                            .font(t.font(18, .bold))
                            .foregroundColor(t.text)
                    } else {
                        Text(ui.tr(.pricesAtCheckout))
                            .font(t.font(15, .semibold))
                            .foregroundColor(t.muted)
                    }
                }
                .accessibilityElement(children: .combine)
            }
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

    private var ui: MealioText { MealioCart.text }
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
                Text(ui.tr(.notFoundAt, ["store": storeName]))
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
        let changeLabel = ui.tr(isOpen ? .done : ((on || item.status == .remembered) ? .change : .choose))

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
                .accessibilityLabel(ui.tr(on ? .a11yLeaveOut : .a11yAdd, ["item": item.ingredient]))
                .accessibilityAddTraits(on ? .isSelected : [])

                MealioThumb(t: t, product: shown ?? options.first, dim: !on, big: false)

                Button(action: onToggleOpen) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.ingredient)
                            .font(t.font(12, .medium))
                            .foregroundColor(t.muted)
                            .lineLimit(1)
                        // Only on a cart from two or more recipes: "For Tacos and Pasta".
                        if let forLine = cart.recipesLabel(for: item.key, text: ui) {
                            Text(forLine)
                                .font(t.font(11))
                                .foregroundColor(t.muted)
                                .lineLimit(1)
                        }
                        Text(shown?.name ?? ui.tr(.chooseProduct))
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

                Button(action: onToggleOpen) {
                    Text(changeLabel)
                        .font(t.font(14, .semibold))
                        .foregroundColor(t.accent)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 10)
            .padding(.trailing, 6)

            if on, let picked = picked, cart.needsPreference(item.key) {
                Text(ui.tr(.chooseOne, ["options": ui.listOr((picked.preferences ?? []).map(\.label))]))
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
        let amount = byWeight ? mealioLbText(lb) : String(n)
        let word = ui.tr(byWeight ? .weight : .quantity)
        let step: (Int) -> Void = { dir in
            if byWeight {
                _ = cart.stepWeight(key: item.key, by: dir)
            } else {
                _ = cart.setQuantity(key: item.key, to: n + dir)
            }
        }
        return HStack {
            Text(word)
                .font(t.font(12))
                .foregroundColor(t.muted)
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                stepButton("\u{2212}", label: ui.tr(.a11yLess, ["item": item.ingredient]), off: atMin) { step(-1) }
                Text(amount)
                    .font(t.font(16, .bold))
                    .foregroundColor(t.text)
                    .frame(minWidth: byWeight ? 64 : 28)
                    .multilineTextAlignment(.center)
                    .accessibilityLabel("\(word) \(amount)")
                stepButton("+", label: ui.tr(.a11yMore, ["item": item.ingredient]), off: atMax) { step(1) }
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
        let gone = item.reason == "not_found"
        if let name = item.remembered?.name {
            return ui.tr(gone ? .usualNotAvailableNamed : .usualOutNamed, ["name": name])
        }
        return ui.tr(gone ? .usualNotAvailable : .usualOut)
    }

    func meta(on: Bool, picked: Product?, options: [Product]) -> String {
        if let p = picked {
            let parts: [String?] = [ui.price(p), p.id == item.remembered?.id ? ui.tr(.yourUsual) : nil]
            return parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
        }
        if item.startUnchecked { return ui.tr(.pantryHint) }
        switch item.status {
        case .remembered: return ui.tr(.notAddingThisTime)
        case .rememberedUnavailable: return ui.tr(.usualOutOfStock)
        default: return ui.plural("options", options.count)
        }
    }

    private func expanded(picked: Product?, options: [Product]) -> some View {
        let placeholder = ui.tr(.searchPlaceholder, ["store": storeName])
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
                            ProgressView().progressViewStyle(.circular).tint(t.onAccent)
                        } else {
                            Text(ui.tr(.search))
                                .font(t.font(14, .semibold))
                                .foregroundColor(t.onAccent)
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(minWidth: 76, minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: max(0, t.radius - 2)).fill(t.text))
                }
                .buttonStyle(.plain)
                .disabled(searching || disabled)
                .accessibilityLabel(ui.tr(.search))
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
        let price = o.outOfStock == true ? ui.tr(.outOfStock) : ui.price(o)
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
                    Text(ui.tr(.yourUsual)).font(t.font(11, .bold)).foregroundColor(t.accent)
                } else if o.badge == "popular" {
                    Text(o.badgeLabel ?? ui.tr(.crowdFavorite)).font(t.font(11, .bold)).foregroundColor(t.muted)
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

    func toggle(on: Bool) {
        guard !disabled else { return }
        if on {
            cart.deselect(key: item.key)
            MealioCart.emit(.itemUnchecked(key: item.key))
        } else if item.status == .remembered, let id = item.selectedId {
            MealioCart.emit(.itemChecked(key: item.key))
            try? cart.select(key: item.key, productId: id, preferenceId: item.rememberedPreferenceId)
        } else if !isOpen {
            onToggleOpen()
        }
    }

    func pick(_ p: Product, preferenceId: String?) {
        guard !disabled else { return }
        // An option tap that ticks the item is a check, as the box is.
        if !cart.isSelected(item.key) { MealioCart.emit(.itemChecked(key: item.key)) }
        try? cart.select(key: item.key, productId: p.id, preferenceId: preferenceId)
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2, !searching, !disabled else { return }
        searching = true
        searchNote = nil
        let cart = self.cart
        let key = item.key
        Task { @MainActor in
            do {
                let found = try await cart.search(key: key, query: q)
                searchNote = found.isEmpty ? ui.tr(.nothingFound, ["query": q]) : nil
                query = ""
            } catch {
                // Stopped because the sheet closed: nothing to say.
                if (error as? MealioError)?.code != MealioError.Code.cancelled {
                    searchNote = mealioProblem(error, ui.tr(.searchFailed))
                }
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

/// One recipe photo in the sheet header. Loads as product images do, but
/// fills its square, since a photo of a dish is not a pack shot on white.
@MainActor
struct MealioRecipePhoto: View {
    let t: MealioTheme
    let url: URL

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: t.radius / 2)
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            t.surface
        }
        .frame(width: 44, height: 44)
        .background(t.surface)
        .clipShape(shape)
        .overlay(shape.strokeBorder(t.background, lineWidth: 2))
        .accessibilityIgnoresInvertColors()
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
        .accessibilityLabel(title)
    }
}

// MARK: - Done

/// The finished run. What the store took, row by row (image, product, the
/// recipe line, amount, price), then what was left out. No total unless every
/// added item has a price. No open-cart button: the user's next step is the
/// store's own app or site, not ours.
@MainActor
struct MealioDoneView: View {
    @ObservedObject var cart: CartSession
    let t: MealioTheme
    let result: AddResult
    let storeName: String
    let onDone: () -> Void
    private let message: String?
    private let actionLabel: String?
    private let onAction: () -> Void
    @State private var open: Bool

    /// `actionLabel` draws the partner's button, which then leads and Done
    /// turns quiet.
    init(t: MealioTheme, cart: CartSession, result: AddResult, storeName: String, onDone: @escaping () -> Void,
         message: String? = nil, actionLabel: String? = nil, onAction: @escaping () -> Void = {}) {
        self._cart = ObservedObject(wrappedValue: cart)
        self.t = t
        self.result = result
        self.storeName = storeName
        self.onDone = onDone
        self.message = message
        self.actionLabel = actionLabel
        self.onAction = onAction
        // "Left out this time" opens on its own when something failed.
        self._open = State(initialValue: !result.failed.isEmpty)
    }

    private var n: Int { result.added.count }

    private var ui: MealioText { MealioCart.text }

    private var title: String {
        n > 0 ? ui.plural("itemsAdded", n) : ui.tr(.nothingAdded)
    }

    /// Empty when the partner hid prices. No partial totals: an unpriced item
    /// leaves no number to show.
    private var subtitle: String {
        guard MealioCart.sheet.showTotal else { return "" }
        let sum = cart.addedTotal(result)
        return sum.total.map { ui.amount($0, estimated: sum.estimated) } ?? ui.tr(.pricesAtCheckout)
    }

    var body: some View {
        let left = mealioLeftOut(cart: cart, result: result, storeName: storeName, ui: ui)
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    banner
                    if let message = message, !message.isEmpty {
                        Text(message)
                            .font(t.font(15))
                            .foregroundColor(t.text)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("mealio-done-message")
                    }
                    if n > 0 {
                        VStack(spacing: 0) {
                            ForEach(Array(result.added.enumerated()), id: \.element.key) { i, a in
                                MealioAddedRow(t: t, cart: cart, item: a, first: i == 0)
                            }
                        }
                        .background(t.background)
                        .clipShape(RoundedRectangle(cornerRadius: t.radius + 2))
                        .overlay(RoundedRectangle(cornerRadius: t.radius + 2).strokeBorder(t.border, lineWidth: 1))
                    }
                    if !left.isEmpty {
                        leftOutCard(left)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            VStack(spacing: 10) {
                if let label = actionLabel {
                    MealioCTA(t: t, title: label, action: onAction)
                        .accessibilityIdentifier("mealio-done-action")
                }
                MealioCTA(t: t, title: ui.tr(.done), quiet: actionLabel != nil, action: onDone)
                Text("Cart by Mealio")
                    .font(t.font(12))
                    .foregroundColor(t.muted)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 12)
        }
    }

    private var banner: some View {
        let ok = n > 0
        let sub = ok ? subtitle : ui.tr(.cartUnchanged)
        return HStack(spacing: 12) {
            ZStack {
                Circle().fill(ok ? t.accent : t.warnText)
                Image(systemName: ok ? "checkmark" : "exclamationmark")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundColor(t.onAccent)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(t.font(15, .bold))
                    .foregroundColor(ok ? t.text : t.warnText)
                if !sub.isEmpty {
                    Text(sub)
                        .font(t.font(13))
                        .foregroundColor(ok ? t.text.opacity(0.85) : t.warnText)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        // The accent at 10% over the sheet, as the RN banner.
        .background(RoundedRectangle(cornerRadius: t.radius + 2).fill(ok ? t.accent.opacity(0.1) : t.warnBackground))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sub.isEmpty ? title : "\(title), \(sub)")
    }

    private func leftOutCard(_ left: [MealioLeftOut]) -> some View {
        let labels = left.map(\.label).joined(separator: ", ")
        let shape = RoundedRectangle(cornerRadius: t.radius + 2)
        return VStack(spacing: 0) {
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { open.toggle() } }) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ui.tr(.leftOut))
                            .font(t.font(14, .semibold))
                            .foregroundColor(t.text)
                        if !open {
                            Text(mealioSentence(labels))
                                .font(t.font(12))
                                .foregroundColor(t.muted)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(t.muted)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 16)
                .frame(minHeight: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(ui.tr(.leftOut)): \(labels)")
            .accessibilityAddTraits(open ? .isSelected : [])

            if open {
                ForEach(left, id: \.key) { x in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mealioSentence(x.label))
                            .font(t.font(14, .medium))
                            .foregroundColor(t.text)
                            .lineLimit(2)
                        Text(x.why)
                            .font(t.font(12))
                            .foregroundColor(x.failed ? t.warnText : t.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 16)
                    .overlay(alignment: .top) { Rectangle().fill(t.border).frame(height: 1) }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(x.label), \(x.why)")
                }
            }
        }
        .background(t.background)
        .clipShape(shape)
        .overlay(shape.strokeBorder(t.border, lineWidth: 1))
    }
}

/// One line the store took: 44pt image (or initials), product, the recipe
/// line, an amount pill and the price.
@MainActor
struct MealioAddedRow: View {
    @ObservedObject var cart: CartSession
    let t: MealioTheme
    let item: AddedItem
    let first: Bool

    init(t: MealioTheme, cart: CartSession, item: AddedItem, first: Bool) {
        self._cart = ObservedObject(wrappedValue: cart)
        self.t = t
        self.item = item
        self.first = first
    }

    var body: some View {
        let product = cart.selected(for: item.key)
        let images: [String?] = [item.imageUrl, product?.imageUrl]
        let image = images.compactMap { $0 }.first { !$0.isEmpty }
        let lines: [String?] = [item.ingredient, cart.items.first { $0.key == item.key }?.ingredient]
        let line = lines.compactMap { $0 }.first { !$0.isEmpty } ?? ""
        let amount = item.weightLb.map(mealioLbText) ?? "\u{00D7}\(item.quantity)"
        let p = cart.addedPrice(item)
        let ui = MealioCart.text
        // Row prices go when the total does.
        let price = MealioCart.sheet.showTotal ? (p.map { ui.amount($0.amount, estimated: $0.estimated) } ?? "") : ""
        let spokenAmount = item.weightLb.map { "\(ui.tr(.weight)) \(mealioLbText($0))" } ?? "\(ui.tr(.quantity)) \(item.quantity)"
        let parts: [String?] = [item.name, line.isEmpty ? nil : ui.tr(.forRecipes, ["recipes": line]), spokenAmount, price.isEmpty ? nil : price]
        let spoken = parts.compactMap { $0 }.joined(separator: ", ")

        return HStack(spacing: 12) {
            thumb(image)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(t.font(14, .semibold))
                    .foregroundColor(t.text)
                    .lineLimit(1)
                if !line.isEmpty {
                    Text(line)
                        .font(t.font(12))
                        .foregroundColor(t.muted)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 4) {
                Text(amount)
                    .font(t.font(12, .bold))
                    .foregroundColor(t.text)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 8)
                    .background(Capsule().fill(t.surface))
                if !price.isEmpty {
                    Text(price)
                        .font(t.font(12))
                        .foregroundColor(t.muted)
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(minHeight: 68)
        .overlay(alignment: .top) {
            if !first { Rectangle().fill(t.border).frame(height: 1) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    @ViewBuilder
    private func thumb(_ image: String?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        if let s = image, let url = URL(string: s) {
            AsyncImage(url: url) { img in
                img.resizable().scaledToFit()
            } placeholder: {
                Color.white
            }
            .frame(width: 44, height: 44)
            .background(Color.white)
            .clipShape(shape)
            .accessibilityHidden(true)
        } else {
            Text(mealioMonogram(item.name))
                .font(t.font(13, .bold))
                .foregroundColor(t.muted)
                .frame(width: 44, height: 44)
                .background(shape.fill(t.surface))
                .accessibilityHidden(true)
        }
    }
}

struct MealioLeftOut {
    let key: String
    let label: String
    let why: String
    let failed: Bool
}

/// Everything the store did not take this run: unchecked, skipped, or failed
/// (with its reason).
@MainActor
func mealioLeftOut(cart: CartSession, result: AddResult, storeName: String, ui: MealioText) -> [MealioLeftOut] {
    func item(_ key: String) -> CartItem? { cart.items.first { $0.key == key } }
    func nonEmpty(_ s: String?) -> String? { (s?.isEmpty ?? true) ? nil : s }
    var out: [MealioLeftOut] = []
    for f in result.failed {
        out.append(MealioLeftOut(key: f.key, label: nonEmpty(item(f.key)?.ingredient) ?? f.name,
                                 why: mealioSentence("\(f.name): \(ui.reason(f.reason))"), failed: true))
    }
    for x in result.skipped {
        let it = item(x.key)
        let why: String
        if it?.status == .unavailable {
            why = ui.tr(.notFoundAt, ["store": storeName])
        } else if x.reason == "preference_required" {
            why = ui.tr(.neededOption)
        } else if x.reason == "deselected" {
            why = ui.tr(.uncheckedThisTime)
        } else {
            why = ui.tr(.notChosen)
        }
        out.append(MealioLeftOut(key: x.key, label: nonEmpty(it?.ingredient) ?? x.key, why: why, failed: false))
    }
    return out
}

/// First letter up: "Corn tortillas, chipotle peppers".
func mealioSentence(_ x: String) -> String {
    guard let f = x.first else { return x }
    return f.uppercased() + x.dropFirst()
}

/// Two letters for an image-less product tile: "Fresh Yellow Onion" -> "FY".
func mealioMonogram(_ name: String) -> String {
    let cleaned = String(name.map { ch -> Character in
        (ch.isASCII && (ch.isLetter || ch.isNumber)) ? ch : " "
    })
    let words = cleaned.split(separator: " ")
    let a = words.first?.first.map { String($0) } ?? ""
    let b = words.dropFirst().first?.first.map { String($0) } ?? ""
    return (a + b).uppercased()
}

/// "0.75 lb", "1 lb": at most two decimals, no trailing zeros.
func mealioLbText(_ lb: Double) -> String {
    var s = String(format: "%.2f", lb)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return "\(s) lb"
}

// MARK: - Location picker

/// One choosable store or location, with a selected ring: name, a detail line,
/// and a spinner or a word on the right. The location step and store settings
/// draw these.
@MainActor
struct MealioStoreOption: View {
    let t: MealioTheme
    let title: String
    var detail: String?
    var selected = false
    var saving = false
    /// "Current" or "Change".
    var trailing: String?
    var disabled = false
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: t.radius)
        return Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(t.font(15, .semibold))
                        .foregroundColor(t.text)
                        .multilineTextAlignment(.leading)
                    if let detail = detail {
                        Text(detail)
                            .font(t.font(12))
                            .foregroundColor(t.muted)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if saving {
                    ProgressView().progressViewStyle(.circular).tint(t.accent)
                } else if let trailing = trailing {
                    Text(trailing)
                        .font(t.font(12))
                        .foregroundColor(t.accent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(shape.fill(t.background))
            .overlay(shape.strokeBorder(selected ? t.accent : t.border, lineWidth: selected ? 2 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Which Kroger family store the user shops at: a zip box, then that chain's
/// nearby stores. A zip the partner or an earlier pick supplied fills the box
/// and searches at once, and the user still taps the store they want. Used in
/// the cart sheet and in store settings.
@MainActor
struct MealioLocationPicker: View {
    struct Back {
        let label: String
        let action: () -> Void
    }

    private struct Found {
        let zip: String
        let locations: [StoreLocation]
    }

    private let t: MealioTheme
    private let store: String
    private let storeName: String
    private let startZip: String?
    private let current: String?
    private let onPicked: (StoreLocation) -> Void
    private let back: Back

    @State private var zip: String
    @State private var found: Found?
    @State private var busy = false
    @State private var saving: String?
    @State private var problem: String?
    /// Only the latest lookup may answer.
    @State private var ask = 0
    @State private var searchedStartZip = false

    private var ui: MealioText { MealioCart.text }

    init(t: MealioTheme, store: String, storeName: String, zip: String?, current: String?,
         onPicked: @escaping (StoreLocation) -> Void, back: Back) {
        self.t = t
        self.store = store
        self.storeName = storeName
        self.startZip = zip
        self.current = current
        self.onPicked = onPicked
        self.back = back
        self._zip = State(initialValue: zip ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(ui.tr(.zipPrompt, ["store": storeName]))
                        .font(t.font(14))
                        .foregroundColor(t.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    zipRow
                    if busy {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(t.accent)
                            .frame(maxWidth: .infinity)
                    }
                    if let problem = problem {
                        Text(problem)
                            .font(t.font(15))
                            .foregroundColor(t.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let found = found {
                        if found.locations.isEmpty {
                            Text(ui.tr(.noStoresNear, ["store": storeName, "zip": found.zip]))
                                .font(t.font(14))
                                .foregroundColor(t.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(found.locations) { l in
                            MealioStoreOption(t: t, title: l.name, detail: l.address, selected: l.id == current,
                                              saving: saving == l.id, trailing: l.id == current ? ui.tr(.current) : nil,
                                              disabled: saving != nil, action: { pick(l) })
                                .accessibilityIdentifier("mealio-location-\(l.id)")
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 2)
                .padding(.bottom, 24)
            }
            MealioCTA(t: t, title: back.label, quiet: true, action: back.action)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .overlay(alignment: .top) { Rectangle().fill(t.border).frame(height: 1) }
        }
        .onAppear {
            guard !searchedStartZip else { return }
            searchedStartZip = true
            if let z = startZip, mealioIsZip(z) { find(z) }
        }
    }

    private var zipRow: some View {
        let shape = RoundedRectangle(cornerRadius: max(0, t.radius - 2))
        let ready = mealioIsZip(zip) && !busy
        return HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                if zip.isEmpty {
                    Text(ui.tr(.zipCode))
                        .font(t.font(16))
                        .foregroundColor(t.muted)
                        .accessibilityHidden(true)
                }
                TextField("", text: $zip)
                    .font(t.font(16))
                    .foregroundColor(t.text)
                    .keyboardType(.numberPad)
                    .submitLabel(.search)
                    .onSubmit { if mealioIsZip(zip) { find(zip) } }
                    .disableAutocorrection(true)
                    .accessibilityLabel(ui.tr(.zipCode))
                    .accessibilityIdentifier("mealio-zip")
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 48)
            .background(shape.fill(t.surface))
            // Set here, not in a Binding: a Binding that drops a typed letter
            // leaves the state unchanged and the text field keeps showing it.
            .onChange(of: zip) { value in
                let clean = mealioCleanZip(value)
                if clean != value { zip = clean }
            }

            Button(action: { find(zip) }) {
                Text(ui.tr(.findStores))
                    .font(t.font(16, .bold))
                    .foregroundColor(t.onAccent)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)
                    .background(shape.fill(t.accent))
                    .opacity(ready ? 1 : 0.5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!ready)
            .accessibilityIdentifier("mealio-find-stores")
        }
    }

    private func find(_ z: String) {
        ask += 1
        let id = ask
        busy = true
        problem = nil
        found = nil
        Task { @MainActor in
            do {
                let locations = try await MealioCart.storeLocations(store: store, zip: z)
                if ask == id { found = Found(zip: z, locations: locations) }
            } catch {
                if ask == id { problem = mealioProblem(error, ui.tr(.couldNotLookUp)) }
            }
            if ask == id { busy = false }
        }
    }

    private func pick(_ l: StoreLocation) {
        saving = l.id
        problem = nil
        Task { @MainActor in
            do {
                try await MealioCart.setStore(store, locationId: l.id)
                onPicked(l)
            } catch {
                problem = mealioProblem(error, ui.tr(.couldNotSaveStore))
                saving = nil
            }
        }
    }
}

// MARK: - Store picker

@MainActor
struct MealioStorePicker: View {
    let t: MealioTheme
    let stores: [StoreInfo]?
    let current: String?
    let onPick: (String) -> Void
    let onBack: (() -> Void)?

    private var ui: MealioText { MealioCart.text }

    var body: some View {
        if let stores = stores {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 10) {
                        if stores.isEmpty {
                            Text(ui.tr(.couldNotLoadStores))
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
                    MealioCTA(t: t, title: ui.tr(.backToList), quiet: true, action: back)
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
                    Text(ui.tr(.current))
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
    /// After a failed add: some items may be in the cart already.
    var note: String? = nil
    let onRetry: () -> Void
    let onClose: () -> Void

    private var ui: MealioText { MealioCart.text }

    private var message: String {
        if error?.code == MealioError.Code.loginCancelled { return ui.tr(.signInClosed) }
        if error?.code == MealioError.Code.cartCapReached { return ui.tr(.capReached) }
        if error?.code == MealioError.Code.tooManyCarts { return ui.tr(.tooManyCarts) }
        if let m = error?.message, !m.isEmpty { return m }
        return ui.tr(.somethingWrongSentence)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(message)
                .font(t.font(15))
                .foregroundColor(t.text)
                .fixedSize(horizontal: false, vertical: true)
            if let note = note {
                Text(note)
                    .font(t.font(14))
                    .foregroundColor(t.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("mealio-add-failed-note")
            }
            Spacer(minLength: 0)
            MealioCTA(t: t, title: ui.tr(.tryAgain), action: onRetry)
            MealioCTA(t: t, title: ui.tr(.close), quiet: true, action: onClose)
        }
        .padding(20)
    }
}
#endif
