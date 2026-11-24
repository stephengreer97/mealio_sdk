// A missing item needs a decision (2026-11-24). An item missing from the add
// (a usual out of stock or gone, an item never chosen, one the store does not
// have) must be picked or skipped before the drop-in adds, so nobody finds an
// ingredient missing at pickup they never chose to leave out. Mirrors
// packages/core/test/missing-decision.test.ts and the list tests in
// packages/react-native/test/flow.test.tsx.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mealio_sdk/mealio_sdk.dart';

import 'support.dart';

typedef _Json = Map<String, Object?>;

_Json _item(String key, String status, [_Json over = const <String, Object?>{}]) => <String, Object?>{
      'key': key,
      'ingredient': key,
      'quantity': 1,
      'status': status,
      'selectedId': null,
      'remembered': null,
      'options': <Object?>[
        <String, Object?>{'id': '$key-1', 'name': '$key one', 'unitPrice': 1},
      ],
      ...over,
    };

_Json _prepared({String cartId = 'c'}) => <String, Object?>{
      'cartId': cartId,
      'store': 'heb',
      'storeName': 'H-E-B',
      'items': <Object?>[
        _item('onion', 'remembered', <String, Object?>{
          'selectedId': 'onion-1',
          'remembered': <String, Object?>{'id': 'onion-1', 'name': 'onion one'},
        }),
        _item('spinach', 'remembered_unavailable', <String, Object?>{
          'remembered': <String, Object?>{'id': 'spinach-0', 'name': 'Baby spinach'},
        }),
        _item('garlic', 'choose'),
        _item('saffron', 'unavailable', <String, Object?>{'options': <Object?>[]}),
        _item('salt', 'choose', <String, Object?>{'startUnchecked': true}),
      ],
    };

CartSession _session(_Json cart) => CartSession(
      MealioClient(
        ClientConfig(
          publishableKey: 'pk',
          getSessionToken: () async => 't',
          httpClient: MockClient((http.Request req) async => http.Response.bytes(utf8.encode('{}'), 200)),
          keys: testKeys,
        ),
        FakeHost(),
      ),
      PreparedCart.fromJson(cart),
    );

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

Future<void> _pumpList(WidgetTester tester, CartSession s, {VoidCallback? onAdd, List<MealioEvent>? events}) =>
    tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MealioThemeScope(
          onEvent: events?.add,
          child: MealioCartList(session: s, onAdd: onAdd ?? () {}),
        ),
      ),
    ));

Finder _key(String k) => find.byKey(ValueKey<String>(k));

