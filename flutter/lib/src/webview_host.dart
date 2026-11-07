// The Flutter Host: a hidden WebView that holds the user's store session, a
// visible login sheet that shares its cookies, and fetch through the hidden
// page. The hidden WebView is drawn by `MealioScope` (widgets/mealio_scope.dart);
// this class owns its controller.
//
// Cookie store: both WebViews use the platform default store (Android's
// process-wide CookieManager, iOS's WKWebsiteDataStore.default()), which is
// what webview_flutter uses when no custom data store is given. So a login in
// the sheet is a login in the hidden WebView.
// VERIFY: on iOS, cookies set in the login WKWebView reach the hidden WKWebView
// without a reload (separate WKProcessPools can sync the shared store late).

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart' show ValueListenable, kDebugMode;
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import 'allowlist.dart';
import 'guard.dart';
import 'host.dart';
import 'matcher.dart';
import 'protocol.dart';
import 'theme.dart';
import 'ui.dart';

/// The JavaScriptChannel every Mealio WebView registers.
const String bridgeChannelName = '__mealioNativeBridge';

/// Defines `window.__mealioNativePost` on top of the channel, then installs
/// `window.ReactNativeWebView.postMessage` (BRIDGE_SHIM). Both halves are
/// idempotent, so it is safe to inject on every page start and before every
/// script.
///
/// The channel is reachable from every frame, and its messages carry no frame
/// info. So `__mealioNativePost`, which only our top-frame injection defines,
/// wraps each message as `{"n": nonce, "m": message}` with a random nonce the
/// Dart side holds, and [bridgeUnwrap] drops anything without it. A sub-frame
/// calling the channel directly cannot forge a result.
///
/// The hidden page takes a new nonce for every script it runs, and this also
/// replaces `window.ReactNativeWebView` with one bound to that nonce. A late
/// message from an earlier script, through the poster it held, carries the
/// old nonce and is dropped.
String bridgeInjection(String nonce) {
  final n = jsonEncode(nonce);
  return 'window.__mealioNativePost = function(s){ __mealioNativeBridge.postMessage(JSON.stringify({ n: '
      '$n, m: String(s) })) };'
      '(function(){ try { window.ReactNativeWebView = { postMessage: function (s) { try { '
      '__mealioNativeBridge.postMessage(JSON.stringify({ n: $n, m: String(s) })); } catch (e) {} } }; } catch (e) {} })();'
      '$bridgeShim';
}

