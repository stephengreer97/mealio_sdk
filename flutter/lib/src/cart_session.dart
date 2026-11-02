// A prepared cart the app can show and edit before filling the store cart.
// Mirrors CartSession in packages/core/src/client.ts.
//
// Every item is shown every run. Remembered products start selected; the user
// can select another option, search for something else, or deselect an item
// to leave it out of THIS run (its remembered choice is kept for next time).

import 'package:flutter/foundation.dart';

import 'client.dart';
import 'errors.dart';
import 'protocol.dart';

/// The estimated total of the selected items.
@immutable
class CartEstimate {
  const CartEstimate({required this.total, required this.count, required this.estimated, required this.unpriced});

  /// Unit price times quantity, summed, rounded to cents.
  final double total;

  /// Selected items.
  final int count;

  /// True when any selected item is sold by weight or has no price: show the
  /// total as "about".
  final bool estimated;

  /// Selected items without a unit price.
  final int unpriced;

  @override
  String toString() => 'CartEstimate(total: $total, count: $count, estimated: $estimated, unpriced: $unpriced)';
}

class _Pick {
  const _Pick(this.productId, this.preferenceId);
  final String productId;
  final String? preferenceId;
}

/// A prepared cart. A [ChangeNotifier]: it notifies after [select],
/// [deselect] and [search], so widgets can rebuild with a
/// `ListenableBuilder`.
class CartSession extends ChangeNotifier {
  CartSession(this._client, this.cart) {
    for (final CartItem it in items) {
      final id = it.selectedId;
      if (id != null && id.isNotEmpty) _picks[it.key] = _Pick(id, it.rememberedPreferenceId);
    }
  }

  final MealioClient _client;

  /// The cart exactly as the server prepared it.
  final PreparedCart cart;

  // Insertion-ordered, like the reference's Map.
  final Map<String, _Pick> _picks = <String, _Pick>{};
  final Map<String, List<Product>> _extra = <String, List<Product>>{};

  String get cartId => cart.cartId;
  String get store => cart.store;

  /// Display name of the store, when the server sent one.
  String? get storeName => cart.storeName;

  /// Every item in recipe order.
  List<CartItem> get items => cart.items;

  // ignore: deprecated_member_use_from_same_package
  @Deprecated('Use items')
  List<CartItem> get ready => cart.ready;
  // ignore: deprecated_member_use_from_same_package
  @Deprecated('Use items')
  List<CartItem> get needsChoice => cart.needsChoice;
  // ignore: deprecated_member_use_from_same_package
  @Deprecated('Use items')
  List<CartItem> get unavailable => cart.unavailable;

  /// Options for an item, including any found with [search], without
  /// duplicates.
  List<Product> options(String key) {
    final it = _find(key);
    final base = it == null ? const <Product>[] : _baseOptions(it);
    final more = _extra[key] ?? const <Product>[];
    final seen = base.map((Product p) => p.id).toSet();
    return <Product>[...base, ...more.where((Product p) => !seen.contains(p.id))];
  }

  String? selectedId(String key) => _picks[key]?.productId;
  bool isSelected(String key) => _picks.containsKey(key);
  int selectedCount() => _picks.length;

  /// The preference picked with the selected product, if any.
  String? selectedPreferenceId(String key) => _picks[key]?.preferenceId;

  /// The selected product for an item, from its options.
  Product? selected(String key) {
    final id = selectedId(key);
    if (id == null) return null;
    for (final Product p in options(key)) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Select `productId` for `key`. Throws [MealioException] with
  /// `unknown_item` or `unknown_product` when either was not offered. Pass
  /// `preferenceId` when the product has `preferences`.
  void select(String key, String productId, {String? preferenceId}) {
    if (_find(key) == null) throw MealioException(MealioErrorCode.unknownItem, 'No item $key');
    if (!options(key).any((Product p) => p.id == productId)) {
      throw MealioException(MealioErrorCode.unknownProduct, 'Product $productId was not offered for $key');
    }
    _picks[key] = _Pick(productId, preferenceId);
    notifyListeners();
  }

  /// Leave the item out of this run. Its remembered choice is kept.
  void deselect(String key) {
    if (_picks.remove(key) != null) notifyListeners();
  }

  /// Search the store for something else and add the results to this item's
  /// options. Returns what the search found.
  Future<List<Product>> search(String key, String query, {StepListener? onStep}) async {
    final r = await _client.search(cart.cartId, key, query, onStep: onStep);
    final prev = _extra[key] ?? const <Product>[];
    final seen = prev.map((Product p) => p.id).toSet();
    _extra[key] = <Product>[...r.options.where((Product p) => !seen.contains(p.id)), ...prev];
    notifyListeners();
    return r.options;
  }

  /// One selection per item, in recipe order. Selected items are added and
  /// remembered; the rest are left out of this run without forgetting their
  /// remembered choice.
  List<Selection> selections() {
    return items.map((CartItem it) {
      final p = _picks[it.key];
      return p == null
          ? Selection(key: it.key, productId: null, remember: false)
          : Selection(
              key: it.key,
              productId: p.productId,
              quantity: it.quantity,
              remember: true,
              preferenceId: p.preferenceId,
            );
    }).toList();
  }

  /// Estimated total of the selected items: unit price times quantity.
  CartEstimate estimate() {
    var total = 0.0;
    var count = 0;
    var unpriced = 0;
    var estimated = false;
    for (final CartItem it in items) {
      final p = selected(it.key);
      if (p == null) continue;
      count += 1;
      final unit = p.unitPrice;
      if (unit != null) {
        total += unit * (it.quantity == 0 ? 1 : it.quantity);
      } else {
        unpriced += 1;
      }
      if (p.estimated) estimated = true;
    }
    return CartEstimate(
      total: (total * 100).round() / 100,
      count: count,
      estimated: estimated || unpriced > 0,
      unpriced: unpriced,
    );
  }

  /// Fill the store cart with the current selections.
  Future<AddResult> addToCart({StepListener? onStep}) => _client.addToCart(cart.cartId, selections(), onStep: onStep);

  @Deprecated('Use select')
  void choose(String key, String productId, {int? quantity, bool? remember, String? preferenceId}) =>
      select(key, productId, preferenceId: preferenceId);

  @Deprecated('Use deselect')
  void skip(String key) => deselect(key);

  /// Items that can be added but are not selected.
  @Deprecated('Every item is shown; use isSelected')
  List<CartItem> pending() =>
      items.where((CartItem it) => it.status != ItemStatus.unavailable && !_picks.containsKey(it.key)).toList();

  /// The current selection for `key`, or null when it is not selected.
  @Deprecated('Use selectedId and selectedPreferenceId')
  Selection? selectionFor(String key) {
    for (final Selection s in selections()) {
      if (s.key == key) return s.productId == null ? null : s;
    }
    return null;
  }

  static List<Product> _baseOptions(CartItem it) {
    if (it.options.isNotEmpty) return it.options;
    // ignore: deprecated_member_use_from_same_package
    final chosen = it.chosen;
    return chosen == null ? const <Product>[] : <Product>[chosen];
  }

  CartItem? _find(String key) {
    for (final CartItem i in items) {
      if (i.key == key) return i;
    }
    return null;
  }
}
