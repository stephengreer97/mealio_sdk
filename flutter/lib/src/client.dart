// The partner-facing flow, platform neutral. Mirrors MealioClient in
// packages/core/src/client.ts. `MealioCart` (mealio_cart.dart) wraps this with
// the WebView host and the stored epoch.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

import 'allowlist.dart';
import 'cart_session.dart';
import 'errors.dart';
import 'host.dart';
import 'protocol.dart';
import 'runner.dart';
import 'verify.dart';

/// The core protocol version this port follows (packages/core 0.2.0).
const String sdkCoreVersion = '0.2.0';

/// This package's version, sent as `X-Mealio-SDK: flutter/<version>`.
const String mealioSdkVersion = '0.5.0';

const String defaultBaseUrl = 'https://mealio.co';

/// What the SDK is doing right now, for a progress screen. Inferred from the
/// server's instruction ids (open-, session-, login-, search-, add-), never
/// from store specifics. `Step` in the TypeScript reference; named
/// `MealioStep` here because Material already exports a `Step`.
enum MealioStep {
  connecting('connecting'),
  checkingSignIn('checking_sign_in'),
  signingIn('signing_in'),
  searching('searching'),
  adding('adding');

  const MealioStep(this.wire);

  /// The reference's string for this step.
  final String wire;
}

/// Called before each instruction the SDK runs.
typedef StepListener = void Function(MealioStep step, Instruction ins);

/// The step an instruction belongs to.
MealioStep stepOf(Instruction ins) {
  if (ins is ShowLogin) return MealioStep.signingIn;
  final id = ins.id;
  if (id.startsWith('search')) return MealioStep.searching;
  if (id.startsWith('add')) return MealioStep.adding;
  if (id.startsWith('session') || id.startsWith('resession')) return MealioStep.checkingSignIn;
  return MealioStep.connecting;
}

/// Everything `MealioClient` needs.
class ClientConfig {
  const ClientConfig({
    required this.publishableKey,
    required this.getSessionToken,
    this.platform = 'flutter',
    this.sdkVersion = mealioSdkVersion,
    this.baseUrl = defaultBaseUrl,
    this.getAttestation,
    this.getEpoch,
    this.httpClient,
    this.keys,
    this.queue,
    this.debug = false,
  });

  final String publishableKey;

  /// From POST /api/v1/sessions on the partner's server. Called again after a
  /// 401. If it fails or takes over 30 seconds, the call fails with
  /// `session_failed`, with your error's message as `message`.
  final Future<String> Function() getSessionToken;
  final String platform;
  final String sdkVersion;
  final String baseUrl;

  /// App Attest / Play Integrity token, when the partner has turned attestation on.
  final Future<String?> Function()? getAttestation;

  /// The device's store-session epoch (bumped by signOutOfAllStores).
  final Future<int> Function()? getEpoch;

  /// Injected for tests. Defaults to a new `http.Client`.
  final http.Client? httpClient;

  /// Trusted public keys by kid. Defaults to the bundled production keys.
  final Map<String, String>? keys;

  /// Clients that share one hidden page share one queue. Defaults to a queue of its own.
  final JobQueue? queue;

  /// Log server warnings. Debug builds only.
  final bool debug;
}

/// Every HTTP request, and your session function, gets this long.
const Duration requestTimeout = Duration(seconds: 30);

/// A [CancelToken] for calls made inside [runCancellable], for prepare
/// functions that do not take one (`MealioCartFlow.prepareCarts`).
const Symbol _cancelZoneKey = #mealioCancelToken;

/// Runs `fn` so that a prepare or search it starts, without a `cancel` of
/// its own, stops when `cancel` fires.
R runCancellable<R>(CancelToken cancel, R Function() fn) =>
    runZoned(fn, zoneValues: <Object?, Object?>{_cancelZoneKey: cancel});

CancelToken? _zoneCancel() {
  final Object? c = Zone.current[_cancelZoneKey];
  return c is CancelToken ? c : null;
}

/// One job at a time on the hidden page. Prepare, search, add and warm all
/// run through here, and a new job waits for the one before it to end.
class JobQueue {
  Future<void> _tail = Future<void>.value();

  /// Jobs queued and not yet ended.
  int _inFlight = 0;

  /// Cart calls waiting or running. A warm-up does not start while any are.
  int pending = 0;

