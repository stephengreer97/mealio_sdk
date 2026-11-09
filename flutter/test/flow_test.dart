// 0.6 in the drop-in: adding cannot be closed, a failed add keeps the picks,
// Add waits for a search, the store prop reaches Try again, and users.
// Mirrors packages/react-native/test/flow.test.tsx.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mealio_sdk/mealio_sdk.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

typedef _Json = Map<String, Object?>;

http.Response _json(Object? body, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), status, headers: <String, String>{'content-type': 'application/json'});

_Json _cart() => <String, Object?>{
      'cartId': 'c1',
      'store': 'heb',
      'storeName': 'H-E-B',
      'items': <Object?>[
        <String, Object?>{
          'key': 'onion',
          'ingredient': 'onion',
          'quantity': 1,
          'status': 'remembered',
          'selectedId': 'o1',
          'remembered': <String, Object?>{'id': 'o1', 'name': 'Yellow Onion'},
          'options': <Object?>[
            <String, Object?>{'id': 'o1', 'name': 'Yellow Onion', 'unitPrice': 1.25},
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
            <String, Object?>{'id': 'g1', 'name': 'Garlic Bulb', 'unitPrice': 0.5},
          ],
        },
      ],
    };

const _Json _added = <String, Object?>{
  'cartId': 'c1',
  'store': 'heb',
  'added': <Object?>[
    <String, Object?>{'key': 'onion', 'productId': 'o1', 'name': 'Yellow Onion', 'quantity': 1, 'unitPrice': 1.25},
  ],
  'skipped': <Object?>[],
  'failed': <Object?>[],
};

const Recipe _recipe = Recipe(id: 'r1', title: 'Tacos', ingredients: <RecipeIngredient>[RecipeIngredient(name: 'onion')]);

/// A fake Mealio server: `/add` and `/search` wait for their gate when one is
/// set, and `/add` fails when `addFails`.
class _Server {
  Completer<void>? addGate;
  Completer<void>? searchGate;
  bool addFails = false;
  final List<String> paths = <String>[];

  late final MockClient mock = MockClient((http.Request r) async {
    paths.add(r.url.path);
    if (r.url.path.endsWith('/add')) {
      await addGate?.future;
      if (addFails) throw http.ClientException('offline');
      return _start(<String, Object?>{'op': 'done', 'id': 'd', 'result': _added});
    }
    if (r.url.path.endsWith('/search')) {
      await searchGate?.future;
      return _start(<String, Object?>{
        'op': 'done',
        'id': 'd',
        'result': <String, Object?>{'key': 'onion', 'query': 'red onion', 'options': <Object?>[]},
      });
    }
    return _json(<String, Object?>{});
  });

  Future<http.Response> _start(_Json ins) async =>
      _json(<String, Object?>{'job': 'job_test', 'envelope': (await signInstructions(<_Json>[ins])).toJson()});

  late final MealioClient client = MealioClient(
    ClientConfig(publishableKey: 'pk', getSessionToken: () async => 't', httpClient: mock, keys: testKeys),
    FakeHost(),
  );

  int prepares = 0;
  final List<String?> stores = <String?>[];

  Future<CartSession> prepare({String? store, required List<Recipe> recipes, String? zip, StepListener? onStep}) async {
    prepares += 1;
    stores.add(store);
    return CartSession(client, PreparedCart.fromJson(_cart()));
  }
}

final Finder _closeButton = find.descendant(of: find.byType(MealioCartFlow), matching: find.bySemanticsLabel('Close'));

