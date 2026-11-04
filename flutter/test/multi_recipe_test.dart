// Multi-recipe carts: `recipes` on prepareCart, the new optional cart fields,
// CartSession.recipes / recipesFor, the "For A and B" line and the drop-in's
// header and rows. Mirrors the reference change in packages/core and
// packages/react-native.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mealio_sdk/mealio_sdk.dart';

import 'support.dart';

http.Response _json(Object? body, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), status, headers: <String, String>{'content-type': 'application/json'});

Recipe _r(String id, [String? title]) =>
    Recipe(id: id, title: title, ingredients: <RecipeIngredient>[RecipeIngredient(name: 'onion $id')]);

MealioClient _client(MockClient mock) => MealioClient(
      ClientConfig(publishableKey: 'pk', getSessionToken: () async => 't', httpClient: mock, keys: testKeys),
      FakeHost(),
    );

/// Answers the start call with an error, so a test can read the body it sent
/// without driving a job.
MockClient _capture(List<Map<String, Object?>> bodies) => MockClient((http.Request req) async {
      bodies.add(jsonDecode(utf8.decode(req.bodyBytes)) as Map<String, Object?>);
      return _json(<String, Object?>{
        'error': <String, Object?>{'code': 'store_unavailable', 'message': 'down'},
      }, 503);
    });

Matcher _throwsCode(String code) =>
    throwsA(isA<MealioException>().having((MealioException e) => e.code, 'code', code));

Map<String, Object?> _multiCart() => <String, Object?>{
      'cartId': 'c1',
      'store': 'heb',
      'storeName': 'H-E-B',
      'recipes': <Object?>[
        <String, Object?>{'id': 'tacos', 'title': 'Tacos'},
        <String, Object?>{'id': 'pasta', 'title': 'Pasta'},
        <String, Object?>{'id': 'soup', 'title': null},
      ],
      'items': <Object?>[
        <String, Object?>{
          'key': 'onion',
          'ingredient': 'onion',
          'quantity': 3,
          'status': 'choose',
          'selectedId': null,
          'remembered': null,
          'recipes': <Object?>[
            <String, Object?>{'id': 'tacos', 'title': 'Tacos', 'quantity': 1},
            <String, Object?>{'id': 'pasta', 'title': 'Pasta', 'quantity': 2},
          ],
          'options': <Object?>[
            <String, Object?>{'id': 'o1', 'name': 'Yellow Onion', 'price': r'$1.25', 'unitPrice': 1.25},
          ],
        },
        <String, Object?>{
          'key': 'basil',
          'ingredient': 'basil',
          'quantity': 1,
          'status': 'choose',
          'selectedId': null,
          'remembered': null,
          'recipes': <Object?>[
            <String, Object?>{'id': 'soup', 'title': null, 'quantity': 1},
          ],
          'options': <Object?>[
            <String, Object?>{'id': 'b1', 'name': 'Fresh Basil', 'price': r'$2.00', 'unitPrice': 2.0},
          ],
        },
      ],
    };

Map<String, Object?> _oldCart() => <String, Object?>{
      'cartId': 'c0',
      'store': 'heb',
      'items': <Object?>[
        <String, Object?>{
          'key': 'onion',
          'ingredient': 'onion',
          'quantity': 1,
          'status': 'choose',
          'selectedId': null,
          'remembered': null,
          'options': <Object?>[],
        },
      ],
    };

CartSession _session(Map<String, Object?> cart) =>
    CartSession(_client(MockClient((http.Request req) async => _json(<String, Object?>{}))), PreparedCart.fromJson(cart));

