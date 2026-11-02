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

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import 'guard.dart';
import 'host.dart';
import 'matcher.dart';
import 'protocol.dart';

/// The JavaScriptChannel every Mealio WebView registers.
const String bridgeChannelName = '__mealioNativeBridge';

/// Defines `window.__mealioNativePost` on top of the channel, then installs
/// `window.ReactNativeWebView.postMessage` (BRIDGE_SHIM). Both halves are
/// idempotent, so it is safe to inject on every page start and before every
/// script.
const String bridgeInjection =
    'window.__mealioNativePost = function(s){ __mealioNativeBridge.postMessage(s) };' + bridgeShim;

/// Message type the in-page fetch posts back. Never collected by `runScript`.
const String fetchResultType = 'MEALIO_FETCH_RESULT';

/// Login sheets keep at most this many messages (the most recent).
const int _maxLoginMessages = 200;

/// A WebViewController set up the way every Mealio WebView needs it.
WebViewController _newController({
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
    onMessageReceived: (JavaScriptMessage m) => onMessage(m.message),
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

Future<void> _injectBridge(WebViewController c) async {
  try {
    await c.runJavaScript(bridgeInjection);
  } catch (_) {
    // No document yet (about:blank on some platforms); the next page start
    // or the next script injects again.
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

/// The Flutter [MealioHost]. One per app, created and drawn by `MealioScope`.
class WebViewHost implements MealioHost {
  WebViewHost() {
    hidden = _newController(
      onMessage: _hiddenMessages.add,
      delegate: NavigationDelegate(
        // webview_flutter has no universal document-start script API, so the
        // bridge goes in at page start and again before every script. On iOS
        // onPageStarted can still see the previous document; the second
        // injection is the one that counts.
        onPageStarted: (String url) => unawaited(_injectBridge(hidden)),
        onPageFinished: (String url) {
          unawaited(_injectBridge(hidden));
          final l = _load;
          if (l != null && !l.isCompleted) l.complete(_LoadEnd(url: url));
        },
        onWebResourceError: (WebResourceError e) {
          // VERIFY: WebResourceError.isForMainFrame (nullable bool) in the resolved webview_flutter version.
          if (e.isForMainFrame != true) return;
          final l = _load;
          if (l != null && !l.isCompleted) l.complete(const _LoadEnd(error: 'load_failed'));
        },
      ),
    );
  }

  static WebViewHost? _current;

  /// The host of the mounted `MealioScope`, or null when none is mounted.
  static WebViewHost? get current => _current;

  /// Called by `MealioScope`. The most recently mounted scope wins.
  static void attach(WebViewHost host) => _current = host;

  /// Called by `MealioScope` on dispose.
  static void detach(WebViewHost host) {
    if (identical(_current, host)) _current = null;
  }

  /// The hidden WebView's controller. `MealioScope` draws it.
  late final WebViewController hidden;

  /// Where the login sheet is pushed. Set by `MealioScope`.
  NavigatorState? Function()? navigatorProvider;

  final StreamController<String> _hiddenMessages = StreamController<String>.broadcast();
  Completer<_LoadEnd>? _load;
  Future<void> _tail = Future<void>.value();
  int _fetchSeq = 0;

  /// The hidden WebView does one thing at a time. The Runner is sequential,
  /// but two carts could run at once; this keeps their steps from
  /// interleaving on one page.
  Future<T> _serial<T>(Future<T> Function() task) {
    final run = _tail.then((_) => task());
    _tail = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  @override
  Future<PageLoad> openPage(String store, String url, int timeoutMs) {
    return _serial(() async {
      final done = Completer<_LoadEnd>();
      _load = done;
      try {
        await hidden.loadRequest(Uri.parse(url));
      } catch (_) {
        if (identical(_load, done)) _load = null;
        return const PageLoad(ok: false, error: 'load_failed');
      }
      try {
        final end = await done.future.timeout(Duration(milliseconds: timeoutMs));
        if (end.error != null) return PageLoad(ok: false, error: end.error);
        String? finalUrl = end.url;
        try {
          finalUrl = await hidden.currentUrl() ?? finalUrl;
        } catch (_) {
          // Keep the URL onPageFinished reported.
        }
        return PageLoad(ok: true, finalUrl: finalUrl);
      } on TimeoutException {
        return const PageLoad(ok: false, error: 'timeout');
      } finally {
        if (identical(_load, done)) _load = null;
      }
    });
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
      try {
        await _injectBridge(hidden);
        await _runQuietly(hidden, guard);
        await _runQuietly(hidden, script);
        final left = timeoutMs - DateTime.now().difference(started).inMilliseconds;
        var timedOut = false;
        if (!matched.isCompleted) {
          try {
            await matched.future.timeout(Duration(milliseconds: left < 0 ? 0 : left));
          } on TimeoutException {
            timedOut = true;
          }
        }
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
        result.complete(_httpResultFrom(m));
      });
      try {
        await _injectBridge(hidden);
        try {
          await hidden.runJavaScript(_fetchScript(id, request, timeoutMs, maxBytes));
        } catch (_) {
          return const HttpResult(ok: false, error: 'no_response');
        }
        // The JS side aborts at timeoutMs; the extra time covers the trip back.
        return await result.future.timeout(
          Duration(milliseconds: timeoutMs + 2000),
          onTimeout: () => const HttpResult(ok: false, error: 'timeout'),
        );
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
        post({ type: '$fetchResultType', id: a.id, ok: true, status: res.status, headers: headers, body: c.body, truncated: c.truncated });
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
  @override
  Future<LoginResult> showLogin(LoginRequest req) async {
    final nav = navigatorProvider?.call();
    if (nav == null) {
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
    Future<void> inject() async {
      await _injectBridge(c);
      await _runQuietly(c, req.guard);
      final check = req.check;
      if (check != null && check.script.isNotEmpty) await _runQuietly(c, check.script);
    }

    c = _newController(
      onMessage: (String raw) {
        final m = parseMessage(raw);
        if (m == null) return;
        messages.add(m);
        if (messages.length > _maxLoginMessages) messages.removeAt(0);
        if (messageMatchesAny(m, req.doneWhen)) finish(LoginOutcome.signedIn);
      },
      delegate: NavigationDelegate(
        onNavigationRequest: (NavigationRequest r) {
          if (!r.isMainFrame) return NavigationDecision.navigate;
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
        onPageStarted: (String url) => unawaited(_injectBridge(c)),
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
    final periodic = req.check;
    if (periodic != null && periodic.script.isNotEmpty && periodic.intervalMs > 0) {
      final every = periodic.intervalMs < 250 ? 250 : periodic.intervalMs;
      timers.add(Timer.periodic(Duration(milliseconds: every), (_) => unawaited(inject())));
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
  }
}

/// The login sheet: a title, a Close button, and the visible WebView. Built
/// from plain widgets (no AppBar) so it needs no MaterialLocalizations and
/// works under a CupertinoApp too.
class _LoginPage extends StatelessWidget {
  const _LoginPage({required this.title, required this.controller, required this.onClose});

  final String title;
  final WebViewController controller;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
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
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: Color(0xFF111111)),
                    ),
                  ),
                  TextButton(onPressed: onClose, child: const Text('Close')),
                  const SizedBox(width: 4),
                ],
              ),
            ),
            const Divider(height: 1, thickness: 1, color: Color(0xFFE5E5E5)),
            Expanded(child: WebViewWidget(controller: controller)),
          ],
        ),
      ),
    );
  }
}
