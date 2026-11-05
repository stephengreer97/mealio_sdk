// The list screen: every item, every time. Remembered products come back
// pre-selected. Unchecking an item leaves it out of this run only: its
// remembered choice stays for next time. There is no skip button. Mirrors
// CartList in packages/react-native/src/MealioCartFlow.tsx.

import 'package:flutter/material.dart';

import '../cart_session.dart';
import '../errors.dart';
import '../protocol.dart';
import '../theme.dart';
import 'flow_parts.dart';

/// "For Tacos and Pasta": the line under an item's ingredient on a cart made
/// from two or more recipes. Null on a one-recipe cart, from older servers,
/// and when none of the item's recipes has a title.
String? forRecipes(CartSession session, String key) =>
    forRecipesLabel(session.recipes.length, session.recipesFor(key));

/// [forRecipes] without a session. `cartRecipeCount` is how many recipes the
/// cart was made from; `itemRecipes` are the ones that call for the item.
/// Untitled recipes are left out: "For A and B", "For A, B and C".
String? forRecipesLabel(int cartRecipeCount, List<ItemRecipe> itemRecipes) {
  if (cartRecipeCount < 2) return null;
  final names = itemRecipes
      .map((ItemRecipe r) => r.title?.trim() ?? '')
      .where((String n) => n.isNotEmpty)
      .toList();
  return names.isEmpty ? null : 'For ${listAnd(names)}';
}

/// The list screen on its own, for apps that host it in their own sheet.
/// Rebuilds whenever `session` changes.
class MealioCartList extends StatefulWidget {
  const MealioCartList({
    super.key,
    required this.session,
    this.storeName,
    this.busy = false,
    this.onAdd,
    this.onChangeStore,
    this.theme,
  });

  final CartSession session;

  /// Defaults to the server's store name, else a label from the store id.
  final String? storeName;

  /// Adding is in progress: the CTA shows a spinner and the list is locked.
  final bool busy;

  /// The CTA. Null hides nothing but leaves the button disabled.
  final VoidCallback? onAdd;

  /// When set, a tappable store chip ("H-E-B  Change") sits above the list.
  final VoidCallback? onChangeStore;

  /// Defaults to `MealioTheme.of(context)`.
  final MealioTheme? theme;

  @override
  State<MealioCartList> createState() => _MealioCartListState();
}

class _MealioCartListState extends State<MealioCartList> {
  String? _open;

