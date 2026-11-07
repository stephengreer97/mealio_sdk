// The partner-facing flow, platform neutral. Mirrors MealioClient in
// packages/core/src/client.ts. `MealioCart` (mealio_cart.dart) wraps this with
// the WebView host and the stored epoch.

import 'dart:convert';

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
const String mealioSdkVersion = '0.4.2';

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
  });

  final String publishableKey;

  /// From POST /api/v1/sessions on the partner's server. Called again after a 401.
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
}

/// How long a warm-up is offered to the next prepare. The server holds the same line (WARM_TTL_MS).
const Duration warmFresh = Duration(minutes: 4);

/// A finished warm-up the next prepare may start from.
class _Warmed {
  _Warmed(this.job, this.store, this.at, this.pageOpens, this.epoch);
  final String job;
  final String store;
  final int at;
  final int pageOpens;
  final Object? epoch;
}

class _JobStart {
  _JobStart(this.job, this.envelope);
  final String job;
  final Envelope envelope;
}

class MealioClient {
  MealioClient(this._cfg, MealioHost host)
      : _runner = Runner(host, allowlist: Allowlist(), keys: _cfg.keys),
        _base = _cfg.baseUrl.replaceFirst(RegExp(r'/$'), ''),
        _http = _cfg.httpClient ?? http.Client();

  final ClientConfig _cfg;
  final Runner _runner;
  final String _base;
  final http.Client _http;
  String? _token;
  _Warmed? _warmed;
  Future<void>? _warming;
  int _lastWarmAt = 0;

  /// Cart jobs (prepare, search, add) driving the hidden page right now.
  int _running = 0;

  /// The allowlist in force, after any widening.
  Allowlist get allowlist => _runner.allowlist;

  /// Stores the SDK supports right now. Public, no session needed.
  Future<List<StoreInfo>> stores() async {
    try {
      final res = await _http.get(Uri.parse('$_base/api/v1/stores'));
      final Object? j = jsonDecode(utf8.decode(res.bodyBytes));
      final Object? list = j is Map ? j['stores'] : null;
      return list is List ? list.map(StoreInfo.fromJson).toList() : <StoreInfo>[];
    } catch (_) {
      throw const MealioException(MealioErrorCode.network, 'Could not reach Mealio');
    }
  }

