// The one-line entry point for partner apps on iOS.
//
//     MealioCart.configure(publishableKey: "pk_live_...") {
//         try await MyServer.mealioSessionToken()   // POST /api/v1/sessions, server side
//     }
//     MealioCartButton(recipe: recipe, store: "heb")   // the whole flow, in one sheet
//     MealioCartButton(recipes: [tacos, pasta])         // one cart from several meals

#if canImport(UIKit) && canImport(WebKit)
import Combine
import UIKit

/// Who is signed in to the partner's app, as told by `MealioCart.setUser`.
/// The button, the cart sheet and store settings watch it.
@MainActor
final class MealioUsers: ObservableObject {
    /// False until `setUser` is first called: users are not tracked.
    @Published private(set) var tracked = false
    @Published private(set) var userId: String?
    /// Bumped on every change of user.
    @Published private(set) var generation = 0

    nonisolated init() {}

    /// False only while users are tracked and nobody is signed in.
    var hasUser: Bool { !tracked || userId != nil }

    /// Returns true when this is a change.
    @discardableResult
    func set(_ id: String?) -> Bool {
        if tracked && id == userId { return false }
        tracked = true
        userId = id
        generation += 1
        return true
    }

    /// Back to not tracking users. Tests only.
    func reset() {
        tracked = false
        userId = nil
        generation += 1
    }
}

@MainActor
public enum MealioCart {
    /// The configured client. Nil until `configure` is called.
    public internal(set) static var client: MealioClient?
    /// The WebView host. The cart flow sheet reads its sign-in from here.
    static var host: WebViewHost?
    /// The drop-in's look. Set it with `configure(theme:)` or directly.
    public static var theme: MealioTheme = .default
    /// The colors for dark mode. Only used when `colorScheme` asks for dark.
    public static var darkTheme: MealioDarkTheme = .default
    /// `.auto` follows the phone. Defaults to `.light`.
    public static var colorScheme: MealioColorScheme = .light
    /// Your words, laid over `DEFAULT_STRINGS`.
    public static var strings: MealioStrings = [:]
    /// How prices read. Nil is "$12.50" and the store's own price text.
    public static var formatMoney: ((Double) -> String)?
    /// How the sheet looks and behaves.
    public static var sheet = MealioSheetOptions()
    /// Every step of the sheet, for your analytics. Nothing is sent to Mealio.
    public static var onEvent: MealioEventListener?
    /// The drop-in's words and prices as they stand now.
    public static var text: MealioText { MealioText(strings: strings, formatMoney: formatMoney) }
    /// Called when the cart button or store settings is used while
    /// `setUser(nil)` says nobody is signed in. Send the user to your sign-in.
    /// Without it, the button is disabled then.
    public static var onSignInRequired: (() -> Void)?
    /// Who is signed in, as `setUser` last said.
    static let users = MealioUsers()

    /// Set up the SDK. Call once, early (for example at app launch).
    ///
    /// - Parameters:
    ///   - publishableKey: Your app's publishable key from the Mealio dashboard.
    ///   - sessionTokenProvider: Returns an SDK session token your server got
    ///     from `POST /api/v1/sessions`. Called again when the token expires.
    ///   - baseURL: Mealio's API. Change only for testing.
    ///   - presenter: Returns the view controller to present the store login
    ///     sheet from. Defaults to the key window's top-most view controller.
    ///   - attestationProvider: Returns an App Attest token, if your app has
    ///     attestation turned on.
    ///   - theme: Your brand for the drop-in (accent, radius, font...).
    ///   - darkTheme: Colors for dark mode.
    ///   - colorScheme: `.light` (the default), `.dark`, or `.auto` to follow the phone.
    ///   - strings: Change or translate any word the drop-in shows.
    ///   - formatMoney: How prices read. With it set, option prices are built
    ///     from the numeric `unitPrice`, not the store's text.
    ///   - sheet: How the sheet looks and behaves.
    ///   - onEvent: Every step of the sheet, for your analytics. Nothing is
    ///     sent to Mealio.
    public static func configure(publishableKey: String,
                                 sessionTokenProvider: @escaping () async throws -> String,
                                 baseURL: URL = DEFAULT_BASE_URL,
                                 presenter: WebViewHost.Presenter? = nil,
                                 attestationProvider: (() async -> String?)? = nil,
                                 theme: MealioTheme? = nil,
                                 darkTheme: MealioDarkTheme? = nil,
                                 colorScheme: MealioColorScheme? = nil,
                                 strings: MealioStrings? = nil,
                                 formatMoney: ((Double) -> String)? = nil,
                                 sheet: MealioSheetOptions? = nil,
                                 onEvent: MealioEventListener? = nil) {
        configure(theme: theme, darkTheme: darkTheme, colorScheme: colorScheme,
                  strings: strings, formatMoney: formatMoney, sheet: sheet, onEvent: onEvent)
        // Configured again: the old client's jobs stop, and its hidden page,
        // sign-in and fetch session go with it.
        MealioCart.client?.cancelJobs()
        MealioCart.host?.tearDown()
        let host = WebViewHost(presenter: presenter)
        let config = MealioClientConfig(publishableKey: publishableKey,
                                        sessionTokenProvider: sessionTokenProvider,
                                        baseURL: baseURL,
                                        attestationProvider: attestationProvider)
        let client = MealioClient(config: config, host: host)
        host.hiddenNavigationPolicy = { [weak client] store, url in
            // The storefront, or the store's own sign-in hosts: a session check
            // can bounce the hidden page through the identity host (Albertsons'
            // Okta tenant) and back.
            guard let allowlist = client?.allowlist else { return false }
            return allowlist.check(store, url, .page).ok || allowlist.check(store, url, .login).ok
        }
        MealioCart.host = host
        MealioCart.client = client
        if users.tracked { client.setUser(users.userId) }
    }

