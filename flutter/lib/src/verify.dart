// Envelope checks. Mirrors packages/core/src/verify.ts, with the same failure
// reasons: shape, unknown_kid, signature, json, version, expired, kind, job,
// seq, empty, too_many, unsupported_op.

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'keys.dart';
import 'protocol.dart';

const String _b64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
final RegExp _notB64 = RegExp(r'[^A-Za-z0-9+/]');

/// base64 (standard or url-safe, padded or not) to bytes. Lenient in exactly
/// the way the reference is: unknown characters and padding are dropped.
Uint8List base64ToBytes(String s) {
  final clean = s.replaceAll('-', '+').replaceAll('_', '/').replaceAll(_notB64, '');
  final out = <int>[];
  var buf = 0;
  var bits = 0;
  for (var i = 0; i < clean.length; i++) {
    // Only the low bits matter; the mask keeps `buf` small on every platform.
    buf = ((buf << 6) | _b64.indexOf(clean[i])) & 0xffffff;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.add((buf >> bits) & 0xff);
    }
  }
  return Uint8List.fromList(out);
}

/// An envelope that must be refused. `why` is the reason from PROTOCOL.md.
class EnvelopeError implements Exception {
  const EnvelopeError(this.why);

  final String why;

  String get code => 'bad_envelope';

  String get message => 'bad_envelope: $why';

  @override
  String toString() => message;
}

final Ed25519 _ed25519 = Ed25519();

Future<bool> _verifySignature(String payload, String sig, String publicKey) async {
  try {
    final pub = SimplePublicKey(base64ToBytes(publicKey), type: KeyPairType.ed25519);
    return await _ed25519.verify(
      utf8.encode(payload),
      signature: Signature(base64ToBytes(sig), publicKey: pub),
    );
  } catch (_) {
    // A malformed key or signature (wrong length) is simply "not valid".
    return false;
  }
}

/// Check the signature over the payload string as received, then parse it.
/// The signature covers the UTF-8 bytes of `payload` exactly as it arrived;
/// it is never re-serialized.
Future<Payload> openEnvelope(Envelope env, [Map<String, String>? keys]) async {
  final payload = env.payload;
  final sig = env.sig;
  if (payload == null || sig == null) throw const EnvelopeError('shape');
  final pub = (keys ?? mealioKeys)[env.kid];
  if (pub == null) throw const EnvelopeError('unknown_kid');
  if (!await _verifySignature(payload, sig, pub)) throw const EnvelopeError('signature');
  Object? p;
  try {
    p = jsonDecode(payload);
  } on FormatException {
    throw const EnvelopeError('json');
  }
  if (p is! Map) throw const EnvelopeError('version');
  final raw = <String, Object?>{};
  for (final MapEntry<Object?, Object?> e in p.entries) {
    final k = e.key;
    if (k is String) raw[k] = e.value;
  }
  if (raw['v'] != protocolVersion) throw const EnvelopeError('version');
  final exp = raw['exp'];
  final nowSeconds = DateTime.now().millisecondsSinceEpoch / 1000;
  if (exp is! num || exp + expSkewSeconds < nowSeconds) throw const EnvelopeError('expired');
  return Payload(raw);
}

/// The job and sequence checks for an instruction envelope. `job` null (or
/// empty) skips the job check, as in the reference.
InstructionsPayload checkInstructions(Payload p, String? job, int lastSeq) {
  final raw = p.raw;
  if (raw['kind'] != 'instructions') throw const EnvelopeError('kind');
  if (job != null && job.isNotEmpty && raw['job'] != job) throw const EnvelopeError('job');
  final seq = raw['seq'];
  if (seq is! num || seq != lastSeq + 1) throw const EnvelopeError('seq');
  final list = raw['instructions'];
  if (list is! List || list.isEmpty) throw const EnvelopeError('empty');
  if (list.length > maxInstructions) throw const EnvelopeError('too_many');
  final typed = <Instruction>[];
  for (final Object? i in list) {
    if (i is! Map || i['id'] is! String || !supportedOps.contains(i['op'])) {
      throw const EnvelopeError('unsupported_op');
    }
    final m = <String, Object?>{};
    for (final MapEntry<Object?, Object?> e in i.entries) {
      final k = e.key;
      if (k is String) m[k] = e.value;
    }
    typed.add(Instruction.fromJson(m));
  }
  return InstructionsPayload(
    v: (raw['v']! as num).toInt(),
    job: raw['job'] is String ? raw['job']! as String : '',
    seq: seq.toInt(),
    exp: raw['exp']! as num,
    store: raw['store'] is String ? raw['store']! as String : '',
    instructions: typed,
  );
}
