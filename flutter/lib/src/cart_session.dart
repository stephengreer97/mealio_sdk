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

  /// Unit price times quantity, summed, rounded to cents. A sold-by-weight
  /// item counts price per lb times its weight (its package price once when
  /// the store prices it as a package).
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

/// The weight step (lb) for a sold-by-weight item whose store lists no
/// weights.
const double weightStep = 0.25;

/// The most a selection may ask for, in lb. The server refuses more.
const double maxWeightLb = 20;

/// The lightest and heaviest weight (lb) a sold-by-weight item can be set to.
@immutable
class WeightRange {
  const WeightRange({required this.min, required this.max});
  final double min;
  final double max;

  @override
  bool operator ==(Object other) => other is WeightRange && other.min == min && other.max == max;

  @override
  int get hashCode => Object.hash(min, max);

  @override
  String toString() => 'WeightRange(min: $min, max: $max)';
}

int _nearestIndex(List<double> opts, double v) {
  var best = 0;
  for (var i = 0; i < opts.length; i += 1) {
    if ((opts[i] - v).abs() < (opts[best] - v).abs() - 1e-9) best = i;
  }
  return best;
}

class _Pick {
  const _Pick(this.productId, this.preferenceId);
  final String productId;
  final String? preferenceId;
}

/// A prepared cart. A [ChangeNotifier]: it notifies after [select],
/// [deselect], [setQuantity], [setWeight], [stepWeight] and [search], so widgets can rebuild with a
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
  final Map<String, int> _qty = <String, int>{};
  final Map<String, double> _lb = <String, double>{};

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

  /// Packages to add for an item: the recipe's quantity (at least 1) until
  /// the user changes it.
  int quantity(String key) {
    final stored = _qty[key];
    if (stored != null) return stored;
    final q = _find(key)?.quantity ?? 1;
    return q < 1 ? 1 : q;
  }

  /// The most the user can add: the selected product's store cap, else 99.
  int maxQuantity(String key) {
    final cap = selected(key)?.maxQuantity;
    return cap != null && cap > 0 ? (cap < 99 ? cap : 99) : 99;
  }

  /// Set the quantity, clamped to 1 and the store's cap. Returns what was
  /// set.
  int setQuantity(String key, int n) {
    final v = n.clamp(1, maxQuantity(key));
    _qty[key] = v;
    notifyListeners();
    return v;
  }

  /// True when the selected product is sold by weight: use [weight], not
  /// [quantity].
  bool isWeight(String key) => selected(key)?.soldByWeight ?? false;

  /// The lightest and heaviest weight (lb) the user can pick for the selected
  /// product: its first and last weight option, else 0.25 to 20.
  WeightRange weightRange(String key) {
    final opts = _weightOptions(key);
    if (opts.isEmpty) return const WeightRange(min: weightStep, max: maxWeightLb);
    return WeightRange(min: opts.first, max: opts.last < maxWeightLb ? opts.last : maxWeightLb);
  }

  /// Pounds to add for a sold-by-weight item: the user's, else the recipe's
  /// own weight, else the store's first weight option, else 0.25. Always a
  /// weight the selected product can be bought in (see [setWeight]). 0 for
  /// count items.
  double weight(String key) {
    if (!isWeight(key)) return 0;
    final set = _lb[key];
    if (set != null) return _snapWeight(key, set);
    final recipe = _find(key)?.weightLb;
    if (recipe != null && recipe > 0) return _snapWeight(key, recipe);
    final opts = _weightOptions(key);
    return opts.isEmpty ? weightStep : opts.first;
  }

  /// Set the weight in lb. Snapped to the nearest weight option when the
  /// store lists them, else to 0.25 lb steps, and clamped to [weightRange].
  /// Returns what was set.
  double setWeight(String key, double lb) {
    final v = _snapWeight(key, lb.isFinite ? lb : 0);
    _lb[key] = v;
    notifyListeners();
    return v;
  }

  /// One step heavier (`dir` 1) or lighter (`dir` -1): the next weight
  /// option, else 0.25 lb. Returns the new weight.
  double stepWeight(String key, int dir) {
    final d = dir < 0 ? -1 : 1;
    final cur = weight(key);
    final opts = _weightOptions(key);
    if (opts.isEmpty) return setWeight(key, cur + d * weightStep);
    final i = (_nearestIndex(opts, cur) + d).clamp(0, opts.length - 1);
    return setWeight(key, opts[i]);
  }

  List<double> _weightOptions(String key) {
    final raw = selected(key)?.weightOptions ?? const <double>[];
    final opts = raw.where((double n) => n.isFinite && n > 0 && n <= maxWeightLb).toSet().toList()..sort();
    return opts;
  }

  double _snapWeight(String key, double lb) {
    final r = weightRange(key);
    final opts = _weightOptions(key);
    final v = lb.clamp(r.min, r.max).toDouble();
    if (opts.isNotEmpty) return opts[_nearestIndex(opts, v)];
    return ((v / weightStep).round() * weightStep).clamp(r.min, r.max).toDouble();
  }

  bool isSelected(String key) => _picks.containsKey(key);
  int selectedCount() => _picks.length;

  /// The preference picked with the selected product, if any.
  String? selectedPreferenceId(String key) => _picks[key]?.preferenceId;

  /// The preference chosen for an item's product, or null. The same as
  /// [selectedPreferenceId], named as in the other SDKs.
  String? preferenceId(String key) => _picks[key]?.preferenceId;

  /// True when the item is ticked but its product offers preferences (H-E-B
  /// deli slicing, for example) and none is chosen. Such an item stays out
  /// of the add and the total until one is, the same rule as the Mealio app:
  /// a missing preference is a different request from "No preference".
  bool needsPreference(String key) {
    final pick = _picks[key];
    if (pick == null) return false;
    final prefs = selected(key)?.preferences ?? const <ProductPreference>[];
    final pref = pick.preferenceId;
    return prefs.isNotEmpty && (pref == null || pref.isEmpty);
  }

  /// Keys of ticked items still waiting on a preference.
  List<String> pendingPreferences() =>
      items.where((CartItem it) => needsPreference(it.key)).map((CartItem it) => it.key).toList();

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
      if (p == null || needsPreference(it.key)) return Selection(key: it.key, productId: null, remember: false);
      if (isWeight(it.key)) {
        return Selection(
          key: it.key,
          productId: p.productId,
          quantity: 1,
          weightLb: weight(it.key),
          remember: true,
          preferenceId: p.preferenceId,
        );
      }
      return Selection(
        key: it.key,
        productId: p.productId,
        quantity: _clampedQuantity(it.key),
        remember: true,
        preferenceId: p.preferenceId,
      );
    }).toList();
  }

  /// Estimated total of the selected items: unit price times quantity, and
  /// for a sold-by-weight item price per lb times the weight (one package
  /// price when the store prices it as a package). An item waiting on a
  /// preference is left out. `estimated` is true when any item is sold by
  /// weight or has no price, so show it as "about".
  CartEstimate estimate() {
    var total = 0.0;
    var count = 0;
    var unpriced = 0;
    var estimated = false;
    for (final CartItem it in items) {
      final p = selected(it.key);
      if (p == null || needsPreference(it.key)) continue;
      count += 1;
      if (p.soldByWeight ?? false) {
        estimated = true;
        final perLb = p.pricePerLb;
        if (perLb != null) {
          total += perLb * weight(it.key);
        } else if (p.unitPrice != null) {
          total += p.unitPrice!;
        } else {
          unpriced += 1;
        }
        continue;
      }
      final unit = p.unitPrice;
      if (unit != null) {
        total += unit * _clampedQuantity(it.key);
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

  int _clampedQuantity(String key) {
    final q = quantity(key);
    final max = maxQuantity(key);
    return q < max ? q : max;
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
