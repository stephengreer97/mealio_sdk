// MealioClient.warm(): the login check run before the tap, and the one-time
// hint it hands the next prepare. Mirrors the TS "warm-up" tests in
// packages/core/test/core.test.ts.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mealio_sdk/mealio_sdk.dart';

import 'support.dart';

http.Response _json(Object? body, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), status, headers: <String, String>{'content-type': 'application/json'});

Future<Envelope> _done(String job, Object? result) => signText(jsonEncode(<String, Object?>{
      'v': 1,
      'kind': 'instructions',
      'job': job,
      'seq': 1,
      'exp': 4102444800,
      'store': 'heb',
      'instructions': <Object?>[
        <String, Object?>{'op': 'done', 'id': 'd1', 'result': result},
      ],
    }));

const Map<String, Object?> _emptyCart = <String, Object?>{
  'cartId': 'c',
  'store': 'heb',
  'items': <Object?>[],
  'ready': <Object?>[],
  'needsChoice': <Object?>[],
  'unavailable': <Object?>[],
};

const Recipe _recipe = Recipe(id: 'r1', ingredients: <RecipeIngredient>[RecipeIngredient(name: 'milk')]);

/// Serves /warm from `warm`, carts always done. Every carts body lands in `carts`.
MealioClient _client(Future<Object?> Function() warm, List<Map<String, Object?>> carts) {
  final mock = MockClient((http.Request req) async {
    if (req.url.path == '/api/v1/sdk/warm') return _json(await warm());
    if (req.url.path == '/api/v1/sdk/carts') {
      carts.add(jsonDecode(utf8.decode(req.bodyBytes)) as Map<String, Object?>);
      return _json(<String, Object?>{'job': 'job_cart', 'envelope': (await _done('job_cart', _emptyCart)).toJson()});
    }
    throw StateError('unexpected ${req.url.path}');
  });
  return MealioClient(
    ClientConfig(publishableKey: 'pk', getSessionToken: () async => 't', httpClient: mock, keys: testKeys),
    FakeHost(),
  );
}

Future<Object?> Function() _warmDone(Object? signedIn) => () async => <String, Object?>{
      'job': 'job_warm',
      'envelope': (await _done('job_warm', <String, Object?>{'store': 'heb', 'signedIn': signedIn})).toJson(),
    };

void main() {
  group('warm-up', () {
    test('hands a signed-in warm-up to the next prepare, once', () async {
      final carts = <Map<String, Object?>>[];
      final c = _client(_warmDone(true), carts);
      await c.warm();
      await c.prepareCart(recipe: _recipe);
      await c.prepareCart(recipe: _recipe);
      expect(carts[0]['warm'], 'job_warm');
      expect(carts[1].containsKey('warm'), isFalse);
    });

    test('sends no hint when signed out, or when there is nothing to warm', () async {
      for (final warm in <Future<Object?> Function()>[_warmDone(false), () async => <String, Object?>{'warm': null}]) {
        final carts = <Map<String, Object?>>[];
        final c = _client(warm, carts);
        await c.warm();
        await c.prepareCart(recipe: _recipe);
        expect(carts[0].containsKey('warm'), isFalse);
      }
    });

    test('sends no hint for another store', () async {
      final carts = <Map<String, Object?>>[];
      final c = _client(_warmDone(true), carts);
      await c.warm();
      await c.prepareCart(store: 'walmart', recipe: _recipe);
      expect(carts[0].containsKey('warm'), isFalse);
    });

    test('a prepare waits for a warm-up in flight', () async {
      final order = <String>[];
      final carts = <Map<String, Object?>>[];
      final c = _client(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        order.add('warm');
        return _warmDone(true)();
      }, carts);
      final w = c.warm();
      final p = c.prepareCart(recipe: _recipe).then((_) => order.add('cart'));
      await Future.wait(<Future<Object?>>[w, p]);
      expect(order, <String>['warm', 'cart']);
    });

    test('runs at most once every few minutes, and never throws', () async {
      var calls = 0;
      final c = _client(() async {
        calls += 1;
        throw StateError('boom');
      }, <Map<String, Object?>>[]);
      await c.warm();
      await c.warm();
      expect(calls, 1);
      c.clearWarm();
      await c.warm();
      expect(calls, 2);
    });
  });
}
