// The partner's entry point: configure once, then prepare carts. Wraps
// MealioClient with the WebView host from MealioScope and the stored
// store-session epoch.

import 'dart:async';

import 'package:flutter/foundation.dart' show ChangeNotifier, Listenable, kDebugMode;
import 'package:flutter/widgets.dart' show BuildContext, ValueChanged, VoidCallback;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'cart_session.dart';
import 'client.dart';
import 'errors.dart';
import 'events.dart';
import 'host.dart';
import 'protocol.dart';
import 'runner.dart' show CancelToken;
import 'strings.dart';
import 'theme.dart';
import 'ui.dart';
import 'webview_host.dart';
import 'widgets/store_settings.dart';

const String _epochKey = 'mealio_sdk.store_epoch';

/// Resolves the mounted MealioScope's host at call time, so `configure` can
/// run before the first frame.
class _ScopedHost implements MealioHost, MealioPageIdentity {
  /// The mounted scope's page. A remount brings a new, blank one.
  @override
  Object? get currentPage => WebViewHost.current?.page;

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

class _Notifier extends ChangeNotifier {
  void notify() => notifyListeners();
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
  MealioCart._(this._client, this._onSignInRequired);

  static MealioCart? _instance;

  /// One queue for the one hidden page, whichever configuration drives it.
  static final JobQueue _queue = JobQueue();

  /// Set up the SDK. Call once, for example in `main()`. Calling it again
  /// replaces the configuration.
  ///
  /// `sessionTokenProvider` returns an SDK session token your server got from
  /// `POST /api/v1/sessions`. It is called again when a token expires.
  ///
  /// `theme` styles the drop-in widgets. `darkTheme`, `colorScheme` (`auto`
  /// follows the phone), `strings` (any word, see [mealioDefaultStrings]),
  /// `formatMoney`, `sheet` and `onEvent` (every step of the sheet, for your
  /// analytics; nothing is sent to Mealio) go with it. `MealioScope` overrides
  /// each one.
  ///
  /// `onSignInRequired` is called when a [MealioCartButton] or the store
  /// settings are used while [setUser] says nobody is signed in.
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
    MealioEventListener? onEvent,
    VoidCallback? onSignInRequired,
  }) {
    MealioLook.configured = MealioLook(
      theme: theme,
      darkTheme: darkTheme,
      colorScheme: colorScheme,
      strings: strings,
      formatMoney: formatMoney,
      sheet: sheet,
      onEvent: onEvent,
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
        queue: _queue,
        debug: kDebugMode,
      ),
      _ScopedHost(),
    );
    // The hidden page checks its own navigations against the same list.
    WebViewHost.sharedAllowlist = client.allowlist;
    // Whatever the old configuration had under way stops with it.
    _instance?._client.cancelJobs();
    return _instance = MealioCart._(client, onSignInRequired);
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
  final VoidCallback? _onSignInRequired;
  final _Notifier _userChanges = _Notifier();
  bool _tracking = false;
  String? _user;

  /// The client underneath, for apps that drive the protocol themselves.
  MealioClient get client => _client;

  /// The `onSignInRequired` given to [configure].
  VoidCallback? get onSignInRequired => _onSignInRequired;

  /// What [setUser] was last given. Null before the first call, too: see [hasUser].
  String? get userId => _user;

  /// False while [setUser] says nobody is signed in. True until it is first called.
  bool get hasUser => !_tracking || _user != null;

  /// Notifies on every change of [setUser].
  Listenable get userChanges => _userChanges;

  /// Tell the SDK who is signed in to your app, or null for nobody. Call it
  /// at start and whenever that changes.
  ///
  /// A change stops any cart being prepared or searched (an add under way
  /// finishes), starts a new Mealio session, and if the old value was a user,
  /// signs out of the stores. A failed store sign-out never blocks this and
  /// is never thrown. While null there is no session and no warm-up, and
  /// [MealioCartButton] calls `onSignInRequired` instead of opening.
  void setUser(String? id) {
    if (_tracking && id == _user) return;
    _tracking = true;
    _user = id;
    if (_client.setUser(id)) {
      unawaited(_clearStores().then<void>((_) {}, onError: (Object _) {}));
    }
    _userChanges.notify();
  }

  /// Stop every cart being prepared or searched. An add under way runs on.
  void cancelJobs() => _client.cancelJobs();

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
    CancelToken? cancel,
  }) async {
    if (WebViewHost.current == null) {
      throw const MealioException(MealioErrorCode.noScope, 'Place MealioScope near the root of your app.');
    }
    return _client.prepareCart(store: store, recipe: recipe, recipes: recipes, zip: zip, onStep: onStep, cancel: cancel);
  }

  /// Runs the login check for the user's store ahead of time, so the next
  /// cart starts at search. MealioCartButton does this when it appears; call
  /// it yourself if you start carts another way. Never shows sign-in, never
  /// throws, and does nothing until a MealioScope is mounted.
  Future<void> warm({String? store}) async {
    if (WebViewHost.current == null || !hasUser) return;
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
    _client.cancelJobs();
    _client.resetSession();
    await _clearStores();
  }

  /// Nothing may keep running in, or remember, the old session's page.
  /// Queued, so an add under way finishes first and the next cart waits.
  Future<void> _clearStores() => _client.runExclusive(() async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(_epochKey, (prefs.getInt(_epochKey) ?? 0) + 1);
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
      });

  /// The signed-in user changed. Forget the session, so the next call asks
  /// your server for a new one. Signing out of the stores does this too.
  void resetSession() => _client.resetSession();

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
