import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mealio_sdk/mealio_sdk.dart';
import 'package:mealio_sdk/testing.dart';

// 0.6 round 8, compatibility: ItemRecipe.quantity stays an int (0.5.0) and
// gains share, the exact number; the fake kit keeps a script's exact quantity.
void main() {
  group('ItemRecipe.share', () {
    test('a half share is kept beside the whole quantity', () {
      final r = ItemRecipe.fromJson(jsonDecode('{"id":"r","title":null,"quantity":0.5}'));
      expect(r.quantity, 0);
      expect(r.share, 0.5);
      expect(r.toJson()['quantity'], 0.5);
    });

    test('a whole share is the quantity, on the wire as an int', () {
      final r = ItemRecipe.fromJson(jsonDecode('{"id":"r","title":"T","quantity":2}'));
      expect(r.quantity, 2);
      expect(r.share, 2.0);
      expect(r.toJson()['quantity'], isA<int>());
      expect(r.toJson()['quantity'], 2);
      expect(ItemRecipe.fromJson(jsonDecode('{"id":"r"}')).share, 1.0);
    });

    test('0.5.0 call sites still compile and read the same', () {
      const r = ItemRecipe(id: 'a', title: 'A', quantity: 3);
      final int q = r.quantity;
      expect(q, 3);
      expect(r.share, 3.0);
      expect(r.toJson(), <String, Object?>{'id': 'a', 'title': 'A', 'quantity': 3});
      expect(const ItemRecipe(id: 'b', quantity: 0, share: 0.25).toJson()['quantity'], 0.25);
    });
  });

  group('fake kit quantities', () {
    MealioFakeItem i15() => const MealioFakeItem(key: 'a', quantity: 1, quantityExact: 1.5, recipes: <ItemRecipe>[ItemRecipe(id: 'r', quantity: 0, share: 0.5)]);
    MealioFakeItem item(String json) => MealioFakeScript.fromJson(jsonDecode('{"items":[$json]}')).items.single;

    test('a fractional item quantity and recipe share are kept', () {
      final i = item('{"key":"a","quantity":1.5,"recipes":[{"id":"r","title":null,"quantity":0.5}]}');
      expect(i.quantity, 1);
      expect(i.quantityExact, 1.5);
      expect(i.recipes!.single.share, 0.5);
    });

    test('a whole quantity has no exact one', () {
      expect(item('{"key":"a","quantity":2}').quantityExact, isNull);
      expect(item('{"key":"a","quantity":2.0}').quantityExact, isNull);
      expect(item('{"key":"a","quantity":3000000000}').quantity, 3000000000);
      expect(item('{"key":"a","quantity":1e400}').quantityExact, double.infinity);
    });

    test('the cart sends the exact quantity and share', () async {
      final fake = MealioFake(MealioFakeScript.fromJson(jsonDecode(
          '{"store":"heb","items":[{"key":"a","quantity":1.5,"options":[{"id":"p","name":"P"}],"recipes":[{"id":"r","title":null,"quantity":0.5}]},'
          '{"key":"b","quantity":1e400,"options":[{"id":"q","name":"Q"}]}]}')));
      final cart = await fake.client().prepareCart(store: 'heb', recipe: const Recipe(id: 'r', ingredients: <RecipeIngredient>[]));
      final a = cart.cart.items.firstWhere((CartItem i) => i.key == 'a');
      expect(a.recipes!.single.share, 0.5);
      expect(a.recipes!.single.quantity, 0);
      // 1e400 (Infinity) went out as JSON.stringify sends it (null), not as a throw.
      expect(cart.cart.items.length, 2);
      expect(mealioFakeCartItem(i15()).recipes!.single.share, 0.5);
    });
  });

  test('the guard judges forms in the capture phase and only prevents the default', () {
    // Before any page handler can stop the event, at window and each shadow root.
    expect(guardScript, contains("addEL(t, 'submit', onSubmit, true)"));
    expect(guardScript, isNot(contains("onSubmit, false")));
    // preventDefault only: the page's own handlers always run.
    expect(guardScript, isNot(contains('stopImmediatePropagation')));
    expect(guardScript, isNot(contains('stopPropagation(')));
    expect(guardScript, isNot(contains("'stopPropagation'")));
    // No action attribute (nor formaction): only the fields are judged, not the page URL.
    expect(guardScript, contains("attrOf(form, 'action') !== null"));
    expect(guardScript, contains("attrOf(submitter, 'formaction')"));
    // requestSubmit() is judged by the same rules.
    expect(guardScript, contains('FE.prototype.requestSubmit = function (by)'));
  });
}
