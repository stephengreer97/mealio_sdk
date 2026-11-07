// Recipe data: servings, pantry and optional items, photos. Mirrors the
// reference change in packages/core and packages/react-native.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mealio_sdk/mealio_sdk.dart';

import 'support.dart';

const List<Object?> _option = <Object?>[
  <String, Object?>{'id': '9', 'name': 'Salt', 'price': r'$1.00', 'unitPrice': 1},
];

Map<String, Object?> _item(String key, String status, {bool? startUnchecked}) => <String, Object?>{
      'key': key,
      'ingredient': key,
      'quantity': 1,
      'status': status,
      'selectedId': status == 'remembered' ? '9' : null,
      'remembered': status == 'remembered' ? const <String, Object?>{'id': '9', 'name': 'Salt'} : null,
      'options': _option,
      if (startUnchecked != null) 'startUnchecked': startUnchecked,
    };

MealioClient _client(http.Client mock) => MealioClient(
      ClientConfig(publishableKey: 'pk', getSessionToken: () async => 't', httpClient: mock, keys: testKeys),
      FakeHost(),
    );

CartSession _session(List<Map<String, Object?>> items) => CartSession(
      _client(MockClient((http.Request req) async => http.Response('{}', 200))),
      PreparedCart.fromJson(<String, Object?>{'cartId': 'c', 'store': 'heb', 'storeName': 'H-E-B', 'items': items}),
    );

/// Answers with an error, so a test reads the body without driving a job.
MockClient _capture(List<Map<String, Object?>> bodies) => MockClient((http.Request req) async {
      bodies.add(jsonDecode(utf8.decode(req.bodyBytes)) as Map<String, Object?>);
      return http.Response(
        jsonEncode(<String, Object?>{
          'error': <String, Object?>{'code': 'store_unavailable', 'message': 'down'},
        }),
        503,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });

Future<void> _pumpList(WidgetTester tester, CartSession s) async {
  tester.view.physicalSize = const Size(400, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: MealioCartList(session: s, onAdd: () {}))));
}