Future<void> _open(
  WidgetTester tester,
  _Server srv, {
  List<MealioEvent>? events,
  ValueChanged<AddResult?>? onClose,
  ValueChanged<AddResult>? onAdded,
  PrepareCarts? prepare,
}) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  addTearDown(() => tester.pumpWidget(const SizedBox()));
  await tester.pumpWidget(MaterialApp(
    home: MealioThemeScope(
      onEvent: events?.add,
      child: Builder(
        builder: (BuildContext context) => TextButton(
          onPressed: () => MealioCartFlow.show(
            context,
            recipe: _recipe,
            store: 'heb',
            loadStores: () async => const <StoreInfo>[StoreInfo(id: 'heb', name: 'H-E-B', via: 'device')],
            prepareCarts: prepare ?? srv.prepare,
            onClose: onClose,
            onAdded: onAdded,
          ),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  group('adding', () {
    testWidgets('cannot be closed once tapped, and reports the add when it ends', (WidgetTester tester) async {
      final srv = _Server()..addGate = Completer<void>();
      final closes = <AddResult?>[];
      final addeds = <AddResult>[];
      final events = <MealioEvent>[];
      await _open(tester, srv, events: events, onClose: closes.add, onAdded: addeds.add);
      await tester.tap(find.text('Add 1 item to H-E-B'));
      await tester.pump();
      // The X, the back button and the scrim all leave it open.
      await tester.tap(_closeButton);
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.tapAt(const Offset(195, 5));
      // Not pumpAndSettle: the spinner never settles while the add runs.
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(MealioCartFlow), findsOneWidget);
      expect(closes, isEmpty);
      srv.addGate!.complete();
      await tester.pumpAndSettle();
      expect(addeds, hasLength(1));
      expect(events.whereType<MealioCartAdded>(), hasLength(1));
      // Closing works again once the add has ended.
      await tester.tap(_closeButton);
      await tester.pumpAndSettle();
      expect(find.byType(MealioCartFlow), findsNothing);
    });

    testWidgets('two taps before a render add once', (WidgetTester tester) async {
      final srv = _Server()..addGate = Completer<void>();
      final events = <MealioEvent>[];
      await _open(tester, srv, events: events);
      final add = find.text('Add 1 item to H-E-B');
      await tester.tap(add);
      await tester.tap(add, warnIfMissed: false);
      srv.addGate!.complete();
      await tester.pumpAndSettle();
      expect(srv.paths.where((String p) => p.endsWith('/add')), hasLength(1));
      expect(events.whereType<MealioAddStarted>(), hasLength(1));
    });

    testWidgets('a failed add says to check the cart, and Try again keeps the picks', (WidgetTester tester) async {
      final srv = _Server()..addFails = true;
      await _open(tester, srv);
      await tester.tap(find.text('Garlic Bulb'));
      await tester.pump();
      expect(find.text('2 of 2 selected'), findsOneWidget);
      await tester.tap(find.text('Add 2 items to H-E-B'));
      await tester.pumpAndSettle();
      expect(find.text('Some items may already be in your cart. Check it before adding again.'), findsOneWidget);
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(srv.prepares, 2);
      expect(find.text('2 of 2 selected'), findsOneWidget);
    });
  });

  group('the list', () {
    testWidgets('Add is off while a search runs', (WidgetTester tester) async {
      final srv = _Server()..searchGate = Completer<void>();
      final events = <MealioEvent>[];
      await _open(tester, srv, events: events);
      // The garlic row is open; search for something else there.
      await tester.enterText(find.byType(TextField).first, 'red onion');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      await tester.tap(find.text('Add 1 item to H-E-B'), warnIfMissed: false);
      await tester.pump();
      expect(events.whereType<MealioAddStarted>(), isEmpty);
      srv.searchGate!.complete();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add 1 item to H-E-B'));
      await tester.pumpAndSettle();
      expect(events.whereType<MealioAddStarted>(), hasLength(1));
    });

    testWidgets('ticking an item by tapping an option sends item_checked', (WidgetTester tester) async {
      final srv = _Server();
      final events = <MealioEvent>[];
      await _open(tester, srv, events: events);
      await tester.tap(find.text('Garlic Bulb'));
      await tester.pump();
      expect(events.whereType<MealioItemChecked>().map((MealioItemChecked e) => e.key), <String>['garlic']);
    });

    testWidgets('a store list that failed to load is asked for again', (WidgetTester tester) async {
      var calls = 0;
      var up = false;
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final srv = _Server();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MealioCartFlow(
            recipe: _recipe,
            store: 'heb',
            onClose: (_) {},
            prepareCarts: srv.prepare,
            loadStores: () async {
              calls += 1;
              if (!up) throw const MealioException('server', 'down');
              return const <StoreInfo>[StoreInfo(id: 'heb', name: 'H-E-B', via: 'device')];
            },
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Store: H-E-B. Change store'));
      await tester.pumpAndSettle();
      expect(find.text('Could not load stores. Close and try again.'), findsOneWidget);
      up = true;
      await tester.tap(find.text('Back to your list'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Store: H-E-B. Change store'));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.text('Could not load stores. Close and try again.'), findsNothing);
    });
  });

  group('the store prop', () {
    testWidgets('Try again uses the store the partner passes now', (WidgetTester tester) async {
      final stores = <String?>[];
      late StateSetter set;
      var store = 'heb';
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(builder: (BuildContext context, StateSetter s) {
            set = s;
            return MealioCartFlow(
              recipe: _recipe,
              store: store,
              onClose: (_) {},
              prepareCarts: ({String? store, required List<Recipe> recipes, String? zip, StepListener? onStep}) async {
                stores.add(store);
                throw const MealioException('store_unavailable', 'Down');
              },
            );
          }),
        ),
      ));
      await tester.pumpAndSettle();
      set(() => store = 'aldi');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(stores, <String?>['heb', 'aldi']);
    });
  });

  group('users', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));
    tearDown(() => MealioCart.configure(publishableKey: 'pk', sessionTokenProvider: () async => 't'));

    testWidgets('with nobody signed in, the button asks for sign-in, or is off without a callback', (WidgetTester tester) async {
      var asked = 0;
      MealioCart.configure(publishableKey: 'pk', sessionTokenProvider: () async => 't').setUser(null);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(children: <Widget>[
            MealioCartButton(recipe: _recipe, label: 'with', onSignInRequired: () => asked += 1),
            const MealioCartButton(recipe: _recipe, label: 'without'),
          ]),
        ),
      ));
      await tester.tap(find.text('with'));
      await tester.pumpAndSettle();
      expect(asked, 1);
      expect(find.byType(MealioCartFlow), findsNothing);
      final without = tester.widget<InkWell>(find.ancestor(of: find.text('without'), matching: find.byType(InkWell)));
      expect(without.onTap, isNull);
      // A user signs in: both buttons open the sheet again.
      MealioCart.instance.setUser('u1');
      await tester.pump();
      final now = tester.widget<InkWell>(find.ancestor(of: find.text('without'), matching: find.byType(InkWell)));
      expect(now.onTap, isNotNull);
    });

    testWidgets('a new user stops the open cart', (WidgetTester tester) async {
      MealioCart.configure(publishableKey: 'pk', sessionTokenProvider: () async => 't').setUser('a');
      final gate = Completer<void>();
      final srv = _Server();
      final closes = <AddResult?>[];
      Future<CartSession> slow({String? store, required List<Recipe> recipes, String? zip, StepListener? onStep}) async {
        await gate.future;
        return srv.prepare(store: store, recipes: recipes);
      }

      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => MealioCartFlow.show(context, recipe: _recipe, prepareCarts: slow, onClose: closes.add),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(MealioCartFlow), findsOneWidget);
      MealioCart.instance.setUser('b');
      await tester.pumpAndSettle();
      expect(find.byType(MealioCartFlow), findsNothing);
      expect(closes, <AddResult?>[null]);
      gate.complete();
      await tester.pumpAndSettle();
    });
  });
}
