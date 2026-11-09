// 0.6 round 5 fixes. Each test here fails without its fix.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mealio_sdk/mealio_sdk.dart';
import 'package:mealio_sdk/src/json_depth.dart';
import 'package:mealio_sdk/testing.dart';

import 'support.dart';

void main() {
  group('guard: installed unarmed, armed by the per-script copy', () {
    test('every page script is preceded by the arming copy; the plain copy only installs', () async {
      final host = FakeHost();
      await Runner(host, keys: testKeys).run(Envelope.fromJson(vectorCase('valid_two_instructions')['envelope']), 'job_test', 0);
      expect(host.guards, <String>[guardArmScript]);
      expect(guardArmScript, '$guardScript\nwindow.__mealioArm(); true;');
      expect(guardScript.contains('__mealioArm()'), isTrue);
      expect(guardScript.endsWith('window.__mealioArm(); true;'), isFalse);
    });
  });

  group('request bodies: bounded recursion and size', () {
    test('operations nested more than 8 deep is blocked; 8 deep is still read', () {
      const inner = '{"query":"query{a}"}';
      expect(bodyBlocked('${'operations=' * 8}$inner'), isFalse);
      expect(bodyBlocked('${'operations=' * 9}$inner'), isTrue);
      expect(bodyBlocked('${'operations=' * 3000}$inner'), isTrue);
    });

    test('a body over 1 MB is blocked without being read', () {
      final pad = 'a' * bodyMaxText;
      expect(bodyBlocked('{"query":"query{a}","x":"placeOrder$pad"}'), isTrue);
      expect(bodyBlocked('{"query":"query{a}","x":"$pad"}'), isTrue);
      expect(bodyBlocked('\uFEFF${'a' * bodyMaxText}'), isFalse);
      // Exactly at the cap it is still parsed: the name in a plain string field is not an operation.
      const at = '{"query":"query{a}","x":"placeOrder"}';
      expect(bodyBlocked(at + ' ' * (bodyMaxText - at.length)), isFalse);
      final sw = Stopwatch()..start();
      expect(bodyBlocked('--B\r\nContent-Disposition: form-data; name="query"\r\n${'X: y\r\n' * 170000}\r\nquery{a}\r\n--B--'), isFalse);
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
    });
  });

  group('protocol vectors', () {
    test('bodyLimits: bodyBlocked follows every vector, quickly', () {
      final all = vectorList('bodyLimits');
      expect(all.map((Map<String, Object?> v) => v['rule']).toSet(), <String>{'depth', 'size'});
      for (final Map<String, Object?> v in all) {
        final body = '${v['prefix']}${(v['fill']! as String) * (v['times']! as int)}${v['suffix']}';
        final sw = Stopwatch()..start();
        expect(bodyBlocked(body), v['blocked'], reason: '${v['rule']} ${v['times']}x ${v['fill']} ${v['suffix']}');
        expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
      }
    });

    test('deepMessages: built at most 512 deep, and the message stays usable', () {
      int depthOf(Object? v) {
        var max = 0;
        final stack = <(Object?, int)>[(v, 1)];
        while (stack.isNotEmpty) {
          final (Object? x, int d) = stack.removeLast();
          final kids = x is Map ? x.values : x is List ? x : null;
          if (kids == null) continue;
          if (d > max) max = d;
          for (final Object? c in kids) {
            stack.add((c, d + 1));
          }
        }
        return max;
      }

      final m = MessageMatcher.fromJson(<String, Object?>{'type': 'X', 'eq': <String, Object?>{'keep': 1}});
      for (final Map<String, Object?> v in vectorList('deepMessages')) {
        final n = v['times']! as int;
        final raw = '${v['prefix']}${(v['open']! as String) * n}${(v['close']! as String) * n}${v['suffix']}';
        final what = '${v['open']}x$n';
        final msg = parseMessage(raw);
        expect(msg, isNotNull, reason: what);
        expect(depthOf(msg), v['depth'], reason: what);
        expect(msg!['keep'], v['keep'], reason: what);
        expect(messageMatches(msg, m), isTrue, reason: what);
        expect(() => jsonEncode(msg), returnsNormally, reason: what);
      }
    });
  });

  group('messages from the page: depth limit 512', () {
    test('a 100k-deep message is read without building it, and matching it does not overflow', () {
      final deep = '{"type":"x","v":${'[' * 100000}${']' * 100000}}';
      final msg = parseMessage(deep)!;
      // 512 containers are built (the message itself is the first); the next is kept empty.
      expect(jsonEncode(msg['v']).length, 2 * 512);
      final m = MessageMatcher.fromJson(<String, Object?>{'type': 'x', 'eq': <String, Object?>{'v': <Object?>[]}});
      expect(messageMatches(msg, m), isFalse);
      expect(parseMessage('{"type":"x","v":${'{"a":' * 100000}1${'}' * 100000}}'), isNotNull);
      expect(bridgeUnwrap('{"n":"a","m":"s","x":${'[' * 100000}${']' * 100000}}', 'a'), 's');
    });

    test('depth-limited reading accepts and refuses exactly what jsonDecode does', () {
      const cases = <String>[
        '1', '-0', '"a\\u0041"', '[]', '{}', '[1,[2,{"a":[3]}]]', '{"a":1,"b":{"c":null}}', ' [ 1 , 2 ] ',
        '[1,]', '{"a":1,}', '[1 2]', '{"a" 1}', '{1:2}', '[', '{"a":', '"\\ud800"', 'tru', 'true false',
        '[01]', '1.5e3', '{"a":1}x', '[}', ']', '{"a":[}]}', '"\t"', '[-]', '[1e]', '{"":{"":[]}}', '', '﻿{}',
      ];
      for (final String c in cases) {
        String want, got;
        try {
          want = jsonEncode(jsonDecode(c));
        } on FormatException {
          want = 'FormatException';
        }
        try {
          got = jsonEncode(decodeJsonLimited(c));
        } on FormatException {
          got = 'FormatException';
        }
        expect(got, want, reason: c);
      }
      expect(jsonEncode(decodeJsonLimited('{"a":[1,{"x":[[]]},3],"b":2}', maxDepth: 2)), '{"a":[1,{},3],"b":2}');
      // Bad JSON past the limit is still bad.
      for (final String c in <String>['[[[1,]]]', '[[{"a" 1}]]', '[[{"a":1}]', '[[[}]]']) {
        expect(() => decodeJsonLimited(c, maxDepth: 1), throwsFormatException, reason: c);
      }
    });
  });

  group('MealioFakeScript.fromJson is strict at every level', () {
    String err(Object? json) {
      try {
        MealioFakeScript.fromJson(json);
        return 'no error';
      } on FormatException catch (e) {
        return e.message;
      }
    }

    test('warm: {} is signed in, as in TypeScript', () {
      expect(MealioFakeScript.fromJson(<String, Object?>{'warm': <String, Object?>{}}).warm!.signedIn, isTrue);
      expect(MealioFakeScript.fromJson(<String, Object?>{'warm': <String, Object?>{'signedIn': false}}).warm!.signedIn, isFalse);
      expect(MealioFakeScript.fromJson(<String, Object?>{'warm': null}).warm, isNull);
    });

    test('unknown fields, missing keys and wrong types name the field', () {
      expect(err(<String, Object?>{'errors': <String, Object?>{'serach': 'network'}}), contains('script.errors.serach'));
      expect(err(<String, Object?>{
        'items': <Object?>[<String, Object?>{'key': 'a', 'remebered': 'x'}],
      }), contains('script.items[0].remebered'));
      expect(err(<String, Object?>{'signIn': 'signedin'}), contains('script.signIn'));
      expect(err(<String, Object?>{'items': <Object?>[<String, Object?>{'options': <Object?>[]}]}), contains('script.items[0].key is required'));
      expect(err(<String, Object?>{'add': <String, Object?>{}}), contains('script.add.fail is required'));
      expect(err(<String, Object?>{'items': <Object?>[<String, Object?>{'key': 1}]}), contains('script.items[0].key must be a string'));
      expect(err(<String, Object?>{
        'items': <Object?>[<String, Object?>{'key': 'a', 'options': <Object?>[<String, Object?>{'id': 'p', 'name': 'P', 'unitPrice': '3'}]}],
      }), contains('script.items[0].options[0].unitPrice'));
      expect(err(<String, Object?>{'search': <String, Object?>{'q': <Object?>[<String, Object?>{'id': 'p'}]}}), contains('script.search.q[0].name'));
      expect(err(<String, Object?>{'errors': <String, Object?>{'add': <String, Object?>{'code': 'x', 'status': 'x'}}}), contains('script.errors.add.status'));
      expect(err(<String, Object?>{'stores': <Object?>[<String, Object?>{'id': 'h', 'name': 'H', 'via': 'web'}]}), contains('script.stores[0].via'));
      expect(err(<String, Object?>{'locations': <Object?>[<String, Object?>{'id': 'l', 'name': 'L', 'address': 'A', 'zip': null, 'x': 1}]}),
          contains('script.locations[0].x'));
      expect(err(<String, Object?>{'warm': <String, Object?>{'signedIn': 'yes'}}), contains('script.warm.signedIn'));
      expect(err(<String, Object?>{'items': <Object?>[<String, Object?>{'key': 'a', 'quantity': 1.5}]}), contains('script.items[0].quantity'));
      expect(() => MealioFakeItem.fromJson(<String, Object?>{'options': <Object?>[]}), throwsFormatException);
      expect(() => MealioFakeError.fromJson(<String, Object?>{'message': 'm'}), throwsFormatException);
    });
  });
}