void main() {
  group('prepareCart with recipes', () {
    test('one recipe goes as recipe, even when passed in recipes', () async {
      final bodies = <Map<String, Object?>>[];
      final client = _client(_capture(bodies));
      await expectLater(client.prepareCart(store: 'heb', recipe: _r('a', 'A')), _throwsCode('store_unavailable'));
      await expectLater(client.prepareCart(store: 'heb', recipes: <Recipe>[_r('b')]), _throwsCode('store_unavailable'));
      expect(bodies, hasLength(2));
      expect((bodies[0]['recipe']! as Map<String, Object?>)['id'], 'a');
      expect(bodies[0].containsKey('recipes'), isFalse);
      expect((bodies[1]['recipe']! as Map<String, Object?>)['id'], 'b');
      expect(bodies[1].containsKey('recipes'), isFalse);
      expect(bodies[1]['store'], 'heb');
    });

    test('several recipes go as recipes, in order', () async {
      final bodies = <Map<String, Object?>>[];
      await expectLater(
        _client(_capture(bodies)).prepareCart(zip: '78701', recipes: <Recipe>[_r('a', 'A'), _r('b'), _r('c')]),
        _throwsCode('store_unavailable'),
      );
      final b = bodies.single;
      expect(b.containsKey('recipe'), isFalse);
      expect(b.containsKey('store'), isFalse);
      expect(b['zip'], '78701');
      final sent = (b['recipes']! as List<Object?>).cast<Map<String, Object?>>();
      expect(sent.map((Map<String, Object?> r) => r['id']), <String>['a', 'b', 'c']);
      expect(sent.first['title'], 'A');
      expect(sent[1].containsKey('title'), isFalse);
      expect(b['sdk'], isA<Map<String, Object?>>());
    });

    test('no recipe, an empty list, or more than maxRecipes throw before any request', () async {
      final bodies = <Map<String, Object?>>[];
      final client = _client(_capture(bodies));
      await expectLater(client.prepareCart(store: 'heb'), _throwsCode(MealioErrorCode.badRecipe));
      await expectLater(client.prepareCart(recipes: const <Recipe>[]), _throwsCode('bad_recipe'));
      final eleven = List<Recipe>.generate(maxRecipes + 1, (int i) => _r('r$i'));
      await expectLater(client.prepareCart(recipes: eleven), _throwsCode(MealioErrorCode.tooManyRecipes));
      expect(MealioErrorCode.tooManyRecipes, 'too_many_recipes');
      expect(bodies, isEmpty);

      // Exactly maxRecipes is allowed.
      final ten = List<Recipe>.generate(maxRecipes, (int i) => _r('r$i'));
      await expectLater(client.prepareCart(recipes: ten), _throwsCode('store_unavailable'));
      expect(bodies.single['recipes']! as List<Object?>, hasLength(10));
    });
  });

  group('parsing', () {
    test('reads PreparedCart.recipes and CartItem.recipes', () {
      final cart = PreparedCart.fromJson(_multiCart());
      expect(cart.recipes!.map((CartRecipe r) => r.id), <String>['tacos', 'pasta', 'soup']);
      expect(cart.recipes!.map((CartRecipe r) => r.title), <String?>['Tacos', 'Pasta', null]);
      final onion = cart.items.first;
      expect(onion.quantity, 3);
      expect(onion.recipes!.map((ItemRecipe r) => r.id), <String>['tacos', 'pasta']);
      expect(onion.recipes!.map((ItemRecipe r) => r.quantity), <int>[1, 2]);
      expect(onion.recipes!.first.title, 'Tacos');
    });

    test('older servers: the new fields are null and toJson leaves them out', () {
      final cart = PreparedCart.fromJson(_oldCart());
      expect(cart.recipes, isNull);
      expect(cart.items.single.recipes, isNull);
      expect(cart.toJson().containsKey('recipes'), isFalse);
      expect(cart.items.single.toJson().containsKey('recipes'), isFalse);
    });

    test('wrong types are tolerated', () {
      final cart = PreparedCart.fromJson(<String, Object?>{
        'cartId': 'c',
        'store': 'heb',
        'recipes': 'nope',
        'items': <Object?>[
          <String, Object?>{
            'key': 'k',
            'ingredient': 'k',
            'quantity': 1,
            'recipes': <Object?>[7, <String, Object?>{'id': 'x'}],
          },
        ],
      });
      expect(cart.recipes, isNull);
      final rs = cart.items.single.recipes!;
      expect(rs.map((ItemRecipe r) => r.id), <String>['', 'x']);
      expect(rs.last.title, isNull);
      expect(rs.last.quantity, 1);
    });

    test('round trips through toJson', () {
      final again = PreparedCart.fromJson(PreparedCart.fromJson(_multiCart()).toJson());
      expect(again.recipes!.map((CartRecipe r) => r.id), <String>['tacos', 'pasta', 'soup']);
      expect(again.items.first.recipes!.map((ItemRecipe r) => r.quantity), <int>[1, 2]);
    });
  });

  group('CartSession', () {
    test('recipes and recipesFor', () {
      final s = _session(_multiCart());
      expect(s.recipes.map((CartRecipe r) => r.id), <String>['tacos', 'pasta', 'soup']);
      expect(s.recipesFor('onion').map((ItemRecipe r) => r.title), <String?>['Tacos', 'Pasta']);
      expect(s.recipesFor('basil').single.id, 'soup');
      expect(s.recipesFor('nope'), isEmpty);
    });

    test('older servers: empty lists', () {
      final s = _session(_oldCart());
      expect(s.recipes, isEmpty);
      expect(s.recipesFor('onion'), isEmpty);
    });
  });

  group('For line', () {
    ItemRecipe ir(String? title) => ItemRecipe(id: title ?? 'x', title: title, quantity: 1);

    test('joins two with and, three or more with commas and and', () {
      expect(forRecipesLabel(2, <ItemRecipe>[ir('Tacos')]), 'For Tacos');
      expect(forRecipesLabel(2, <ItemRecipe>[ir('Tacos'), ir('Pasta')]), 'For Tacos and Pasta');
      expect(forRecipesLabel(3, <ItemRecipe>[ir('A'), ir('B'), ir('C')]), 'For A, B and C');
      expect(forRecipesLabel(4, <ItemRecipe>[ir('A'), ir('B'), ir('C'), ir('D')]), 'For A, B, C and D');
    });

    test('leaves out untitled recipes, and gives null with no names', () {
      expect(forRecipesLabel(3, <ItemRecipe>[ir('A'), ir(null), ir(''), ir('B')]), 'For A and B');
      expect(forRecipesLabel(3, <ItemRecipe>[ir(null)]), isNull);
      expect(forRecipesLabel(3, const <ItemRecipe>[]), isNull);
    });

    test('null on a one-recipe cart', () {
      expect(forRecipesLabel(1, <ItemRecipe>[ir('A')]), isNull);
      expect(forRecipesLabel(0, <ItemRecipe>[ir('A'), ir('B')]), isNull);
    });

    test('from a session', () {
      final s = _session(_multiCart());
      expect(forRecipes(s, 'onion'), 'For Tacos and Pasta');
      expect(forRecipes(s, 'basil'), isNull);
      expect(forRecipes(_session(_oldCart()), 'onion'), isNull);
    });
  });

  group('drop-in', () {
    void phone(WidgetTester tester) {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
    }

    testWidgets('the list shows the For line only on a multi-recipe cart', (WidgetTester tester) async {
      phone(tester);
      await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: MealioCartList(session: _session(_multiCart()), onAdd: () {}))));
      expect(find.text('For Tacos and Pasta'), findsOneWidget);

      await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: MealioCartList(key: const ValueKey<String>('old'), session: _session(_oldCart()), onAdd: () {}))));
      expect(find.textContaining('For '), findsNothing);
    });

    testWidgets('the flow takes recipes: "N meals" in the header, prepareCarts gets them all',
        (WidgetTester tester) async {
      phone(tester);
      final got = <List<String>>[];
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => MealioCartFlow.show(
              context,
              recipes: <Recipe>[_r('tacos', 'Tacos'), _r('pasta', 'Pasta'), _r('soup')],
              store: 'heb',
              prepareCarts: (
                  {String? store, required List<Recipe> recipes, String? zip, StepListener? onStep}) async {
                got.add(recipes.map((Recipe r) => r.id).toList());
                return _session(_multiCart());
              },
            ),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(got, <List<String>>[
        <String>['tacos', 'pasta', 'soup'],
      ]);
      expect(find.text('3 meals'), findsOneWidget);
      expect(find.text('For Tacos and Pasta'), findsOneWidget);
    });

    testWidgets('one recipe still uses prepareCart and the recipe title', (WidgetTester tester) async {
      phone(tester);
      Recipe? got;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => MealioCartFlow.show(
              context,
              recipes: <Recipe>[_r('tacos', 'Tacos')],
              store: 'heb',
              prepareCart: ({String? store, required Recipe recipe, String? zip, StepListener? onStep}) async {
                got = recipe;
                return _session(_oldCart());
              },
            ),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(got?.id, 'tacos');
      expect(find.text('Tacos'), findsOneWidget);
    });

    test('MealioCart.prepareCart fits both injection types', () {
      // Compile-time check: the default tear-off is assignable to both.
      PrepareCart one(MealioCart m) => m.prepareCart;
      PrepareCarts many(MealioCart m) => m.prepareCart;
      expect(one, isNotNull);
      expect(many, isNotNull);
    });
  });
}
