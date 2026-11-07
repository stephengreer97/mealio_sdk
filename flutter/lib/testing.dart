/// Test support for apps that use mealio_sdk.
///
/// A widget test of a screen that holds `MealioScope` and
/// `MealioCartButton` needs a WebView platform (there is none under
/// `flutter test`), stored preferences, and a Mealio that answers without
/// the network:
///
/// ```dart
/// import 'package:mealio_sdk/testing.dart';
///
/// setUp(() {
///   installMealioTestPlatform();
///   configureMealioForTesting(onSignInRequired: () => signInTapped = true);
/// });
///
/// testWidgets('recipe screen', (tester) async {
///   await tester.pumpWidget(MyApp()); // with MealioScope and MealioCartButton
///   await tester.tap(find.byType(MealioCartButton));
///   await tester.pump();
/// });
/// ```
///
/// Nothing here reaches a store or Mealio. The fake WebView never loads a
/// page; [MealioFakeWebViewController] records what the SDK asked of it.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'src/client.dart' show defaultBaseUrl;
import 'src/mealio_cart.dart';

/// Makes `MealioScope` work in `flutter test`: installs
/// [MealioFakeWebViewPlatform] as the WebView platform, and gives
/// `SharedPreferences` an in-memory store holding `preferences` (the SDK
/// keeps its store sign-out count there, under `mealio_sdk.store_epoch`).
/// Call it in `setUp`, or at the start of each test. Returns the platform.
MealioFakeWebViewPlatform installMealioTestPlatform({Map<String, Object> preferences = const <String, Object>{}}) {
  // ignore: invalid_use_of_visible_for_testing_member
  SharedPreferences.setMockInitialValues(preferences);
  MealioFakeWebViewController.reset();
  final platform = MealioFakeWebViewPlatform();
  WebViewPlatform.instance = platform;
  return platform;
}

/// [MealioCart.configure] for a test. Every request goes to `httpClient`
/// instead of the network. Without one, each answers 503 with a `server`
/// error, so a cart shows the error screen and a warm-up does nothing.
/// `sessionTokenProvider` defaults to one that returns `"test-session"`.
/// Configuring again in the next test replaces it.
MealioCart configureMealioForTesting({
  String publishableKey = 'pk_test_mealio',
  Future<String> Function()? sessionTokenProvider,
  http.Client? httpClient,
  String baseUrl = defaultBaseUrl,
  VoidCallback? onSignInRequired,
}) {
  final client = httpClient ?? MockClient((http.Request _) async => mealioTestErrorResponse());
  return http.runWithClient(
    () => MealioCart.configure(
      publishableKey: publishableKey,
      sessionTokenProvider: sessionTokenProvider ?? () async => 'test-session',
      baseUrl: baseUrl,
      onSignInRequired: onSignInRequired,
    ),
    () => client,
  );
}

/// A Mealio error answer, as the API sends it.
http.Response mealioTestErrorResponse({int status = 503, String code = 'server', String message = 'Test server'}) =>
    http.Response.bytes(
      utf8.encode(jsonEncode(<String, Object?>{
        'error': <String, Object?>{'code': code, 'message': message},
      })),
      status,
      headers: <String, String>{'content-type': 'application/json'},
    );

/// A WebView platform that draws an empty box and never loads anything.
class MealioFakeWebViewPlatform extends WebViewPlatform {
  @override
  PlatformWebViewController createPlatformWebViewController(PlatformWebViewControllerCreationParams params) =>
      MealioFakeWebViewController(params);

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(PlatformNavigationDelegateCreationParams params) =>
      MealioFakeNavigationDelegate(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(PlatformWebViewWidgetCreationParams params) =>
      MealioFakeWebViewWidget(params);

  @override
  PlatformWebViewCookieManager createPlatformCookieManager(PlatformWebViewCookieManagerCreationParams params) =>
      MealioFakeCookieManager(params);
}

/// Holds the page callbacks the SDK registered, so a test can fire them.
class MealioFakeNavigationDelegate extends PlatformNavigationDelegate {
  MealioFakeNavigationDelegate(super.params) : super.implementation();