  Future<T> run<T>(Future<T> Function() job) {
    // Idle: start from a fresh future in the caller's zone. The old tail may
    // belong to a zone that no longer runs anything (a finished widget test),
    // and chaining on it would never start this job.
    final before = _inFlight == 0 ? Future<void>.value() : _tail;
    _inFlight += 1;
    final out = before.then((_) => job());
    _tail = out.then<void>((_) {}, onError: (Object _) {}).whenComplete(() => _inFlight -= 1);
    return out;
  }
}

/// The session token an add was called with, kept for the whole add.
class _Pin {
  _Pin(this.token, this.gen);
  String token;

  /// The session generation it belongs to. A newer one means another user.
  final int gen;
}

/// `f`, or `onLate()` thrown once `d` passes.
Future<T> _deadline<T>(Future<T> f, Duration d, Object Function() onLate) =>
    f.timeout(d, onTimeout: () => throw onLate());

void _stopIf(CancelToken? cancel) {
  if (cancel != null && cancel.cancelled) {
    throw const MealioException(MealioErrorCode.cancelled, 'Cancelled');
  }
}

/// An error's message without Dart's "Exception: " prefix.
String _messageOf(Object e) {
  if (e is MealioException) return e.message;
  if (e is TimeoutException) return e.message ?? 'getSessionToken did not answer in time';
  final s = e.toString();
  return s.startsWith('Exception: ') ? s.substring('Exception: '.length) : s;
}

/// How long a warm-up is offered to the next prepare. The server holds the same line (WARM_TTL_MS).
const Duration warmFresh = Duration(minutes: 4);

/// A finished warm-up the next prepare may start from.
class _Warmed {
  _Warmed(this.job, this.store, this.at, this.pageOpens, this.epoch, this.page);
  final String job;
  final String store;
  final int at;
  final int pageOpens;
  final Object? epoch;

  /// The hidden page it ran on, when the host can say ([MealioPageIdentity]).
  final Object? page;
}

class _JobStart {
  _JobStart(this.job, this.envelope);
  final String job;
  final Envelope envelope;
}

class MealioClient {
  MealioClient(this._cfg, MealioHost host)
      : _host = host,
        _runner = Runner(host, allowlist: Allowlist(), keys: _cfg.keys),
        _base = _cfg.baseUrl.replaceFirst(RegExp(r'/$'), ''),
        _http = _cfg.httpClient ?? http.Client(),
        _queue = _cfg.queue ?? JobQueue();

  final ClientConfig _cfg;
  final MealioHost _host;
  final Runner _runner;
  final String _base;
  final http.Client _http;
  final JobQueue _queue;
  String? _token;

  /// Bumped by [resetSession], so a token still on its way is not kept.
  int _sessionGen = 0;
  _Warmed? _warmed;
  Future<void>? _warming;
  CancelToken? _warmCancel;
  int _lastWarmAt = 0;

  /// Tokens of the prepares and searches waiting or running.
  final Set<CancelToken> _active = <CancelToken>{};

  /// False until [setUser] is first called: users are not tracked.
  bool _tracking = false;

  /// Who is signed in, while tracked. Null: nobody.
  String? _user;

  bool get _nobody => _tracking && _user == null;

  Object? get _page {
    final Object h = _host;
    return h is MealioPageIdentity ? h.currentPage : null;
  }

  /// The allowlist in force, after any widening.
  Allowlist get allowlist => _runner.allowlist;

  /// The stores this app offers right now. No session needed. A failed load
  /// throws: it never reads as no stores.
  Future<List<StoreInfo>> stores() async {
    final res = await _request(
      () => _http.get(Uri.parse('$_base/api/v1/stores'), headers: <String, String>{'X-Mealio-Publishable-Key': _cfg.publishableKey}),
    );
    final Object? list = _answer(res.status, res.json)['stores'];
    return list is List ? list.map(StoreInfo.fromJson).toList() : <StoreInfo>[];
  }

  /// A Kroger family chain's stores near a zip, nearest first, for the user
  /// to choose from. Save their choice with [setStore].
  Future<List<StoreLocation>> storeLocations(String store, String zip) async {
    final j = await _post('/api/v1/sdk/locations', <String, Object?>{'store': store, 'zip': zip});
    final Object? list = j['locations'];
    return list is List ? list.map(StoreLocation.fromJson).toList() : <StoreLocation>[];
  }

  /// The user's default store, and their exact store if it is in the Kroger
  /// family.
  Future<StorePreferences> storePreferences() async =>
      StorePreferences.fromJson(await _post('/api/v1/sdk/preferences', <String, Object?>{}));

