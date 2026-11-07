// The look options: money, dark mode, button variants, the custom button,
// the sheet options and the done screen.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mealio_sdk/mealio_sdk.dart';
import 'package:mealio_sdk/src/theme.dart' show MealioLook;
import 'package:mealio_sdk/src/widgets/flow_parts.dart' show DoneView, ProductThumb, SheetFrame;
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

http.Response _json(Object? body) => http.Response.bytes(utf8.encode(jsonEncode(body)), 200,
    headers: <String, String>{'content-type': 'application/json'});

const Recipe _recipe = Recipe(
  id: 'r1',
  title: 'Tacos',
  ingredients: <RecipeIngredient>[RecipeIngredient(name: 'onion')],
);

Map<String, Object?> _option(String id, String name, {String? price, double? unit, bool estimated = false}) =>
    <String, Object?>{
      'id': id,
      'name': name,
      if (price != null) 'price': price,
      if (unit != null) 'unitPrice': unit,
      'estimated': estimated,
      'imageUrl': 'https://img.example/$id.jpg',
    };

Map<String, Object?> _item(String key, List<Map<String, Object?>> options, {bool picked = true}) => <String, Object?>{
      'key': key,
      'ingredient': key,
      'quantity': 1,
      'status': picked ? 'remembered' : 'choose',
      'selectedId': picked ? options.first['id'] : null,
      'remembered': picked ? options.first : null,
      'options': options,
    };

Map<String, Object?> _cart(List<Map<String, Object?>> items) =>
    <String, Object?>{'cartId': 'c1', 'store': 'heb', 'storeName': 'H-E-B', 'items': items};

Map<String, Object?> _onionCart() => _cart(<Map<String, Object?>>[
      _item('onion', <Map<String, Object?>>[_option('o1', 'Yellow Onion', price: r'$1.25', unit: 1.25)]),
    ]);

MealioClient _client(MockClient mock) => MealioClient(
      ClientConfig(publishableKey: 'pk', getSessionToken: () async => 't', httpClient: mock, keys: testKeys),
      FakeHost(),
    );

CartSession _session({Map<String, Object?>? cart, MockClient? mock}) => CartSession(
      _client(mock ?? MockClient((http.Request req) async => _json(<String, Object?>{}))),
      PreparedCart.fromJson(cart ?? _onionCart()),
    );

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

AddResult _added({double? unitPrice = 1.25}) => AddResult(
      cartId: 'c1',
      store: 'heb',
      added: <AddedItem>[
        AddedItem(key: 'onion', productId: 'o1', name: 'Yellow Onion', quantity: 1, unitPrice: unitPrice),
      ],
      skipped: const <SkippedItem>[],
      failed: const <FailedItem>[],
      storeCartUrl: null,
    );

Widget _app(Widget child, {Map<String, String>? strings, MealioMoneyFormat? money, MealioSheetOptions? sheet}) =>
    MaterialApp(
      home: Scaffold(
        body: MealioThemeScope(strings: strings, formatMoney: money, sheet: sheet, child: child),
      ),
    );

/// A one-pixel PNG, for the logo.
final Uint8List _pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

/// A signed add-to-cart answer that adds the onion.
Future<MockClient> _addsOnion() async {
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
        'failed': <Object?>[],
      },
    },
  ]);
  return MockClient((http.Request req) async => _json(<String, Object?>{'job': 'job_test', 'envelope': done.toJson()}));
}