  NavigationRequestCallback? onNavigationRequest;
  PageEventCallback? onPageStarted;
  PageEventCallback? onPageFinished;
  WebResourceErrorCallback? onWebResourceError;
  UrlChangeCallback? onUrlChange;

  @override
  Future<void> setOnNavigationRequest(NavigationRequestCallback onNavigationRequest) async =>
      this.onNavigationRequest = onNavigationRequest;

  @override
  Future<void> setOnPageStarted(PageEventCallback onPageStarted) async => this.onPageStarted = onPageStarted;

  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async => this.onPageFinished = onPageFinished;

  @override
  Future<void> setOnHttpError(HttpResponseErrorCallback onHttpError) async {}

  @override
  Future<void> setOnProgress(ProgressCallback onProgress) async {}

  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback onWebResourceError) async =>
      this.onWebResourceError = onWebResourceError;

  @override
  Future<void> setOnUrlChange(UrlChangeCallback onUrlChange) async => this.onUrlChange = onUrlChange;

  @override
  Future<void> setOnHttpAuthRequest(HttpAuthRequestCallback onHttpAuthRequest) async {}

  @override
  Future<void> setOnSSlAuthError(SslAuthErrorCallback onSslAuthError) async {}
}

/// Records the loads and scripts the SDK asked for. By default a load
/// starts and finishes at once.
class MealioFakeWebViewController extends PlatformWebViewController {
  MealioFakeWebViewController(super.params) : super.implementation() {
    all.add(this);
  }

  /// Every controller made since [reset], oldest first.
  static final List<MealioFakeWebViewController> all = <MealioFakeWebViewController>[];

  /// When set, `runJavaScript` of a script containing this never completes.
  static String? hangOn;

  /// Called on each load instead of starting and finishing the page at once.
  static void Function(MealioFakeWebViewController controller, String url)? onLoad;

  /// Forgets [all], [hangOn] and [onLoad].
  static void reset() {
    all.clear();
    hangOn = null;
    onLoad = null;
  }

  MealioFakeNavigationDelegate? delegate;
  final List<String> loads = <String>[];
  final List<String> scripts = <String>[];

  /// The SDK's bridge channel. Post a message as the page would with
  /// `channel!.onMessageReceived(JavaScriptMessage(message: ...))`.
  JavaScriptChannelParams? channel;
  String? url;

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams javaScriptChannelParams) async =>
      channel = javaScriptChannelParams;

  @override
  Future<void> setPlatformNavigationDelegate(PlatformNavigationDelegate handler) async =>
      delegate = handler as MealioFakeNavigationDelegate;

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    final u = params.uri.toString();
    loads.add(u);
    url = u;
    final f = onLoad;
    if (f != null) {
      f(this, u);
    } else {
      delegate?.onPageStarted?.call(u);
      delegate?.onPageFinished?.call(u);
    }
  }

  @override
  Future<String?> currentUrl() async => url;

  @override
  Future<void> runJavaScript(String javaScript) {
    scripts.add(javaScript);
    final h = hangOn;
    if (h != null && javaScript.contains(h)) return Completer<void>().future;
    return Future<void>.value();
  }

  @override
  Future<void> clearCache() async {}

  @override
  Future<void> clearLocalStorage() async {}
}

/// Draws an empty box in place of the WebView.
class MealioFakeWebViewWidget extends PlatformWebViewWidget {
  MealioFakeWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox(key: ValueKey<String>('mealio-fake-webview'));
}

/// Clearing cookies succeeds and does nothing.
class MealioFakeCookieManager extends PlatformWebViewCookieManager {
  MealioFakeCookieManager(super.params) : super.implementation();

  @override
  Future<bool> clearCookies() async => true;
}
