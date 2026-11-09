// Sheet events: a walk through the sheet checks the order and the fields, then
// the ways it can close, the throwing listener, and where onEvent is set.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mealio_sdk/mealio_sdk.dart';
import 'package:mealio_sdk/src/theme.dart' show MealioLook;
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

typedef _Json = Map<String, Object?>;

http.Response _json(Object? body) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );

_Json _cart({String store = 'heb', String storeName = 'H-E-B'}) => <String, Object?>{
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

/// Answers add-to-cart with the onion added and the saffron failed.
Future<MockClient> _adds() async {
  final done = await signInstructions(<Map<String, Object?>>[
    <String, Object?>{
      'op': 'done',
      'id': 'i1',
      'result': <String, Object?>{
        'cartId': 'c1',
        'store': 'heb',
        'added': <Object?>[
          <String, Object?>{'key': 'onion', 'productId': 'o1', 'name': 'Yellow Onion', 'quantity': 1, 'unitPrice': 1.25},
        ],
        'skipped': <Object?>[],
        'failed': <Object?>[
          <String, Object?>{'key': 'saffron', 'productId': 's1', 'name': 'Saffron', 'reason': 'not_confirmed'},
        ],
      },
    },
  ]);
  return MockClient((http.Request req) async => _json(<String, Object?>{'job': 'job_test', 'envelope': done.toJson()}));
}

/// Answers add-to-cart with a failure.
final MockClient _addFails = MockClient((http.Request req) async => throw http.ClientException('down'));

const Recipe _recipe = Recipe(
  id: 'r1',
  title: 'Weeknight Tacos',
  ingredients: <RecipeIngredient>[RecipeIngredient(name: 'onion'), RecipeIngredient(name: 'saffron')],
);

const List<StoreInfo> _stores = <StoreInfo>[
  StoreInfo(id: 'heb', name: 'H-E-B', via: 'device'),
  StoreInfo(id: 'kroger', name: 'Kroger', via: 'kroger_api'),
];

Future<CartSession> Function({String? store, required Recipe recipe, String? zip, StepListener? onStep}) _prepare({
  MockClient? mock,
  Object? Function(String? store)? fails,
  Completer<void>? gate,
  bool location = false,
}) =>
    ({String? store, required Recipe recipe, String? zip, StepListener? onStep}) async {
      await gate?.future;
      final e = fails?.call(store);
      if (e != null) throw e;
      return CartSession(
        _client(mock ?? MockClient((http.Request req) async => _json(<String, Object?>{}))),
        PreparedCart.fromJson(<String, Object?>{
          ..._cart(store: store ?? 'heb'),
          if (location) 'location': <String, Object?>{'id': 'l1', 'name': 'Kroger Main', 'address': '1 Main St', 'zip': '45202'},
        }),
      );
    };

/// A scope below the Navigator, so `show` has to carry it to the sheet, and a
/// button that opens the sheet.
Future<void> _open(
  WidgetTester tester,
  MealioEventListener? onEvent, {
  String? store = 'heb',
  MockClient? mock,
  Object? Function(String? store)? fails,
  Completer<void>? gate,
  bool location = false,
  ValueChanged<AddResult?>? onClose,
  ValueChanged<AddResult>? onAdded,
  ValueChanged<Object>? onError,
}) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  // A sheet left open would report into the next test as it is removed.
  addTearDown(() => tester.pumpWidget(const SizedBox()));
  await tester.pumpWidget(MaterialApp(
    home: MealioThemeScope(
      onEvent: onEvent,
      child: Builder(
        builder: (BuildContext context) => TextButton(
          onPressed: () => MealioCartFlow.show(
            context,
            recipe: _recipe,
            store: store,
            loadStores: () async => _stores,
            prepareCart: _prepare(mock: mock, fails: fails, gate: gate, location: location),
            loadLocations: (String store, String zip) async => const <StoreLocation>[],
            saveStore: (String store, {String? locationId}) async => StorePreferences(defaultStore: store),
            onClose: onClose,
            onAdded: onAdded,
            onError: onError,
          ),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
}

/// The sheet's own close button. The scrim has the same label.
final Finder _closeButton =
    find.descendant(of: find.byType(MealioCartFlow), matching: find.bySemanticsLabel('Close'));

/// Taps the scrim, above the sheet.
Future<void> _tapScrim(WidgetTester tester) async {
  await tester.tapAt(const Offset(195, 5));
  await tester.pump();
}

class _LoginHost implements WebViewHost {
  @override
  MealioLook? look;

  @override
  final ValueNotifier<MealioLoginView?> login = ValueNotifier<MealioLoginView?>(null);

  @override
  void flowOpened() {}

  @override
  void flowClosed() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Login implements MealioLoginView {
  int cancels = 0;

  @override
  String get title => 'Sign in to H-E-B';

  @override
  Widget get webview => const SizedBox();

  @override
  void cancel() => cancels += 1;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late List<_Json> log;
  void listen(MealioEvent e) => log.add(e.toJson());
  setUp(() => log = <_Json>[]);
  tearDown(() => MealioLook.configured = null);

  test('every event has the same type and fields as on React Native', () {
    const MealioEvent closed = MealioSheetClosed(step: MealioSheetStep.adding, added: 0);
    expect(<_Json>[
      const MealioSheetOpened(recipes: 2).toJson(),
      const MealioStorePicked(store: 'heb').toJson(),
      const MealioLocationAsked(store: 'kroger').toJson(),
      const MealioSigninShown(store: null).toJson(),
      const MealioListShown(store: 'heb', items: 4).toJson(),
      const MealioItemUnchecked(key: 'onion').toJson(),
      const MealioItemChecked(key: 'onion').toJson(),
      const MealioAddStarted(items: 3).toJson(),
      const MealioCartAdded(store: 'heb', added: 2, failed: 1).toJson(),
      const MealioErrorEvent(code: 'network', step: MealioSheetStep.loading).toJson(),
      closed.toJson(),
    ], <_Json>[
      <String, Object?>{'type': 'sheet_opened', 'recipes': 2},
      <String, Object?>{'type': 'store_picked', 'store': 'heb'},
      <String, Object?>{'type': 'location_asked', 'store': 'kroger'},
      <String, Object?>{'type': 'signin_shown', 'store': null},
      <String, Object?>{'type': 'list_shown', 'store': 'heb', 'items': 4},
      <String, Object?>{'type': 'item_unchecked', 'key': 'onion'},
      <String, Object?>{'type': 'item_checked', 'key': 'onion'},
      <String, Object?>{'type': 'add_started', 'items': 3},
      <String, Object?>{'type': 'cart_added', 'store': 'heb', 'added': 2, 'failed': 1},
      <String, Object?>{'type': 'error', 'code': 'network', 'step': 'loading'},
      <String, Object?>{'type': 'sheet_closed', 'step': 'adding', 'added': 0},
    ]);
    expect(MealioSheetStep.values.map((MealioSheetStep s) => s.name),
        <String>['loading', 'stores', 'location', 'signin', 'list', 'adding', 'done', 'error']);
    switch (closed) {
      case MealioSheetClosed(:final MealioSheetStep step):
        expect(step, MealioSheetStep.adding);
      default:
        fail('not a MealioSheetClosed');
    }
  });

  test('mealioSafeListener passes events on, and survives a throw or no listener', () {
    final got = <String>[];
    mealioSafeListener((MealioEvent e) => got.add(e.type))(const MealioSheetOpened(recipes: 1));
    expect(got, <String>['sheet_opened']);
    mealioSafeListener((MealioEvent e) => throw StateError('boom'))(const MealioSheetOpened(recipes: 1));
    mealioSafeListener(null)(const MealioSheetOpened(recipes: 1));
  });

  testWidgets('a whole walk: picks a store, unchecks, adds, closes from done', (WidgetTester tester) async {
    final mock = (await tester.runAsync(_adds))!;
    await _open(
      tester,
      listen,
      store: null,
      mock: mock,
      fails: (String? store) =>
          store == null ? const MealioException(MealioErrorCode.storeRequired, 'Pick a store') : null,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('H-E-B'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Leave out onion'));
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Add onion'));
    await tester.pump();
    await tester.tap(find.text('Add 1 item to H-E-B'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    expect(log, <_Json>[
      <String, Object?>{'type': 'sheet_opened', 'recipes': 1},
      <String, Object?>{'type': 'store_picked', 'store': 'heb'},
      <String, Object?>{'type': 'list_shown', 'store': 'heb', 'items': 2},
      <String, Object?>{'type': 'item_unchecked', 'key': 'onion'},
      <String, Object?>{'type': 'item_checked', 'key': 'onion'},
      <String, Object?>{'type': 'add_started', 'items': 1},
      <String, Object?>{'type': 'cart_added', 'store': 'heb', 'added': 1, 'failed': 1},
      <String, Object?>{'type': 'sheet_closed', 'step': 'done', 'added': 1},
    ]);
  });

  testWidgets('sheet_opened arrives after the build, so a listener may call setState', (WidgetTester tester) async {
    final thrown = <Object>[];
    late StateSetter rebuild;
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(builder: (BuildContext context, StateSetter set) {
        rebuild = set;
        return MealioThemeScope(
          onEvent: (MealioEvent e) {
            log.add(e.toJson());
            try {
              rebuild(() {});
            } catch (x) {
              thrown.add(x);
            }
          },
          child: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => MealioCartFlow.show(context, recipe: _recipe, store: 'heb', prepareCart: _prepare()),
              child: const Text('open'),
            ),
          ),
        );
      }),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(log.map((_Json e) => e['type']), <String>['sheet_opened', 'list_shown']);
    expect(thrown, isEmpty);
    await tester.tap(_closeButton);
    await tester.pumpAndSettle();
    expect(thrown, isEmpty);
  });

  group('location_asked', () {
    testWidgets('when a cart needs a location, then closing there reports location', (WidgetTester tester) async {
      await _open(
        tester,
        listen,
        store: 'kroger',
        fails: (String? store) => const MealioException(MealioErrorCode.locationRequired, 'Pick a store'),
      );
      await tester.pumpAndSettle();
      await tester.tap(_closeButton);
      await tester.pumpAndSettle();
      expect(log, <_Json>[
        <String, Object?>{'type': 'sheet_opened', 'recipes': 1},
        <String, Object?>{'type': 'location_asked', 'store': 'kroger'},
        <String, Object?>{'type': 'sheet_closed', 'step': 'location', 'added': 0},
      ]);
    });

    testWidgets('from the list, and leaving the store picker reports stores', (WidgetTester tester) async {
      await _open(tester, listen, store: 'kroger', location: true);
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Store location: Kroger Main. Change location'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Back to your list'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Store: H-E-B. Change store'));
      await tester.pumpAndSettle();
      await _tapScrim(tester);
      await tester.pumpAndSettle();
      expect(log, <_Json>[
        <String, Object?>{'type': 'sheet_opened', 'recipes': 1},
        <String, Object?>{'type': 'list_shown', 'store': 'kroger', 'items': 2},
        <String, Object?>{'type': 'location_asked', 'store': 'kroger'},
        <String, Object?>{'type': 'sheet_closed', 'step': 'stores', 'added': 0},
      ]);
    });
  });

  group('errors', () {
    testWidgets('a failed load reports step loading, and comes before onError', (WidgetTester tester) async {
      var calls = 0;
      await _open(
        tester,
        listen,
        fails: (String? store) => (calls += 1) == 1 ? const MealioException(MealioErrorCode.network, 'no') : null,
        onError: (Object e) => log.add(<String, Object?>{'type': 'onError'}),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(log, <_Json>[
        <String, Object?>{'type': 'sheet_opened', 'recipes': 1},
        <String, Object?>{'type': 'error', 'code': 'network', 'step': 'loading'},
        <String, Object?>{'type': 'onError'},
        <String, Object?>{'type': 'list_shown', 'store': 'heb', 'items': 2},
      ]);
    });

    testWidgets('a failure that is not a MealioException has the code error', (WidgetTester tester) async {
      await _open(tester, listen, fails: (String? store) => StateError('boom'));
      await tester.pumpAndSettle();
      expect(log.last, <String, Object?>{'type': 'error', 'code': 'error', 'step': 'loading'});
    });

    testWidgets('a failed add reports step adding, then closing reports step error', (WidgetTester tester) async {
      await _open(tester, listen, mock: _addFails);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add 1 item to H-E-B'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Close').last);
      await tester.pumpAndSettle();
      expect(log, <_Json>[
        <String, Object?>{'type': 'sheet_opened', 'recipes': 1},
        <String, Object?>{'type': 'list_shown', 'store': 'heb', 'items': 2},
        <String, Object?>{'type': 'add_started', 'items': 1},
        <String, Object?>{'type': 'error', 'code': 'network', 'step': 'adding'},
        <String, Object?>{'type': 'sheet_closed', 'step': 'error', 'added': 0},
      ]);
    });
  });

  group('sheet_closed', () {
    testWidgets('a scrim tap reports once, at the step left, before onClose', (WidgetTester tester) async {
      await _open(tester, listen, onClose: (AddResult? r) => log.add(<String, Object?>{'type': 'onClose'}));
      await tester.pumpAndSettle();
      await _tapScrim(tester);
      // Still sliding away: already reported.
      expect(find.byType(MealioCartFlow), findsOneWidget);
      expect(log.last['type'], 'onClose');
      await tester.pumpAndSettle();
      expect(find.byType(MealioCartFlow), findsNothing);
      expect(log, <_Json>[
        <String, Object?>{'type': 'sheet_opened', 'recipes': 1},
        <String, Object?>{'type': 'list_shown', 'store': 'heb', 'items': 2},
        <String, Object?>{'type': 'sheet_closed', 'step': 'list', 'added': 0},
        <String, Object?>{'type': 'onClose'},
      ]);
    });

    testWidgets('the back button reports the same', (WidgetTester tester) async {
      await _open(tester, listen);
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(log.last, <String, Object?>{'type': 'sheet_closed', 'step': 'list', 'added': 0});
      expect(log.where((_Json e) => e['type'] == 'sheet_closed'), hasLength(1));
    });

    testWidgets('leaving while it loads reports loading, and the late cart stays quiet', (WidgetTester tester) async {
      final gate = Completer<void>();
      await _open(tester, listen, gate: gate);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await _tapScrim(tester);
      gate.complete();
      await tester.pumpAndSettle();
      expect(log, <_Json>[
        <String, Object?>{'type': 'sheet_opened', 'recipes': 1},
        <String, Object?>{'type': 'sheet_closed', 'step': 'loading', 'added': 0},
      ]);
    });

    testWidgets('leaving from done by the scrim still counts what was added', (WidgetTester tester) async {
      final mock = (await tester.runAsync(_adds))!;
      await _open(tester, listen, mock: mock);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add 1 item to H-E-B'));
      await tester.pumpAndSettle();
      await _tapScrim(tester);
      await tester.pumpAndSettle();
      expect(log.last, <String, Object?>{'type': 'sheet_closed', 'step': 'done', 'added': 1});
    });

    testWidgets('a flow in a route of the app\'s own reports when it is removed', (WidgetTester tester) async {
      final key = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: key,
        home: MealioThemeScope(
          onEvent: listen,
          child: Scaffold(
            body: Builder(
              builder: (BuildContext context) => TextButton(
                onPressed: () => unawaited(Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (BuildContext _) => MealioThemeScope(
                    onEvent: listen,
                    child: Scaffold(
                      body: MealioCartFlow(recipe: _recipe, store: 'heb', prepareCart: _prepare(), onClose: (AddResult? r) {}),
                    ),
                  ),
                ))),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      key.currentState!.pop();
      await tester.pumpAndSettle();
      expect(log.last, <String, Object?>{'type': 'sheet_closed', 'step': 'list', 'added': 0});
      expect(log.where((_Json e) => e['type'] == 'sheet_closed'), hasLength(1));
    });
  });

  group('sign-in', () {
    late _LoginHost host;
    setUp(() {
      host = _LoginHost();
      WebViewHost.attach(host);
      addTearDown(() => WebViewHost.detach(host));
    });

    testWidgets('signin_shown when the page appears, and closing there reports signin', (WidgetTester tester) async {
      final login = _Login();
      await _open(tester, listen, gate: Completer<void>());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      host.login.value = login;
      await tester.pump();
      expect(find.text('Sign in to H-E-B'), findsOneWidget);
      // Set again: the same sign-in, not a new one.
      host.login.notifyListeners();
      await tester.pump();

      await tester.tap(_closeButton);
      await tester.pumpAndSettle();
      expect(login.cancels, 1);
      expect(log, <_Json>[
        <String, Object?>{'type': 'sheet_opened', 'recipes': 1},
        <String, Object?>{'type': 'signin_shown', 'store': 'heb'},
        <String, Object?>{'type': 'sheet_closed', 'step': 'signin', 'added': 0},
      ]);
    });

    testWidgets('with no store named, signin_shown has none, and the scrim reports signin', (WidgetTester tester) async {
      await _open(tester, listen, store: null, gate: Completer<void>());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      host.login.value = _Login();
      await tester.pump();
      await _tapScrim(tester);
      await tester.pumpAndSettle();
      expect(log, <_Json>[
        <String, Object?>{'type': 'sheet_opened', 'recipes': 1},
        <String, Object?>{'type': 'signin_shown', 'store': null},
        <String, Object?>{'type': 'sheet_closed', 'step': 'signin', 'added': 0},
      ]);
    });

    testWidgets('0.6.1: a different store from the sign-in page stops it and shows the stores', (WidgetTester tester) async {
      final login = _Login();
      await _open(tester, listen, gate: Completer<void>());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      host.login.value = login;
      await tester.pump();
      expect(find.text('Sign in to H-E-B'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('mealio-signin-different-store')));
      await tester.pump();
      await tester.pump();
      expect(login.cancels, 1);
      expect(find.text('Sign in to H-E-B'), findsNothing);
      expect(find.text('Kroger'), findsOneWidget);
      host.login.value = null;
      await tester.tap(find.text('Kroger'));
      await tester.pump();
      expect(log, <_Json>[
        <String, Object?>{'type': 'sheet_opened', 'recipes': 1},
        <String, Object?>{'type': 'signin_shown', 'store': 'heb'},
        <String, Object?>{'type': 'store_picked', 'store': 'kroger'},
      ]);
    });

    testWidgets('a sign-in already showing is reported after sheet_opened', (WidgetTester tester) async {
      host.login.value = _Login();
      await _open(tester, listen, gate: Completer<void>());
      await tester.pump();
      expect(log, <_Json>[
        <String, Object?>{'type': 'sheet_opened', 'recipes': 1},
        <String, Object?>{'type': 'signin_shown', 'store': 'heb'},
      ]);
      host.login.value = null;
    });
  });

  testWidgets('a listener that throws on every event never breaks the sheet', (WidgetTester tester) async {
    final mock = (await tester.runAsync(_adds))!;
    final seen = <String>[];
    AddResult? added;
    AddResult? closed;
    var closes = 0;
    await _open(
      tester,
      (MealioEvent e) {
        seen.add(e.type);
        throw StateError('their bug');
      },
      mock: mock,
      onAdded: (AddResult r) => added = r,
      onClose: (AddResult? r) {
        closes += 1;
        closed = r;
      },
    );
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Leave out onion'));
    await tester.pump();
    expect(find.text('Select items to add'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Add onion'));
    await tester.pump();
    await tester.tap(find.text('Add 1 item to H-E-B'));
    await tester.pumpAndSettle();
    expect(find.text('In your H-E-B cart'), findsOneWidget);
    expect(added, isNotNull);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(MealioCartFlow), findsNothing);
    expect(closes, 1);
    expect(closed!.added.single.key, 'onion');
    expect(seen, <String>[
      'sheet_opened',
      'list_shown',
      'item_unchecked',
      'item_checked',
      'add_started',
      'cart_added',
      'sheet_closed',
    ]);
  });

  group('where onEvent is set', () {
    final missed = <String>[];
    void wrong(MealioEvent e) => missed.add(e.type);
    setUp(missed.clear);

    Future<void> openPlain(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => MealioCartFlow.show(context, recipe: _recipe, store: 'heb', prepareCart: _prepare()),
            child: const Text('open'),
          ),
        ),
      ));
      addTearDown(() => tester.pumpWidget(const SizedBox()));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    void configure(MealioEventListener onEvent) {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      MealioCart.configure(publishableKey: 'pk', sessionTokenProvider: () async => 't', onEvent: onEvent);
    }

    testWidgets('configure is the last fallback', (WidgetTester tester) async {
      configure(listen);
      await openPlain(tester);
      expect(log.first['type'], 'sheet_opened');
    });

    testWidgets('MealioScope wins over configure', (WidgetTester tester) async {
      configure(wrong);
      final host = _LoginHost()..look = MealioLook(onEvent: listen);
      WebViewHost.attach(host);
      addTearDown(() => WebViewHost.detach(host));
      await openPlain(tester);
      expect(log.first['type'], 'sheet_opened');
      expect(missed, isEmpty);
    });

    testWidgets('MealioThemeScope wins over both, and only the winner hears', (WidgetTester tester) async {
      configure(wrong);
      final host = _LoginHost()..look = MealioLook(onEvent: wrong);
      WebViewHost.attach(host);
      addTearDown(() => WebViewHost.detach(host));
      await _open(tester, listen);
      await tester.pumpAndSettle();
      expect(log.first['type'], 'sheet_opened');
      expect(missed, isEmpty);
    });

    testWidgets('a scope that leaves onEvent null falls back on its own', (WidgetTester tester) async {
      configure(listen);
      await _open(tester, null);
      await tester.pumpAndSettle();
      expect(log.first['type'], 'sheet_opened');
    });

    testWidgets('a new listener does not rebuild, and is the one that hears', (WidgetTester tester) async {
      var builds = 0;
      final old = <String>[];
      Widget app(MealioEventListener onEvent, Widget child) =>
          MaterialApp(home: MealioThemeScope(onEvent: onEvent, child: child));
      final child = Builder(builder: (BuildContext context) {
        builds += 1;
        MealioTheme.of(context);
        return TextButton(onPressed: () => MealioUi.of(context).emit(const MealioAddStarted(items: 1)), child: const Text('go'));
      });
      await tester.pumpWidget(app((MealioEvent e) => old.add(e.type), child));
      await tester.pumpWidget(app(listen, child));
      expect(builds, 1);
      await tester.tap(find.text('go'));
      expect(old, isEmpty);
      expect(log.single['type'], 'add_started');
    });
  });
}
