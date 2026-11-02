// Message parsing and matching. Mirrors packages/core/src/matcher.ts.

import 'dart:convert';

import 'protocol.dart';

/// Parse one posted message. Anything that is not a JSON object is dropped
/// (returns null).
JsonMessage? parseMessage(Object? raw) {
  Object? v = raw;
  if (raw is String) {
    try {
      v = jsonDecode(raw);
    } on FormatException {
      return null;
    }
  }
  if (v is! Map) return null;
  final out = <String, Object?>{};
  for (final MapEntry<Object?, Object?> e in v.entries) {
    final k = e.key;
    if (k is String) out[k] = e.value;
  }
  return out;
}

/// `JSON.stringify` for parsed JSON values, so object comparison matches the
/// reference exactly (key order included). Integral doubles print without a
/// fraction, as JavaScript prints them.
String _jsStringify(Object? v) {
  if (v == null) return 'null';
  if (v is bool) return v ? 'true' : 'false';
  if (v is num) {
    if (v is double) {
      if (v.isNaN || v.isInfinite) return 'null';
      if (v == v.truncateToDouble() && v.abs() < 1e21) return v.toInt().toString();
    }
    return v.toString();
  }
  if (v is String) return jsonEncode(v);
  if (v is List) return '[${v.map(_jsStringify).join(',')}]';
  if (v is Map) {
    final parts = <String>[];
    for (final MapEntry<Object?, Object?> e in v.entries) {
      parts.add('${jsonEncode(e.key.toString())}:${_jsStringify(e.value)}');
    }
    return '{${parts.join(',')}}';
  }
  return jsonEncode(v.toString());
}

/// Strict equality for primitives, JSON text equality for objects and arrays.
/// A missing field (`present == false`) never equals anything.
bool _same(bool present, Object? a, Object? b) {
  if (!present) return false;
  final aObj = a is Map || a is List;
  final bObj = b is Map || b is List;
  if (a == null || b == null || !aObj || !bObj) {
    // JS `===`: no cross-type coercion. Dart `==` on num compares values
    // (1 == 1.0), like JS numbers do.
    if (aObj || bObj) return false;
    return a == b;
  }
  return _jsStringify(a) == _jsStringify(b);
}

/// PROTOCOL.md "Matcher". `type` must be strictly equal, every `eq` field
/// strictly equal, and every `ne` field not equal (missing counts as not equal).
bool messageMatches(JsonMessage msg, MessageMatcher m) {
  if (msg['type'] != m.type) return false;
  final eq = m.eq;
  if (eq != null) {
    for (final String k in eq.keys) {
      if (!_same(msg.containsKey(k), msg[k], eq[k])) return false;
    }
  }
  final ne = m.ne;
  if (ne != null) {
    for (final String k in ne.keys) {
      if (_same(msg.containsKey(k), msg[k], ne[k])) return false;
    }
  }
  return true;
}

bool messageMatchesAny(JsonMessage msg, List<MessageMatcher> list) {
  for (final MessageMatcher m in list) {
    if (messageMatches(msg, m)) return true;
  }
  return false;
}