  /// Make a store the user's default. A Kroger family store needs `locationId`
  /// from [storeLocations] the first time, and otherwise fails with
  /// `location_required`. Sending it later moves them to that store.
  Future<StorePreferences> setStore(String store, {String? locationId}) async => StorePreferences.fromJson(
        await _post('/api/v1/sdk/preferences', <String, Object?>{
          'store': store,
          if (locationId != null && locationId.isNotEmpty) 'locationId': locationId,
        }),
      );

  /// Start a cart: signs in to the store if needed, searches every ingredient.
  /// A Kroger family store the user has not chosen a location for fails with
  /// `location_required`, before any sign-in. Pass `zip` to use the nearest
  /// store instead of asking them.
  /// `store` is optional: without it Mealio uses the user's default store,
  /// and fails with `store_required` when they have none yet.
  ///
  /// Pass `recipe` for one recipe, or `recipes` for up to [maxRecipes] in one
  /// cart: ingredients they share become one item, and each pick is
  /// remembered under every recipe that calls for it. `recipes` wins when
  /// both are given. Throws [MealioException] `bad_recipe` for none and
  /// `too_many_recipes` for more than [maxRecipes], before any request.
  ///
  /// Pass `cancel` to stop it: it stops after the current step, sends nothing
  /// more, never shows sign-in, and fails with `cancelled`.
  Future<CartSession> prepareCart({
    String? store,
    Recipe? recipe,
    List<Recipe>? recipes,
    String? zip,
    StepListener? onStep,
    CancelToken? cancel,
  }) async {
    final list = recipes ?? (recipe == null ? const <Recipe>[] : <Recipe>[recipe]);
    if (list.isEmpty) {
      throw const MealioException(MealioErrorCode.badRecipe, 'Pass recipe, or recipes with at least one recipe.');
    }
    if (list.length > maxRecipes) {
      throw const MealioException(MealioErrorCode.tooManyRecipes, 'At most $maxRecipes recipes in one cart.');
    }
    // One recipe goes as `recipe`, so a server from before multi-recipe still
    // understands it.
    final input = list.length == 1
        ? <String, Object?>{'recipe': list.first.toJson()}
        : <String, Object?>{'recipes': list.map((Recipe r) => r.toJson()).toList()};
    if (store != null) input['store'] = store;
    if (zip != null) input['zip'] = zip;
    final stop = cancel ?? _zoneCancel() ?? CancelToken();
    return _cartJob(() async {
      input.addAll(await _about());
      _stopIf(stop);
      final warm = _takeWarm(store, input['epoch']);
      if (warm != null) input['warm'] = warm;
      final start = _jobStart(await _post('/api/v1/sdk/carts', input, cancel: stop));
      final prepared = PreparedCart.fromJson(await _driveLoop(start, onStep, cancel: stop));
      if (_cfg.debug) {
        for (final CartWarning w in prepared.warnings ?? const <CartWarning>[]) {
          debugPrint('[mealio] ${w.code}: ${w.message}');
        }
      }
      return CartSession(this, prepared);
    }, stop);
  }

