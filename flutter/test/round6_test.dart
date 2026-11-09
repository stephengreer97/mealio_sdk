// Round 6 fixes (spec-0.6-round6.md): fractional quantity in the testing kit,
// LoginRequest arms the guard by default, and the multipart scan is linear.
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mealio_sdk/mealio_sdk.dart';
import 'package:mealio_sdk/testing.dart';

import 'support.dart';

void main() {
  group('testing kit: a quantity is a number, as in TypeScript', () {
    test('a fractional item or recipe quantity is accepted and read as whole packages', () {
      final s = MealioFakeScript.fromJson(jsonDecode(
          '{"items":[{"key":"a","quantity":1.5,"recipes":[{"id":"r","title":null,"quantity":2.5}]}]}'));
      expect(s.items.single.quantity, 1);
      expect(s.items.single.recipes!.single.quantity, 2);
    });

    test('1e400 (Infinity) is accepted and is no quantity, as JSON.stringify sends null', () {
      final s = MealioFakeScript.fromJson(jsonDecode(
          '{"items":[{"key":"a","quantity":1e400,"recipes":[{"id":"r","title":null,"quantity":-1e400}]}]}'));
      expect(s.items.single.quantity, isNull);
      expect(s.items.single.recipes!.single.quantity, 1);
    });

    test('the client reads an infinite number from the server as missing, not a crash', () {
      final r = ItemRecipe.fromJson(<String, Object?>{'id': 'r', 'title': null, 'quantity': double.infinity});
      expect(r.quantity, 1);
    });
  });

  test('LoginRequest.armGuard defaults to GUARD_ARM_SCRIPT', () {
    final r = LoginRequest(
      store: 'heb',
      url: 'https://www.heb.com/login',
      title: 'H-E-B',
      guard: guardScript,
      check: null,
      doneWhen: const <MessageMatcher>[],
      doneWhenUrl: null,
      timeoutMs: 1000,
      allowNavigation: (_) => true,
    );
    expect(r.armGuard, guardArmScript);
  });

  group('multipart scan is linear', () {
    test('a body of repeated name=query lines under 1 MB is judged in well under a second', () {
      for (final String line in <String>['name=query\n', 'name="query"\r\n', 'name=operations x\n', 'name=query name=query ']) {
        final body = line * (1000000 ~/ line.length);
        expect(body.length, lessThan(bodyMaxText));
        final sw = Stopwatch()..start();
        expect(bodyBlocked(body), isFalse);
        expect(sw.elapsedMilliseconds, lessThan(2000), reason: jsonEncode(line));
      }
      // Still read: the blocked field at the end of all that.
      final tail = '${'name=query\n' * 80000}\nmutation { placeOrder { id } }';
      final sw = Stopwatch()..start();
      expect(bodyBlocked(tail), isTrue);
      expect(sw.elapsedMilliseconds, lessThan(2000));
    });

    test('multipartScan vectors: judged right, each in well under a second', () {
      final all = vectorList('multipartScan');
      expect(all, isNotEmpty);
      for (final Map<String, Object?> v in all) {
        final body = '${v['prefix']}${(v['fill']! as String) * (v['times']! as int)}${v['suffix']}';
        final sw = Stopwatch()..start();
        expect(bodyBlocked(body), v['blocked'], reason: jsonEncode(v['fill']));
        expect(sw.elapsedMilliseconds, lessThan(2000), reason: jsonEncode(v['fill']));
      }
    });

    test('multipartFields finds exactly what MULTIPART_FIELD does (fuzzed)', () {
      final rnd = Random(606);
      const atoms = <String>[
        'name=', 'name="', "name='", 'operations', 'operationName', 'query', 'operationsX', 'Query', '"', "'", ';', ' ',
        '\t', '\v', ' ', '﻿', '​', '\r', '\n', '\r\n', '\r\r\n', '\n\n', '\r\n\r\n', '--', '\n--',
        '\r\n--', '-', 'X: y', 'Content-Disposition: form-data; ', 'a', 'mutation{placeOrder{id}}', '=',
      ];
      final re = RegExp(multipartField);
      for (var i = 0; i < 30000; i++) {
        final b = StringBuffer(rnd.nextBool() ? '--B\r\nContent-Disposition: form-data; ' : '');
        for (var k = rnd.nextInt(24); k >= 0; k--) {
          b.write(atoms[rnd.nextInt(atoms.length)]);
        }
        final s = b.toString();
        final want = <(String, String)>[for (final Match m in re.allMatches(s)) (m.group(1)!, m.group(2)!)];
        expect(multipartFields(s), want, reason: jsonEncode(s));
      }
    });
  });
}