    /// Tell the SDK who is signed in to your app, or nil when nobody is. Call
    /// it at launch and whenever that changes. On a change it stops a cart
    /// being prepared, starts a new Mealio session, and when the old value was
    /// a user, signs out of the stores (an add under way finishes first). A
    /// failed store sign-out never blocks this. While nil there is no session
    /// and no warm-up, and the cart button calls `onSignInRequired`.
    /// Until you call it, users are not tracked and everything works as before.
    public static func setUser(_ id: String?) {
        guard users.set(id) else { return }
        guard let client = client else { return }
        if client.setUser(id) {
            Task { @MainActor in
                _ = try? await client.runExclusive(stoppable: { stop in
                    await MealioCart.clearStores(nil, using: client, stop: stop)
                })
            }
        }
    }

    /// True unless `setUser(nil)` says nobody is signed in.
    public static var hasUser: Bool { users.hasUser }

    /// Change the drop-in's look after `configure`. What you leave out stays
    /// as it is. To clear `formatMoney` or `onEvent`, set it to nil directly.
    public static func configure(theme: MealioTheme? = nil,
                                 darkTheme: MealioDarkTheme? = nil,
                                 colorScheme: MealioColorScheme? = nil,
                                 strings: MealioStrings? = nil,
                                 formatMoney: ((Double) -> String)? = nil,
                                 sheet: MealioSheetOptions? = nil,
                                 onEvent: MealioEventListener? = nil) {
        if let theme = theme { MealioCart.theme = theme }
        if let darkTheme = darkTheme { MealioCart.darkTheme = darkTheme }
        if let colorScheme = colorScheme { MealioCart.colorScheme = colorScheme }
        if let strings = strings { MealioCart.strings = strings }
        if let formatMoney = formatMoney { MealioCart.formatMoney = formatMoney }
        if let sheet = sheet { MealioCart.sheet = sheet }
        if let onEvent = onEvent { MealioCart.onEvent = onEvent }
    }

    /// Tell the partner's listener, if there is one.
    static func emit(_ event: MealioEvent) {
        onEvent?(event)
    }

    /// Start a cart for a recipe at a store. Shows the store's login if the
    /// user is not signed in (inside the cart flow sheet when one is open),
    /// then searches every ingredient. `onStep` reports progress.
    /// Pass `cancel` to stop it: it stops after the current step, never shows
    /// sign-in, and fails with `cancelled`.
    public static func prepareCart(store: String? = nil, recipe: Recipe, zip: String? = nil,
                                   cancel: CancelToken? = nil, onStep: StepListener? = nil) async throws -> CartSession {
        guard let client = client else {
            throw MealioError(code: MealioError.Code.notConfigured, message: "Call MealioCart.configure first")
        }
        return try await client.prepareCart(store: store, recipe: recipe, zip: zip, cancel: cancel, onStep: onStep)
    }

    /// Start one cart from several recipes (1 to `MAX_RECIPES`). Ingredients
    /// they share become one item; each pick is remembered under every recipe
    /// that calls for it.
    public static func prepareCart(store: String? = nil, recipes: [Recipe], zip: String? = nil,
                                   cancel: CancelToken? = nil, onStep: StepListener? = nil) async throws -> CartSession {
        guard let client = client else {
            throw MealioError(code: MealioError.Code.notConfigured, message: "Call MealioCart.configure first")
        }
        return try await client.prepareCart(store: store, recipes: recipes, zip: zip, cancel: cancel, onStep: onStep)
    }

