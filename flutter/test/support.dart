// Shared test helpers: the vectors fixture, a fake Host, and a signer that
// uses the same deterministic TEST key as protocol/make-vectors.mjs.

import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:mealio_sdk/mealio_sdk.dart';

/// test/fixtures/test-vectors.json, a copy of protocol/test-vectors.json.
final Map<String, Object?> vectors =
    jsonDecode(File('test/fixtures/test-vectors.json').readAsStringSync()) as Map<String, Object?>;

List<Map<String, Object?>> vectorList(String name) =>
    (vectors[name]! as List<Object?>).cast<Map<String, Object?>>();

/// Only the test key. The production key must not verify test envelopes.
final Map<String, String> testKeys = <String, String>{
  vectors['kid']! as String: vectors['publicKey']! as String,
};

Map<String, Object?> vectorCase(String name) => vectorList('cases').firstWhere(
      (Map<String, Object?> c) => c['name'] == name,
    );

/// `Buffer.alloc(32, 7)` in make-vectors.mjs.
final List<int> testSeed = List<int>.filled(32, 7);

final Ed25519 _ed = Ed25519();

Future<SimpleKeyPair> testKeyPair() => _ed.newKeyPairFromSeed(testSeed);

/// Signs `payload` (a JSON string) with the test key, kid `ktest`.
Future<Envelope> signText(String payload, {String kid = 'ktest'}) async {
  final sig = await _ed.sign(utf8.encode(payload), keyPair: await testKeyPair());
  return Envelope(payload: payload, sig: base64Encode(sig.bytes), kid: kid);
}

/// Signs an instructions payload for job `job_test` at `seq`.
Future<Envelope> signInstructions(
  List<Map<String, Object?>> instructions, {
  int seq = 1,
  String store = 'heb',
  String kind = 'instructions',
  Object? v = 1,
  num exp = 4102444800,
}) {
  return signText(jsonEncode(<String, Object?>{
    'v': v,
    'kind': kind,
    'job': 'job_test',
    'seq': seq,
    'exp': exp,
    'store': store,
    'instructions': instructions,
  }));
}

/// A Host that records calls and answers like the TypeScript test's fakeHost.
class FakeHost implements MealioHost {
  FakeHost({this.onOpen, this.onScript, this.onLogin, this.onFetch});

  final List<String> calls = <String>[];
  final Future<PageLoad> Function(String url)? onOpen;
  final Future<ScriptRun> Function(String script, List<MessageMatcher> until)? onScript;
  final Future<LoginResult> Function(LoginRequest request)? onLogin;
  final Future<HttpResult> Function(FetchRequest request)? onFetch;

  @override
  Future<PageLoad> openPage(String store, String url, int timeoutMs) async {
    calls.add('open $url');
    final f = onOpen;
    if (f != null) return f(url);
    return PageLoad(ok: true, finalUrl: url);
  }

  @override
  Future<ScriptRun> runScript(
    String store,
    String guard,
    String script,
    List<MessageMatcher> until,
    int timeoutMs,
  ) async {
    calls.add('script');
    final f = onScript;
    if (f != null) return f(script, until);
    return ScriptRun(
      messages: <JsonMessage>[
        <String, Object?>{'type': until.isNotEmpty ? until.first.type : 'X', 'loggedIn': true},
      ],
      timedOut: false,
    );
  }

  @override
  Future<LoginResult> showLogin(LoginRequest request) async {
    calls.add('login');
    final f = onLogin;
    if (f != null) return f(request);
    return const LoginResult(outcome: LoginOutcome.signedIn, messages: <JsonMessage>[]);
  }

  @override
  Future<HttpResult> fetch(String store, FetchRequest request, int timeoutMs, int maxBytes) async {
    calls.add('fetch');
    final f = onFetch;
    if (f != null) return f(request);
    return const HttpResult(ok: true, status: 200, body: '{}');
  }
}
