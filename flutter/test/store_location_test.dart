// Kroger family store locations: the client calls and models, the location
// step in the cart sheet, the list's location row, and store settings.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mealio_sdk/mealio_sdk.dart';

import 'support.dart';

const StoreLocation _oak = StoreLocation(id: 'k2', name: 'Kroger Oak', address: '3 Oak St, Dallas, TX 75202', zip: '75202');
const StoreLocation _elm = StoreLocation(id: 'k3', name: 'Kroger Elm', address: '9 Elm St, Dallas, TX 75203', zip: '75203');

const List<StoreInfo> _stores = <StoreInfo>[
  StoreInfo(id: 'heb', name: 'H-E-B', via: 'device'),
  StoreInfo(id: 'kroger', name: 'Kroger', via: 'kroger_api'),
];

const Recipe _recipe = Recipe(id: 'r1', title: 'Tacos', ingredients: <RecipeIngredient>[RecipeIngredient(name: 'onion')]);

const MealioException _noLocation = MealioException(MealioErrorCode.locationRequired, 'Choose a store');

http.Response _json(Object? body, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), status, headers: <String, String>{'content-type': 'application/json'});

MealioClient _client(MockClient mock) => MealioClient(
      ClientConfig(publishableKey: 'pk', getSessionToken: () async => 't', httpClient: mock, keys: testKeys),
      FakeHost(),
    );

Map<String, Object?> _cart({StoreLocation? location}) => <String, Object?>{
      'cartId': 'c1',
      'store': 'kroger',
      'storeName': 'Kroger',
      if (location != null) 'location': location.toJson(),
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
          ],
        },
      ],
    };

CartSession _session({StoreLocation? location}) => CartSession(
      _client(MockClient((http.Request req) async => _json(<String, Object?>{}))),
      PreparedCart.fromJson(_cart(location: location)),
    );

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

/// A fake server for the sheets, recording every call.
class _Fake {
  _Fake({this.location, this.locations = const <StoreLocation>[_oak, _elm]});

  /// The saved location. Null makes prepare answer location_required.
  StoreLocation? location;
  List<StoreLocation> locations;
  final List<String?> prepared = <String?>[];
  final List<String?> zips = <String?>[];
  final List<String> looked = <String>[];
  final List<String> saved = <String>[];
  Object? lookupError;
  Object? saveError;
  Completer<void>? saveGate;

  Future<CartSession> prepare({String? store, required Recipe recipe, String? zip, StepListener? onStep}) async {
    prepared.add(store);
    zips.add(zip);
    final at = location;
    if (at == null) throw _noLocation;
    return _session(location: at);
  }

  Future<List<StoreLocation>> load(String store, String zip) async {
    looked.add('$store $zip');
    final e = lookupError;
    if (e != null) throw e;
    return locations;
  }

  Future<StorePreferences> save(String store, {String? locationId}) async {
    saved.add('$store $locationId');
    await saveGate?.future;
    final e = saveError;
    if (e != null) throw e;
    for (final StoreLocation l in locations) {
      if (l.id == locationId) location = l;
    }
    return StorePreferences(defaultStore: store, location: location);
  }
}