void main() {
  group('the prepare body', () {
    final matcher = throwsA(isA<MealioException>());

    test('leaves the new fields out when they are not set', () async {
      final bodies = <Map<String, Object?>>[];
      await expectLater(
        _client(_capture(bodies)).prepareCart(
          store: 'heb',
          recipe: const Recipe(id: 'r', ingredients: <RecipeIngredient>[RecipeIngredient(name: 'salt')]),
        ),
        matcher,
      );
      expect(bodies.single['recipe'], <String, Object?>{
        'id': 'r',
        'ingredients': <Object?>[
          <String, Object?>{'name': 'salt'},
        ],
      });
    });

    test('carries them when set, on one recipe and on several', () async {
      const recipe = Recipe(
        id: 'r',
        servings: 4,
        makeServings: 2,
        photoUrl: 'https://x.test/a.jpg',
        ingredients: <RecipeIngredient>[
          RecipeIngredient(name: 'salt', pantry: true),
          RecipeIngredient(name: 'cilantro', optional: true),
          RecipeIngredient(name: 'onion', pantry: false, optional: false),
        ],
      );
      const wire = <String, Object?>{
        'id': 'r',
        'ingredients': <Object?>[
          <String, Object?>{'name': 'salt', 'pantry': true},
          <String, Object?>{'name': 'cilantro', 'optional': true},
          <String, Object?>{'name': 'onion', 'pantry': false, 'optional': false},
        ],
        'servings': 4,
        'makeServings': 2,
        'photoUrl': 'https://x.test/a.jpg',
      };
      final bodies = <Map<String, Object?>>[];
      final client = _client(_capture(bodies));
      await expectLater(client.prepareCart(store: 'heb', recipe: recipe), matcher);
      await expectLater(client.prepareCart(store: 'heb', recipes: <Recipe>[recipe, recipe]), matcher);
      expect(bodies[0]['recipe'], wire);
      expect(bodies[1]['recipes'], <Object?>[wire, wire]);
    });

    test('a recipe round trips through fromJson', () {
      final r = Recipe.fromJson(const <String, Object?>{
        'id': 'r',
        'ingredients': <Object?>[
          <String, Object?>{'name': 'salt', 'pantry': true, 'optional': false},
        ],
        'servings': 1.5,
        'makeServings': 3,
        'photoUrl': 'https://x.test/a.jpg',
      });
      expect(r.servings, 1.5);
      expect(r.makeServings, 3);
      expect(r.photoUrl, 'https://x.test/a.jpg');
      expect(r.ingredients.single.pantry, isTrue);
      expect(r.ingredients.single.optional, isFalse);
    });
  });

  group('CartItem.startUnchecked', () {
    test('reads true and false, and round trips', () {
      final on = CartItem.fromJson(_item('salt', 'remembered', startUnchecked: true));
      expect(on.startUnchecked, isTrue);
      expect(on.toJson()['startUnchecked'], isTrue);
      expect(CartItem.fromJson(_item('salt', 'remembered', startUnchecked: false)).startUnchecked, isFalse);
    });

    test('older servers: null, and toJson leaves it out', () {
      final old = CartItem.fromJson(_item('salt', 'remembered'));
      expect(old.startUnchecked, isNull);
      expect(old.toJson().containsKey('startUnchecked'), isFalse);
    });

    test('a value of the wrong type becomes null', () {
      final bad = CartItem.fromJson(<String, Object?>{..._item('salt', 'remembered'), 'startUnchecked': 'yes'});
      expect(bad.startUnchecked, isNull);
    });
  });

  group('CartSession', () {
    CartSession session() => _session(<Map<String, Object?>>[
          _item('salt', 'remembered', startUnchecked: true),
          _item('onion', 'remembered'),
        ]);

    test('a remembered product stays unchecked until the user checks it', () {
      final c = session();
      expect(c.isSelected('salt'), isFalse);
      expect(c.isSelected('onion'), isTrue);
      c.select('salt', '9');
      expect(c.isSelected('salt'), isTrue);
      c.deselect('salt');
      expect(c.isSelected('salt'), isFalse);
    });

    test('is left out of the estimate until then', () {
      final c = session();
      expect(c.estimate().count, 1);
      c.select('salt', '9');
      expect(c.estimate().count, 2);
    });

    test('startUnchecked: false pre-selects as usual', () {
      expect(_session(<Map<String, Object?>>[_item('salt', 'remembered', startUnchecked: false)]).isSelected('salt'), isTrue);
    });
  });

  group('the list', () {
    testWidgets('the first open item skips startUnchecked items', (WidgetTester tester) async {
      await _pumpList(
        tester,
        _session(<Map<String, Object?>>[
          _item('salt', 'choose', startUnchecked: true),
          _item('pepper', 'remembered_unavailable', startUnchecked: true),
          _item('onion', 'choose'),
        ]),
      );
      // Open rows offer "Done"; a single match means only onion is open.
      expect(find.text('Done'), findsOneWidget);
      expect(find.text('Choose'), findsNWidgets(2));
    });

    testWidgets('nothing opens when every open candidate is startUnchecked', (WidgetTester tester) async {
      await _pumpList(tester, _session(<Map<String, Object?>>[_item('salt', 'choose', startUnchecked: true)]));
      expect(find.text('Done'), findsNothing);
    });

    testWidgets('the remember note ignores startUnchecked items', (WidgetTester tester) async {
      const note = ValueKey<String>('mealio-remember-note');
      await _pumpList(
        tester,
        _session(<Map<String, Object?>>[_item('salt', 'choose', startUnchecked: true), _item('onion', 'remembered')]),
      );
      expect(find.byKey(note), findsNothing);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MealioCartList(
            key: const ValueKey<String>('second'),
            session: _session(<Map<String, Object?>>[_item('salt', 'choose', startUnchecked: true), _item('onion', 'choose')]),
            onAdd: () {},
          ),
        ),
      ));
      expect(find.byKey(note), findsOneWidget);
    });

    testWidgets('the hint shows until the item is checked, then returns', (WidgetTester tester) async {
      final s = _session(<Map<String, Object?>>[
        _item('salt', 'remembered', startUnchecked: true),
        _item('pepper', 'choose', startUnchecked: true),
        _item('onion', 'remembered'),
      ]);
      await _pumpList(tester, s);
      expect(find.text('You may already have this'), findsNWidgets(2));
      expect(find.text('Not adding this time'), findsNothing);

      s.select('salt', '9');
      await tester.pump();
      expect(find.text('You may already have this'), findsOneWidget);

      s.deselect('salt');
      await tester.pump();
      expect(find.text('You may already have this'), findsNWidgets(2));

      // A plain remembered item keeps its usual line.
      s.deselect('onion');
      await tester.pump();
      expect(find.text('Not adding this time'), findsOneWidget);
    });
  });

  group('header photos', () {
    const photos = ValueKey<String>('mealio-recipe-photos');

    Recipe recipe(String id, String? photo) => Recipe(id: id, title: id, photoUrl: photo, ingredients: const <RecipeIngredient>[]);

    Future<void> open(WidgetTester tester, List<Recipe> recipes) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => MealioCartFlow.show(
              context,
              recipes: recipes,
              store: 'heb',
              prepareCarts: ({String? store, required List<Recipe> recipes, String? zip, StepListener? onStep}) async =>
                  _session(<Map<String, Object?>>[_item('onion', 'remembered')]),
            ),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    List<String> shown(WidgetTester tester) => tester
        .widgetList<Image>(find.descendant(of: find.byKey(photos), matching: find.byType(Image)))
        .map((Image i) => (i.image as NetworkImage).url)
        .toList();

    testWidgets('shows the first 3 https photos and skips the rest', (WidgetTester tester) async {
      await open(tester, <Recipe>[
        recipe('a', 'http://x.test/plain.jpg'),
        recipe('b', 'https://x.test/1.jpg'),
        recipe('c', null),
        recipe('d', 'https://x.test/2.jpg'),
        recipe('e', 'data:image/png;base64,AA'),
        recipe('f', 'https://x.test/3.jpg'),
        recipe('g', 'https://x.test/4.jpg'),
      ]);
      expect(shown(tester), <String>['https://x.test/1.jpg', 'https://x.test/2.jpg', 'https://x.test/3.jpg']);
    });

    testWidgets('they overlap', (WidgetTester tester) async {
      await open(tester, <Recipe>[recipe('a', 'https://x.test/1.jpg'), recipe('b', 'https://x.test/2.jpg')]);
      final images = find.descendant(of: find.byKey(photos), matching: find.byType(Image));
      final first = tester.getRect(images.at(0));
      final second = tester.getRect(images.at(1));
      expect(second.left, lessThan(first.right));
      expect(second.left, greaterThan(first.left));
    });

    testWidgets('are hidden from screen readers', (WidgetTester tester) async {
      final handle = tester.ensureSemantics();
      await open(tester, <Recipe>[recipe('a', 'https://x.test/1.jpg')]);
      final box = tester.renderObject<RenderBox>(find.byKey(photos));
      expect(box, isA<RenderExcludeSemantics>());
      expect((box as RenderExcludeSemantics).excluding, isTrue);
      handle.dispose();
    });

    testWidgets('no photos, no stack', (WidgetTester tester) async {
      await open(tester, <Recipe>[recipe('a', null), recipe('b', 'http://x.test/plain.jpg')]);
      expect(find.byKey(photos), findsNothing);
    });

    testWidgets('a photo that fails to load does not break the sheet', (WidgetTester tester) async {
      await open(tester, <Recipe>[recipe('a', 'https://x.test/1.jpg')]);
      expect(tester.takeException(), isNull);
      expect(find.byKey(photos), findsOneWidget);
    });
  });
}
