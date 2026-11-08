// package:mealio_sdk/testing.dart's scripted fake Mealio, used the way a
// partner would: the real client and CartSession, and the real sheet.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mealio_sdk/mealio_sdk.dart';
import 'package:mealio_sdk/testing.dart';

const Recipe _recipe = Recipe(
  id: 'r',
  title: 'Soup',
  ingredients: <RecipeIngredient>[RecipeIngredient(name: 'onion'), RecipeIngredient(name: 'salt')],
);

const Product _onion = Product(id: 'o1', name: 'Yellow Onion', price: r'$1.25', unitPrice: 1.25);
const Product _salt = Product(id: 's1', name: 'Salt');

MealioFakeScript _script() => MealioFakeScript(
      items: <MealioFakeItem>[
        const MealioFakeItem(key: 'onion', options: <Product>[_onion], remembered: 'o1', quantity: 2),
        const MealioFakeItem(key: 'salt', options: <Product>[_salt], remembered: 's1', startUnchecked: true),
      ],
      search: <String, List<Product>>{
        'sweet onion': const <Product>[Product(id: 'o9', name: 'Sweet Onion', unitPrice: 2)],
      },
      warnings: const <CartWarning>[CartWarning(code: 'lines_dropped', message: 'One line was empty.')],
    );

TypeMatcher<MealioException> _code(String code) => isA<MealioException>().having((MealioException e) => e.code, 'code', code);