  @override
  void initState() {
    super.initState();
    for (final CartItem i in widget.session.items) {
      if (i.status == ItemStatus.choose || i.status == ItemStatus.rememberedUnavailable) {
        _open = i.key;
        break;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme ?? MealioTheme.of(context);
    final s = widget.session;
    final storeName = widget.storeName ?? s.storeName ?? storeLabel(s.store);
    return withMaterialDefaults(
      context,
      Material(
        color: t.background,
        child: ListenableBuilder(
          listenable: s,
          builder: (BuildContext context, Widget? _) {
            final est = s.estimate();
            final selectable = s.items.where((CartItem i) => i.status != ItemStatus.unavailable).length;
            final canAdd = !widget.busy && est.count > 0 && widget.onAdd != null;
            final pending = s.pendingPreferences().length;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                  child: Row(
                    children: <Widget>[
                      if (widget.onChangeStore != null) ...<Widget>[
                        _storeChip(t, storeName),
                        const SizedBox(width: 10),
                      ],
                      Flexible(
                        child: Text('${est.count} of $selectable selected', style: t.style(size: 14, color: t.muted)),
                      ),
                    ],
                  ),
                ),
                // Said while any item has no saved product, which on a recipe's
                // first cart is every item: the run where nothing on screen shows it yet.
                if (s.items.any((CartItem i) => i.status == ItemStatus.choose))
                  Container(
                    key: const ValueKey<String>('mealio-remember-note'),
                    margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: t.surface,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: t.border),
                    ),
                    child: Text(
                      'Pick a product for each item and Mealio will remember your preferences.',
                      style: t.style(size: 13, weight: FontWeight.w500, height: 18 / 13, color: t.text),
                    ),
                  ),
                Expanded(
                  child: ListView(
                    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.manual,
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    children: gapped(<Widget>[
                      for (final CartItem it in s.items)
                        _ItemRow(
                          key: ValueKey<String>(it.key),
                          theme: t,
                          session: s,
                          item: it,
                          storeName: storeName,
                          open: _open == it.key,
                          disabled: widget.busy,
                          onToggleOpen: () => setState(() => _open = _open == it.key ? null : it.key),
                        ),
                    ], 10),
                  ),
                ),
                Footer(
                  theme: t,
                  children: <Widget>[
                    if (pending > 0)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          '${pending == 1 ? '1 checked item needs' : '$pending checked items need'} '
                          'an option chosen before adding.',
                          style: t.style(size: 12, height: 17 / 12, color: t.warnText),
                        ),
                      ),
                    // No partial totals: one unpriced item and there is no number to show.
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: <Widget>[
                        Expanded(
                          child: Text(est.total != null && est.estimated ? 'Estimated total' : 'Total',
                              style: t.style(size: 14, color: t.muted)),
                        ),
                        if (est.total != null)
                          Text('${est.estimated ? 'about ' : ''}${mealioMoney(est.total!)}',
                              style: t.style(size: 18, weight: FontWeight.w700))
                        else
                          Text('Prices at checkout', style: t.style(size: 15, weight: FontWeight.w600, color: t.muted)),
                      ],
                    ),
                    Cta(
                      theme: t,
                      busy: widget.busy,
                      label: est.count > 0 ? 'Add ${plural(est.count, 'item')} to $storeName' : 'Select items to add',
                      onTap: canAdd ? widget.onAdd : null,
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

extension on _MealioCartListState {
  Widget _storeChip(MealioTheme t, String storeName) {
    final onTap = widget.busy ? null : widget.onChangeStore;
    final chipText = t.style(size: 13, weight: FontWeight.w600);
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: 'Store: $storeName. Change store',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        // 36 tall to look at, 44 tall to touch.
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Container(
            constraints: const BoxConstraints(minHeight: 36),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(color: t.surface, borderRadius: BorderRadius.circular(18)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(storeName, style: chipText),
                const SizedBox(width: 8),
                Text('Change', style: t.style(size: 13, weight: FontWeight.w600, color: t.accent)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ItemRow extends StatefulWidget {
  const _ItemRow({
    super.key,
    required this.theme,
    required this.session,
    required this.item,
    required this.storeName,
    required this.open,
    required this.disabled,
    required this.onToggleOpen,
  });

  final MealioTheme theme;
  final CartSession session;
  final CartItem item;
  final String storeName;
  final bool open;
  final bool disabled;
  final VoidCallback onToggleOpen;

  @override
  State<_ItemRow> createState() => _ItemRowState();
}

class _ItemRowState extends State<_ItemRow> {
  final TextEditingController _query = TextEditingController();
  bool _searching = false;
  String? _searchNote;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  CartSession get _s => widget.session;
  CartItem get _item => widget.item;

  void _toggle() {
    if (widget.disabled) return;
    final on = _s.isSelected(_item.key);
    final id = _item.selectedId;
    if (on) {
      _s.deselect(_item.key);
    } else if (_item.status == ItemStatus.remembered && id != null) {
      _s.select(_item.key, id, preferenceId: _item.rememberedPreferenceId);
    } else if (!widget.open) {
      widget.onToggleOpen();
    }
  }

  void _pick(Product p, [String? preferenceId]) {
    if (widget.disabled) return;
    _s.select(_item.key, p.id, preferenceId: preferenceId);
  }

  Future<void> _search() async {
    final q = _query.text.trim();
    if (q.length < 2 || _searching) return;
    setState(() {
      _searching = true;
      _searchNote = null;
    });
    try {
      final found = await _s.search(_item.key, q);
      if (!mounted) return;
      setState(() => _searchNote = found.isEmpty ? 'Nothing found for "$q".' : null);
      _query.clear();
    } catch (e) {
      if (!mounted) return;
      setState(() => _searchNote = e is MealioException && e.message.isNotEmpty ? e.message : 'Search failed. Try again.');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    final item = _item;
    final storeName = widget.storeName;
    final cardDecoration = BoxDecoration(
      color: t.background,
      borderRadius: BorderRadius.circular(t.radius + 2),
      border: Border.all(color: widget.open ? t.muted : t.border),
    );
    final ingredient = Text(item.ingredient,
        maxLines: 1, overflow: TextOverflow.ellipsis, style: t.style(size: 12, weight: FontWeight.w500, color: t.muted));
    final forLine = forRecipes(_s, item.key);
    final Widget? forText = forLine == null
        ? null
        : Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Text(forLine,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: t.style(size: 11, color: t.muted)),
          );

    if (item.status == ItemStatus.unavailable) {
      return Semantics(
        container: true,
        label: '${item.ingredient}, not found at $storeName',
        excludeSemantics: true,
        child: Container(
          decoration: cardDecoration,
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: <Widget>[
              SizedBox(width: 48, height: 48, child: Center(child: _box(t, on: false, disabled: true))),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    ingredient,
                    if (forText != null) forText,
                    Text('Not found at $storeName', style: t.style(size: 14, weight: FontWeight.w600, color: t.muted)),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    final on = _s.isSelected(item.key);
    final picked = _s.selected(item.key);
    final options = _s.options(item.key);
    final shown = picked ?? (item.status == ItemStatus.remembered ? item.remembered : null);
    final rememberedId = item.remembered?.id;

    final String meta;
    if (picked != null) {
      meta = <String?>[
        priceText(picked),
        picked.id == rememberedId ? 'Your usual' : null,
      ].whereType<String>().where((String x) => x.isNotEmpty).join(' · ');
    } else if (item.status == ItemStatus.remembered) {
      meta = 'Not adding this time';
    } else if (item.status == ItemStatus.rememberedUnavailable) {
      meta = 'Your usual is out of stock';
    } else {
      meta = plural(options.length, 'option');
    }

    final TextStyle nameStyle;
    if (on) {
      nameStyle = t.style(size: 15, height: 20 / 15, weight: FontWeight.w600);
    } else if (shown != null) {
      nameStyle = t.style(
          size: 15, height: 20 / 15, weight: FontWeight.w600, color: t.muted, decoration: TextDecoration.lineThrough);
    } else {
      nameStyle = t.style(size: 15, height: 20 / 15, weight: FontWeight.w600, color: t.muted);
    }

    final changeLabel = widget.open ? 'Done' : (on || item.status == ItemStatus.remembered ? 'Change' : 'Choose');

    final row = Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 10, right: 6),
      child: Row(
        children: <Widget>[
          Semantics(
            checked: on,
            enabled: !widget.disabled,
            label: '${on ? 'Leave out ' : 'Add '}${item.ingredient}',
            onTap: widget.disabled ? null : _toggle,
            excludeSemantics: true,
            child: InkWell(
              onTap: widget.disabled ? null : _toggle,
              customBorder: const CircleBorder(),
              child: SizedBox(width: 48, height: 48, child: Center(child: _box(t, on: on, disabled: false))),
            ),
          ),
          const SizedBox(width: 10),
          ProductThumb(theme: t, product: shown ?? (options.isEmpty ? null : options.first), dim: !on),
          const SizedBox(width: 10),
          Expanded(
            child: Semantics(
              button: true,
              hint: 'Shows the options',
              child: InkWell(
                onTap: widget.onToggleOpen,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    ingredient,
                    if (forText != null) forText,
                    Text(shown?.name ?? 'Choose a product',
                        maxLines: 2, overflow: TextOverflow.ellipsis, style: nameStyle),
                    if (meta.isNotEmpty) Text(meta, style: t.style(size: 12, height: 17 / 12, color: t.muted)),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Semantics(
            button: true,
            label: changeLabel,
            hint: widget.open ? 'Hides the options for ${item.ingredient}' : 'Shows the options for ${item.ingredient}',
            excludeSemantics: true,
            child: InkWell(
              onTap: widget.onToggleOpen,
              borderRadius: BorderRadius.circular(8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Center(
                    widthFactor: 1,
                    child: Text(changeLabel, style: t.style(size: 14, weight: FontWeight.w600, color: t.accent)),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );

    final children = <Widget>[row];

    if (on && picked != null && _s.needsPreference(item.key)) {
      children.add(Semantics(
        liveRegion: true,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Text(
            'Choose one: ${listOr(picked.preferences.map((ProductPreference p) => p.label).toList())}',
            style: t.style(size: 13, height: 18 / 13, weight: FontWeight.w600, color: t.accent),
          ),
        ),
      ));
    }

    if (on && picked != null) children.add(_quantityRow(t, picked));

    if (item.status == ItemStatus.rememberedUnavailable && !on) {
      final r = item.remembered;
      children.add(WarnBox(
        theme: t,
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        text: 'Your usual${r != null ? ', ${r.name},' : ''} is '
            '${item.reason == 'not_found' ? 'not available' : 'out of stock'} today. '
            'Pick another this time. It stays your usual.',
      ));
    }

    if (widget.open) children.add(_expanded(t, picked, options, rememberedId, storeName));

    return Container(
      decoration: cardDecoration,
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );
  }

  // Sold by weight: the stepper is pounds, stepping through the store's
  // weights (else 0.25 lb). Otherwise a count, clamped to the store cap.
  Widget _quantityRow(MealioTheme t, Product picked) {
    final key = _item.key;
    final byWeight = picked.soldByWeight ?? false;
    final range = byWeight ? _s.weightRange(key) : null;
    final lb = byWeight ? _s.weight(key) : 0.0;
    final q = _s.quantity(key);
    final atMin = range != null ? lb <= range.min : q <= 1;
    final atMax = range != null ? lb >= range.max : q >= _s.maxQuantity(key);
    void step(int dir) {
      if (byWeight) {
        _s.stepWeight(key, dir);
      } else {
        _s.setQuantity(key, q + dir);
      }
    }

    final value = byWeight ? lbText(lb) : '$q';
    return Padding(
      padding: const EdgeInsets.only(left: 58, right: 12, bottom: 10),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(byWeight ? 'Weight' : 'Quantity', style: t.style(size: 12, height: 17 / 12, color: t.muted)),
          ),
          _stepButton(t, '−', 'Less ${_item.ingredient}', !atMin, () => step(-1)),
          const SizedBox(width: 4),
          Semantics(
            container: true,
            label: byWeight ? 'Weight $value' : 'Quantity $value',
            excludeSemantics: true,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: byWeight ? 64 : 28),
              child: Text(value, textAlign: TextAlign.center, style: t.style(size: 16, weight: FontWeight.w700)),
            ),
          ),
          const SizedBox(width: 4),
          _stepButton(t, '+', 'More ${_item.ingredient}', !atMax, () => step(1)),
        ],
      ),
    );
  }

  Widget _stepButton(MealioTheme t, String glyph, String label, bool inBounds, VoidCallback onTap) {
    final enabled = inBounds && !widget.disabled;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      onTap: enabled ? onTap : null,
      excludeSemantics: true,
      child: Opacity(
        opacity: inBounds ? 1 : 0.4,
        child: Material(
          color: t.surface,
          borderRadius: BorderRadius.circular(10),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: enabled ? onTap : null,
            child: SizedBox(
              width: 44,
              height: 44,
              child: Center(child: Text(glyph, style: t.style(size: 20, weight: FontWeight.w600))),
            ),
          ),
        ),
      ),
    );
  }

  Widget _expanded(MealioTheme t, Product? picked, List<Product> options, String? rememberedId, String storeName) {
    final prefs = picked?.preferences ?? const <ProductPreference>[];
    final selPref = _s.preferenceId(_item.key);
    final searchLabel = 'Search $storeName for something else';
    final note = _searchNote;
    return Container(
      decoration: BoxDecoration(border: Border(top: BorderSide(color: t.border))),
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: gapped(<Widget>[
          if (options.isNotEmpty)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: gapped(<Widget>[
                    for (final Product o in options) _option(t, o, picked?.id == o.id, o.id == rememberedId),
                  ], 10, axis: Axis.horizontal),
                ),
              ),
            ),
          if (picked != null && prefs.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(
                spacing: 8,
                children: <Widget>[
                  for (final ProductPreference p in prefs)
                    Semantics(
                      inMutuallyExclusiveGroup: true,
                      checked: selPref == p.id,
                      button: true,
                      label: p.label,
                      excludeSemantics: true,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _pick(picked, p.id),
                        // 36 tall to look at, 44 tall to touch.
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Container(
                            constraints: const BoxConstraints(minHeight: 36),
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            decoration: BoxDecoration(
                              color: selPref == p.id ? t.accent : t.surface,
                              borderRadius: BorderRadius.circular(18),
                            ),
                            child: Center(
                              widthFactor: 1,
                              heightFactor: 1,
                              child: Text(p.label,
                                  style: t.style(size: 13, color: selPref == p.id ? t.onAccent : t.text)),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Semantics(
                    label: searchLabel,
                    child: TextField(
                      controller: _query,
                      enabled: !widget.disabled,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _search(),
                      style: t.style(size: 14),
                      cursorColor: t.accent,
                      decoration: InputDecoration(
                        hintText: searchLabel,
                        hintStyle: t.style(size: 14, color: t.muted),
                        isDense: true,
                        filled: true,
                        fillColor: t.surface,
                        constraints: const BoxConstraints(minHeight: 44),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
                        border: OutlineInputBorder(
                          borderSide: BorderSide.none,
                          borderRadius: BorderRadius.circular(t.radius - 2),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Semantics(
                  button: true,
                  label: _searching ? 'Searching' : 'Search',
                  excludeSemantics: true,
                  child: Material(
                    color: t.text,
                    borderRadius: BorderRadius.circular(t.radius - 2),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: _searching || widget.disabled ? null : _search,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 44, minWidth: 76),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          child: Center(
                            widthFactor: 1,
                            child: _searching
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(strokeWidth: 2.5, color: Color(0xFFFFFFFF)),
                                  )
                                : Text('Search',
                                    style: t.style(size: 14, weight: FontWeight.w600, color: const Color(0xFFFFFFFF))),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (note != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(note, style: t.style(size: 12, height: 17 / 12, color: t.muted)),
            ),
        ], 12),
      ),
    );
  }

  Widget _option(MealioTheme t, Product o, bool sel, bool usual) {
    final price = o.outOfStock ? 'Out of stock' : priceText(o);
    final tag = usual ? 'Your usual' : (o.badge == 'popular' ? 'Popular' : null);
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: sel,
      button: true,
      label: <String>[o.name, if (price.isNotEmpty) price, if (tag != null) tag].join(', '),
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _pick(o),
        child: Container(
          width: 136,
          margin: EdgeInsets.all(sel ? 0 : 1),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: t.background,
            borderRadius: BorderRadius.circular(t.radius),
            border: Border.all(color: sel ? t.accent : t.border, width: sel ? 2 : 1),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: gapped(<Widget>[
              ProductThumb(theme: t, product: o, big: true),
              Text(o.name,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: t.style(
                      size: 13, height: 17 / 13, weight: FontWeight.w500, color: o.outOfStock ? t.muted : t.text)),
              Text(price, style: t.style(size: 13, weight: FontWeight.w600)),
              if (tag != null)
                Text(tag, style: t.style(size: 11, weight: FontWeight.w700, color: usual ? t.accent : t.muted)),
            ], 6),
          ),
        ),
      ),
    );
  }

  static Widget _box(MealioTheme t, {required bool on, required bool disabled}) {
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: on ? t.accent : null,
        borderRadius: BorderRadius.circular(7),
        border: on ? null : Border.all(color: disabled ? t.border : t.muted, width: 2),
      ),
      alignment: Alignment.center,
      child: on ? Text('✓', style: t.style(size: 14, weight: FontWeight.w800, color: t.onAccent)) : null,
    );
  }
}
