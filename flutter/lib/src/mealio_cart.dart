// The partner's entry point: configure once, then prepare carts. Wraps
// MealioClient with the WebView host from MealioScope and the stored
// store-session epoch.

import 'package:flutter/widgets.dart' show BuildContext, ValueChanged;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'cart_session.dart';
import 'client.dart';
import 'errors.dart';
import 'host.dart';
import 'protocol.dart';
import 'strings.dart';
import 'theme.dart';
import 'ui.dart';
import 'webview_host.dart';
import 'widgets/store_settings.dart';

const String _epochKey = 'mealio_sdk.store_epoch';

/// Resolves the mounted MealioScope's host at call time, so `configure` can
/// run before the first frame.
class _ScopedHost implements MealioHost {
  WebViewHost get _h {
    final h = WebViewHost.current;
    if (h == null) {
      throw const MealioException(MealioErrorCode.noScope, 'Place MealioScope near the root of your app.');
    }
    return h;
  }

  @override
  Future<PageLoad> openPage(String store, String url, int timeoutMs) => _h.openPage(store, url, timeoutMs);

  @override
  Future<ScriptRun> runScript(
    String store,
    String guard,
    String script,
    List<MessageMatcher> until,
    int timeoutMs,
  ) =>
      _h.runScript(store, guard, script, until, timeoutMs);

  @override
  Future<LoginResult> showLogin(LoginRequest request) => _h.showLogin(request);

  @override
  Future<HttpResult> fetch(String store, FetchRequest request, int timeoutMs, int maxBytes) =>
      _h.fetch(store, request, timeoutMs, maxBytes);
}

/// The Mealio Cart SDK.
///
/// ```dart
/// MealioCart.configure(
///   publishableKey: 'pk_live_...',
///   sessionTokenProvider: () => myServer.mealioSessionToken(),
///   theme: const MealioTheme(accent: Color(0xFF0B5FFF)),
/// );
/// // Then, anywhere: MealioCartButton(recipe: recipe, store: 'heb'),
/// // or MealioCartButton(recipes: <Recipe>[tacos, pasta]) for one cart.
/// ```
class MealioCart {
  MealioCart._(this._client);

  static MealioCart? _instance;

  /// Set up the SDK. Call once, for example in `main()`. Calling it again
  /// replaces the configuration.
  ///
  /// `sessionTokenProvider` returns an SDK session token your server got from
  /// `POST /api/v1/sessions`. It is called again when a token expires.
  ///
  /// `theme` styles the drop-in widgets. `darkTheme`, `colorScheme` (`auto`
  /// follows the phone), `strings` (any word, see [mealioDefaultStrings]),
  /// `formatMoney` and `sheet` go with it. `MealioScope` overrides each one.
  static MealioCart configure({
    required String publishableKey,
    required Future<String> Function() sessionTokenProvider,
    String baseUrl = defaultBaseUrl,
    Future<String?> Function()? attestationProvider,
    MealioTheme? theme,
    MealioTheme? darkTheme,
    MealioColorScheme? colorScheme,
    Map<String, String>? strings,
    MealioMoneyFormat? formatMoney,
    MealioSheetOptions? sheet,
  }) {
    MealioLook.configured = MealioLook(
      theme: theme,
      darkTheme: darkTheme,
      colorScheme: colorScheme,
      strings: strings,
      formatMoney: formatMoney,
      sheet: sheet,
    );
    final client = MealioClient(
      ClientConfig(
        publishableKey: publishableKey,
        getSessionToken: sessionTokenProvider,
        platform: 'flutter',
        sdkVersion: mealioSdkVersion,
        baseUrl: baseUrl,
        getAttestation: attestationProvider,
        getEpoch: storeEpoch,
      ),
      _ScopedHost(),
    );
    // The hidden page checks its own navigations against the same list.
    WebViewHost.sharedAllowlist = client.allowlist;
    return _instance = MealioCart._(client);
  }