void main() {
  group('a missing item needs a decision', () {
    test('waits on every unpicked item except a remembered one and a startUnchecked one', () {
      final cs = _session(_prepared());
      expect(cs.undecided(), <String>['spinach', 'garlic', 'saffron']);
      expect(cs.needsDecision('onion'), isFalse);
      expect(cs.needsDecision('salt'), isFalse);
      expect(cs.needsDecision('nope'), isFalse);
    });

    test('deselect settles an item, and undoDeselect brings it back', () {
      final cs = _session(_prepared());
      var notes = 0;
      cs.addListener(() => notes += 1);
      cs.deselect('spinach');
      expect(notes, 1);
      expect(cs.isDeselected('spinach'), isTrue);
      expect(cs.undecided(), <String>['garlic', 'saffron']);
      cs.undoDeselect('spinach');
      expect(notes, 2);
      expect(cs.isDeselected('spinach'), isFalse);
      expect(cs.undecided(), <String>['spinach', 'garlic', 'saffron']);
    });

    test('a pick settles an item and clears a deselect', () {
      final cs = _session(_prepared());
      cs.deselect('garlic');
      cs.select('garlic', 'garlic-1');
      expect(cs.isDeselected('garlic'), isFalse);
      expect(cs.needsDecision('garlic'), isFalse);
    });

    test('unticking a pick is a decision too, and sends nothing for the item', () {
      final cs = _session(_prepared());
      cs.select('garlic', 'garlic-1');
      cs.deselect('garlic');
      expect(cs.needsDecision('garlic'), isFalse);
      expect(cs.selections().firstWhere((Selection s) => s.key == 'garlic').productId, isNull);
    });

    test('restorePicks carries a deselect over, and nothing the user did not decide', () async {
      final from = _session(_prepared());
      from.deselect('spinach');
      final to = _session(_prepared(cartId: 'c2'));
      await to.restorePicks(from);
      expect(to.isDeselected('spinach'), isTrue);
      expect(to.undecided(), <String>['garlic', 'saffron']);
    });
  });

  group('the list', () {
    _Json gateCart() => <String, Object?>{
          ..._prepared(),
          'items': <Object?>[
            (_prepared()['items']! as List<Object?>).first,
            _item('garlic', 'choose'),
          ],
        };

    testWidgets('a missing item must be picked or skipped before Add: the button reviews it instead',
        (WidgetTester tester) async {
      _phone(tester);
      final events = <MealioEvent>[];
      var adds = 0;
      final s = _session(gateCart());
      await _pumpList(tester, s, onAdd: () => adds += 1, events: events);

      expect(find.text('Review 1 item'), findsOneWidget);
      expect(find.text('1 item is not in your order yet. Pick a product or skip it.'), findsOneWidget);
      expect(_key('mealio-undecided-note'), findsOneWidget);
      await tester.tap(_key('mealio-list-cta'));
      await tester.pumpAndSettle();
      expect(adds, 0);

      await skipUndecided(tester, <String>['garlic']);
      expect(find.text('Skipped this time'), findsOneWidget);
      expect(find.text('Add 1 item to H-E-B'), findsOneWidget);
      expect(_key('mealio-undecided-note'), findsNothing);
      expect(events.whereType<MealioItemUnchecked>().map((MealioItemUnchecked e) => e.key), <String>['garlic']);

      await tester.tap(_key('mealio-undo-skip-garlic'));
      await tester.pump();
      expect(find.text('Review 1 item'), findsOneWidget);
      expect(find.text('Skipped this time'), findsNothing);

      await tester.ensureVisible(find.text('garlic one'));
      await tester.tap(find.text('garlic one'));
      await tester.pump();
      expect(find.text('Add 2 items to H-E-B'), findsOneWidget);
      await tester.tap(_key('mealio-list-cta'));
      expect(adds, 1);
    });

    testWidgets('the skip and undo buttons have labels for screen readers', (WidgetTester tester) async {
      _phone(tester);
      final handle = tester.ensureSemantics();
      final s = _session(gateCart());
      await _pumpList(tester, s);
      expect(find.bySemanticsLabel('Skip garlic this time'), findsOneWidget);
      s.deselect('garlic');
      await tester.pump();
      expect(find.bySemanticsLabel('Undo skip garlic'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('the button opens the first item waiting and scrolls to it', (WidgetTester tester) async {
      _phone(tester);
      final remembered = <Object?>[
        for (var i = 0; i < 12; i += 1)
          _item('k$i', 'remembered', <String, Object?>{
            'selectedId': 'k$i-1',
            'remembered': <String, Object?>{'id': 'k$i-1', 'name': 'k$i one'},
          }),
      ];
      final s = _session(<String, Object?>{
        ..._prepared(),
        'items': <Object?>[_item('garlic', 'choose'), ...remembered, _item('basil', 'choose')],
      });
      await _pumpList(tester, s);
      // Garlic starts open. Skipping it leaves basil, at the bottom, off screen.
      await skipUndecided(tester, <String>['garlic']);
      final cta = _key('mealio-list-cta');
      expect(find.text('Review 1 item'), findsOneWidget);
      final viewport = tester.getRect(find.byType(Scrollable).first);
      expect(viewport.contains(tester.getRect(find.text('basil')).topLeft), isFalse);

      await tester.tap(cta);
      await tester.pumpAndSettle();
      // Basil is open now (its Done, its search field) and in view.
      expect(find.text('Search H-E-B for something else'), findsOneWidget);
      final basil = tester.getRect(find.text('basil'));
      expect(viewport.contains(basil.topLeft), isTrue);
      expect(s.undecided(), <String>['basil']);
    });

    testWidgets('an out-of-stock usual offers Pick another and Skip this time', (WidgetTester tester) async {
      _phone(tester);
      final s = _session(<String, Object?>{
        ..._prepared(),
        'items': <Object?>[
          _item('spinach', 'remembered_unavailable', <String, Object?>{
            'reason': 'out_of_stock',
            'remembered': <String, Object?>{'id': 'p0', 'name': 'Baby Spinach'},
            'options': <Object?>[
              <String, Object?>{'id': 'p3', 'name': 'Spinach Bunch', 'unitPrice': 2},
            ],
          }),
        ],
      });
      await _pumpList(tester, s);
      expect(find.textContaining('Baby Spinach'), findsOneWidget);
      // The row opened first, so Pick another is not needed until it is closed.
      expect(_key('mealio-pick-another-spinach'), findsNothing);
      expect(_key('mealio-skip-spinach'), findsOneWidget);

      await tester.tap(find.text('Done'));
      await tester.pump();
      expect(find.text('Search H-E-B for something else'), findsNothing);
      await tester.tap(_key('mealio-pick-another-spinach'));
      await tester.pump();
      expect(find.text('Search H-E-B for something else'), findsOneWidget);
      expect(_key('mealio-pick-another-spinach'), findsNothing);

      await tester.tap(_key('mealio-skip-spinach'));
      await tester.pump();
      expect(find.text('Select items to add'), findsOneWidget);
      expect(find.textContaining('is out of stock today'), findsNothing);
      expect(find.text('Skipped this time'), findsOneWidget);
      expect(_key('mealio-undo-skip-spinach'), findsOneWidget);
    });

    testWidgets('an item the store does not have can be skipped and undone', (WidgetTester tester) async {
      _phone(tester);
      final s = _session(<String, Object?>{
        ..._prepared(),
        'items': <Object?>[
          (_prepared()['items']! as List<Object?>).first,
          _item('saffron', 'unavailable', <String, Object?>{'options': <Object?>[]}),
        ],
      });
      await _pumpList(tester, s);
      expect(find.text('Review 1 item'), findsOneWidget);
      await tester.tap(_key('mealio-skip-saffron'));
      await tester.pump();
      expect(find.text('Skipped this time'), findsOneWidget);
      expect(find.text('Add 1 item to H-E-B'), findsOneWidget);
      await tester.tap(_key('mealio-undo-skip-saffron'));
      await tester.pump();
      expect(find.text('Review 1 item'), findsOneWidget);
    });

    testWidgets('a remembered item unticked and a pantry item never wait', (WidgetTester tester) async {
      _phone(tester);
      final s = _session(<String, Object?>{
        ..._prepared(),
        'items': <Object?>[
          (_prepared()['items']! as List<Object?>).first,
          _item('salt', 'choose', <String, Object?>{'startUnchecked': true}),
        ],
      });
      await _pumpList(tester, s);
      await tester.tap(find.bySemanticsLabel('Leave out onion'));
      await tester.pump();
      expect(find.text('Select items to add'), findsOneWidget);
      expect(find.text('Not adding this time'), findsOneWidget);
      expect(find.text('You may already have this'), findsOneWidget);
      expect(find.text('Skipped this time'), findsNothing);
      expect(skipButtons(), findsNothing);
    });
  });

  group('items left off by default', () {
    test('lists startUnchecked items not selected, in order, and drops one once selected', () {
      final p = _prepared();
      (p['items']! as List<Object?>).add(_item('pepper', 'remembered', <String, Object?>{
        'startUnchecked': true,
        'selectedId': 'pepper-1',
        'remembered': <String, Object?>{'id': 'pepper-1', 'name': 'pepper one'},
      }));
      final cs = _session(p);
      expect(cs.uncheckedByDefault(), <String>['salt', 'pepper']);
      cs.select('pepper', 'pepper-1');
      expect(cs.uncheckedByDefault(), <String>['salt']);
    });

    testWidgets('names the items left off by default above Add, and Add them checks the ones with a usual',
        (WidgetTester tester) async {
      _phone(tester);
      final handle = tester.ensureSemantics();
      final events = <MealioEvent>[];
      final s = _session(<String, Object?>{
        ..._prepared(),
        'items': <Object?>[
          (_prepared()['items']! as List<Object?>).first,
          _item('salt', 'remembered', <String, Object?>{
            'startUnchecked': true,
            'selectedId': 'salt-1',
            'remembered': <String, Object?>{'id': 'salt-1', 'name': 'salt one'},
          }),
          _item('olive oil', 'choose', <String, Object?>{'startUnchecked': true}),
        ],
      });
      await _pumpList(tester, s, events: events);
      expect(find.text('Not adding: salt, olive oil.'), findsOneWidget);
      expect(find.bySemanticsLabel('Add salt, olive oil'), findsOneWidget);

      await tester.tap(_key('mealio-off-add'));
      await tester.pump();
      expect(events.whereType<MealioItemChecked>().map((MealioItemChecked e) => e.key), <String>['salt']);
      // Olive oil has no usual, so it is still named until the user picks one.
      expect(find.text('Not adding: olive oil.'), findsOneWidget);
      expect(_key('mealio-off-add'), findsNothing);
      expect(find.text('Add 2 items to H-E-B'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('says nothing above Add when nothing is left off by default', (WidgetTester tester) async {
      _phone(tester);
      final s = _session(<String, Object?>{
        ..._prepared(),
        'items': <Object?>[(_prepared()['items']! as List<Object?>).first],
      });
      await _pumpList(tester, s);
      expect(_key('mealio-off-line'), findsNothing);
    });
  });
}
