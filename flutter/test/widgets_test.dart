// The drop-in widgets against a fake prepared cart: the list's count and CTA,
// unchecking, and the flow's store picker and done screen.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mealio_sdk/mealio_sdk.dart';

import 'support.dart';

http.Response _json(Object? body, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), status, headers: <String, String>{'content-type': 'application/json'});

Map<String, Object?> _cart({String store = 'heb', String storeName = 'H-E-B'}) => <String, Object?>{
      'cartId': 'c1',
      'store': store,
      'storeName': storeName,
      'items': <Object?>[
        <String, Object?>{
          'key': 'onion',
          'ingredient': 'onion',
          'quantity': 1,
          'status': 'remembered',
          'selectedId': 'o1',
          'remembered': <String, Object?>{'id': 'o1', 'name': 'Yellow Onion'},
          'options': <Object?>[
            <String, Object?>{'id': 'o1', 'name': 'Yellow Onion', 'price': r'$1.25', 'unitPrice': 1.25},
            <String, Object?>{'id': 'o2', 'name': 'Red Onion', 'price': r'$1.50', 'unitPrice': 1.5},
          ],
        },
        <String, Object?>{
          'key': 'garlic',
          'ingredient': 'garlic',
          'quantity': 1,
          'status': 'choose',
          'selectedId': null,
          'remembered': null,
          'options': <Object?>[
            <String, Object?>{'id': 'g1', 'name': 'Garlic Bulb', 'price': r'$0.50', 'unitPrice': 0.5},
          ],
        },
        <String, Object?>{
          'key': 'beef',
          'ingredient': 'beef',
          'quantity': 1,
          'status': 'remembered_unavailable',
          'selectedId': null,
          'reason': 'out_of_stock',
          'remembered': <String, Object?>{'id': 'b0', 'name': 'Lean Beef', 'outOfStock': true},
          'options': <Object?>[
            <String, Object?>{'id': 'b1', 'name': 'Ground Beef', 'price': r'$5.99/lb', 'unitPrice': 5.99, 'estimated': true},
          ],
        },
        <String, Object?>{
          'key': 'saffron',
          'ingredient': 'saffron',
          'quantity': 1,
          'status': 'unavailable',
          'selectedId': null,
          'remembered': null,
          'options': <Object?>[],
          'reason': 'no_results',
        },
      ],
    };

MealioClient _client(MockClient mock) => MealioClient(
      ClientConfig(publishableKey: 'pk', getSessionToken: () async => 't', httpClient: mock, keys: testKeys),
      FakeHost(),
    );

CartSession _session({MockClient? mock, Map<String, Object?>? cart}) => CartSession(
      _client(mock ?? MockClient((http.Request req) async => _json(<String, Object?>{}))),
      PreparedCart.fromJson(cart ?? _cart()),
    );

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

const Recipe _recipe = Recipe(
  id: 'r1',
  title: 'Weeknight Tacos',
  ingredients: <RecipeIngredient>[
    RecipeIngredient(name: 'onion'),
    RecipeIngredient(name: 'garlic'),
    RecipeIngredient(name: 'beef'),
    RecipeIngredient(name: 'saffron'),
  ],
);