class _Host implements WebViewHost {
  @override
  MealioLook? look;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('money', () {
    String euro(double n) => '${n.toStringAsFixed(2).replaceAll('.', ',')} €';

    testWidgets('the default reads \$12.50 and options keep the store text', (WidgetTester tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(MealioCartList(
        session: _session(cart: _cart(<Map<String, Object?>>[
          _item('onion', <Map<String, Object?>>[_option('o1', 'Yellow Onion', price: 'Now 1.25!', unit: 1.25)]),
        ])),
        onAdd: () {},
      )));
      expect(find.textContaining('Now 1.25!'), findsWidgets);
      expect(find.text(r'$1.25'), findsOneWidget);
    });

    testWidgets('with formatMoney, totals and options come from the numbers', (WidgetTester tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(
        MealioCartList(
          session: _session(cart: _cart(<Map<String, Object?>>[
            _item('onion', <Map<String, Object?>>[
              _option('o1', 'Yellow Onion', price: 'Now 1.25!', unit: 1.25),
              _option('o2', 'Red Onion', price: r'$1.50', unit: 1.5, estimated: true),
              _option('o3', 'Odd Onion', price: 'Ask us'),
            ]),
          ])),
          onAdd: () {},
        ),
        money: euro,
      ));
      await tester.tap(find.text('Change'));
      await tester.pump();
      expect(find.text('Now 1.25!'), findsNothing);
      expect(find.text('1,25 €'), findsNWidgets(2)); // The option and the total.
      expect(find.text('1,50 € est.'), findsOneWidget);
      // No number to build from: the store's text stands.
      expect(find.text('Ask us'), findsOneWidget);
      expect(find.textContaining(r'$'), findsNothing);
    });

