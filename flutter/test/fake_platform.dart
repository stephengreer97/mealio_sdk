// A fake WebView platform, so WebViewHost runs in tests: each controller
// records its loads and scripts, and the test fires the page events by hand.

import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

class FakeDelegate extends PlatformNavigationDelegate {
  FakeDelegate(super.params) : super.implementation();
  NavigationRequestCallback? onNav;
  PageEventCallback? started, finished;
  WebResourceErrorCallback? err;
  UrlChangeCallback? urlChange;
  @override Future<void> setOnNavigationRequest(NavigationRequestCallback c) async => onNav = c;
  @override Future<void> setOnPageStarted(PageEventCallback c) async => started = c;
  @override Future<void> setOnPageFinished(PageEventCallback c) async => finished = c;
  @override Future<void> setOnHttpError(HttpResponseErrorCallback c) async {}
  @override Future<void> setOnProgress(ProgressCallback c) async {}
  @override Future<void> setOnWebResourceError(WebResourceErrorCallback c) async => err = c;
  @override Future<void> setOnUrlChange(UrlChangeCallback c) async => urlChange = c;
  @override Future<void> setOnHttpAuthRequest(HttpAuthRequestCallback c) async {}
  @override Future<void> setOnSSlAuthError(SslAuthErrorCallback c) async {}
}

class FakeController extends PlatformWebViewController {
  FakeController(super.params) : super.implementation() { all.add(this); }
  static final List<FakeController> all = <FakeController>[];
  FakeDelegate? d;
  final List<String> loads = <String>[];
  final List<String> scripts = <String>[];
  /// When set, runJavaScript for a script containing this never completes.
  static String? hangOn;
  /// Called on each load. Default: page finishes at once.
  static void Function(FakeController c, String url)? onLoad;
  JavaScriptChannelParams? channel;
  String? url;
  @override Future<void> setJavaScriptMode(JavaScriptMode m) async {}
  @override Future<void> addJavaScriptChannel(JavaScriptChannelParams p) async => channel = p;
  @override Future<void> setPlatformNavigationDelegate(PlatformNavigationDelegate h) async => d = h as FakeDelegate;
  @override Future<void> loadRequest(LoadRequestParams p) async {
    final u = p.uri.toString();
    loads.add(u); url = u;
    final f = onLoad;
    if (f != null) { f(this, u); } else { d?.started?.call(u); d?.finished?.call(u); }
  }
  @override Future<String?> currentUrl() async => url;
  @override Future<void> runJavaScript(String s) {
    scripts.add(s);
    if (hangOn != null && s.contains(hangOn!)) return Completer<void>().future;
    return Future<void>.value();
  }
  @override Future<void> clearCache() async {}
  @override Future<void> clearLocalStorage() async {}
}

class FakeWidget extends PlatformWebViewWidget {
  FakeWidget(super.params) : super.implementation();
  @override Widget build(BuildContext context) => const SizedBox(key: ValueKey<String>('fake-webview'));
}

class FakeCookies extends PlatformWebViewCookieManager {
  FakeCookies(super.params) : super.implementation();
  @override Future<bool> clearCookies() async => true;
}

class FakePlatform extends WebViewPlatform {
  @override PlatformWebViewController createPlatformWebViewController(PlatformWebViewControllerCreationParams p) => FakeController(p);
  @override PlatformNavigationDelegate createPlatformNavigationDelegate(PlatformNavigationDelegateCreationParams p) => FakeDelegate(p);
  @override PlatformWebViewWidget createPlatformWebViewWidget(PlatformWebViewWidgetCreationParams p) => FakeWidget(p);
  @override PlatformWebViewCookieManager createPlatformCookieManager(PlatformWebViewCookieManagerCreationParams p) => FakeCookies(p);
}