/// The original message posted through [bridgeInjection] with `nonce`, or
/// null when `raw` was not posted that way.
String? bridgeUnwrap(String raw, String nonce) {
  Object? j;
  try {
    j = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  if (j is! Map<String, Object?>) return null;
  final m = j['m'];
  if (j['n'] != nonce || m is! String) return null;
  return m;
}

final Random _random = Random.secure();

/// A fresh bridge nonce: 128 random bits, hex.
String _newNonce() =>
    List<String>.generate(16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

bool _isBlank(String url) => url.startsWith('about:blank');

/// Message type the in-page fetch posts back. Never collected by `runScript`.
const String fetchResultType = 'MEALIO_FETCH_RESULT';

/// Login sheets keep at most this many messages (the most recent).
const int _maxLoginMessages = 200;

/// A WebViewController set up the way every Mealio WebView needs it.
WebViewController _newController({
  required String Function() nonce,
  required void Function(String message) onMessage,
  required NavigationDelegate delegate,
}) {
  final c = WebViewController();
  // These return futures that complete once the platform side has applied
  // the setting. Platform calls run in order, so the first loadRequest sees
  // all of them.
  unawaited(c.setJavaScriptMode(JavaScriptMode.unrestricted));
  unawaited(c.addJavaScriptChannel(
    bridgeChannelName,
    onMessageReceived: (JavaScriptMessage m) {
      final s = bridgeUnwrap(m.message, nonce());
      if (s != null) onMessage(s);
    },
  ));
  unawaited(c.setNavigationDelegate(delegate));
  _applyPlatformSettings(c);
  return c;
}

void _applyPlatformSettings(WebViewController c) {
  final p = c.platform;
  if (p is AndroidWebViewController) {
    // Store logins hand off to identity providers (Google, Apple, Microsoft,
    // Instacart, Albertsons) that set cookies from their own domains. Android
    // WebView drops third-party cookies unless told otherwise.
    final cookies = WebViewCookieManager().platform;
    if (cookies is AndroidWebViewCookieManager) {
      // VERIFY: AndroidWebViewCookieManager.setAcceptThirdPartyCookies(AndroidWebViewController, bool)
      unawaited(cookies.setAcceptThirdPartyCookies(p, true));
    }
    unawaited(p.setMediaPlaybackRequiresUserGesture(true));
  } else if (p is WebKitWebViewController) {
    // Lets a developer inspect the store page from Safari in debug builds.
    // VERIFY: WebKitWebViewController.setInspectable exists in the resolved webview_flutter_wkwebview.
    if (kDebugMode) unawaited(p.setInspectable(true));
  }
}

Future<void> _injectBridge(WebViewController c, String nonce) async {
  try {
    await c.runJavaScript(bridgeInjection(nonce));
  } catch (_) {
    // No document yet (about:blank on some platforms); the next page start
    // or the next script injects again.
  }
}

/// Replaces whatever the WebView shows with a blank page.
Future<void> _loadBlank(WebViewController c) async {
  try {
    await c.loadRequest(Uri.parse('about:blank'));
  } catch (_) {
    // No WebView platform (tests); nothing showing.
  }
}

/// Runs `script` and ignores any JavaScript error it reports. React Native's
/// `injectJavaScript` (the reference host) never reports errors, and Android's
/// `evaluateJavascript` doesn't either; iOS does. Ignoring them keeps every
/// platform the same: a failing script simply posts nothing and times out.
Future<void> _runQuietly(WebViewController c, String script) async {
  try {
    await c.runJavaScript(script);
  } catch (e) {
    if (kDebugMode) debugPrint('mealio_sdk: script error ignored: $e');
  }
}

class _LoadEnd {
  const _LoadEnd({this.url, this.error});
  final String? url;
  final String? error;
}

/// One page_open's wait. Only this request's own events settle it: a finish
/// counts once a page has started since the request, and never for a
/// navigation that was replaced before it finished.
class _PageWait {
  final Completer<_LoadEnd> done = Completer<_LoadEnd>();

  /// The page that started for this request, if one has.
  String? started;

  /// Pages whose navigation was replaced (a redirect, or Android's plugin
  /// cancelling a navigation and loading it again). Their finish is stale.
  final Set<String> replaced = <String>{};

  void end(_LoadEnd e) {
    if (!done.isCompleted) done.complete(e);
  }
}

/// Runs `f` until `end`. False when time ran out first; `f` is then left
/// behind, so a platform call that never returns cannot hold up the page.
Future<bool> _before(Future<void> f, DateTime end) async {
  final left = end.difference(DateTime.now());
  if (left <= Duration.zero) return false;
  try {
    await f.timeout(left);
    return true;
  } on TimeoutException {
    return false;
  }
}

/// A store sign-in in progress, handed to an open cart flow sheet so it can
/// show the sign-in inside itself. [webview] shares the hidden WebView's
/// cookie store, and its navigation is checked against the allowlist exactly
/// as on the full-screen login route.
class MealioLoginView {
  MealioLoginView({required this.url, required this.title, required this.controller, required VoidCallback cancel})
      : _cancel = cancel;

  /// The page the sign-in started on.
  final String url;

  /// The title the server gave, e.g. "Sign in to H-E-B".
  final String title;

  /// The visible WebView's controller.
  final WebViewController controller;
  final VoidCallback _cancel;

  /// The sign-in WebView, ready to place in a sheet. Mount one at a time.
  Widget get webview => WebViewWidget(controller: controller);

  /// Ends the sign-in as cancelled.
  void cancel() => _cancel();
}

/// The Flutter [MealioHost]. One per app, created and drawn by `MealioScope`.
class WebViewHost implements MealioHost {
  WebViewHost() {
    hidden = _newController(
      // Read per message: it changes with every script.
      nonce: () => _hiddenNonce,
      onMessage: _hiddenMessages.add,
      delegate: NavigationDelegate(
        // The runner checks every page_open, but a page can navigate itself
        // (a script, a redirect, a form). Main-frame navigations stay on the
        // current store's own pages or its sign-in hosts (a store sign-in can
        // bounce the storefront through its identity host). Sub-frames are not
        // navigations of the page.
        onNavigationRequest: (NavigationRequest r) {
          if (!r.isMainFrame || _isBlank(r.url)) return NavigationDecision.navigate;
          final l = _load;
          if (_pageAllowed(r.url)) {
            // A new navigation replaces the page that started, and that
            // page's finish must not end the wait. On Android the plugin
            // cancels every main-frame navigation it is asked about and loads
            // it again itself, and the cancelled one can still report a
            // finish: wait for the reissued load to start. iOS lets the
            // navigation go on, and a server redirect starts no new page.
            final from = l?.started;
            if (l != null && from != null && from != r.url) l.replaced.add(from);
            if (l != null && reissuesNavigations) l.started = null;
            return NavigationDecision.navigate;
          }
          l?.end(const _LoadEnd(error: 'blocked'));
          return NavigationDecision.prevent;
        },
        // webview_flutter has no universal document-start script API, so the
        // bridge goes in at page start and again before every script. On iOS
        // onPageStarted can still see the previous document; the second
        // injection is the one that counts.
        onPageStarted: (String url) {
          if (_isBlank(url)) return;
          // The backstop: some navigations (a form POST, for one) never reach
          // onNavigationRequest. A page we would have refused is replaced
          // with a blank one, as on the login sheet.
          if (!_pageAllowed(url)) {
            unawaited(_loadBlank(hidden));
            _load?.end(_LoadEnd(url: url, error: 'blocked'));
            return;
          }
          unawaited(_injectBridge(hidden, _hiddenNonce));
          final l = _load;
          if (l != null) {
            l.started = url;
            l.replaced.remove(url);
          }
        },
        onPageFinished: (String url) {
          if (_isBlank(url)) return;
          unawaited(_injectBridge(hidden, _hiddenNonce));
          final l = _load;
          // A page that finished without starting for this request is an
          // older load: a stale finish never answers this one.
          if (l == null || l.started == null || l.replaced.contains(url)) return;
          l.end(_LoadEnd(url: url));
        },
        onWebResourceError: (WebResourceError e) {
          // iOS reports a web content process that died here. The page it
          // held is gone, so no warm-up may count on it.
          if (e.errorType == WebResourceErrorType.webContentProcessTerminated) _page = Object();
          // VERIFY: WebResourceError.isForMainFrame (nullable bool) in the resolved webview_flutter version.
          if (e.isForMainFrame != true) return;
          _load?.end(const _LoadEnd(error: 'load_failed'));
        },
      ),
    );
  }

  static final ValueNotifier<WebViewHost?> _current = ValueNotifier<WebViewHost?>(null);

  /// The host of the mounted `MealioScope`, or null when none is mounted.
  static WebViewHost? get current => _current.value;

  /// Notifies when the mounted host changes, as on a `MealioScope` remount.
  /// An open cart flow moves to the new host.
  static ValueListenable<WebViewHost?> get currentListenable => _current;

  /// Called by `MealioScope`. The most recently mounted scope wins.
  static void attach(WebViewHost host) => _current.value = host;

  /// Called by `MealioScope` on dispose.
  static void detach(WebViewHost host) {
    if (identical(_current.value, host)) _current.value = null;
  }

  /// The page the hidden WebView holds, compared by identity. Replaced when
  /// the page is lost, so a warm-up made on it is not offered.
  Object get page => _page;
  Object _page = Object();

  /// True on Android, where webview_flutter_android cancels each main-frame
  /// navigation it asks about and loads it again
  /// (AndroidNavigationDelegate._handleNavigation).
  @visibleForTesting
  late bool reissuesNavigations = hidden.platform is AndroidWebViewController;

  bool _pageAllowed(String url) {
    final store = _pageStore;
    return store != null &&
        (_allowlist.check(store, url, UrlUse.page).ok || _allowlist.check(store, url, UrlUse.login).ok);
  }

  /// The hidden WebView's controller. `MealioScope` draws it.
  late final WebViewController hidden;

  /// The allowlist the hidden page's own navigations and fetch redirects are
  /// checked against. `MealioCart.configure` sets it to the client's (so a
  /// signed widening applies here too); the bundled list stands otherwise.
  static Allowlist? sharedAllowlist;
  static final Allowlist _bundledAllowlist = Allowlist();
  Allowlist get _allowlist => sharedAllowlist ?? _bundledAllowlist;

  /// The hidden page's bridge nonce. A new one for every script, so a late
  /// message from the script before cannot answer the next.
  String _hiddenNonce = _newNonce();

  /// The store whose page the hidden WebView was last asked to open.
  String? _pageStore;

  /// Where the login sheet is pushed. Set by `MealioScope`.
  NavigatorState? Function()? navigatorProvider;

  /// What was given to `MealioScope`, if anything.
  MealioLook? look;

  /// The theme given to `MealioScope`, if any.
  MealioTheme? get theme => look?.theme;

  /// The sign-in in progress while a cart flow sheet is open, else null.
  /// The flow sheet listens to this and shows [MealioLoginView.webview].
  final ValueNotifier<MealioLoginView?> login = ValueNotifier<MealioLoginView?>(null);

  int _flows = 0;

  /// Whether a cart flow sheet is open (and so hosts sign-ins itself).
  bool get flowOpen => _flows > 0;

  /// Called by a cart flow sheet when it opens. While one is open, sign-ins
  /// go to [login] instead of a route of their own.
  void flowOpened() => _flows += 1;

  /// Called by a cart flow sheet when it closes. Closing the last one cancels
  /// a sign-in it was showing.
  void flowClosed() {
    if (_flows > 0) _flows -= 1;
    if (_flows == 0) login.value?.cancel();
  }

  final StreamController<String> _hiddenMessages = StreamController<String>.broadcast();
  _PageWait? _load;
  Future<void> _tail = Future<void>.value();
  int _fetchSeq = 0;

  /// The hidden WebView does one thing at a time. Whole jobs are queued by
  /// the client (JobQueue); this also keeps single steps from overlapping.
  /// Every task here ends by its own timeout, so a platform call that never
  /// returns cannot block the steps behind it.
  Future<T> _serial<T>(Future<T> Function() task) {
    final run = _tail.then((_) => task());
    _tail = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  @override
  Future<PageLoad> openPage(String store, String url, int timeoutMs) {
    return _serial(() async {
      final until = DateTime.now().add(Duration(milliseconds: timeoutMs));
      final wait = _PageWait();
      // Only this request's wait is live: an older one ends here.
      _load?.end(const _LoadEnd(error: 'superseded'));
      _load = wait;
      _pageStore = store;
      try {
        try {
          if (!await _before(hidden.loadRequest(Uri.parse(url)), until)) return _stopLoad();
        } catch (_) {
          return const PageLoad(ok: false, error: 'load_failed');
        }
        final _LoadEnd end;
        try {
          end = await wait.done.future.timeout(until.difference(DateTime.now()));
        } on TimeoutException {
          return _stopLoad();
        }
        if (end.error != null) return PageLoad(ok: false, finalUrl: end.url, error: end.error);
        String? finalUrl = end.url;
        try {
          finalUrl = await hidden.currentUrl().timeout(const Duration(seconds: 1)) ?? finalUrl;
        } catch (_) {
          // Keep the URL onPageFinished reported.
        }
        return PageLoad(ok: true, finalUrl: finalUrl);
      } finally {
        if (identical(_load, wait)) _load = null;
      }
    });
  }

  /// A load that ran out of time is stopped, so it cannot finish later under
  /// the next step's script.
  PageLoad _stopLoad() {
    unawaited(_loadBlank(hidden));
    return const PageLoad(ok: false, error: 'timeout');
  }

  @override
  Future<ScriptRun> runScript(
    String store,
    String guard,
    String script,
    List<MessageMatcher> until,
    int timeoutMs,
  ) {
    return _serial(() async {
      // This run's own nonce: anything stamped for an earlier one is dropped.
      _hiddenNonce = _newNonce();
      final messages = <JsonMessage>[];
      final matched = Completer<void>();
      final started = DateTime.now();
      // Listen before injecting, so a message the script posts synchronously
      // is not missed. Everything posted from here on is "after injection".
      final sub = _hiddenMessages.stream.listen((String raw) {
        final m = parseMessage(raw);
        if (m == null || m['type'] == fetchResultType) return;
        messages.add(m);
        if (!matched.isCompleted && messageMatchesAny(m, until)) matched.complete();
      });
      // The timeout covers the injection too: a runJavaScript that never
      // returns ends this step as timed out.
      final deadline = started.add(Duration(milliseconds: timeoutMs));
      try {
        final injected = await _before(
          () async {
            await _injectBridge(hidden, _hiddenNonce);
            await _runQuietly(hidden, guard);
            await _runQuietly(hidden, script);
          }(),
          deadline,
        );
        final timedOut = !matched.isCompleted && !(injected && await _before(matched.future, deadline));
        return ScriptRun(messages: List<JsonMessage>.of(messages), timedOut: timedOut);
      } finally {
        await sub.cancel();
      }
    });
  }

  /// One HTTP request with the store's cookies.
  ///
  /// webview_flutter's `WebViewCookieManager` can set and clear cookies but
  /// cannot READ them, so the request cannot be made from Dart with a Cookie
  /// header. Instead it runs INSIDE the hidden WebView page as
  /// `fetch(url, {credentials: 'include'})` and posts the response back over
  /// the bridge. Consequences, all of which the server plans for:
  /// - It runs on whatever page the hidden WebView is on, so the server opens
  ///   a store page first (`page_open`) and the page's CORS rules apply.
  /// - It goes through `window.fetch`, which GUARD_SCRIPT wraps when present,
  ///   so the guard's blocks and rate cap apply too.
  /// - Headers the browser forbids scripts to set (Cookie, User-Agent,
  ///   Origin, Referer) are ignored; the browser sends its own.
  /// - `maxBytes` counts UTF-8 bytes of the response text, truncated in JS
  ///   before the body crosses the bridge.
  @override
  Future<HttpResult> fetch(String store, FetchRequest request, int timeoutMs, int maxBytes) {
    return _serial(() async {
      _fetchSeq += 1;
      final id = 'mf${_fetchSeq}_${DateTime.now().microsecondsSinceEpoch}';
      final result = Completer<HttpResult>();
      final sub = _hiddenMessages.stream.listen((String raw) {
        final m = parseMessage(raw);
        if (m == null || m['type'] != fetchResultType || m['id'] != id || result.isCompleted) return;
        // A redirect off the store's allowed hosts: the body is not the
        // store's, and must not reach the server as if it were.
        final finalUrl = m['url'];
        if (m['ok'] == true &&
            finalUrl is String &&
            finalUrl.isNotEmpty &&
            finalUrl != request.url &&
            !_allowlist.check(store, finalUrl, UrlUse.fetch).ok) {
          result.complete(const HttpResult(ok: false, error: 'redirect_blocked'));
          return;
        }
        result.complete(_httpResultFrom(m));
      });
      // The JS side aborts at timeoutMs; the extra time covers the trip back.
      // The injection counts against it too.
      final until = DateTime.now().add(Duration(milliseconds: timeoutMs + 2000));
      try {
        try {
          final injected = await _before(
            () async {
              await _injectBridge(hidden, _hiddenNonce);
              await hidden.runJavaScript(_fetchScript(id, request, timeoutMs, maxBytes));
            }(),
            until,
          );
          if (!injected) return const HttpResult(ok: false, error: 'timeout');
        } catch (_) {
          return const HttpResult(ok: false, error: 'no_response');
        }
        if (result.isCompleted) return await result.future;
        if (!await _before(result.future, until)) return const HttpResult(ok: false, error: 'timeout');
        return await result.future;
      } finally {
        await sub.cancel();
      }
    });
  }

  static HttpResult _httpResultFrom(JsonMessage m) {
    if (m['ok'] != true) {
      return HttpResult(ok: false, error: m['error'] is String ? m['error']! as String : 'no_response');
    }
    final headers = <String, String>{};
    final h = m['headers'];
    if (h is Map) {
      for (final MapEntry<Object?, Object?> e in h.entries) {
        final k = e.key;
        final v = e.value;
        if (k is String && v != null) headers[k] = v.toString();
      }
    }
    return HttpResult(
      ok: true,
      status: m['status'] is num ? (m['status']! as num).toInt() : null,
      headers: headers,
      body: m['body'] is String ? m['body']! as String : '',
      truncated: m['truncated'] == true,
    );
  }

  static String _fetchScript(String id, FetchRequest req, int timeoutMs, int maxBytes) {
    // Every value goes in as a JSON literal, so nothing from the request can
    // break out of the script.
    final args = jsonEncode(<String, Object?>{
      'id': id,
      'method': req.method,
      'url': req.url,
      'headers': req.headers,
      'body': req.body,
      'timeoutMs': timeoutMs,
      'maxBytes': maxBytes,
    });
    return '''
(function(){
  var a = $args;
  function post(o) { try { window.ReactNativeWebView.postMessage(JSON.stringify(o)); } catch (e) {} }
  var ctrl = (typeof AbortController !== 'undefined') ? new AbortController() : null;
  var timer = ctrl ? setTimeout(function () { ctrl.abort(); }, a.timeoutMs) : null;
  var method = String(a.method || 'GET').toUpperCase();
  var init = { method: method, headers: a.headers || {}, credentials: 'include' };
  if (a.body != null && method !== 'GET' && method !== 'HEAD') init.body = a.body;
  if (ctrl) init.signal = ctrl.signal;
  function cut(text) {
    if (typeof TextEncoder === 'undefined' || typeof TextDecoder === 'undefined') {
      return text.length > a.maxBytes ? { body: text.slice(0, a.maxBytes), truncated: true } : { body: text, truncated: false };
    }
    var bytes = new TextEncoder().encode(text);
    if (bytes.length <= a.maxBytes) return { body: text, truncated: false };
    return { body: new TextDecoder().decode(bytes.slice(0, a.maxBytes)), truncated: true };
  }
  try {
    fetch(a.url, init).then(function (res) {
      var headers = {};
      try { res.headers.forEach(function (v, k) { headers[k] = v; }); } catch (e) {}
      return res.text().then(function (text) {
        var c = cut(text);
        post({ type: '$fetchResultType', id: a.id, ok: true, status: res.status, url: String(res.url || ''), headers: headers, body: c.body, truncated: c.truncated });
      });
    }).catch(function (e) {
      post({ type: '$fetchResultType', id: a.id, ok: false, error: (e && e.name === 'AbortError') ? 'timeout' : 'no_response' });
    }).then(function () { if (timer) clearTimeout(timer); });
  } catch (e) {
    post({ type: '$fetchResultType', id: a.id, ok: false, error: 'no_response' });
  }
})(); true;''';
  }

  /// Shows the store's login page full screen, in a VISIBLE WebView that
  /// shares the hidden WebView's cookie store.
  ///
  /// - Every top-frame navigation is checked with `allowNavigation`; refused
  ///   ones are cancelled. Sub-frame navigations (captcha, consent) are not
  ///   navigations of the sheet and are let through, as PROTOCOL.md says.
  /// - After every page load and every `check.intervalMs`, GUARD_SCRIPT then
  ///   `check.script` are injected; a message matching `doneWhen` means
  ///   signed in.
  /// - A URL matching `doneWhenUrl` also means signed in.
  /// - Close, the system back gesture, or popping the route means cancelled.
  ///
  /// When a cart flow sheet is open ([flowOpen]) the sign-in is handed to it
  /// through [login] and shows inside that sheet. Otherwise it is pushed as a
  /// route of its own.
  @override
  Future<LoginResult> showLogin(LoginRequest req) async {
    final inFlow = flowOpen;
    final NavigatorState? nav = inFlow ? null : navigatorProvider?.call();
    if (!inFlow && nav == null) {
      throw StateError('mealio_sdk: no Navigator for the login sheet. '
          'Pass navigatorKey to MealioScope, or place MealioScope below your Navigator.');
    }

    final messages = <JsonMessage>[];
    final done = Completer<LoginOutcome>();
    void finish(LoginOutcome o) {
      if (!done.isCompleted) done.complete(o);
    }

    final RegExp? doneUrl = _compileDoneUrl(req.doneWhenUrl);
    bool urlDone(String? u) => u != null && doneUrl != null && doneUrl.hasMatch(u);

    // When the matching navigation is one the allowlist lets through (for
    // example Kroger's OAuth return to mealio.co), let it load before closing
    // so its request reaches the server. This timer is the fallback in case
    // the platform never reports the commit.
    // VERIFY: with Kroger's real OAuth return that the 10 s fallback and onUrlChange
    // close the sheet only after the return request has reached the server.
    Timer? returnTimer;

    late final WebViewController c;
    final nonce = _newNonce();
    Future<void> inject() async {
      await _injectBridge(c, nonce);
      await _runQuietly(c, req.guard);
      final check = req.check;
      if (check != null && check.script.isNotEmpty) await _runQuietly(c, check.script);
    }

    c = _newController(
      nonce: () => nonce,
      onMessage: (String raw) {
        final m = parseMessage(raw);
        if (m == null) return;
        messages.add(m);
        if (messages.length > _maxLoginMessages) messages.removeAt(0);
        if (messageMatchesAny(m, req.doneWhen)) finish(LoginOutcome.signedIn);
      },
      delegate: NavigationDelegate(
        onNavigationRequest: (NavigationRequest r) {
          if (!r.isMainFrame || _isBlank(r.url)) return NavigationDecision.navigate;
          final allowed = req.allowNavigation(r.url);
          if (urlDone(r.url)) {
            if (!allowed) {
              // The URL itself is the signal; nothing needs to load.
              finish(LoginOutcome.signedIn);
            } else {
              returnTimer ??= Timer(const Duration(seconds: 10), () => finish(LoginOutcome.signedIn));
            }
          }
          return allowed ? NavigationDecision.navigate : NavigationDecision.prevent;
        },
        // The backstop: some navigations (a form POST on iOS, for one) never
        // reach onNavigationRequest. A top-frame page we would have refused
        // is replaced with a blank one and ends the sign-in.
        onPageStarted: (String url) {
          if (_isBlank(url) || req.allowNavigation(url)) {
            unawaited(_injectBridge(c, nonce));
            return;
          }
          unawaited(_loadBlank(c));
          finish(urlDone(url) ? LoginOutcome.signedIn : LoginOutcome.cancelled);
        },
        onPageFinished: (String url) {
          if (urlDone(url)) {
            finish(LoginOutcome.signedIn);
            return;
          }
          unawaited(inject());
        },
        // Single-page apps change the URL without a page load.
        // VERIFY: NavigationDelegate.onUrlChange / UrlChange.url (webview_flutter >= 4.2).
        onUrlChange: (UrlChange change) {
          if (urlDone(change.url)) finish(LoginOutcome.signedIn);
        },
      ),
    );

    final timers = <Timer>[
      Timer(Duration(milliseconds: req.timeoutMs), () => finish(LoginOutcome.timeout)),
    ];
    // The job was cancelled (the sheet closed, the user changed): close.
    final stopListening = req.cancel?.onCancel(() => finish(LoginOutcome.cancelled));
    unawaited(done.future.then((_) => stopListening?.call()));
    final periodic = req.check;
    if (periodic != null && periodic.script.isNotEmpty && periodic.intervalMs > 0) {
      final every = periodic.intervalMs < 250 ? 250 : periodic.intervalMs;
      timers.add(Timer.periodic(Duration(milliseconds: every), (_) => unawaited(inject())));
    }

    if (nav == null) {
      // Inside the open flow sheet.
      final view = MealioLoginView(
        url: req.url,
        title: req.title,
        controller: c,
        cancel: () => finish(LoginOutcome.cancelled),
      );
      login.value = view;
      try {
        await c.loadRequest(Uri.parse(req.url));
      } catch (_) {
        finish(LoginOutcome.cancelled);
      }
      final outcome = await done.future;
      for (final Timer t in timers) {
        t.cancel();
      }
      returnTimer?.cancel();
      if (identical(login.value, view)) login.value = null;
      return LoginResult(outcome: outcome, messages: List<JsonMessage>.of(messages));
    }

    final route = PageRouteBuilder<void>(
      opaque: true,
      pageBuilder: (BuildContext context, Animation<double> a, Animation<double> b) => _LoginPage(
        title: req.title,
        controller: c,
        onClose: () => finish(LoginOutcome.cancelled),
      ),
      transitionsBuilder: (BuildContext context, Animation<double> a, Animation<double> b, Widget child) {
        return SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
              .animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
          child: child,
        );
      },
    );
    // A pop we did not start (back button, swipe) is a cancel.
    unawaited(nav.push(route).then((_) => finish(LoginOutcome.cancelled)));

    try {
      await c.loadRequest(Uri.parse(req.url));
    } catch (_) {
      finish(LoginOutcome.cancelled);
    }

    final outcome = await done.future;
    for (final Timer t in timers) {
      t.cancel();
    }
    returnTimer?.cancel();
    try {
      if (route.isCurrent) {
        nav.pop();
      } else if (route.isActive) {
        nav.removeRoute(route);
      }
    } catch (_) {
      // The navigator may already be gone; nothing to close.
    }
    return LoginResult(outcome: outcome, messages: List<JsonMessage>.of(messages));
  }

  /// `doneWhenUrl` is a JavaScript regex source. The common subset (classes,
  /// groups, anchors, escapes) means the same in Dart. One that does not
  /// compile is ignored, leaving `doneWhen` and the timeout.
  static RegExp? _compileDoneUrl(String? src) {
    if (src == null || src.isEmpty) return null;
    try {
      return RegExp(src);
    } on FormatException {
      return null;
    }
  }

  /// Clears every cookie in the shared store and the hidden page's local
  /// storage. webview_flutter cannot clear one site's cookies, only all.
  Future<void> clearStoreSessions() async {
    try {
      await WebViewCookieManager().clearCookies();
    } catch (_) {
      // No WebView platform (tests); nothing to clear.
    }
    try {
      await hidden.clearLocalStorage();
    } catch (_) {
      // Best effort; cookies are what hold the store login.
    }
    try {
      await hidden.clearCache();
    } catch (_) {
      // Best effort.
    }
    // The signed-out store page must not stay up in the hidden WebView.
    _pageStore = null;
    await _loadBlank(hidden);
  }
}

/// The full-screen login route, used when no cart flow sheet is open: a
/// title, a Close button, and the visible WebView. Built from plain widgets
/// (no AppBar) so it needs no MaterialLocalizations and works under a
/// CupertinoApp too.
class _LoginPage extends StatelessWidget {
  const _LoginPage({required this.title, required this.controller, required this.onClose});

  final String title;
  final WebViewController controller;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final t = MealioTheme.of(context);
    final close = MealioUi.of(context).tr('close');
    return Material(
      color: t.background,
      child: SafeArea(
        bottom: false,
        child: Column(
          children: <Widget>[
            SizedBox(
              height: 52,
              child: Row(
                children: <Widget>[
                  const SizedBox(width: 16),
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.style(size: 16, weight: FontWeight.w600),
                      ),
                    ),
                  ),
                  Semantics(
                    button: true,
                    label: close,
                    excludeSemantics: true,
                    child: InkWell(
                      onTap: onClose,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Center(
                            child: Text(close, style: t.style(size: 16, weight: FontWeight.w600, color: t.accent)),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                ],
              ),
            ),
            Container(height: 1, color: t.border),
            Expanded(child: WebViewWidget(controller: controller)),
          ],
        ),
      ),
    );
  }
}
