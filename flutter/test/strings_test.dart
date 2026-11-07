// The strings table: it matches protocol/strings.json exactly, placeholders
// and plurals fill in, and a partner's override reaches the widgets.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mealio_sdk/mealio_sdk.dart';

import 'support.dart';

CartSession _session() => CartSession(
      MealioClient(
        ClientConfig(
          publishableKey: 'pk',
          getSessionToken: () async => 't',
          httpClient: MockClient((http.Request req) async => http.Response('{}', 200)),
          keys: testKeys,
        ),
        FakeHost(),
      ),
      PreparedCart.fromJson(const <String, Object?>{
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
      }),
    );

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

/// Every key replaced, so a default still on screen was never translated.
final Map<String, String> _everyKey = <String, String>{
  for (final String key in mealioDefaultStrings.keys) key: '<$key>',
};

/// Every Text and every accessibility label and hint on screen.
List<String> _words(WidgetTester tester) {
  final out = <String>[];
  for (final Text t in tester.widgetList<Text>(find.byType(Text))) {
    if (t.data != null) out.add(t.data!);
  }
  void walk(SemanticsNode n) {
    out
      ..add(n.label)
      ..add(n.hint);
    n.visitChildren((SemanticsNode c) {
      walk(c);
      return true;
    });
  }

  walk(tester.getSemantics(find.byType(Scaffold)).owner!.rootSemanticsNode!);
  return out;
}

void _expectNoDefaults(WidgetTester tester) {
  final words = _words(tester);
  for (final String text in mealioDefaultStrings.values.where((String v) => !v.contains('{'))) {
    expect(words, isNot(contains(text)));
  }
}

