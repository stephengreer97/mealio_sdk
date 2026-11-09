// decodeJsonLimited against TypeScript parseJson, case by case. The fixture
// is made by tool/gen_json_depth_fuzz.cjs running the real matcher.ts in node.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mealio_sdk/src/json_depth.dart';

// The fixture's shape: JSON.stringify strings (lone surrogates escaped in
// lower case), every number '#', keys in order.
String _str(String s) =>
    jsonEncode(s).replaceAllMapped(RegExp(r'[\ud800-\udfff]'), (m) => '\\u${m[0]!.codeUnitAt(0).toRadixString(16).padLeft(4, '0')}');

String _shape(Object? v) {
  if (v == null) return 'null';
  if (v is Map) return '{${v.entries.map((e) => '${_str(e.key as String)}:${_shape(e.value)}').join(',')}}';
  if (v is List) return '[${v.map(_shape).join(',')}]';
  if (v is num) return '#';
  if (v is String) return _str(v);
  return v.toString();
}

String? _run(String s, int maxDepth) {
  try {
    return _shape(decodeJsonLimited(s, maxDepth: maxDepth));
  } on FormatException {
    return null;
  }
}

void main() {
  test('decodeJsonLimited accepts and builds what TypeScript parseJson does (fuzzed)', () {
    final cases = jsonDecode(File('test/fixtures/json-depth-fuzz.json').readAsStringSync()) as List<Object?>;
    expect(cases.length, greaterThan(20000));
    final bad = <String>[];
    for (final Object? c in cases) {
      final l = c! as List<Object?>;
      final s = l[0]! as String;
      if (_run(s, 3) != l[1]) bad.add('at 3: ${jsonEncode(s)} ts=${l[1]} dart=${_run(s, 3)}');
      if (_run(s, 512) != l[2]) bad.add('at 512: ${jsonEncode(s).substring(0, 80)}… ts=${l[2] != null}');
    }
    expect(bad.take(5).toList(), isEmpty, reason: '${bad.length} differ');
  });

  test('a too-deep container is blanked by bracket matching, its contents unread', () {
    // TypeScript keeps these: the inner container is never parsed.
    expect(jsonEncode(decodeJsonLimited('[[[1,]]]', maxDepth: 1)), '[[]]');
    expect(jsonEncode(decodeJsonLimited('[{"a" 1 junk}]', maxDepth: 1)), '[{}]');
    expect(jsonEncode(decodeJsonLimited('[[[}]]', maxDepth: 1)), '[[]]');
    expect(jsonEncode(decodeJsonLimited('{"a":["]",{"b":"\\"}"}]}', maxDepth: 1)), '{"a":[]}');
    // Brackets that never close, or bad text outside the deep part, are still bad.
    expect(() => decodeJsonLimited('[[{"a":1}]', maxDepth: 1), throwsFormatException);
    expect(() => decodeJsonLimited('[[1],]', maxDepth: 1), throwsFormatException);
    expect(() => decodeJsonLimited('[${'[' * 100000}', maxDepth: 512), throwsFormatException);
  });
}