    testWidgets('the done screen uses it', (WidgetTester tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(
        DoneView(theme: MealioTheme.standard, session: _session(), result: _added(), storeName: 'H-E-B', onDone: () {}),
        money: euro,
      ));
      expect(find.text('1,25 €'), findsNWidgets(2));
    });
  });

  group('dark mode', () {
    test('the default dark colors match DEFAULT_DARK_THEME', () {
      const d = MealioTheme.standardDark;
      expect(d.accent, const Color(0xFF5FBF8F));
      expect(d.onAccent, const Color(0xFF0E1A14));
      expect(d.background, const Color(0xFF1B1B1A));
      expect(d.surface, const Color(0xFF2A2A28));
      expect(d.text, const Color(0xFFF2F1EE));
      expect(d.muted, const Color(0xFFB4B2AC));
      expect(d.border, const Color(0xFF3A3A37));
      expect(d.radius, 14);
      expect(d.fontFamily, isNull);
      expect(d.warnBackground, const Color(0xFF3B2A10));
      expect(d.warnText, const Color(0xFFF5C27A));
    });

    test('light is the default, dark and auto choose by scheme and phone', () {
      expect(MealioTheme.resolve(platformBrightness: Brightness.dark), MealioTheme.standard);
      expect(MealioTheme.resolve(colorScheme: MealioColorScheme.dark, platformBrightness: Brightness.light),
          MealioTheme.standardDark);
      expect(MealioTheme.resolve(colorScheme: MealioColorScheme.auto, platformBrightness: Brightness.dark),
          MealioTheme.standardDark);
      expect(MealioTheme.resolve(colorScheme: MealioColorScheme.auto, platformBrightness: Brightness.light),
          MealioTheme.standard);
    });

    test('radius and font carry over unless the dark theme sets them', () {
      const light = MealioTheme(radius: 4, fontFamily: 'Inter', accent: Color(0xFF000001));
      final carried = MealioTheme.resolve(light: light, colorScheme: MealioColorScheme.dark);
      expect(carried.radius, 4);
      expect(carried.fontFamily, 'Inter');
      expect(carried.accent, MealioTheme.standardDark.accent);

      final own = MealioTheme.resolve(
        light: light,
        dark: const MealioTheme.dark(radius: 14, fontFamily: 'Lora', accent: Color(0xFF00FF00)),
        colorScheme: MealioColorScheme.dark,
      );
      expect(own.radius, 14);
      expect(own.fontFamily, 'Lora');
      expect(own.accent, const Color(0xFF00FF00));
      expect(own.background, MealioTheme.standardDark.background);

      final copied = MealioTheme.resolve(
        light: light,
        dark: MealioTheme.standardDark.copyWith(accent: const Color(0xFF00FF00)),
        colorScheme: MealioColorScheme.dark,
      );
      expect(copied.radius, 4);
    });

    testWidgets('auto follows the phone, live, in an open sheet', (WidgetTester tester) async {
      _phone(tester);
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MealioThemeScope(
            colorScheme: MealioColorScheme.auto,
            child: Builder(
              builder: (BuildContext context) => TextButton(
                onPressed: () => MealioCartFlow.show(
                  context,
                  recipe: _recipe,
                  prepareCart: ({String? store, required Recipe recipe, String? zip, StepListener? onStep}) async =>
                      _session(),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      Color sheet() => tester
          .widget<Material>(find.descendant(of: find.byType(SheetFrame), matching: find.byType(Material)).first)
          .color!;
      expect(sheet(), MealioTheme.standard.background);

      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpAndSettle();
      expect(sheet(), MealioTheme.standardDark.background);
      expect(tester.widget<Text>(find.text('Your H-E-B list')).style!.color, MealioTheme.standardDark.text);
    });

    testWidgets('light stays light on a dark phone unless the partner opts in', (WidgetTester tester) async {
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      late BuildContext at;
      await tester.pumpWidget(_app(Builder(builder: (BuildContext c) {
        at = c;
        return const SizedBox();
      })));
      expect(MealioTheme.of(at), MealioTheme.standard);
    });

    testWidgets('a partner dark theme is used, with the MealioScope host as the fallback', (WidgetTester tester) async {
      final host = _Host()
        ..look = const MealioLook(
          theme: MealioTheme(radius: 6),
          darkTheme: MealioTheme.dark(accent: Color(0xFFFF0000)),
          colorScheme: MealioColorScheme.dark,
        );
      WebViewHost.attach(host);
      addTearDown(() => WebViewHost.detach(host));
      late BuildContext at;
      await tester.pumpWidget(MaterialApp(home: Builder(builder: (BuildContext c) {
        at = c;
        return const SizedBox();
      })));
      final t = MealioTheme.of(at);
      expect(t.accent, const Color(0xFFFF0000));
      expect(t.background, MealioTheme.standardDark.background);
      expect(t.radius, 6);
    });

    testWidgets('the search button uses onAccent, and photos keep their white', (WidgetTester tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(MealioThemeScope(
        colorScheme: MealioColorScheme.dark,
        child: MealioCartList(
          session: _session(cart: _cart(<Map<String, Object?>>[
            _item('onion', <Map<String, Object?>>[_option('o1', 'Yellow Onion', price: r'$1.25', unit: 1.25)], picked: false),
          ])),
          onAdd: () {},
        ),
      )));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.text('Search')).style!.color, MealioTheme.standardDark.onAccent);
      final white = find.descendant(
        of: find.byType(ProductThumb),
        matching: find.byWidgetPredicate((Widget w) => w is Container && w.color == const Color(0xFFFFFFFF)),
      );
      expect(white, findsWidgets);
    });
  });

  group('button variants', () {
    Material material(WidgetTester tester, Finder of) =>
        tester.widget<Material>(find.ancestor(of: of, matching: find.byType(Material)).first);

    testWidgets('solid is the default', (WidgetTester tester) async {
      await tester.pumpWidget(_app(const MealioCartButton(recipe: _recipe)));
      final text = find.text('Add to my grocery cart');
      expect(tester.getSize(find.byType(MealioCartButton)).height, greaterThanOrEqualTo(52));
      expect(material(tester, text).color, MealioTheme.standard.accent);
      expect(tester.widget<Text>(text).style!.color, MealioTheme.standard.onAccent);
    });

    testWidgets('outline is an accent ring with accent text', (WidgetTester tester) async {
      await tester.pumpWidget(_app(const MealioCartButton(recipe: _recipe, variant: MealioButtonVariant.outline)));
      final text = find.text('Add to my grocery cart');
      final m = material(tester, text);
      expect(m.color!.a, 0);
      final shape = m.shape! as RoundedRectangleBorder;
      expect(shape.side.color, MealioTheme.standard.accent);
      expect(shape.side.width, 2);
      expect(tester.widget<Text>(text).style!.color, MealioTheme.standard.accent);
    });

    testWidgets('compact uses addToCartShort and keeps its own width', (WidgetTester tester) async {
      await tester.pumpWidget(_app(const MealioCartButton(recipe: _recipe, variant: MealioButtonVariant.compact)));
      expect(find.text('Add to cart'), findsOneWidget);
      final size = tester.getSize(find.ancestor(of: find.text('Add to cart'), matching: find.byType(InkWell)));
      expect(size.height, 36);
      expect(size.width, lessThan(200));
      await tester.pumpWidget(_app(const MealioCartButton(
        recipe: _recipe,
        variant: MealioButtonVariant.compact,
        label: 'Get it',
      )));
      expect(find.text('Get it'), findsOneWidget);
    });

    testWidgets('icon is a round 48 button that speaks its label', (WidgetTester tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_app(const MealioCartButton(recipe: _recipe, variant: MealioButtonVariant.icon)));
      final icon = find.byIcon(Icons.shopping_cart);
      expect(icon, findsOneWidget);
      expect(find.text('Add to my grocery cart'), findsNothing);
      expect(tester.getSize(find.ancestor(of: icon, matching: find.byType(InkWell))), const Size(48, 48));
      expect(material(tester, icon).shape, isA<CircleBorder>());
      expect(find.bySemanticsLabel('Add to my grocery cart'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('the label comes from the table', (WidgetTester tester) async {
      await tester.pumpWidget(_app(
        const MealioCartButton(recipe: _recipe, variant: MealioButtonVariant.compact),
        strings: const <String, String>{'addToCartShort': 'Al carrito'},
      ));
      expect(find.text('Al carrito'), findsOneWidget);
    });
  });

  group('custom button', () {
    tearDown(() {
      MealioCart.configure(publishableKey: 'pk', sessionTokenProvider: () async => 't');
    });

    testWidgets('gets the label and opens the whole flow', (WidgetTester tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(MealioCartButton(
        recipe: _recipe,
        variant: MealioButtonVariant.compact,
        builder: (BuildContext context, MealioCartButtonDetails b) =>
            TextButton(onPressed: b.onPressed, child: Text('mine: ${b.label}, ${b.disabled}')),
      )));
      expect(find.text('mine: Add to cart, false'), findsOneWidget);
      await tester.tap(find.byType(TextButton));
      await tester.pumpAndSettle();
      // The sheet is up: with no scope mounted it ends at the no_scope error.
      expect(find.byType(MealioCartFlow), findsOneWidget);
    });

    testWidgets('disabled has no onPressed', (WidgetTester tester) async {
      MealioCartButtonDetails? seen;
      await tester.pumpWidget(_app(MealioCartButton(
        recipe: _recipe,
        disabled: true,
        builder: (BuildContext context, MealioCartButtonDetails b) {
          seen = b;
          return const SizedBox();
        },
      )));
      expect(seen!.disabled, isTrue);
      expect(seen!.onPressed, isNull);
    });

    testWidgets('keeps the warm-up', (WidgetTester tester) async {
      final host = _Host();
      WebViewHost.attach(host);
      addTearDown(() => WebViewHost.detach(host));
      SharedPreferences.setMockInitialValues(<String, Object>{});
      var tokens = 0;
      MealioCart.configure(
        publishableKey: 'pk',
        sessionTokenProvider: () async {
          tokens += 1;
          return 't';
        },
      );
      await tester.pumpWidget(_app(MealioCartButton(
        recipe: _recipe,
        store: 'heb',
        builder: (BuildContext context, MealioCartButtonDetails b) => const SizedBox(),
      )));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      expect(tokens, greaterThan(0));
    });
  });

  group('sheet options', () {
    Widget list(CartSession s) => MealioCartList(session: s, onAdd: () {});

    testWidgets('showTotal false hides the list total, not the option prices', (WidgetTester tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(list(_session()), sheet: const MealioSheetOptions(showTotal: false)));
      expect(find.text('Total'), findsNothing);
      expect(find.textContaining('Prices at checkout'), findsNothing);
      expect(find.text(r'$1.25 · Your usual'), findsOneWidget);
      expect(find.text('Add 1 item to H-E-B'), findsOneWidget);
    });

    testWidgets('showTotal false hides the done subtitle and row prices', (WidgetTester tester) async {
      _phone(tester);
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_app(
        DoneView(theme: MealioTheme.standard, session: _session(), result: _added(), storeName: 'H-E-B', onDone: () {}),
        sheet: const MealioSheetOptions(showTotal: false),
      ));
      expect(find.text('1 item added'), findsOneWidget);
      expect(find.textContaining(r'$'), findsNothing);
      expect(find.text('Prices at checkout'), findsNothing);
      expect(find.bySemanticsLabel('1 item added'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'\$')), findsNothing);
      handle.dispose();
    });

    testWidgets('with it on, an unpriced item means no number at all', (WidgetTester tester) async {
      _phone(tester);
      final cart = _cart(<Map<String, Object?>>[
        _item('onion', <Map<String, Object?>>[_option('o1', 'Yellow Onion', price: r'$1.25', unit: 1.25)]),
        _item('garlic', <Map<String, Object?>>[_option('g1', 'Garlic')]),
      ]);
      await tester.pumpWidget(_app(list(_session(cart: cart))));
      expect(find.text('Prices at checkout'), findsOneWidget);
      expect(find.text(r'$1.25'), findsNothing);

      await tester.pumpWidget(_app(DoneView(
        theme: MealioTheme.standard,
        session: _session(cart: _cart(<Map<String, Object?>>[
          _item('onion', <Map<String, Object?>>[_option('o1', 'Yellow Onion')]),
        ])),
        result: _added(unitPrice: null),
        storeName: 'H-E-B',
        onDone: () {},
      )));
      await tester.pump();
      expect(find.text('Prices at checkout'), findsOneWidget);
      expect(find.textContaining(r'$'), findsNothing);
    });

    testWidgets('height: auto, full, and a fraction clamped to 0.5..1', (WidgetTester tester) async {
      _phone(tester);
      Future<(double, BorderRadiusGeometry?)> sized(MealioSheetHeight h) async {
        await tester.pumpWidget(_app(
          SheetFrame(theme: MealioTheme.standard, title: 'T', onClose: () {}, child: const SizedBox()),
          sheet: MealioSheetOptions(height: h),
        ));
        final frame = find.descendant(of: find.byType(SheetFrame), matching: find.byType(Material)).first;
        return (tester.getSize(frame).height, tester.widget<Material>(frame).borderRadius);
      }

      const screen = 844.0;
      final auto = await sized(MealioSheetHeight.auto);
      expect(auto.$1, closeTo(screen * 0.94, 0.01));
      expect(auto.$2, const BorderRadius.vertical(top: Radius.circular(20)));
      final full = await sized(MealioSheetHeight.full);
      expect(full.$1, screen);
      expect(full.$2, BorderRadius.zero);
      expect((await sized(MealioSheetHeight.fraction(0.7))).$1, closeTo(screen * 0.7, 0.01));
      expect((await sized(MealioSheetHeight.fraction(0.1))).$1, closeTo(screen * 0.5, 0.01));
      final over = await sized(MealioSheetHeight.fraction(3));
      expect(over.$1, screen);
      expect(over.$2, const BorderRadius.vertical(top: Radius.circular(20)));
    });

    testWidgets('a full sheet keeps its header under the status bar', (WidgetTester tester) async {
      _phone(tester);
      tester.view.padding = const FakeViewPadding(top: 141);
      addTearDown(tester.view.resetPadding);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MealioThemeScope(
            sheet: const MealioSheetOptions(height: MealioSheetHeight.full),
            child: SheetFrame(theme: MealioTheme.standard, title: 'T', onClose: () {}, child: const SizedBox()),
          ),
        ),
      ));
      expect(tester.getTopLeft(find.text('T')).dy, greaterThanOrEqualTo(47));
    });

    testWidgets('logo sits in the header', (WidgetTester tester) async {
      await tester.pumpWidget(_app(
        SheetFrame(theme: MealioTheme.standard, title: 'T', onClose: () {}, child: const SizedBox()),
        sheet: MealioSheetOptions(logo: MemoryImage(_pixel)),
      ));
      final logo = find.byKey(const ValueKey<String>('mealio-sheet-logo'));
      expect(logo, findsOneWidget);
      expect(tester.getSize(logo), const Size(36, 36));
      expect(tester.getTopLeft(logo).dx, lessThan(tester.getTopLeft(find.text('T')).dx));
    });

    testWidgets('no logo by default', (WidgetTester tester) async {
      await tester.pumpWidget(_app(
        SheetFrame(theme: MealioTheme.standard, title: 'T', onClose: () {}, child: const SizedBox()),
      ));
      expect(find.byKey(const ValueKey<String>('mealio-sheet-logo')), findsNothing);
    });
  });

  group('done screen', () {
    testWidgets('doneMessage shows under the banner', (WidgetTester tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(DoneView(
        theme: MealioTheme.standard,
        session: _session(),
        result: _added(),
        storeName: 'H-E-B',
        onDone: () {},
        message: 'Enjoy your meal!',
      )));
      expect(find.text('Enjoy your meal!'), findsOneWidget);
      expect(tester.getTopLeft(find.text('Enjoy your meal!')).dy,
          greaterThan(tester.getTopLeft(find.text('1 item added')).dy));
    });

    testWidgets('no action: Done is the main button', (WidgetTester tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(DoneView(
          theme: MealioTheme.standard, session: _session(), result: _added(), storeName: 'H-E-B', onDone: () {})));
      expect(tester.widget<Text>(find.text('Done')).style!.color, MealioTheme.standard.onAccent);
    });

    testWidgets('the action is the main button and Done turns quiet', (WidgetTester tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(DoneView(
        theme: MealioTheme.standard,
        session: _session(),
        result: _added(),
        storeName: 'H-E-B',
        onDone: () {},
        action: MealioDoneAction(label: 'Back to meal plan', onPress: (_) {}),
      )));
      expect(tester.widget<Text>(find.text('Back to meal plan')).style!.color, MealioTheme.standard.onAccent);
      expect(tester.widget<Text>(find.text('Done')).style!.color, MealioTheme.standard.text);
      final done = find.ancestor(of: find.text('Done'), matching: find.byType(Material)).first;
      expect(tester.widget<Material>(done).color, MealioTheme.standard.surface);
      expect(tester.getTopLeft(find.text('Back to meal plan')).dy, lessThan(tester.getTopLeft(find.text('Done')).dy));
      expect(find.text('Cart by Mealio'), findsOneWidget);
    });

    testWidgets('tapping it closes the sheet, then calls onPress with the result', (WidgetTester tester) async {
      _phone(tester);
      final mock = await tester.runAsync(_addsOnion);
      final log = <String>[];
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => MealioCartFlow.show(
              context,
              recipe: _recipe,
              store: 'heb',
              doneMessage: 'Enjoy your meal!',
              prepareCart: ({String? store, required Recipe recipe, String? zip, StepListener? onStep}) async =>
                  _session(mock: mock),
              onClose: (AddResult? r) => log.add('close ${r?.added.length}'),
              doneAction: MealioDoneAction(
                label: 'Back to meal plan',
                onPress: (AddResult r) {
                  log.add('press ${r.added.length} open=${find.byType(MealioCartFlow).evaluate().isNotEmpty}');
                },
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('Add 1 item to H-E-B'));
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();
      expect(find.text('Enjoy your meal!'), findsOneWidget);
      expect(log, isEmpty);

      await tester.tap(find.byKey(const ValueKey<String>('mealio-done-action')));
      await tester.pumpAndSettle();
      expect(find.byType(MealioCartFlow), findsNothing);
      expect(log.first, 'close 1');
      expect(log.last, startsWith('press 1'));
      expect(log, hasLength(2));
    });

    testWidgets('Done alone does not call onPress', (WidgetTester tester) async {
      _phone(tester);
      var pressed = 0;
      await tester.pumpWidget(_app(DoneView(
        theme: MealioTheme.standard,
        session: _session(),
        result: _added(),
        storeName: 'H-E-B',
        onDone: () {},
        action: MealioDoneAction(label: 'Go', onPress: (_) => pressed += 1),
      )));
      await tester.tap(find.text('Done'));
      await tester.pump();
      expect(pressed, 0);
    });
  });
}