Future<void> _open(WidgetTester tester, _Fake f, {String? store = 'kroger', String? zip}) async {
  _phone(tester);
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (BuildContext context) => TextButton(
        onPressed: () => MealioCartFlow.show(
          context,
          recipe: _recipe,
          store: store,
          zip: zip,
          loadStores: () async => _stores,
          prepareCart: f.prepare,
          loadLocations: f.load,
          saveStore: f.save,
        ),
        child: const Text('open'),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Finder _zipBox() => find.byKey(const ValueKey<String>('mealio-zip'));

String _zipText(WidgetTester tester) => tester.widget<TextField>(_zipBox()).controller!.text;

void main() {
  group('client', () {
    /// Records each POST as path and body, and answers with `reply`.
    MealioClient recording(List<(String, Object?)> calls, http.Response Function() reply) => _client(
          MockClient((http.Request req) async {
            calls.add((req.url.path, jsonDecode(req.body)));
            return reply();
          }),
        );

    test('storeLocations posts the store and zip and reads the list', () async {
      final calls = <(String, Object?)>[];
      final c = recording(calls, () => _json(<String, Object?>{'locations': <Object?>[_oak.toJson()]}));
      final got = await c.storeLocations('kroger', '75202');
      expect(got.single.id, 'k2');
      expect(got.single.name, 'Kroger Oak');
      expect(got.single.address, '3 Oak St, Dallas, TX 75202');
      expect(got.single.zip, '75202');
      expect(calls.single.$1, '/api/v1/sdk/locations');
      expect(calls.single.$2, <String, Object?>{'store': 'kroger', 'zip': '75202'});
    });

    test('storeLocations is empty when the server sends no list', () async {
      final c = recording(<(String, Object?)>[], () => _json(<String, Object?>{}));
      expect(await c.storeLocations('kroger', '75202'), isEmpty);
    });

    test('storePreferences reads with an empty body; setStore writes, with locationId only when given', () async {
      final calls = <(String, Object?)>[];
      final c = recording(calls, () => _json(<String, Object?>{'defaultStore': 'kroger', 'location': _oak.toJson()}));
      final read = await c.storePreferences();
      expect(read.defaultStore, 'kroger');
      expect(read.location?.id, 'k2');
      await c.setStore('kroger', locationId: 'k2');
      await c.setStore('heb');
      expect(calls.map(((String, Object?) x) => x.$1).toSet(), <String>{'/api/v1/sdk/preferences'});
      expect(calls.map(((String, Object?) x) => x.$2).toList(), <Object?>[
        <String, Object?>{},
        <String, Object?>{'store': 'kroger', 'locationId': 'k2'},
        <String, Object?>{'store': 'heb'},
      ]);
    });

    test('preferences with no store are all null', () async {
      final c = recording(
        <(String, Object?)>[],
        () => _json(<String, Object?>{'defaultStore': null, 'location': null}),
      );
      final read = await c.storePreferences();
      expect(read.defaultStore, isNull);
      expect(read.location, isNull);
    });

    test('a cart with no store chosen fails with location_required', () async {
      final c = recording(
        <(String, Object?)>[],
        () => _json(<String, Object?>{
          'error': <String, Object?>{'code': 'location_required', 'message': 'Choose'},
        }, 409),
      );
      await expectLater(
        c.prepareCart(store: 'kroger', recipe: _recipe),
        throwsA(isA<MealioException>().having((MealioException e) => e.code, 'code', MealioErrorCode.locationRequired)),
      );
    });

    test('MealioCart methods fit the injection types', () {
      // Compile-time check: the default tear-offs are assignable.
      LoadLocations load(MealioCart m) => m.storeLocations;
      SaveStore save(MealioCart m) => m.setStore;
      LoadPreferences prefs(MealioCart m) => m.storePreferences;
      expect(<Object>[load, save, prefs], hasLength(3));
    });
  });

  group('models', () {
    test('a cart carries its location, and an old server omits it', () {
      final cart = PreparedCart.fromJson(_cart(location: _oak));
      expect(cart.location?.name, 'Kroger Oak');
      expect(CartSession(_client(MockClient((http.Request r) async => _json(null))), cart).location?.id, 'k2');
      expect(cart.toJson()['location'], _oak.toJson());

      final old = PreparedCart.fromJson(_cart());
      expect(old.location, isNull);
      expect(old.toJson().containsKey('location'), isFalse);
    });

    test('a location may have no zip', () {
      final l = StoreLocation.fromJson(<String, Object?>{'id': 'k', 'name': 'N', 'address': 'A', 'zip': null});
      expect(l.zip, isNull);
    });
  });

  group('location step in the cart sheet', () {
    testWidgets('a known store goes to the zip step, a prefilled zip searches, and a tap saves and restarts the cart',
        (WidgetTester tester) async {
      final f = _Fake();
      await _open(tester, f, zip: '75202');

      expect(find.text('Find your Kroger'), findsOneWidget);
      expect(find.text('Enter your zip code to see Kroger stores near you.'), findsOneWidget);
      expect(_zipText(tester), '75202');
      expect(f.looked, <String>['kroger 75202']);
      expect(find.text('Kroger Oak'), findsOneWidget);
      expect(find.text('3 Oak St, Dallas, TX 75202'), findsOneWidget);
      expect(find.text('Kroger Elm'), findsOneWidget);
      // No cart yet, so the way back is to another store.
      expect(find.text('Choose a different store'), findsOneWidget);
      expect(find.text('Back to your list'), findsNothing);

      await tester.tap(find.byKey(const ValueKey<String>('mealio-location-k2')));
      await tester.pumpAndSettle();
      expect(f.saved, <String>['kroger k2']);
      expect(f.prepared, <String?>['kroger', 'kroger']);
      expect(find.text('Your Kroger list'), findsOneWidget);
    });

    testWidgets('the drop-in never sends zip to prepareCart', (WidgetTester tester) async {
      final f = _Fake();
      await _open(tester, f, zip: '75202');
      await tester.tap(find.byKey(const ValueKey<String>('mealio-location-k2')));
      await tester.pumpAndSettle();
      expect(f.zips, <String?>[null, null]);
    });

    testWidgets('no store known: the store picker comes first, then the location step', (WidgetTester tester) async {
      final f = _Fake();
      await _open(tester, f, store: null);
      expect(find.text('Choose your store'), findsOneWidget);
      expect(find.text('Back to your list'), findsNothing);

      await tester.tap(find.text('Kroger'));
      await tester.pumpAndSettle();
      expect(f.prepared, <String?>[null, 'kroger']);
      expect(find.text('Find your Kroger'), findsOneWidget);
    });

    testWidgets('with no zip nothing searches until the user enters five digits', (WidgetTester tester) async {
      final f = _Fake();
      await _open(tester, f);
      expect(f.looked, isEmpty);
      expect(_zipText(tester), '');

      await tester.enterText(_zipBox(), '75a2');
      await tester.pump();
      expect(_zipText(tester), '752');
      await tester.tap(find.byKey(const ValueKey<String>('mealio-find-stores')), warnIfMissed: false);
      await tester.pump();
      expect(f.looked, isEmpty);

      await tester.enterText(_zipBox(), '752021234');
      await tester.pump();
      expect(_zipText(tester), '75202');
      await tester.tap(find.byKey(const ValueKey<String>('mealio-find-stores')));
      await tester.pumpAndSettle();
      expect(f.looked, <String>['kroger 75202']);
      expect(find.text('Kroger Oak'), findsOneWidget);
    });

    testWidgets('a zip that is not five digits fills the box but does not search', (WidgetTester tester) async {
      final f = _Fake();
      await _open(tester, f, zip: '7520');
      expect(_zipText(tester), '7520');
      expect(f.looked, isEmpty);
    });

    testWidgets('says so when the chain has no stores near the zip', (WidgetTester tester) async {
      final f = _Fake(locations: const <StoreLocation>[]);
      await _open(tester, f, zip: '75202');
      expect(find.text('No Kroger stores near 75202. Try another zip code.'), findsOneWidget);
    });

    testWidgets('a failed lookup and a failed save show why and stay put', (WidgetTester tester) async {
      final f = _Fake()..lookupError = StateError('no');
      await _open(tester, f, zip: '75202');
      expect(find.text('Could not look up stores. Try again.'), findsOneWidget);

      f.lookupError = null;
      f.saveError = StateError('no');
      await tester.tap(find.byKey(const ValueKey<String>('mealio-find-stores')));
      await tester.pumpAndSettle();
      expect(find.text('Could not look up stores. Try again.'), findsNothing);

      await tester.tap(find.byKey(const ValueKey<String>('mealio-location-k2')));
      await tester.pumpAndSettle();
      expect(find.text('Could not save that store. Try again.'), findsOneWidget);
      expect(find.text('Find your Kroger'), findsOneWidget);
      expect(f.prepared, <String?>['kroger']);

      f.saveError = const MealioException('nope', 'That store closed');
      await tester.tap(find.byKey(const ValueKey<String>('mealio-location-k2')));
      await tester.pumpAndSettle();
      expect(find.text('That store closed'), findsOneWidget);
    });

    testWidgets('Choose a different store opens the store picker', (WidgetTester tester) async {
      final f = _Fake();
      await _open(tester, f);
      await tester.tap(find.text('Choose a different store'));
      await tester.pumpAndSettle();
      expect(find.text('Choose your store'), findsOneWidget);
      expect(find.text('Current'), findsOneWidget);
    });

    testWidgets('the back button waits for a save, and closing during one does not restart the cart',
        (WidgetTester tester) async {
      final f = _Fake()..saveGate = Completer<void>();
      await _open(tester, f, zip: '75202');
      await tester.tap(find.byKey(const ValueKey<String>('mealio-location-k2')));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.tap(find.text('Choose a different store'), warnIfMissed: false);
      await tester.pump();
      expect(find.text('Find your Kroger'), findsOneWidget);

      await tester.tap(find.text('✕'));
      await tester.pumpAndSettle();
      f.saveGate!.complete();
      await tester.pumpAndSettle();
      expect(f.saved, <String>['kroger k2']);
      expect(f.prepared, <String?>['kroger']);
    });
  });

  group('location row on the list', () {
    testWidgets('shows the store with a Change link that opens the location step, and back returns to the same list',
        (WidgetTester tester) async {
      final f = _Fake(location: _oak);
      await _open(tester, f);

      expect(find.text('Kroger Oak, 3 Oak St, Dallas, TX 75202'), findsOneWidget);
      final link = find.bySemanticsLabel('Store location: Kroger Oak. Change location');
      expect(tester.getSemantics(link), isSemantics(label: 'Store location: Kroger Oak. Change location', isButton: true, hasTapAction: true));

      await tester.tap(link);
      await tester.pumpAndSettle();
      expect(find.text('Find your Kroger'), findsOneWidget);
      // The cart's zip fills the box and searches; its store is marked.
      expect(_zipText(tester), '75202');
      expect(f.looked, <String>['kroger 75202']);
      expect(find.text('Current'), findsOneWidget);
      expect(find.text('Back to your list'), findsOneWidget);
      expect(find.text('Choose a different store'), findsNothing);

      await tester.tap(find.text('Back to your list'));
      await tester.pumpAndSettle();
      expect(find.text('Your Kroger list'), findsOneWidget);
      expect(f.prepared, <String?>['kroger']);
    });

    testWidgets('the cart zip wins over the partner zip, and a new pick restarts the cart', (WidgetTester tester) async {
      final f = _Fake(location: _oak);
      await _open(tester, f, zip: '10001');
      await tester.tap(find.bySemanticsLabel('Store location: Kroger Oak. Change location'));
      await tester.pumpAndSettle();
      expect(_zipText(tester), '75202');

      await tester.tap(find.byKey(const ValueKey<String>('mealio-location-k3')));
      await tester.pumpAndSettle();
      expect(f.saved, <String>['kroger k3']);
      expect(f.prepared, <String?>['kroger', 'kroger']);
      expect(find.text('Kroger Elm, 9 Elm St, Dallas, TX 75203'), findsOneWidget);
    });

    testWidgets('no location, no row; no callback, no link', (WidgetTester tester) async {
      _phone(tester);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: MealioCartList(session: _session(), onAdd: () {}))));
      expect(find.byKey(const ValueKey<String>('mealio-location')), findsNothing);

      await tester.pumpWidget(MaterialApp(home: Scaffold(body: MealioCartList(session: _session(location: _oak), onAdd: () {}))));
      final row = find.byKey(const ValueKey<String>('mealio-location'));
      expect(row, findsOneWidget);
      expect(find.descendant(of: row, matching: find.text('Change')), findsNothing);
    });
  });

  group('MealioStoreSettings', () {
    Future<List<StorePreferences>> open(
      WidgetTester tester,
      _Fake f, {
      StorePreferences prefs = const StorePreferences(defaultStore: 'kroger', location: _oak),
      LoadStores? loadStores,
    }) async {
      _phone(tester);
      final changes = <StorePreferences>[];
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => MealioStoreSettings.show(
              context,
              onChange: changes.add,
              loadStores: loadStores ?? () async => _stores,
              loadPreferences: () async => prefs,
              loadLocations: f.load,
              saveStore: f.save,
            ),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return changes;
    }

    testWidgets('lists the stores with the current one and its location', (WidgetTester tester) async {
      final f = _Fake();
      await open(tester, f);
      expect(find.text('Your grocery store'), findsOneWidget);
      expect(find.text('H-E-B'), findsOneWidget);
      expect(find.text('Kroger'), findsOneWidget);
      expect(find.text('Kroger Oak, 3 Oak St, Dallas, TX 75202'), findsOneWidget);
      expect(find.text('Change'), findsOneWidget);
      expect(find.text('Current'), findsNothing);

      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text('Your grocery store'), findsNothing);
    });

    testWidgets('a device store saves at once and says Current', (WidgetTester tester) async {
      final f = _Fake();
      final changes = await open(tester, f, prefs: const StorePreferences(defaultStore: 'kroger'));
      expect(find.text('Current'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('mealio-store-heb')));
      await tester.pumpAndSettle();
      expect(f.saved, <String>['heb null']);
      expect(changes.single.defaultStore, 'heb');
      expect(find.text('Find your H-E-B'), findsNothing);
    });

    testWidgets('a Kroger family store asks which one, prefilled when it is already theirs',
        (WidgetTester tester) async {
      final f = _Fake();
      final changes = await open(tester, f);
      await tester.tap(find.byKey(const ValueKey<String>('mealio-store-kroger')));
      await tester.pumpAndSettle();
      expect(find.text('Find your Kroger'), findsOneWidget);
      expect(_zipText(tester), '75202');
      expect(find.text('Current'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey<String>('mealio-location-k3')));
      await tester.pumpAndSettle();
      expect(f.saved, <String>['kroger k3']);
      expect(changes.single.defaultStore, 'kroger');
      expect(changes.single.location?.id, 'k3');
      expect(find.text('Your grocery store'), findsOneWidget);
      expect(find.text('Kroger Elm, 9 Elm St, Dallas, TX 75203'), findsOneWidget);
    });

    testWidgets('a different chain starts with an empty box; Back to your stores returns', (WidgetTester tester) async {
      final f = _Fake();
      await open(tester, f, prefs: const StorePreferences(defaultStore: 'heb'));
      await tester.tap(find.byKey(const ValueKey<String>('mealio-store-kroger')));
      await tester.pumpAndSettle();
      expect(_zipText(tester), '');
      expect(f.looked, isEmpty);
      await tester.tap(find.text('Back to your stores'));
      await tester.pumpAndSettle();
      expect(find.text('Your grocery store'), findsOneWidget);
    });

    testWidgets('a failed load and a failed save show why', (WidgetTester tester) async {
      final f = _Fake()..saveError = StateError('no');
      await open(tester, f);
      await tester.tap(find.byKey(const ValueKey<String>('mealio-store-heb')));
      await tester.pumpAndSettle();
      expect(find.text('Could not save that store. Try again.'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await open(tester, f, loadStores: () async => throw StateError('no'));
      expect(find.text('Could not load your stores.'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
    });

    testWidgets('openStoreSettings opens the sheet with no store loaded yet', (WidgetTester tester) async {
      _phone(tester);
      MealioCart.configure(publishableKey: 'pk', sessionTokenProvider: () async => 't', baseUrl: 'https://mealio.test');
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => MealioCart.instance.openStoreSettings(context),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Your grocery store'), findsOneWidget);
    });
  });
}
