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

/// The core protocol version this port follows (packages/core 0.1.0).
const String sdkCoreVersion = '0.1.0';

/// This package's version, sent as `X-Mealio-SDK: flutter/<version>`.
const String mealioSdkVersion = '0.2.0';

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

  /// Start a cart: signs in to the store if needed, searches every ingredient.
  /// `store` is optional: without it Mealio uses the user's default store,
  /// and fails with `store_required` when they have none yet.
  Future<CartSession> prepareCart({
    String? store,
    required Recipe recipe,
    String? zip,
    StepListener? onStep,
  }) async {
    final input = <String, Object?>{'recipe': recipe.toJson()};
    if (store != null) input['store'] = store;
    if (zip != null) input['zip'] = zip;
    input.addAll(await _about());
    final start = _jobStart(await _post('/api/v1/sdk/carts', input));
    final result = await _drive(start, onStep);
    return CartSession(this, PreparedCart.fromJson(result));
  }

  /// Search the store again for one item ("minced garlic jar").
  Future<SearchResult> search(String cartId, String key, String query, {StepListener? onStep}) async {
    final start = _jobStart(await _post(
      '/api/v1/sdk/carts/${Uri.encodeComponent(cartId)}/search',
      <String, Object?>{'key': key, 'query': query, ...await _about()},
    ));
    return SearchResult.fromJson(await _drive(start, onStep));
  }

  /// Fill the store cart with the user's choices.
  Future<AddResult> addToCart(String cartId, List<Selection> selections, {StepListener? onStep}) async {
    final start = _jobStart(await _post(
      '/api/v1/sdk/carts/${Uri.encodeComponent(cartId)}/add',
      <String, Object?>{
        'selections': selections.map((Selection s) => s.toJson()).toList(),
        ...await _about(),
      },
    ));
    return AddResult.fromJson(await _drive(start, onStep));
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

  Future<Object?> _drive(_JobStart start, StepListener? onStep) async {
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
