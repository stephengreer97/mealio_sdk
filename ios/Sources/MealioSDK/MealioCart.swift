// The one-line entry point for partner apps on iOS.
//
//     MealioCart.configure(publishableKey: "pk_live_...") {
//         try await MyServer.mealioSessionToken()   // POST /api/v1/sessions, server side
//     }
//     MealioCartButton(recipe: recipe, store: "heb")   // the whole flow, in one sheet
//     MealioCartButton(recipes: [tacos, pasta])         // one cart from several meals

#if canImport(UIKit) && canImport(WebKit)
import UIKit

@MainActor
public enum MealioCart {
    /// The configured client. Nil until `configure` is called.
    public private(set) static var client: MealioClient?
    /// The WebView host. The cart flow sheet reads its sign-in from here.
    static var host: WebViewHost?
    /// The drop-in's look. Set it with `configure(theme:)` or directly.
    public static var theme: MealioTheme = .default

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
    public static func configure(publishableKey: String,
                                 sessionTokenProvider: @escaping () async throws -> String,
                                 baseURL: URL = DEFAULT_BASE_URL,
                                 presenter: WebViewHost.Presenter? = nil,
                                 attestationProvider: (() async -> String?)? = nil,
                                 theme: MealioTheme? = nil) {
        if let theme = theme { MealioCart.theme = theme }
        let host = WebViewHost(presenter: presenter)
        let config = MealioClientConfig(publishableKey: publishableKey,
                                        sessionTokenProvider: sessionTokenProvider,
                                        baseURL: baseURL,
                                        attestationProvider: attestationProvider)
        let client = MealioClient(config: config, host: host)
        host.hiddenNavigationPolicy = { [weak client] store, url in
            client?.allowlist.check(store, url, .page).ok ?? false
        }
        MealioCart.host = host
        MealioCart.client = client
    }

    /// Change the drop-in's look after `configure`.
    public static func configure(theme: MealioTheme) {
        MealioCart.theme = theme
    }

    /// Start a cart for a recipe at a store. Shows the store's login if the
    /// user is not signed in (inside the cart flow sheet when one is open),
    /// then searches every ingredient. `onStep` reports progress.
    public static func prepareCart(store: String? = nil, recipe: Recipe, zip: String? = nil,
                                   onStep: StepListener? = nil) async throws -> CartSession {
        guard let client = client else {
            throw MealioError(code: MealioError.Code.notConfigured, message: "Call MealioCart.configure first")
        }
        return try await client.prepareCart(store: store, recipe: recipe, zip: zip, onStep: onStep)
    }

    /// Start one cart from several recipes (1 to `MAX_RECIPES`). Ingredients
    /// they share become one item; each pick is remembered under every recipe
    /// that calls for it.
    public static func prepareCart(store: String? = nil, recipes: [Recipe], zip: String? = nil,
                                   onStep: StepListener? = nil) async throws -> CartSession {
        guard let client = client else {
            throw MealioError(code: MealioError.Code.notConfigured, message: "Call MealioCart.configure first")
        }
        return try await client.prepareCart(store: store, recipes: recipes, zip: zip, onStep: onStep)
    }

    /// Stores the SDK supports right now (`GET /api/v1/stores`).
    public static func stores() async throws -> [StoreInfo] {
        guard let client = client else {
            throw MealioError(code: MealioError.Code.notConfigured, message: "Call MealioCart.configure first")
        }
        return try await client.stores()
    }

    /// Forget the user's login at one store: removes that store's cookies and
    /// website data from the device.
    public static func signOutOfStore(_ store: String) async {
        let allowlist = client?.allowlist ?? Allowlist()
        await WebViewHost.clearWebsiteData(forDomains: domains(of: [store], in: allowlist))
        afterSignOut()
    }

    /// Forget the user's login at every Mealio store. Website data of other
    /// sites (your app's own web content) is left alone.
    public static func signOutOfAllStores() async {
        let allowlist = client?.allowlist ?? Allowlist()
        await WebViewHost.clearWebsiteData(forDomains: domains(of: allowlist.storeIds, in: allowlist))
        afterSignOut()
    }

    /// The store-session epoch every call reports. Bumped by every sign-out.
    public static var storeEpoch: Int { StoreEpoch.current() }

    private static func afterSignOut() {
        host?.resetHiddenPage()
        StoreEpoch.bump()
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