  /// A Kroger family chain's stores near a zip, nearest first, for the user
  /// to choose from. Save their choice with [setStore].
  Future<List<StoreLocation>> storeLocations(String store, String zip) async {
    final j = await _post('/api/v1/sdk/locations', <String, Object?>{'store': store, 'zip': zip});
    final Object? list = j is Map ? j['locations'] : null;
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
  Future<CartSession> prepareCart({
    String? store,
    Recipe? recipe,
    List<Recipe>? recipes,
    String? zip,
    StepListener? onStep,
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
    return _cartJob(() async {
      await _settleWarm();
      input.addAll(await _about());
      final warm = _takeWarm(store, input['epoch']);
      if (warm != null) input['warm'] = warm;
      final start = _jobStart(await _post('/api/v1/sdk/carts', input));
      final result = await _drive(start, onStep);
      return CartSession(this, PreparedCart.fromJson(result));
    });
  }

  /// Run the login check for the user's store now, before they tap, so the
  /// cart that follows can start at search. Mealio picks the store: the
  /// user's default, or none, in which case nothing happens (a new user has
  /// no store to check yet). Never shows sign-in, never throws, and does
  /// nothing if it ran in the last few minutes. MealioCartButton calls it
  /// when it appears. Mirrors MealioClient.warm() in packages/core.
  Future<void> warm({String? store}) {
    final inFlight = _warming;
    if (inFlight != null) return inFlight;
    // A cart is already driving the one hidden page: a warm-up now would load
    // over it mid-run. Nothing to gain either, the cart has the session.
    if (_running > 0) return Future<void>.value();
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastWarmAt < warmFresh.inMilliseconds) return Future<void>.value();
    _lastWarmAt = now;
    final w = _runWarm(store).whenComplete(() => _warming = null);
    _warming = w;
    return w;
  }

  /// Forget any warm-up, e.g. after signing out of the stores.
  void clearWarm() {
    _warmed = null;
    _lastWarmAt = 0;
  }

  Future<void> _runWarm(String? store) async {
    try {
      final about = await _about();
      final res = await _post('/api/v1/sdk/warm', <String, Object?>{if (store != null) 'store': store, ...about});
      if (res is! Map || res['job'] is! String) {
        _warmed = null;
        return;
      }
      final start = _jobStart(res);
      final r = await _drive(start, null, warm: true);
      _warmed = r is Map && r['signedIn'] == true && r['store'] is String
          ? _Warmed(start.job, r['store']! as String, DateTime.now().millisecondsSinceEpoch, _runner.pageOpens, about['epoch'])
          : null;
    } catch (_) {
      // A warm-up that fails costs the user nothing: the cart runs as it always has.
      _warmed = null;
    }
  }

  /// Every job drives the one hidden page: none may start while a warm-up is driving it.
  Future<void> _settleWarm() async {
    final w = _warming;
    if (w != null) await w;
  }

  /// The warm job id, once, if the page it left is still showing and it is still fresh.
  String? _takeWarm(String? store, Object? epoch) {
    final w = _warmed;
    _warmed = null;
    if (w == null) return null;
    if (store != null && store != w.store) return null;
    if (w.pageOpens != _runner.pageOpens || w.epoch != epoch) return null;
    if (DateTime.now().millisecondsSinceEpoch - w.at > warmFresh.inMilliseconds) return null;
    return w.job;
  }

  /// Search the store again for one item ("minced garlic jar").
  Future<SearchResult> search(String cartId, String key, String query, {StepListener? onStep}) {
    return _cartJob(() async {
      await _settleWarm();
      final start = _jobStart(await _post(
        '/api/v1/sdk/carts/${Uri.encodeComponent(cartId)}/search',
        <String, Object?>{'key': key, 'query': query, ...await _about()},
      ));
      return SearchResult.fromJson(await _drive(start, onStep));
    });
  }

  /// Fill the store cart with the user's choices.
  Future<AddResult> addToCart(String cartId, List<Selection> selections, {StepListener? onStep}) {
    return _cartJob(() async {
      await _settleWarm();
      final start = _jobStart(await _post(
        '/api/v1/sdk/carts/${Uri.encodeComponent(cartId)}/add',
        <String, Object?>{
          'selections': selections.map((Selection s) => s.toJson()).toList(),
          ...await _about(),
        },
      ));
      return AddResult.fromJson(await _drive(start, onStep));
    });
  }

  /// Who is calling, carried on every job-starting call (this used to be a
  /// separate hello round trip).
  Future<Map<String, Object?>> _about() async {
    final epoch = _cfg.getEpoch == null ? 0 : await _cfg.getEpoch!();
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

  /// A cart call, from before it waits on a warm-up until its job is done. The
  /// whole call counts as running, not just its drive: a warm-up started while
  /// the first request was in flight would otherwise load over the page.
  Future<T> _cartJob<T>(Future<T> Function() fn) async {
    _running += 1;
    try {
      return await fn();
    } finally {
      _running -= 1;
    }
  }

  Future<Object?> _drive(_JobStart start, StepListener? onStep, {bool warm = false}) =>
      _driveLoop(start, onStep, allowLogin: !warm);

  Future<Object?> _driveLoop(_JobStart start, StepListener? onStep, {required bool allowLogin}) async {
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
          allowLogin: allowLogin,
        );
      } on EnvelopeError catch (e) {
        throw MealioException(
          e.why == 'unsupported_op' ? MealioErrorCode.unsupported : MealioErrorCode.badEnvelope,
          e.message,
        );
      }
      seq = out.payload.seq;
      final terminal = out.terminal;
      if (terminal is TerminalDone) return terminal.result;
      if (terminal is TerminalFail) throw MealioException(terminal.code, terminal.message);
      final body = StepRequest(seq: seq, results: out.results).toJson();
      final next = await _post('/api/v1/sdk/jobs/${Uri.encodeComponent(start.job)}/step', body);
      env = Envelope.fromJson(next is Map ? next['envelope'] : null);
    }
    throw const MealioException(MealioErrorCode.server, 'job did not finish');
  }

  Future<Object?> _post(String path, Object? body, {bool retried = false}) async {
    _token ??= await _cfg.getSessionToken();
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $_token',
      'X-Mealio-Publishable-Key': _cfg.publishableKey,
      'X-Mealio-SDK': '${_cfg.platform}/${_cfg.sdkVersion}',
    };
    final getAttestation = _cfg.getAttestation;
    if (getAttestation != null) {
      String? a;
      try {
        a = await getAttestation();
      } catch (_) {
        a = null;
      }
      if (a != null && a.isNotEmpty) headers['X-Mealio-Attestation'] = a;
    }
    http.Response res;
    try {
      // Bytes, not a String body: a String body makes package:http append
      // "; charset=utf-8" to Content-Type.
      res = await _http.post(Uri.parse(_base + path), headers: headers, body: utf8.encode(jsonEncode(body)));
    } catch (_) {
      throw const MealioException(MealioErrorCode.network, 'Could not reach Mealio');
    }
    if (res.statusCode == 401 && !retried) {
      _token = null;
      return _post(path, body, retried: true);
    }
    Object? json;
    try {
      // Always UTF-8: `res.body` would fall back to latin1 without a charset,
      // and the envelope payload must reach the verifier exactly as sent.
      json = jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {
      json = null;
    }
    if (res.statusCode == 401) {
      throw const MealioException(MealioErrorCode.sessionExpired, 'The Mealio session expired');
    }
    if (res.statusCode < 200 || res.statusCode > 299) {
      final Object? err = json is Map ? json['error'] : null;
      final code = err is Map && err['code'] is String ? err['code']! as String : MealioErrorCode.server;
      final message =
          err is Map && err['message'] is String ? err['message']! as String : 'Mealio answered ${res.statusCode}';
      throw MealioException(code, message);
    }
    return json;
  }
}