void main() {
  group('the real client on a scripted Mealio', () {
    test('remembered picks, startUnchecked items, warnings, and an add', () async {
      final fake = MealioFake(_script());
      final cart = await fake.client().prepareCart(recipe: _recipe);
      expect(cart.selectedId('onion'), 'o1');
      expect(cart.quantity('onion'), 2);
      expect(cart.isSelected('salt'), isFalse);
      expect(cart.items.firstWhere((CartItem i) => i.key == 'salt').startUnchecked, isTrue);
      expect(cart.warnings.single.code, 'lines_dropped');
      expect(cart.estimate().total, 2.5);

      final r = await cart.addToCart();
      expect(r.added.map((AddedItem a) => a.productId), <String>['o1']);
      expect(r.skipped.map((SkippedItem s) => s.key), <String>['salt']);
      expect(fake.requests.map((MealioFakeRequest q) => q.kind), <String>['prepare', 'add']);
      expect(fake.hostCalls, <String>['open https://www.heb.com/']);
    });

    test('the total is null when a selected item has no price', () async {
      final cart = await MealioFake(_script()).client().prepareCart(recipe: _recipe);
      cart.select('salt', 's1');
      final e = cart.estimate();
      expect(e.total, isNull);
      expect(e.unpriced, 1);
    });

    test('search results come from the script, and an add of a searched product works on that cart', () async {
      final fake = MealioFake(_script());
      final cart = await fake.client().prepareCart(recipe: _recipe);
      expect((await cart.search('onion', 'Sweet Onion')).map((Product p) => p.id), <String>['o9']);
      expect(await cart.search('onion', 'shallot'), isEmpty);
      cart.select('onion', 'o9');
      final r = await cart.addToCart();
      expect(r.added.single.productId, 'o9');
      expect(r.added.single.unitPrice, 2);
    });

    test('a product the cart was not offered fails as not_offered, as the server does', () async {
      final fake = MealioFake(_script());
      final client = fake.client();
      final first = await client.prepareCart(recipe: _recipe);
      await first.search('onion', 'sweet onion');
      first.select('onion', 'o9');
      final r = await client.addToCart('cart_2', first.selections());
      expect(r.failed.single.reason, 'not_offered');
    });

    test('restorePicks after a failed add searches again on the new cart, so the add works', () async {
      final fake = MealioFake(_script()..addFailure = const MealioFakeError('store_unavailable'));
      final client = fake.client();
      final first = await client.prepareCart(recipe: _recipe);
      await first.search('onion', 'sweet onion');
      first.select('onion', 'o9');
      first.setQuantity('onion', 3);
      await expectLater(first.addToCart(), throwsA(_code('store_unavailable')));

      fake.script.addFailure = null;
      final second = await client.prepareCart(recipe: _recipe);
      await second.restorePicks(first);
      expect(fake.requests.last.path, '/api/v1/sdk/carts/${second.cartId}/search');
      final r = await second.addToCart();
      expect(r.failed, isEmpty);
      expect(r.added.single.productId, 'o9');
      expect(r.added.single.quantity, 3);
    });

    test('errors by code: HTTP with a status, a failed job without', () async {
      final fake = MealioFake(_script()..errors = <String, MealioFakeError>{
            'prepare': const MealioFakeError('cart_cap_reached', status: 429),
          });
      await expectLater(fake.client().prepareCart(recipe: _recipe), throwsA(_code('cart_cap_reached')));
      fake.script.errors = <String, MealioFakeError>{'prepare': const MealioFakeError('store_unavailable')};
      await expectLater(fake.client().prepareCart(recipe: _recipe), throwsA(_code('store_unavailable')));
      fake.script.errors = <String, MealioFakeError>{'session': const MealioFakeError('no_user')};
      await expectLater(fake.client().prepareCart(recipe: _recipe), throwsA(_code(MealioErrorCode.sessionFailed)));
    });

    test('sign-in required: the fake store page answers as scripted', () async {
      final fake = MealioFake(_script()..signIn = 'signed_in');
      expect((await fake.client().prepareCart(recipe: _recipe)).items, hasLength(2));
      expect(fake.hostCalls, contains('login'));
      fake.script.signIn = 'cancelled';
      await expectLater(fake.client().prepareCart(recipe: _recipe), throwsA(_code(MealioErrorCode.loginCancelled)));
    });

    test('a user switch cancels the prepare with user_changed, and the next user can prepare', () async {
      final fake = MealioFake(_script());
      final client = fake.client();
      client.setUser('a');
      final release = fake.hold('prepare');
      final first = client.prepareCart(recipe: _recipe);
      await Future<void>.delayed(Duration.zero);
      client.setUser('b');
      release();
      await expectLater(
        first,
        throwsA(isA<MealioException>().having((MealioException e) => e.reason, 'reason', MealioCancelReason.userChanged)),
      );
      expect((await client.prepareCart(recipe: _recipe)).selectedId('onion'), 'o1');
    });

    test('the store list, preferences and locations come from the script', () async {
      final fake = MealioFake(MealioFakeScript(
        locations: const <StoreLocation>[StoreLocation(id: 'k1', name: 'Kroger Main', address: '1 Main St')],
      ));
      final client = fake.client();
      expect((await client.stores()).single.id, 'heb');
      expect((await client.storePreferences()).defaultStore, 'heb');
      final p = await client.setStore('kroger', locationId: 'k1');
      expect(<Object?>[p.defaultStore, p.location?.name], <Object?>['kroger', 'Kroger Main']);
    });
  });

  group('widgets on a scripted Mealio', () {
    Widget app(Widget home) {
      final nav = GlobalKey<NavigatorState>();
      return MaterialApp(
        navigatorKey: nav,
        builder: (BuildContext c, Widget? child) => MealioScope(navigatorKey: nav, child: child!),
        home: Scaffold(body: Center(child: home)),
      );
    }

    void phone(WidgetTester tester) {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    testWidgets('the drop-in sheet shows the scripted list and adds it', (WidgetTester tester) async {
      phone(tester);
      installMealioTestPlatform();
      final fake = MealioFake(_script());
      configureMealioForTesting(fake: fake);
      AddResult? added;
      await tester.pumpWidget(app(MealioCartButton(recipe: _recipe, store: 'heb', onAdded: (AddResult r) => added = r)));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(MealioCartButton));
      await tester.pumpAndSettle();
      expect(find.text('Yellow Onion'), findsWidgets);
      expect(fake.requests.map((MealioFakeRequest r) => r.kind), contains('prepare'));
      await tester.tap(find.text('Add 1 item to H-E-B'));
      await tester.pumpAndSettle();
      expect(added?.added.map((AddedItem a) => a.productId), <String>['o1']);
    });

    testWidgets('closing the sheet while it prepares cancels the prepare', (WidgetTester tester) async {
      phone(tester);
      installMealioTestPlatform();
      final fake = MealioFake(_script());
      configureMealioForTesting(fake: fake);
      final release = fake.hold('prepare');
      Object? error;
      await tester.pumpWidget(app(Builder(
        builder: (BuildContext context) => TextButton(
          onPressed: () => MealioCartFlow.show(
            context,
            recipe: _recipe,
            store: 'heb',
            prepareCart: ({String? store, required Recipe recipe, String? zip, StepListener? onStep}) {
              final p = MealioCart.instance.prepareCart(store: store, recipe: recipe);
              p.then((_) {}, onError: (Object e) {
                error = e;
              });
              return p;
            },
          ),
          child: const Text('open'),
        ),
      )));
      await tester.tap(find.text('open'));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.tapAt(const Offset(10, 10));
      release();
      await tester.pumpAndSettle();
      expect(error, isA<MealioException>().having((MealioException e) => e.reason, 'reason', MealioCancelReason.closed));
      expect(fake.hostCalls, isEmpty, reason: 'a cancelled prepare never drives the page');
    });
  });
}
