// 0.6 round 4: a cancel aborts the HTTP request at once, runExclusive's
// cancel fires at 30 seconds, restorePicks re-runs the search that found the
// picked product and never throws (an outside cancel still restarts the
// sheet), held fake requests never time out, and the core version.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mealio_sdk/mealio_sdk.dart';
import 'package:mealio_sdk/testing.dart';

const Recipe _recipe = Recipe(id: 'r', title: 'Tacos', ingredients: <RecipeIngredient>[RecipeIngredient(name: 'onion')]);

MealioFakeScript _script() => MealioFakeScript(
      items: <MealioFakeItem>[
        const MealioFakeItem(key: 'onion', options: <Product>[Product(id: 'o1', name: 'Yellow Onion', unitPrice: 1)], remembered: 'o1'),
      ],
      search: <String, List<Product>>{
        'red onion': const <Product>[Product(id: 'o9', name: 'Red Onion', unitPrice: 2)],
        'white onion': const <Product>[Product(id: 'o7', name: 'White Onion', unitPrice: 2)],
      },
    );

TypeMatcher<MealioException> _code(String code) => isA<MealioException>().having((MealioException e) => e.code, 'code', code);

Future<void> _frames(WidgetTester tester, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  group('a cancelled job aborts its HTTP request at once (item 5)', () {
    test('the prepare settles with cancelled while its request is still held, and the next job runs', () async {
      final fake = MealioFake(_script());
      final client = fake.client();
      final release = fake.hold('prepare');
      final cancel = CancelToken();
      Object? err;
      var settled = false;
      unawaited(client.prepareCart(recipe: _recipe, cancel: cancel).then((_) => settled = true, onError: (Object e) {
        settled = true;
        err = e;
      }));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(fake.requests.map((MealioFakeRequest r) => r.kind), <String>['prepare']);
      cancel.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(settled, isTrue);
      expect(err, _code(MealioErrorCode.cancelled));

      final next = await client.prepareCart(recipe: _recipe);
      expect(next.selectedId('onion'), 'o1');
      release();
    });
  });

  group('runExclusive (item 5)', () {
    testWidgets('its cancel token fires at 30 seconds, with the network error', (WidgetTester tester) async {
      final client = MealioFake(_script()).client();
      CancelToken? given;
      Object? err;
      final hold = Completer<void>();
      unawaited(client.runExclusive((CancelToken c) {
        given = c;
        return hold.future;
      }).then((_) {}, onError: (Object e) => err = e));
      await tester.pump(const Duration(seconds: 29));
      expect(given!.cancelled, isFalse);
      await tester.pump(const Duration(seconds: 2));
      expect(err, _code(MealioErrorCode.network));
      expect(given!.cancelled, isTrue);
      hold.complete();
      await tester.pump(const Duration(seconds: 31));
    });
  });

  group('restorePicks (item 4)', () {
    test('re-runs the search that found the picked product, not the last search', () async {
      final fake = MealioFake(_script());
      final client = fake.client();
      final a = await client.prepareCart(recipe: _recipe);
      await a.search('onion', 'red onion');
      await a.search('onion', 'white onion');
      a.select('onion', 'o9');
      a.setQuantity('onion', 4);

      final b = await client.prepareCart(recipe: _recipe);
      await b.restorePicks(a);
      expect(fake.requests.last.body?['query'], 'red onion');
      expect(b.selectedId('onion'), 'o9');
      expect(b.quantity('onion'), 4);
    });

    test('never throws: a cancel ends it with what it restored so far', () async {
      final fake = MealioFake(_script());
      final client = fake.client();
      final a = await client.prepareCart(recipe: _recipe);
      await a.search('onion', 'red onion');
      a.select('onion', 'o9');
      final b = await client.prepareCart(recipe: _recipe);
      final cancel = CancelToken();
      final release = fake.hold('search');
      final f = b.restorePicks(a, cancel: cancel);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      cancel.cancel();
      await expectLater(f, completes);
      expect(b.selectedId('onion'), 'o1');
      release();
    });

    testWidgets('an outside cancel during the restore still starts the sheet again', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      installMealioTestPlatform();
      final fake = MealioFake(MealioFakeScript(
        items: <MealioFakeItem>[
          const MealioFakeItem(key: 'onion', options: <Product>[Product(id: 'o1', name: 'Yellow Onion', unitPrice: 1)]),
        ],
        search: <String, List<Product>>{
          'red onion': const <Product>[Product(id: 'o9', name: 'Red Onion', unitPrice: 2)],
        },
        addFailure: const MealioFakeError('store_unavailable'),
      ));
      configureMealioForTesting(fake: fake);
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: nav,
        builder: (BuildContext c, Widget? child) => MealioScope(navigatorKey: nav, child: child!),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => MealioCartFlow.show(context, recipe: _recipe, store: 'heb'),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await _frames(tester);
      await tester.enterText(find.byType(TextField).first, 'red onion');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await _frames(tester);
      await tester.tap(find.text('Red Onion'));
      await _frames(tester);
      await tester.tap(find.text('Add 1 item to H-E-B'));
      await _frames(tester);
      expect(find.text('Try again'), findsOneWidget);

      fake.script.addFailure = null;
      final release = fake.hold('search');
      await tester.tap(find.text('Try again'));
      await _frames(tester);
      expect(fake.requests.where((MealioFakeRequest r) => r.kind == 'prepare'), hasLength(2));
      expect(fake.requests.last.kind, 'search');
      MealioCart.instance.cancelJobs();
      await _frames(tester);
      expect(fake.requests.where((MealioFakeRequest r) => r.kind == 'prepare'), hasLength(3),
          reason: 'the sheet starts the cart again');
      expect(find.text('Try again'), findsNothing);
      release();
      await _frames(tester);
      expect(find.text('Red Onion'), findsWidgets, reason: 'the restart restored the searched pick');
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('the testing kit', () {
    testWidgets('a held request does not run into the 30-second timeout', (WidgetTester tester) async {
      final fake = MealioFake(_script());
      final client = fake.client();
      final release = fake.hold('prepare');
      CartSession? cart;
      Object? err;
      unawaited(client.prepareCart(recipe: _recipe).then((CartSession c) => cart = c, onError: (Object e) => err = e));
      await tester.pump(const Duration(seconds: 45));
      expect(err, isNull);
      release();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      expect(cart?.selectedId('onion'), 'o1');
    });
  });

  test('the core version is the package version (item 9)', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(r'^version: (\S+)', multiLine: true).firstMatch(pubspec)!.group(1);
    expect(sdkCoreVersion, version);
  });
}
