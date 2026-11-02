// The one-line entry point for partner apps on iOS.
//
//     MealioCart.configure(publishableKey: "pk_live_...") {
//         try await MyServer.mealioSessionToken()   // POST /api/v1/sessions, server side
//     }
//     let session = try await MealioCart.prepareCart(store: "heb", recipe: recipe)

#if canImport(UIKit) && canImport(WebKit)
import UIKit

@MainActor
public enum MealioCart {
    /// The configured client. Nil until `configure` is called.
    public private(set) static var client: MealioClient?
    private static var host: WebViewHost?

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
    public static func configure(publishableKey: String,
                                 sessionTokenProvider: @escaping () async throws -> String,
                                 baseURL: URL = DEFAULT_BASE_URL,
                                 presenter: WebViewHost.Presenter? = nil,
                                 attestationProvider: (() async -> String?)? = nil) {
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

    /// Start a cart for a recipe at a store. Shows the store's login sheet if
    /// the user is not signed in, then searches every ingredient.
    public static func prepareCart(store: String, recipe: Recipe, zip: String? = nil) async throws -> CartSession {
        guard let client = client else {
            throw MealioError(code: MealioError.Code.notConfigured, message: "Call MealioCart.configure first")
        }
        return try await client.prepareCart(store: store, recipe: recipe, zip: zip)
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

    /// The store-session epoch `hello` reports. Bumped by every sign-out.
    public static var storeEpoch: Int { StoreEpoch.current() }

    private static func afterSignOut() {
        host?.resetHiddenPage()
        StoreEpoch.bump()
        client?.resetHello()
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