    /// Stores the SDK supports right now (`GET /api/v1/stores`).
    public static func stores() async throws -> [StoreInfo] {
        guard let client = client else {
            throw MealioError(code: MealioError.Code.notConfigured, message: "Call MealioCart.configure first")
        }
        return try await client.stores()
    }

    /// A Kroger family chain's stores near a zip, nearest first, for your own
    /// store screen. Save the user's choice with `setStore`.
    public static func storeLocations(store: String, zip: String) async throws -> [StoreLocation] {
        guard let client = client else {
            throw MealioError(code: MealioError.Code.notConfigured, message: "Call MealioCart.configure first")
        }
        return try await client.storeLocations(store: store, zip: zip)
    }

    /// The user's default store, and their exact store if it is in the Kroger family.
    public static func storePreferences() async throws -> StorePreferences {
        guard let client = client else {
            throw MealioError(code: MealioError.Code.notConfigured, message: "Call MealioCart.configure first")
        }
        return try await client.storePreferences()
    }

    /// Make a store the user's default. Kroger family stores need `locationId`
    /// the first time, and otherwise fail with `location_required`.
    @discardableResult
    public static func setStore(_ store: String, locationId: String? = nil) async throws -> StorePreferences {
        guard let client = client else {
            throw MealioError(code: MealioError.Code.notConfigured, message: "Call MealioCart.configure first")
        }
        return try await client.setStore(store, locationId: locationId)
    }

    /// Forget the user's login at one store: removes that store's cookies and
    /// website data from the device. A cart being prepared stops; an add
    /// under way finishes first.
    public static func signOutOfStore(_ store: String) async {
        guard let client = client else {
            let d = domains(of: [store], in: Allowlist())
            await boundedStep(signOutStepMs, cancel: nil) { await WebViewHost.clearWebsiteData(forDomains: d) }
            await boundedStep(signOutStepMs, cancel: nil) { _ = StoreEpoch.bump() }
            return
        }
        client.cancelJobs()
        client.resetSession()
        _ = try? await client.runExclusive(stoppable: { stop in
            await MealioCart.clearStores([store], using: client, stop: stop)
        })
    }

    /// Forget the user's login at every Mealio store. Website data of other
    /// sites (your app's own web content) is left alone. A cart being
    /// prepared stops; an add under way finishes first.
    public static func signOutOfAllStores() async {
        guard let client = client else {
            let allowlist = Allowlist()
            let d = domains(of: allowlist.storeIds, in: allowlist)
            await boundedStep(signOutStepMs, cancel: nil) { await WebViewHost.clearWebsiteData(forDomains: d) }
            await boundedStep(signOutStepMs, cancel: nil) { _ = StoreEpoch.bump() }
            return
        }
        client.cancelJobs()
        client.resetSession()
        _ = try? await client.runExclusive(stoppable: { stop in
            await MealioCart.clearStores(nil, using: client, stop: stop)
        })
    }

    /// Each step of a store sign-out gets this long (and stops when its token fires).
    static let signOutStepMs = 10_000

    /// The website data of `stores` (nil: every store), the hidden page and
    /// the session. Runs in the job queue, so nothing is driving the page
    /// meanwhile. Every step is bounded and stops when `stop` fires.
    private static func clearStores(_ stores: [String]?, using client: MealioClient, stop: CancelToken) async {
        let allowlist = client.allowlist
        let d = domains(of: stores ?? allowlist.storeIds, in: allowlist)
        await boundedStep(signOutStepMs, cancel: stop) { await WebViewHost.clearWebsiteData(forDomains: d) }
        await afterSignOut(stop: stop)
    }

    /// The signed-in user changed. Forget the session, so the next call asks
    /// your server for a new one. Signing out of the stores does this too.
    public static func resetSession() {
        client?.resetSession()
    }

    /// The store-session epoch every call reports. Bumped by every sign-out.
    public static var storeEpoch: Int { StoreEpoch.current() }

    /// Run the login check for the user's store ahead of time, so the next
    /// cart starts at search. MealioCartButton does this when it appears; call
    /// it yourself if you start carts another way. Never shows sign-in.
    public static func warm(store: String? = nil) async {
        await client?.warm(store: store)
    }

    private static func afterSignOut(stop: CancelToken) async {
        MealioCart.client?.resetSession()
        await boundedStep(signOutStepMs, cancel: stop) { MealioCart.host?.resetHiddenPage() }
        await boundedStep(signOutStepMs, cancel: stop) { _ = StoreEpoch.bump() }
    }

    private static func domains(of stores: [String], in allowlist: Allowlist) -> Set<String> {
        var out = Set<String>()
        for store in stores {
            guard let h = allowlist.hostsFor(store) else { continue }
            for host in h.hosts + h.authHosts {
                out.insert(Allowlist.registrableDomain(host))
            }
        }
        return out
    }
}
#endif