  /// Run the login check for the user's store now, before they tap, so the
  /// cart that follows can start at search. Mealio picks the store: the
  /// user's default, or none, in which case nothing happens (a new user has
  /// no store to check yet). Never shows sign-in, never throws, and does
  /// nothing if it ran in the last few minutes. MealioCartButton calls it
  /// when it appears. Mirrors MealioClient.warm() in packages/core.
  Future<void> warm({String? store}) {
    if (_nobody) return Future<void>.value();
    final inFlight = _warming;
    if (inFlight != null && !(_warmCancel?.cancelled ?? false)) return inFlight;
    // A cart is already waiting for or driving the one hidden page: a warm-up
    // now would only delay it. Nothing to gain either, the cart has the session.
    if (_queue.pending > 0) return Future<void>.value();
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastWarmAt < warmFresh.inMilliseconds) return Future<void>.value();
    _lastWarmAt = now;
    final cancel = CancelToken();
    _warmCancel = cancel;
    late final Future<void> w;
    w = _queue.run(() => _runWarm(store, cancel)).whenComplete(() {
      if (identical(_warming, w)) _warming = null;
    });
    _warming = w;
    return w;
  }

  /// The signed-in user changed. Forget the session, so the next call asks
  /// your server for a new one. Signing out of the stores does this too. A
  /// warm-up under way stops, and its result is never offered to the next
  /// prepare.
  void resetSession() {
    _sessionGen += 1;
    _token = null;
    _warmCancel?.cancel();
    clearWarm();
  }

  /// Tell the SDK who is signed in to your app, or null for nobody. On a
  /// change it cancels any prepare or search and resets the session. An add
  /// runs on. While null, warm does nothing and calls that need a session
  /// fail with `not_signed_in`, without asking your server. Returns true when
  /// the old value was a user: the platform then signs out of the stores.
  bool setUser(String? id) {
    if (_tracking && id == _user) return false;
    final wasUser = _tracking && _user != null;
    _tracking = true;
    _user = id;
    cancelJobs();
    resetSession();
    return wasUser;
  }

  /// Cancel every prepare and search, waiting or running. An add is not touched.
  void cancelJobs() {
    for (final CancelToken c in List<CancelToken>.of(_active)) {
      c.cancel();
    }
    _warmCancel?.cancel();
  }

  /// Run `fn` with the hidden page to itself, in the queue with the jobs. For
  /// work that must not land in the middle of one, like clearing store sessions.
  /// After [requestTimeout] the caller gets `network`, but the queue stays
  /// held until `fn` has really finished, so no job runs alongside it.
  Future<T> runExclusive<T>(Future<T> Function() fn) {
    final result = Completer<T>();
    unawaited(_queue.run(() async {
      final timer = Timer(requestTimeout, () {
        if (!result.isCompleted) {
          result.completeError(const MealioException(MealioErrorCode.network, 'That took too long'));
        }
      });
      try {
        final v = await Future<T>.sync(fn);
        if (!result.isCompleted) result.complete(v);
      } catch (e, s) {
        if (!result.isCompleted) result.completeError(e, s);
      } finally {
        timer.cancel();
      }
    }));
    return result.future;
  }

  /// The current token. One that arrives after a reset belongs to the last
  /// user. With `cancel` (a prepare or search), a user change while it waits
  /// fails it with `cancelled`: it never takes the next user's token. With
  /// `pinned` (an add being requested), the token fetched is returned even
  /// if the user changed meanwhile, since it belongs to the user who tapped.
  Future<String> _sessionToken({CancelToken? cancel, bool pinned = false}) async {
    final first = _sessionGen;
    void stopIfChanged() {
      _stopIf(cancel);
      if (cancel != null && _sessionGen != first) {
        throw const MealioException(MealioErrorCode.cancelled, 'Cancelled');
      }
    }

    while (true) {
      stopIfChanged();
      if (_nobody) throw const MealioException(MealioErrorCode.notSignedIn, 'Nobody is signed in');
      final current = _token;
      if (current != null) return current;
      final gen = _sessionGen;
      String fresh;
      try {
        fresh = await _deadline(
          Future<String>.sync(_cfg.getSessionToken),
          requestTimeout,
          () => TimeoutException('getSessionToken did not answer in time'),
        );
      } catch (e) {
        if (gen != _sessionGen) {
          stopIfChanged();
          if (!pinned) continue;
        }
        final m = _messageOf(e);
        throw MealioException(MealioErrorCode.sessionFailed, m.isEmpty ? 'Could not start a Mealio session' : m);
      }
      if (gen == _sessionGen) {
        _token = fresh;
      } else {
        stopIfChanged();
        if (pinned) return fresh;
      }
    }
  }

  void clearWarm() {
    _warmed = null;
    _lastWarmAt = 0;
  }

  Future<void> _runWarm(String? store, CancelToken cancel) async {
    try {
      _stopIf(cancel);
      final about = await _about();
      _stopIf(cancel);
      final res = await _post('/api/v1/sdk/warm', <String, Object?>{if (store != null) 'store': store, ...about}, cancel: cancel);
      if (res['job'] is! String) {
        _warmed = null;
        return;
      }
      final start = _jobStart(res);
      final r = await _driveLoop(start, null, warm: true, cancel: cancel);
      _warmed = r is Map && r['signedIn'] == true && r['store'] is String
          ? _Warmed(start.job, r['store']! as String, DateTime.now().millisecondsSinceEpoch, _runner.pageOpens,
              about['epoch'], _page)
          : null;
    } catch (_) {
      // A warm-up that fails costs the user nothing: the cart runs as it always has.
      if (!cancel.cancelled) _warmed = null;
    }
  }

  /// The warm job id, once, if the page it left is still showing and it is still fresh.
  String? _takeWarm(String? store, Object? epoch) {
    final w = _warmed;
    _warmed = null;
    if (w == null) return null;
    if (store != null && store != w.store) return null;
    if (w.pageOpens != _runner.pageOpens || w.epoch != epoch) return null;
    // A remounted MealioScope has a new, blank hidden page.
    if (!identical(w.page, _page)) return null;
    if (DateTime.now().millisecondsSinceEpoch - w.at > warmFresh.inMilliseconds) return null;
    return w.job;
  }

  /// Search the store again for one item ("minced garlic jar"). `cancel`
  /// stops it as it stops [prepareCart].
  Future<SearchResult> search(String cartId, String key, String query, {StepListener? onStep, CancelToken? cancel}) {
    final stop = cancel ?? _zoneCancel() ?? CancelToken();
    return _cartJob(() async {
      final about = await _about();
      _stopIf(stop);
      final start = _jobStart(await _post(
        '/api/v1/sdk/carts/${Uri.encodeComponent(cartId)}/search',
        <String, Object?>{'key': key, 'query': query, ...about},
        cancel: stop,
      ));
      return SearchResult.fromJson(await _driveLoop(start, onStep, cancel: stop));
    }, stop);
  }

  /// Fill the store cart with the user's choices. It cannot be cancelled:
  /// once tapped it runs to its end under the session it was called with,
  /// even if the user changes while it waits or runs. If that session expires
  /// after a user change it fails with `session_expired`; it never switches
  /// to the next user's session. Every wait in it is bounded, so it does end.
  Future<AddResult> addToCart(String cartId, List<Selection> selections, {StepListener? onStep}) {
    // Taken now, not when the add reaches the front of the queue.
    final gen = _sessionGen;
    final token = _sessionToken(pinned: true);
    token.ignore();
    return _cartJob(() async {
      final pin = _Pin(await token, gen);
      final start = _jobStart(await _post(
        '/api/v1/sdk/carts/${Uri.encodeComponent(cartId)}/add',
        <String, Object?>{
          'selections': selections.map((Selection s) => s.toJson()).toList(),
          ...await _about(),
        },
        pin: pin,
      ));
      return AddResult.fromJson(await _driveLoop(start, onStep, pin: pin));
    });
  }

  /// Who is calling, carried on every job-starting call (this used to be a
  /// separate hello round trip).
  Future<Map<String, Object?>> _about() async {
    final getEpoch = _cfg.getEpoch;
    final epoch = getEpoch == null
        ? 0
        : await _deadline(
            getEpoch(),
            requestTimeout,
            () => const MealioException(MealioErrorCode.network, 'Could not read the store sign-out state'),
          );
    return <String, Object?>{
      'sdk': <String, Object?>{
        'platform': _cfg.platform,
        'version': _cfg.sdkVersion,
        'core': sdkCoreVersion,
        'ops': supportedOps,
      },
      'epoch': epoch,
    };
  }

  /// Apply a signed allowlist widening, if the server ever sends one. An
  /// allowlist that does not verify is ignored; the bundled one stands.
  Future<void> widenAllowlist(Envelope env) async {
    try {
      final p = await openEnvelope(env, _cfg.keys);
      if (p.kind == 'allowlist') _runner.allowlist.widen(AllowlistPayload.fromJson(p.raw));
    } catch (_) {
      // Ignored on purpose.
    }
  }

  _JobStart _jobStart(Object? json) {
    if (json is! Map || json['job'] is! String) {
      throw const MealioException(MealioErrorCode.server, 'Mealio did not start a job');
    }
    return _JobStart(json['job']! as String, Envelope.fromJson(json['envelope']));
  }

  /// A cart call, queued. It counts as pending from the moment it is called,
  /// so a warm-up cannot slip in ahead of it. A cancelled call never starts.
  Future<T> _cartJob<T>(Future<T> Function() fn, [CancelToken? cancel]) async {
    _queue.pending += 1;
    if (cancel != null) _active.add(cancel);
    try {
      return await _queue.run(() {
        _stopIf(cancel);
        return fn();
      });
    } finally {
      _queue.pending -= 1;
      if (cancel != null) _active.remove(cancel);
    }
  }

  Future<Object?> _driveLoop(
    _JobStart start,
    StepListener? onStep, {
    bool warm = false,
    CancelToken? cancel,
    _Pin? pin,
  }) async {
    var env = start.envelope;
    var seq = 0;
    for (var guard = 0; guard < 200; guard += 1) {
      StepOutcome out;
      try {
        out = await _runner.run(
          env,
          start.job,
          seq,
          onStep: onStep == null ? null : (Instruction ins) => onStep(stepOf(ins), ins),
          allowLogin: !warm,
          cancel: cancel,
        );
      } on EnvelopeError catch (e) {
        throw MealioException(
          e.why == 'unsupported_op' ? MealioErrorCode.unsupported : MealioErrorCode.badEnvelope,
          e.message,
        );
      }
      _stopIf(cancel);
      seq = out.payload.seq;
      final terminal = out.terminal;
      if (terminal is TerminalDone) return terminal.result;
      if (terminal is TerminalFail) throw MealioException(terminal.code, terminal.message);
      final body = StepRequest(seq: seq, results: out.results).toJson();
      final next = await _post('/api/v1/sdk/jobs/${Uri.encodeComponent(start.job)}/step', body, cancel: cancel, pin: pin);
      env = Envelope.fromJson(next['envelope']);
    }
    throw const MealioException(MealioErrorCode.server, 'job did not finish');
  }

  /// One HTTP call, bounded: headers and body both inside [requestTimeout].
  /// `json` is null if it was not JSON.
  Future<({int status, Object? json})> _request(Future<http.Response> Function() send) async {
    http.Response res;
    try {
      res = await send().timeout(requestTimeout);
    } catch (_) {
      throw const MealioException(MealioErrorCode.network, 'Could not reach Mealio');
    }
    Object? json;
    try {
      // Always UTF-8: `res.body` would fall back to latin1 without a charset,
      // and the envelope payload must reach the verifier exactly as sent.
      json = jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {
      json = null;
    }
    return (status: res.statusCode, json: json);
  }

  /// `cancel` belongs to a prepare, search or warm-up; `pin` to an add.
  Future<Map<Object?, Object?>> _post(
    String path,
    Object? body, {
    CancelToken? cancel,
    _Pin? pin,
    bool retried = false,
  }) async {
    final bearer = pin?.token ?? await _sessionToken(cancel: cancel);
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $bearer',
      'X-Mealio-Publishable-Key': _cfg.publishableKey,
      'X-Mealio-SDK': '${_cfg.platform}/${_cfg.sdkVersion}',
    };
    final getAttestation = _cfg.getAttestation;
    if (getAttestation != null) {
      String? a;
      try {
        a = await getAttestation().timeout(requestTimeout);
      } catch (_) {
        a = null;
      }
      if (a != null && a.isNotEmpty) headers['X-Mealio-Attestation'] = a;
    }
    // Bytes, not a String body: a String body makes package:http append
    // "; charset=utf-8" to Content-Type.
    final res = await _request(() => _http.post(Uri.parse(_base + path), headers: headers, body: utf8.encode(jsonEncode(body))));
    if (res.status == 401 && !retried) {
      if (_token == bearer) _token = null;
      if (pin != null) {
        // The add belongs to the user it was called for. Another user's
        // session must never carry it.
        if (pin.gen != _sessionGen) {
          throw const MealioException(MealioErrorCode.sessionExpired, 'The Mealio session expired');
        }
        final fresh = await _sessionToken(pinned: true);
        if (pin.gen != _sessionGen) {
          throw const MealioException(MealioErrorCode.sessionExpired, 'The Mealio session expired');
        }
        pin.token = fresh;
      }
      return _post(path, body, cancel: cancel, pin: pin, retried: true);
    }
    if (res.status == 401) {
      throw const MealioException(MealioErrorCode.sessionExpired, 'The Mealio session expired');
    }
    return _answer(res.status, res.json);
  }
}

/// The body of a good answer, or the error it stands for.
Map<Object?, Object?> _answer(int status, Object? json) {
  if (status < 200 || status > 299) {
    final Object? err = json is Map ? json['error'] : null;
    final code = err is Map && err['code'] is String ? err['code']! as String : MealioErrorCode.server;
    final message = err is Map && err['message'] is String ? err['message']! as String : 'Mealio answered $status';
    throw MealioException(code, message);
  }
  // A captive portal or a proxy can answer 200 with a web page.
  if (json is! Map) throw const MealioException(MealioErrorCode.server, 'Mealio sent an answer that could not be read');
  return json;
}
