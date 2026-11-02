// A drop-in sheet for a prepared cart: what is ready, what needs a choice,
// what is unavailable, and an Add to cart button. Material widgets; apps that
// want their own look can build on CartSession directly.

import 'package:flutter/material.dart';

import '../cart_session.dart';
import '../errors.dart';
import '../protocol.dart';

class MealioCartSheet extends StatefulWidget {
  const MealioCartSheet({
    super.key,
    required this.session,
    this.onAdded,
    this.onError,
    this.onDone,
    this.onOpenStoreCart,
  });

  final CartSession session;

  /// Called once the store cart has been filled.
  final ValueChanged<AddResult>? onAdded;

  /// Called when adding fails. The sheet also shows the message.
  final ValueChanged<MealioException>? onError;

  /// Called when the user taps Done after adding.
  final ValueChanged<AddResult>? onDone;

  /// Called with `storeCartUrl` when the user taps "Open store cart". The
  /// button only shows when this is set and the store gave a URL.
  final ValueChanged<String>? onOpenStoreCart;

  /// Shows the sheet as a modal bottom sheet. Resolves with the result after
  /// the user taps Done, or null if they dismiss it first.
  static Future<AddResult?> show(
    BuildContext context,
    CartSession session, {
    ValueChanged<String>? onOpenStoreCart,
  }) {
    return showModalBottomSheet<AddResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (BuildContext sheetContext) => FractionallySizedBox(
        heightFactor: 0.92,
        child: MealioCartSheet(
          session: session,
          onOpenStoreCart: onOpenStoreCart,
          onDone: (AddResult r) => Navigator.of(sheetContext).pop(r),
        ),
      ),
    );
  }

  @override
  State<MealioCartSheet> createState() => _MealioCartSheetState();
}

class _MealioCartSheetState extends State<MealioCartSheet> {
  /// needsChoice items whose product is picked but whose preference is not.
  final Map<String, String> _awaitingPreference = <String, String>{};
  bool _adding = false;
  AddResult? _result;
  String? _error;

  CartSession get _s => widget.session;

  bool get _canAdd => !_adding && _s.pending().isEmpty && _awaitingPreference.isEmpty;

  int get _toAdd => _s.selections().where((Selection x) => x.productId != null).length;

  String? _pickedId(CartItem item) => _awaitingPreference[item.key] ?? _s.selectionFor(item.key)?.productId;

  void _pickProduct(CartItem item, Product p) {
    if (p.outOfStock || _adding) return;
    setState(() {
      if (p.preferences.isEmpty) {
        _awaitingPreference.remove(item.key);
        _s.choose(item.key, p.id, quantity: item.quantity);
      } else {
        _awaitingPreference[item.key] = p.id;
        _s.clearChoice(item.key);
      }
    });
  }

  void _pickPreference(CartItem item, Product p, ProductPreference pref) {
    setState(() {
      _awaitingPreference.remove(item.key);
      _s.choose(item.key, p.id, quantity: item.quantity, preferenceId: pref.id);
    });
  }

  void _skip(CartItem item) {
    setState(() {
      _awaitingPreference.remove(item.key);
      _s.skip(item.key);
    });
  }

  void _restoreReady(CartItem item) {
    final chosen = item.chosen;
    if (chosen == null) return;
    setState(() => _s.choose(item.key, chosen.id, quantity: item.quantity));
  }

