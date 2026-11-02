// A prepared cart the app can show and edit before filling the store cart.
// Mirrors CartSession in packages/core/src/client.ts.

import 'client.dart';
import 'errors.dart';
import 'protocol.dart';

class CartSession {
  CartSession(this._client, this.cart) {
    for (final CartItem it in cart.ready) {
      final chosen = it.chosen;
      if (chosen != null) {
        _picks[it.key] = Selection(key: it.key, productId: chosen.id, quantity: it.quantity, remember: true);
      }
    }
  }

  final MealioClient _client;

  /// The cart exactly as the server prepared it.
  final PreparedCart cart;

  // Insertion-ordered, like the reference's Map.
  final Map<String, Selection> _picks = <String, Selection>{};

  String get cartId => cart.cartId;
  String get store => cart.store;
  List<CartItem> get ready => cart.ready;
  List<CartItem> get needsChoice => cart.needsChoice;
  List<CartItem> get unavailable => cart.unavailable;

  /// Items still waiting on the user.
  List<CartItem> pending() => cart.needsChoice.where((CartItem it) => !_picks.containsKey(it.key)).toList();

  /// The current pick for `key`, or null. A pick with `productId == null`
  /// means the item is skipped.
  Selection? selectionFor(String key) => _picks[key];

  /// Pick `productId` for `key`. Throws [MealioException] with
  /// `unknown_item` or `unknown_product` when either was not offered.
  /// Pass `preferenceId` when the product has `preferences`.
  void choose(String key, String productId, {int? quantity, bool? remember, String? preferenceId}) {
    final item = _find(key);
    if (item == null) throw MealioException(MealioErrorCode.unknownItem, 'No item $key');
    final known = <Product?>[item.chosen, ...item.options].any((Product? p) => p != null && p.id == productId);
    if (!known) {
      throw MealioException(MealioErrorCode.unknownProduct, 'Product $productId was not offered for $key');
    }
    _picks[key] = Selection(
      key: key,
      productId: productId,
      quantity: quantity ?? item.quantity,
      remember: remember ?? true,
      preferenceId: preferenceId,
    );
  }

  /// Leave `key` out of the store cart.
  void skip(String key) {
    _picks[key] = Selection(key: key, productId: null, remember: false);
  }

  /// Forget the pick for a `needsChoice` item, so it is pending again.
  /// Ready items keep their pick; use [skip] to leave one out.
  void clearChoice(String key) {
    if (cart.needsChoice.any((CartItem i) => i.key == key)) _picks.remove(key);
  }

  List<Selection> selections() => _picks.values.toList();

  /// Fill the store cart with the current selections.
  Future<AddResult> addToCart() => _client.addToCart(cart.cartId, selections());

  CartItem? _find(String key) {
    for (final CartItem i in <CartItem>[...cart.ready, ...cart.needsChoice]) {
      if (i.key == key) return i;
    }
    return null;
  }
}