void main() {
  group('table', () {
    test('equals protocol/strings.json exactly', () {
      final source = jsonDecode(File('../protocol/strings.json').readAsStringSync()) as Map<String, Object?>;
      expect(source.length, greaterThan(90));
      expect(mealioDefaultStrings.keys.toList(), source.keys.toList());
      expect(mealioDefaultStrings, source);
    });

    test('fills placeholders; an unknown one stays visible', () {
      expect(mealioFillText('Your {store} list', <String, Object?>{'store': 'H-E-B'}), 'Your H-E-B list');
      expect(mealioFillText('{count} of {total}', <String, Object?>{'count': 2, 'total': 5}), '2 of 5');
      expect(mealioFillText('Your {stroe} list', <String, Object?>{'store': 'H-E-B'}), 'Your {stroe} list');
      expect(const MealioUi().tr('titleList'), 'Your {store} list');
    });

    test('plurals pick _one or _other and fill count', () {
      const ui = MealioUi();
      expect(ui.plural('options', 1), '1 option');
      expect(ui.plural('options', 0), '0 options');
      expect(ui.plural('addItems', 1, <String, Object?>{'store': 'H-E-B'}), 'Add 1 item to H-E-B');
      expect(ui.plural('addItems', 3, <String, Object?>{'store': 'H-E-B'}), 'Add 3 items to H-E-B');
    });

    test('an override wins and keeps its placeholders; other keys stay', () {
      const ui = MealioUi(strings: <String, String>{'titleList': 'Lista de {store}'});
      expect(ui.tr('titleList', <String, Object?>{'store': 'H-E-B'}), 'Lista de H-E-B');
      expect(ui.tr('done'), 'Done');
    });

    test('lists use the table words', () {
      const ui = MealioUi(strings: <String, String>{'and': 'y', 'forRecipes': 'Para {recipes}'});
      final session = _session();
      expect(forRecipes(session, 'onion', ui), isNull);
      ItemRecipe ir(String t) => ItemRecipe(id: t, title: t, quantity: 1);
      expect(forRecipesLabel(2, <ItemRecipe>[ir('Tacos'), ir('Pasta')], ui), 'Para Tacos y Pasta');
    });
  });

  group('overrides reach widgets', () {
    testWidgets('a word and an accessibility label on the list', (WidgetTester tester) async {
      _phone(tester);
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MealioThemeScope(
            strings: const <String, String>{
              'addItems_one': 'Añadir {count} a {store}',
              'a11yLeaveOut': 'Quitar {item}',
            },
            child: MealioCartList(session: _session(), onAdd: () {}),
          ),
        ),
      ));
      expect(find.text('Añadir 1 a H-E-B'), findsOneWidget);
      expect(find.bySemanticsLabel('Quitar onion'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('MealioCart.configure sets them too, and MealioThemeScope wins', (WidgetTester tester) async {
      _phone(tester);
      MealioCart.configure(
        publishableKey: 'pk',
        sessionTokenProvider: () async => 't',
        strings: const <String, String>{'selectItems': 'From configure', 'total': 'Suma'},
      );
      addTearDown(() => MealioCart.configure(publishableKey: 'pk', sessionTokenProvider: () async => 't'));
      final session = _session()..deselect('onion');
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: MealioCartList(session: session, onAdd: () {}))));
      expect(find.text('From configure'), findsOneWidget);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MealioThemeScope(
            strings: const <String, String>{'selectItems': 'From scope'},
            child: MealioCartList(session: session, onAdd: () {}),
          ),
        ),
      ));
      expect(find.text('From scope'), findsOneWidget);
    });

    testWidgets('a local scope follows the sheet onto the root navigator', (WidgetTester tester) async {
      _phone(tester);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MealioThemeScope(
            strings: const <String, String>{'titleSettings': 'Mi tienda'},
            child: Builder(
              builder: (BuildContext context) => TextButton(
                onPressed: () => MealioStoreSettings.show(
                  context,
                  loadStores: () async => const <StoreInfo>[],
                  loadPreferences: () async => const StorePreferences(),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Mi tienda'), findsOneWidget);
    });

    testWidgets('no default word is left on the list, the location picker or store settings',
        (WidgetTester tester) async {
      _phone(tester);
      final handle = tester.ensureSemantics();
      final session = _session();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MealioThemeScope(strings: _everyKey, child: MealioCartList(session: session, onAdd: () {}, onChangeStore: () {})),
        ),
      ));
      expect(find.text('<change>'), findsWidgets);
      _expectNoDefaults(tester);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MealioThemeScope(
            strings: _everyKey,
            child: MealioStoreSettings(
              onClose: () {},
              loadStores: () async => const <StoreInfo>[
                StoreInfo(id: 'heb', name: 'H-E-B', via: 'device'),
                StoreInfo(id: 'kroger', name: 'Kroger', via: 'kroger_api'),
              ],
              loadPreferences: () async => const StorePreferences(defaultStore: 'heb'),
              loadLocations: (String store, String zip) async => const <StoreLocation>[],
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('<titleSettings>'), findsOneWidget);
      expect(find.text('<current>'), findsOneWidget);
      expect(find.text('<done>'), findsOneWidget);
      expect(find.bySemanticsLabel('<close>'), findsOneWidget);
      _expectNoDefaults(tester);

      await tester.tap(find.text('Kroger'));
      await tester.pumpAndSettle();
      expect(find.text('<titleLocation>'), findsOneWidget);
      expect(find.text('<zipPrompt>'), findsOneWidget);
      expect(find.text('<findStores>'), findsOneWidget);
      expect(find.text('<backToStores>'), findsOneWidget);
      _expectNoDefaults(tester);

      await tester.enterText(find.byType(TextField), '78701');
      await tester.pump();
      await tester.tap(find.text('<findStores>'));
      await tester.pumpAndSettle();
      expect(find.text('<noStoresNear>'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('store settings falls back to table text for a failed load', (WidgetTester tester) async {
      _phone(tester);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MealioThemeScope(
            strings: const <String, String>{'couldNotLoadYourStores': 'No se pudo'},
            child: MealioStoreSettings(
              onClose: () {},
              loadStores: () async => throw StateError('down'),
              loadPreferences: () async => const StorePreferences(),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('No se pudo'), findsOneWidget);
    });
  });
}