  Future<void> _add() async {
    setState(() {
      _adding = true;
      _error = null;
    });
    try {
      final r = await _s.addToCart();
      if (!mounted) return;
      setState(() {
        _result = r;
        _adding = false;
      });
      widget.onAdded?.call(r);
    } on MealioException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _adding = false;
      });
      widget.onError?.call(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Material(
      child: SafeArea(
        top: false,
        child: result == null ? _buildCart(context) : _buildResult(context, result),
      ),
    );
  }

  Widget _buildCart(BuildContext context) {
    final theme = Theme.of(context);
    final children = <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Text('Your cart', style: theme.textTheme.titleLarge),
      ),
    ];

    if (_s.needsChoice.isNotEmpty) {
      children.add(_sectionTitle(context, 'Pick a product'));
      for (final CartItem item in _s.needsChoice) {
        children.add(_choiceItem(context, item));
      }
    }
    if (_s.ready.isNotEmpty) {
      children.add(_sectionTitle(context, 'Ready'));
      for (final CartItem item in _s.ready) {
        children.add(_readyItem(context, item));
      }
    }
    if (_s.unavailable.isNotEmpty) {
      children.add(_sectionTitle(context, 'Not available'));
      for (final CartItem item in _s.unavailable) {
        children.add(ListTile(
          dense: true,
          title: Text(item.ingredient),
          subtitle: Text(_reasonText(item.reason)),
          leading: const Icon(Icons.remove_shopping_cart_outlined),
        ));
      }
    }

    return Column(
      children: <Widget>[
        Expanded(child: ListView(children: children)),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            width: double.infinity,
            height: 48,
            child: FilledButton(
              onPressed: _canAdd && _toAdd > 0 ? _add : null,
              child: _adding
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(_canAdd ? 'Add $_toAdd ${_toAdd == 1 ? 'item' : 'items'} to cart' : 'Pick a product for every item'),
            ),
          ),
        ),
      ],
    );
  }

  Widget _sectionTitle(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(text, style: Theme.of(context).textTheme.titleSmall),
    );
  }

  Widget _readyItem(BuildContext context, CartItem item) {
    final chosen = item.chosen;
    final sel = _s.selectionFor(item.key);
    final skipped = sel != null && sel.productId == null;
    return ListTile(
      leading: _thumb(chosen?.imageUrl),
      title: Text(chosen?.name ?? item.ingredient, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(<String>[
        item.ingredient,
        if (chosen?.price != null) chosen!.price!,
        'Qty ${item.quantity}',
      ].join(' · ')),
      trailing: skipped
          ? TextButton(onPressed: _adding ? null : () => _restoreReady(item), child: const Text('Undo'))
          : TextButton(onPressed: _adding ? null : () => _skip(item), child: const Text('Skip')),
      enabled: !skipped,
    );
  }

  Widget _choiceItem(BuildContext context, CartItem item) {
    final theme = Theme.of(context);
    final picked = _pickedId(item);
    final sel = _s.selectionFor(item.key);
    final skipped = sel != null && sel.productId == null;
    final Product? awaitingProduct = _option(item, _awaitingPreference[item.key]);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: <Widget>[
                    Expanded(child: Text(item.ingredient, style: theme.textTheme.titleMedium)),
                    if (skipped)
                      Text('Skipped', style: theme.textTheme.labelMedium)
                    else
                      TextButton(onPressed: _adding ? null : () => _skip(item), child: const Text('Skip')),
                  ],
                ),
              ),
              for (final Product p in item.options)
                ListTile(
                  dense: true,
                  enabled: !p.outOfStock && !_adding,
                  selected: !skipped && picked == p.id,
                  leading: _thumb(p.imageUrl),
                  title: Text(p.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text(<String>[
                    if (p.price != null) p.price!,
                    if (p.size != null) p.size!,
                    if (p.outOfStock) 'Out of stock',
                    if (_badgeText(p.badge) != null) _badgeText(p.badge)!,
                  ].join(' · ')),
                  trailing: Icon(
                    !skipped && picked == p.id ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                  ),
                  onTap: () => _pickProduct(item, p),
                ),
              if (awaitingProduct != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('Choose one', style: theme.textTheme.labelLarge),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: <Widget>[
                          for (final ProductPreference pref in awaitingProduct.preferences)
                            ChoiceChip(
                              label: Text(pref.label),
                              selected: false,
                              onSelected: (_) => _pickPreference(item, awaitingProduct, pref),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              if (awaitingProduct == null && picked != null && !skipped)
                _chosenPreferenceLabel(context, item, picked),
            ],
          ),
        ),
      ),
    );
  }

  /// Shows which preference was picked, with a way to change it.
  Widget _chosenPreferenceLabel(BuildContext context, CartItem item, String productId) {
    final prefId = _s.selectionFor(item.key)?.preferenceId;
    if (prefId == null) return const SizedBox.shrink();
    final p = _option(item, productId);
    if (p == null) return const SizedBox.shrink();
    var label = prefId;
    for (final ProductPreference pref in p.preferences) {
      if (pref.id == prefId) label = pref.label;
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(label, style: Theme.of(context).textTheme.bodySmall)),
          TextButton(onPressed: _adding ? null : () => _pickProduct(item, p), child: const Text('Change')),
        ],
      ),
    );
  }

  Widget _buildResult(BuildContext context, AddResult r) {
    final theme = Theme.of(context);
    final url = r.storeCartUrl;
    return Column(
      children: <Widget>[
        Expanded(
          child: ListView(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  r.added.isEmpty
                      ? 'Nothing was added'
                      : 'Added ${r.added.length} ${r.added.length == 1 ? 'item' : 'items'} to your cart',
                  style: theme.textTheme.titleLarge,
                ),
              ),
              for (final AddedItem a in r.added)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.check_circle_outline),
                  title: Text(a.name),
                  subtitle: Text('Qty ${a.quantity}'),
                ),
              if (r.failed.isNotEmpty) _sectionTitle(context, 'Could not add'),
              for (final FailedItem f in r.failed)
                ListTile(
                  dense: true,
                  leading: Icon(Icons.error_outline, color: theme.colorScheme.error),
                  title: Text(f.name),
                  subtitle: Text(_reasonText(f.reason)),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: <Widget>[
              if (url != null && widget.onOpenStoreCart != null) ...<Widget>[
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => widget.onOpenStoreCart!(url),
                    child: const Text('Open store cart'),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: FilledButton(onPressed: () => widget.onDone?.call(r), child: const Text('Done')),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _thumb(String? url) {
    const size = 44.0;
    final placeholder = Container(
      width: size,
      height: size,
      color: const Color(0xFFEEEEEE),
      child: const Icon(Icons.shopping_basket_outlined, size: 20, color: Color(0xFF999999)),
    );
    if (url == null || url.isEmpty) return placeholder;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.network(
        url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (BuildContext context, Object error, StackTrace? stack) => placeholder,
      ),
    );
  }

  static Product? _option(CartItem item, String? productId) {
    if (productId == null) return null;
    for (final Product p in item.options) {
      if (p.id == productId) return p;
    }
    return null;
  }

  static String? _badgeText(String? badge) {
    switch (badge) {
      case 'picked_before':
        return 'Picked before';
      case 'popular':
        return 'Popular';
      case 'partner_pick':
        return 'Recommended';
      default:
        return null;
    }
  }

  static String _reasonText(String? reason) {
    if (reason == null || reason.isEmpty) return 'Not available at this store';
    if (reason == 'no_results') return 'No matching products';
    if (reason == 'out_of_stock') return 'Out of stock';
    return reason.replaceAll('_', ' ');
  }
}