void main() {
  group('MealioCartList', () {
    testWidgets('a quantity stepper on checked rows changes the total, bounded by the store cap',
        (WidgetTester tester) async {
      _phone(tester);
      final cart = _cart();
      final onion = (cart['items']! as List<Object?>).first! as Map<String, Object?>;
      (onion['options']! as List<Object?>)[0] = <String, Object?>{
        'id': 'o1',
        'name': 'Yellow Onion',
        'price': r'$1.25',
        'unitPrice': 1.25,
        'maxQuantity': 2,
      };
      final s = _session(cart: cart);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: MealioCartList(session: s, onAdd: () {}))));

      expect(find.text('Quantity'), findsOneWidget);
      expect(find.bySemanticsLabel('Quantity 1'), findsOneWidget);
      final fewer = find.bySemanticsLabel('Less onion');
      final more = find.bySemanticsLabel('More onion');
      expect(tester.getSize(fewer).width, greaterThanOrEqualTo(44));
      expect(tester.getSize(more).width, greaterThanOrEqualTo(44));
      expect(tester.getSemantics(fewer),
          isSemantics(label: 'Less onion', isButton: true, isEnabled: false, hasTapAction: false));
      expect(tester.getSemantics(more),
          isSemantics(label: 'More onion', isButton: true, isEnabled: true, hasTapAction: true));

      await tester.tap(more);
      await tester.pump();
      expect(s.quantity('onion'), 2);
      expect(find.bySemanticsLabel('Quantity 2'), findsOneWidget);
      expect(find.text(r'$2.50'), findsOneWidget);
      expect(find.text('Add 1 item to H-E-B'), findsOneWidget);
      // At the cap: More is disabled and a tap does nothing.
      expect(tester.getSemantics(more),
          isSemantics(label: 'More onion', isButton: true, isEnabled: false, hasTapAction: false));
      await tester.tap(more);
      await tester.pump();
      expect(s.quantity('onion'), 2);

      await tester.tap(fewer);
      await tester.pump();
      expect(s.quantity('onion'), 1);
      expect(find.text(r'$1.25'), findsWidgets);

      // Unchecked rows show no stepper.
      await tester.tap(find.bySemanticsLabel('Leave out onion'));
      await tester.pump();
      expect(find.text('Quantity'), findsNothing);
    });

    testWidgets('a sold-by-weight pick steps in pounds and prices per lb', (WidgetTester tester) async {
      _phone(tester);
      final cart = _cart();
      final onion = (cart['items']! as List<Object?>).first! as Map<String, Object?>;
      final byWeight = <String, Object?>{
        'id': 'o1',
        'name': 'Yellow Onion',
        'price': r'$4.00/lb',
        'unitPrice': 4,
        'estimated': true,
        'soldByWeight': true,
        'pricePerLb': 4,
        'weightOptions': <Object?>[0.5, 0.75, 1],
      };
      (onion['options']! as List<Object?>)[0] = byWeight;
      onion['remembered'] = byWeight;
      onion['weightLb'] = 0.75;
      final s = _session(cart: cart);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: MealioCartList(session: s, onAdd: () {}))));

      expect(find.text('Weight'), findsOneWidget);
      expect(find.text('Quantity'), findsNothing);
      expect(find.text('0.75 lb'), findsOneWidget);
      expect(find.bySemanticsLabel('Weight 0.75 lb'), findsOneWidget);
      expect(find.text(r'$4.00/lb est. · Your usual'), findsOneWidget);
      expect(find.text('Estimated total'), findsOneWidget);
      expect(find.text(r'about $3.00'), findsOneWidget);

      final less = find.bySemanticsLabel('Less onion');
      final more = find.bySemanticsLabel('More onion');
      expect(tester.getSize(less), const Size(44, 44));
      expect(tester.getSize(more), const Size(44, 44));

      await tester.tap(more);
      await tester.pump();
      expect(s.weight('onion'), 1);
      expect(find.text('1 lb'), findsOneWidget);
      expect(find.text(r'about $4.00'), findsOneWidget);
      // The heaviest weight the store sells: More is disabled.
      expect(tester.getSemantics(more),
          isSemantics(label: 'More onion', isButton: true, isEnabled: false, hasTapAction: false));
      expect(s.selections().first.toJson(), <String, Object?>{
        'key': 'onion',
        'productId': 'o1',
        'quantity': 1,
        'weightLb': 1.0,
        'remember': true,
      });

      await tester.tap(less);
      await tester.pump();
      await tester.tap(less);
      await tester.pump();
      expect(find.text('0.5 lb'), findsOneWidget);
      expect(tester.getSemantics(less),
          isSemantics(label: 'Less onion', isButton: true, isEnabled: false, hasTapAction: false));
      expect(tester.getSemantics(more),
          isSemantics(label: 'More onion', isButton: true, isEnabled: true, hasTapAction: true));
    });

    testWidgets('an item whose product has preferences says "Choose one" and is held out until one is picked',
        (WidgetTester tester) async {
      _phone(tester);
      final cart = _cart();
      final garlic = (cart['items']! as List<Object?>)[1]! as Map<String, Object?>;
      garlic['options'] = <Object?>[
        <String, Object?>{
          'id': 'g1',
          'name': 'Garlic Bulb',
          'price': r'$0.50',
          'unitPrice': 0.5,
          'preferences': <Object?>[
            <String, Object?>{'id': 'whole', 'label': 'Whole'},
            <String, Object?>{'id': 'peeled', 'label': 'Peeled'},
            <String, Object?>{'id': 'none', 'label': 'No preference'},
          ],
        },
      ];
      final s = _session(cart: cart);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: MealioCartList(session: s, onAdd: () {}))));
      expect(find.textContaining('Choose one'), findsNothing);
      expect(find.textContaining('needs an option chosen'), findsNothing);

      await tester.tap(find.text('Garlic Bulb'));
      await tester.pump();
      expect(s.isSelected('garlic'), isTrue);
      expect(find.text('Choose one: Whole, Peeled or No preference'), findsOneWidget);
      final line = tester.widget<Text>(find.text('Choose one: Whole, Peeled or No preference'));
      expect(line.style!.color, MealioTheme.of(tester.element(find.byType(MealioCartList))).accent);
      expect(find.text('1 checked item needs an option chosen before adding.'), findsOneWidget);
      // Held out of the count, the total and the add.
      expect(find.text('Add 1 item to H-E-B'), findsOneWidget);
      expect(find.text(r'$1.25'), findsWidgets);
      expect(s.selections()[1].productId, isNull);

      await tester.tap(find.bySemanticsLabel('Peeled'));
      await tester.pump();
      expect(find.textContaining('Choose one'), findsNothing);
      expect(find.textContaining('needs an option chosen'), findsNothing);
      expect(find.text('Add 2 items to H-E-B'), findsOneWidget);
      expect(find.text(r'$1.75'), findsOneWidget);
      expect(s.selections()[1].preferenceId, 'peeled');
    });

    testWidgets('shows the count and CTA, and unchecking changes them', (WidgetTester tester) async {
      _phone(tester);
      final s = _session();
      var adds = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: MealioCartList(session: s, onAdd: () => adds += 1)),
      ));

      expect(find.text('1 of 3 selected'), findsOneWidget);
      expect(find.text('Add 1 item to H-E-B'), findsOneWidget);
      expect(find.text('Total'), findsOneWidget);
      expect(find.text(r'$1.25'), findsWidgets);
      expect(find.textContaining('You check out'), findsNothing);
      await tester.scrollUntilVisible(find.text('Not found at H-E-B'), 200, scrollable: find.byType(Scrollable).first);
      expect(find.text('Not found at H-E-B'), findsOneWidget);
      await tester.scrollUntilVisible(find.textContaining('Your usual picks stay saved for next time'), 200,
          scrollable: find.byType(Scrollable).first);
      expect(find.textContaining('Your usual picks stay saved for next time'), findsOneWidget);
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 2000));
      await tester.pumpAndSettle();
      // The first item needing a choice starts expanded.
      expect(find.text('Search H-E-B for something else'), findsOneWidget);
      expect(find.text('Choose a product'), findsWidgets);

      await tester.tap(find.bySemanticsLabel('Leave out onion'));
      await tester.pump();
      expect(s.isSelected('onion'), isFalse);
      expect(find.text('0 of 3 selected'), findsOneWidget);
      expect(find.text('Select items to add'), findsOneWidget);
      expect(find.text('Not adding this time'), findsOneWidget);
      final name = tester.widget<Text>(find.text('Yellow Onion'));
      expect(name.style!.decoration, TextDecoration.lineThrough);
      await tester.tap(find.text('Select items to add'));
      expect(adds, 0);

      await tester.tap(find.bySemanticsLabel('Add onion'));
      await tester.pump();
      expect(find.text('1 of 3 selected'), findsOneWidget);

      // Picking the garlic option selects it.
      await tester.tap(find.text('Garlic Bulb'));
      await tester.pump();
      expect(find.text('2 of 3 selected'), findsOneWidget);
      expect(find.text('Add 2 items to H-E-B'), findsOneWidget);
      expect(find.text(r'$1.75'), findsOneWidget);

      await tester.tap(find.text('Add 2 items to H-E-B'));
      expect(adds, 1);
    });

    testWidgets('a sold-by-weight pick makes the total an estimate', (WidgetTester tester) async {
      _phone(tester);
      final s = _session();
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: MealioCartList(session: s, onAdd: () {}))));
      expect(find.textContaining('Your usual, Lean Beef, is out of stock today'), findsOneWidget);
      s.select('beef', 'b1');
      await tester.pump();
      expect(find.text('Estimated total'), findsOneWidget);
      expect(find.text(r'about $7.24'), findsOneWidget);
      expect(find.textContaining('Your usual, Lean Beef'), findsNothing);
    });
  });

  group('MealioCartFlow', () {
    testWidgets('loads, changes store, adds, and shows the done screen', (WidgetTester tester) async {
      _phone(tester);
      final done = await tester.runAsync(() => signInstructions(<Map<String, Object?>>[
            <String, Object?>{
              'op': 'done',
              'id': 'i1',
              'result': <String, Object?>{
                'cartId': 'c1',
                'store': 'kroger',
                'added': <Object?>[
                  <String, Object?>{
                    'key': 'onion',
                    'productId': 'o1',
                    'name': 'Yellow Onion',
                    'quantity': 1,
                    'weightLb': 1.25,
                  },
                ],
                'skipped': <Object?>[
                  <String, Object?>{'key': 'garlic', 'reason': 'deselected'},
                ],
                'failed': <Object?>[
                  <String, Object?>{'key': 'beef', 'productId': 'b1', 'name': 'Ground Beef', 'reason': 'not_confirmed'},
                ],
                'storeCartUrl': 'https://www.kroger.com/cart',
                'verified': false,
              },
            },
          ]));
      final mock = MockClient((http.Request req) async => _json(<String, Object?>{'job': 'job_test', 'envelope': done!.toJson()}));
      final prepared = <String?>[];
      AddResult? closed;
      AddResult? added;

      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Center(
            child: TextButton(
              onPressed: () async {
                closed = await MealioCartFlow.show(
                  context,
                  recipe: _recipe,
                  store: 'heb',
                  onAdded: (AddResult r) => added = r,
                  loadStores: () async => const <StoreInfo>[
                    StoreInfo(id: 'heb', name: 'H-E-B', via: 'device'),
                    StoreInfo(id: 'kroger', name: 'Kroger', via: 'kroger_api'),
                  ],
                  prepareCart: ({String? store, required Recipe recipe, String? zip, StepListener? onStep}) async {
                    prepared.add(store);
                    onStep?.call(MealioStep.searching, const PageOpen(id: 'search-1', url: '', timeoutMs: 1));
                    return CartSession(
                      _client(mock),
                      PreparedCart.fromJson(store == 'kroger' ? _cart(store: 'kroger', storeName: 'Kroger') : _cart()),
                    );
                  },
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(prepared, <String?>['heb']);
      expect(find.text('Weeknight Tacos'), findsOneWidget);
      expect(find.text('Your H-E-B list'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Store: H-E-B. Change store'));
      await tester.pumpAndSettle();
      expect(find.text('Choose your store'), findsOneWidget);
      expect(find.text('Current'), findsOneWidget);
      expect(find.text('Back to your list'), findsOneWidget);

      await tester.tap(find.text('Kroger'));
      await tester.pumpAndSettle();
      expect(prepared, <String?>['heb', 'kroger']);
      expect(find.text('Your Kroger list'), findsOneWidget);

      await tester.tap(find.text('Add 1 item to Kroger'));
      await tester.pumpAndSettle();
      expect(find.text('All set'), findsOneWidget);
      expect(find.text('Added 1 item to Kroger'), findsOneWidget);
      expect(find.text('Yellow Onion, 1.25 lb'), findsOneWidget);
      expect(find.textContaining('Ground Beef (not confirmed in your cart)'), findsOneWidget);
      expect(find.text('Left out'), findsOneWidget);
      expect(find.textContaining('Check out on'), findsNothing);
      expect(find.textContaining('Open store cart'), findsNothing);
      expect(added!.verified, isFalse);

      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text('All set'), findsNothing);
      expect(closed!.added.single.key, 'onion');
    });

    testWidgets('store_required goes straight to the store picker', (WidgetTester tester) async {
      _phone(tester);
      final prepared = <String?>[];
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => MealioCartFlow.show(
              context,
              recipe: _recipe,
              loadStores: () async => const <StoreInfo>[StoreInfo(id: 'heb', name: 'H-E-B', via: 'device')],
              prepareCart: ({String? store, required Recipe recipe, String? zip, StepListener? onStep}) async {
                prepared.add(store);
                if (store == null) throw const MealioException(MealioErrorCode.storeRequired, 'Pick a store');
                return _session();
              },
            ),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Choose your store'), findsOneWidget);
      expect(find.text('Back to your list'), findsNothing);
      await tester.tap(find.text('H-E-B'));
      await tester.pumpAndSettle();
      expect(prepared, <String?>[null, 'heb']);
      expect(find.text('Add 1 item to H-E-B'), findsOneWidget);
    });

    testWidgets('an error offers Try again and Close', (WidgetTester tester) async {
      _phone(tester);
      var calls = 0;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => MealioCartFlow.show(
              context,
              recipe: _recipe,
              store: 'heb',
              prepareCart: ({String? store, required Recipe recipe, String? zip, StepListener? onStep}) async {
                calls += 1;
                throw const MealioException(MealioErrorCode.loginCancelled, 'closed');
              },
            ),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Sign-in was closed before it finished.'), findsOneWidget);
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(calls, 2);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Something went wrong'), findsNothing);
    });
  });

  testWidgets('MealioCartButton draws a themed button', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: MealioThemeScope(
          theme: MealioTheme(accent: Color(0xFF0B5FFF)),
          child: MealioCartButton(recipe: _recipe, store: 'heb'),
        ),
      ),
    ));
    expect(find.text('Add to my grocery cart'), findsOneWidget);
    final m = tester.widget<Material>(
      find.ancestor(of: find.text('Add to my grocery cart'), matching: find.byType(Material)).first,
    );
    expect(m.color, const Color(0xFF0B5FFF));
  });
}
