// The one testing-kit script every platform runs: test/fixtures/fake-script.json,
// a copy of protocol/fake-script.json. Each case's `script` goes through
// MealioFakeScript.fromJson (the TypeScript kit's field names), and its steps
// run on a real client.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mealio_sdk/mealio_sdk.dart';
import 'package:mealio_sdk/testing.dart';

typedef _Json = Map<String, Object?>;

final _Json _file = jsonDecode(File('test/fixtures/fake-script.json').readAsStringSync()) as _Json;

Future<void> _run(_Json c) async {
  final scriptJson = Map<String, Object?>.of(c['script']! as _Json);
  final fake = MealioFake(MealioFakeScript.fromJson(scriptJson));
  final client = fake.client();
  final recipe = Recipe.fromJson(_file['recipe']);
  final carts = <String, CartSession>{};

  for (final Object? s in c['steps']! as List<Object?>) {
    final step = s! as _Json;
    final what = step['do']! as String;
    final name = (step['cart'] as String?) ?? 'a';
    final expected = step['expect'];
    final reason = '${c['name']}: $what $step';
    final want = expected is Map ? expected.cast<String, Object?>() : const <String, Object?>{};

    Future<Object?> act() async {
      switch (what) {
        case 'prepare':
          return carts[name] = await client.prepareCart(recipe: recipe);
        case 'search':
          return carts[name]!.search(step['key']! as String, step['query']! as String);
        case 'select':
          carts[name]!.select(step['key']! as String, step['productId']! as String);
          return null;
        case 'add':
          return carts[name]!.addToCart();
        case 'restorePicks':
          await carts[name]!.restorePicks(carts[step['from']! as String]!);
          return null;
        case 'setScript':
          (step['set']! as _Json).forEach((String k, Object? v) {
            if (v == null) {
              scriptJson.remove(k);
            } else {
              scriptJson[k] = v;
            }
          });
          fake.script = MealioFakeScript.fromJson(scriptJson);
          return null;
        case 'requests':
          return fake.requests.map((MealioFakeRequest r) => r.kind).toList();
        case 'searches':
          return fake.requests.where((MealioFakeRequest r) => r.kind == 'search').map((MealioFakeRequest r) => r.body?['query']).toList();
      }
      fail('unknown step $what');
    }

    if (want['error'] != null) {
      await expectLater(
        act(),
        throwsA(isA<MealioException>().having((MealioException e) => e.code, 'code', want['error'])),
        reason: reason,
      );
      continue;
    }
    final out = await act();
    if (expected == null) continue;
    final cart = carts[name];
    switch (what) {
      case 'requests':
      case 'searches':
        expect(out, expected, reason: reason);
      case 'search':
        expect((out! as List<Product>).map((Product p) => p.id), want['options'], reason: reason);
      case 'select':
        expect(cart!.selectedId(step['key']! as String), want['selectedId'], reason: reason);
      case 'add':
        final r = out! as AddResult;
        expect(r.added.map((AddedItem a) => a.key), want['added'], reason: reason);
        expect(r.skipped.map((SkippedItem a) => a.key), want['skipped'], reason: reason);
        expect(r.failed.map((FailedItem a) => a.key), want['failed'], reason: reason);
        if (want.containsKey('addedTotal')) {
          final total = cart!.addedTotal(r).total;
          expect(total == null ? null : (total * 100).round(), ((want['addedTotal']! as num) * 100).round(), reason: reason);
        }
      case 'prepare':
      case 'restorePicks':
        if (want.containsKey('store')) expect(cart!.store, want['store'], reason: reason);
        if (want.containsKey('storeName')) expect(cart!.storeName, want['storeName'], reason: reason);
        if (want.containsKey('recipes')) {
          expect(cart!.recipes.map((CartRecipe r) => <String, Object?>{'id': r.id, 'title': r.title}), want['recipes'], reason: reason);
        }
        final items = want['items'] as Map<String, Object?>? ?? const <String, Object?>{};
        items.forEach((String key, Object? v) {
          final w = v! as _Json;
          final item = cart!.items.firstWhere((CartItem i) => i.key == key);
          if (w.containsKey('status')) expect(item.status.wire, w['status'], reason: '$reason $key');
          if (w.containsKey('selectedId')) expect(cart.selectedId(key), w['selectedId'], reason: '$reason $key');
          if (w.containsKey('quantity')) expect(cart.quantity(key), w['quantity'], reason: '$reason $key');
        });
      default:
        fail('no expectation for $what');
    }
  }
}

void main() {
  group('protocol/fake-script.json', () {
    for (final Object? c in _file['cases']! as List<Object?>) {
      final json = c! as _Json;
      test(json['name']! as String, () => _run(json));
    }
  });

  group('MealioFakeScript.fromJson', () {
    test('reads every field with the TypeScript names', () {
      final s = MealioFakeScript.fromJson(<String, Object?>{
        'store': 'kroger',
        'storeName': 'Kroger',
        'items': <Object?>[
          <String, Object?>{'key': 'k', 'quantity': 2, 'weightLb': 1.5, 'startUnchecked': true, 'rememberedUnavailable': true, 'remembered': 'p'},
        ],
        'warnings': <Object?>[<String, Object?>{'code': 'lines_dropped', 'message': 'x'}],
        'search': <String, Object?>{'q': <Object?>[<String, Object?>{'id': 'p', 'name': 'P'}]},
        'add': <String, Object?>{'fail': <String, Object?>{'code': 'store_unavailable', 'status': 503}},
        'signIn': 'timeout',
        'errors': <String, Object?>{'search': 'search_limit', 'prepare': <String, Object?>{'code': 'cart_cap_reached', 'status': 429}},
        'locations': <Object?>[<String, Object?>{'id': 'l1', 'name': 'Main', 'address': '1 Main'}],
        'warm': null,
      });
      expect(s.store, 'kroger');
      expect(s.items.single.weightLb, 1.5);
      expect(s.items.single.startUnchecked, isTrue);
      expect(s.items.single.rememberedUnavailable, isTrue);
      expect(s.warnings.single.code, 'lines_dropped');
      expect(s.search['q']!.single.id, 'p');
      expect(s.addFailure!.status, 503);
      expect(s.signIn, 'timeout');
      expect(s.errors['search']!.code, 'search_limit');
      expect(s.errors['prepare']!.status, 429);
      expect(s.locations.single.id, 'l1');
      expect(s.warm, isNull);
      expect(MealioFakeScript.fromJson(<String, Object?>{}).warm?.signedIn, isTrue);
    });

    test('refuses a field the kit does not know, so a typo shows', () {
      expect(() => MealioFakeScript.fromJson(<String, Object?>{'addFailure': <String, Object?>{}}), throwsFormatException);
    });
  });
}
