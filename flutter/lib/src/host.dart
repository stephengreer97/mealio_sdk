// The Host is the only platform-specific part of the relay: WebViews, HTTP and
// UI. Mirrors the `Host` interface in packages/core/src/runner.ts. The Runner
// does all checking (signature, allowlist, rate caps) before it calls a Host.

import 'protocol.dart';
import 'runner.dart' show CancelToken;

/// What `openPage` reports.
class PageLoad {
  const PageLoad({required this.ok, this.finalUrl, this.error});
  final bool ok;
  final String? finalUrl;

  /// `timeout`, `blocked` or `load_failed`.
  final String? error;
}

/// What `runScript` reports.
class ScriptRun {
  const ScriptRun({required this.messages, required this.timedOut, this.error});
  final List<JsonMessage> messages;
  final bool timedOut;
  final String? error;
}

/// Everything the login sheet needs.
class LoginRequest {
  const LoginRequest({
    required this.store,
    required this.url,
    required this.title,
    required this.guard,
    required this.check,
    required this.doneWhen,
    required this.doneWhenUrl,
    required this.timeoutMs,
    required this.allowNavigation,
    this.cancel,
  });
  final String store;
  final String url;
  final String title;
  final String guard;
  final LoginCheck? check;
  final List<MessageMatcher> doneWhen;
  final String? doneWhenUrl;
  final int timeoutMs;

  /// Must be asked for every top-frame navigation; refuse it when false.
  final bool Function(String url) allowNavigation;

  /// Close the sheet as `cancelled` when this fires.
  final CancelToken? cancel;
}

/// What `showLogin` reports.
class LoginResult {
  const LoginResult({required this.outcome, required this.messages});
  final LoginOutcome outcome;
  final List<JsonMessage> messages;
}

/// What `fetch` reports. `ok` means a response arrived, whatever its status.
class HttpResult {
  const HttpResult({required this.ok, this.status, this.headers, this.body, this.truncated, this.error});
  final bool ok;
  final int? status;
  final Map<String, String>? headers;
  final String? body;
  final bool? truncated;
  final String? error;
}

/// The platform side of the relay. `WebViewHost` is the Flutter one; tests
/// use a fake.
abstract class MealioHost {
  /// Load `url` in the hidden WebView.
  Future<PageLoad> openPage(String store, String url, int timeoutMs);

  /// Inject `guard` then `script` into the hidden page. Resolve with every
  /// JSON message posted after injection, stopping at the first that matches
  /// `until` or when `timeoutMs` passes.
  Future<ScriptRun> runScript(String store, String guard, String script, List<MessageMatcher> until, int timeoutMs);

  /// Show the login sheet. `request.allowNavigation(url)` must be asked for
  /// every top-frame navigation; refuse it when false.
  Future<LoginResult> showLogin(LoginRequest request);

  /// One HTTP request with the store's cookies.
  Future<HttpResult> fetch(String store, FetchRequest request, int timeoutMs, int maxBytes);
}

/// A Host whose hidden page can be replaced, as a remounted `MealioScope`
/// does. The client offers a warm-up only to the page it ran on.
abstract interface class MealioPageIdentity {
  /// The hidden page now in use, compared by identity.
  Object? get currentPage;
}

/// A Host that can put its hidden page back to a blank one. After exclusive
/// work outlives its cap (`MealioClient.runExclusive`) the page may be left
/// half way, so the next job calls this before it starts.
abstract interface class MealioPageReset {
  /// Load a blank page and forget the store page. Bounded by the client.
  Future<void> resetPage();
}