  /// The configured SDK. Throws [MealioException] `not_configured` before
  /// [configure].
  static MealioCart get instance {
    final i = _instance;
    if (i == null) {
      throw const MealioException(MealioErrorCode.notConfigured, 'Call MealioCart.configure first.');
    }
    return i;
  }

  static bool get isConfigured => _instance != null;

  final MealioClient _client;

  /// The client underneath, for apps that drive the protocol themselves.
  MealioClient get client => _client;

  /// Stores the SDK supports right now.
  Future<List<StoreInfo>> stores() => _client.stores();

  /// A Kroger family chain's stores near a zip, for your own store screen.
  Future<List<StoreLocation>> storeLocations(String store, String zip) => _client.storeLocations(store, zip);

  /// The user's default store, and their exact store if it is in the Kroger
  /// family.
  Future<StorePreferences> storePreferences() => _client.storePreferences();

  /// Make a store the user's default. Kroger family stores need `locationId`
  /// the first time.
  Future<StorePreferences> setStore(String store, {String? locationId}) =>
      _client.setStore(store, locationId: locationId);

  /// Opens the sheet where the user changes their store or zip. Put it on
  /// your settings screen. `onChange` is called each time their store
  /// changes. Same as [MealioStoreSettings.show].
  Future<void> openStoreSettings(
    BuildContext context, {
    ValueChanged<StorePreferences>? onChange,
    MealioTheme? theme,
  }) =>
      MealioStoreSettings.show(context, onChange: onChange, theme: theme);

  /// Start a cart for `recipe` at `store`: signs the user in to the store if
  /// needed and searches every ingredient. Without `store`, Mealio uses the
  /// user's default store and fails with `store_required` when there is none.
  /// A Kroger family store the user has not chosen a location for fails with
  /// `location_required`, before any sign-in. Pass `zip` to use the nearest
  /// store instead of asking them.
  /// `onStep` reports progress. Throws [MealioException].
  ///
  /// Pass `recipes` instead of `recipe` to fill one cart from up to
  /// [maxRecipes] recipes. Ingredients they share become one item.
  Future<CartSession> prepareCart({
    String? store,
    Recipe? recipe,
    List<Recipe>? recipes,
    String? zip,
    StepListener? onStep,
  }) async {
    if (WebViewHost.current == null) {
      throw const MealioException(MealioErrorCode.noScope, 'Place MealioScope near the root of your app.');
    }
    return _client.prepareCart(store: store, recipe: recipe, recipes: recipes, zip: zip, onStep: onStep);
  }

  /// Runs the login check for the user's store ahead of time, so the next
  /// cart starts at search. MealioCartButton does this when it appears; call
  /// it yourself if you start carts another way. Never shows sign-in, never
  /// throws, and does nothing until a MealioScope is mounted.
  Future<void> warm({String? store}) async {
    if (WebViewHost.current == null) return;
    await _client.warm(store: store);
  }

  /// Signs the user out of `store`.
  ///
  /// webview_flutter can only clear ALL WebView cookies, not one site's, so
  /// this signs the user out of every store, exactly like
  /// [signOutOfAllStores]. It exists so the API matches the other SDKs.
  Future<void> signOutOfStore(String store) => signOutOfAllStores();

  /// Clears every store login on this device and bumps the stored
  /// store-session epoch, which the next cart reports to Mealio.
  Future<void> signOutOfAllStores() async {
    _client.clearWarm();
    final host = WebViewHost.current;
    if (host != null) {
      await host.clearStoreSessions();
    } else {
      try {
        await WebViewCookieManager().clearCookies();
      } catch (_) {
        // No WebView platform; nothing to clear.
      }
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_epochKey, (prefs.getInt(_epochKey) ?? 0) + 1);
  }

  /// The device's store-session epoch. Starts at 0.
  static Future<int> storeEpoch() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getInt(_epochKey) ?? 0;
    } catch (_) {
      return 0;
    }
  }
}
