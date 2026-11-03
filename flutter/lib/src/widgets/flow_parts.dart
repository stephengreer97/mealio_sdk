// Pieces the drop-in sheets share: the sheet route and frame, the header,
// the loading, done and error screens. Mirrors the pieces in
// packages/react-native/src/MealioCartFlow.tsx. Not exported.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../cart_session.dart';
import '../client.dart';
import '../protocol.dart';
import '../theme.dart';

/// Puts `children` in a list with `gap` between each.
List<Widget> gapped(List<Widget> children, double gap, {Axis axis = Axis.vertical}) {
  final out = <Widget>[];
  for (var i = 0; i < children.length; i += 1) {
    if (i > 0) out.add(axis == Axis.vertical ? SizedBox(height: gap) : SizedBox(width: gap));
    out.add(children[i]);
  }
  return out;
}

String plural(int n, String word) => '$n $word${n == 1 ? '' : 's'}';

/// "H-E-B" for "heb", "Price Chopper" for "price_chopper".
String storeLabel(String id) {
  const known = <String, String>{
    'heb': 'H-E-B',
    'aldi': 'ALDI',
    'kroger': 'Kroger',
    'safeway': 'Safeway',
    'wegmans': 'Wegmans',
  };
  final k = known[id];
  if (k != null) return k;
  return id
      .replaceAll('_', ' ')
      .replaceAllMapped(RegExp(r'\b\w'), (Match m) => m.group(0)!.toUpperCase());
}

/// Gives a TextField what it needs when the app has no Material
/// localizations (a CupertinoApp or a bare WidgetsApp).
Widget withMaterialDefaults(BuildContext context, Widget child) {
  if (Localizations.of<MaterialLocalizations>(context, MaterialLocalizations) != null) return child;
  return Localizations.override(
    context: context,
    locale: Localizations.maybeLocaleOf(context) ?? const Locale('en'),
    delegates: const <LocalizationsDelegate<Object?>>[DefaultMaterialLocalizations.delegate],
    child: child,
  );
}

/// The modal route every Mealio sheet uses: a scrim, the sheet sliding up
/// from the bottom. Built on PopupRoute so it needs nothing from Material.
class MealioSheetRoute<T> extends PopupRoute<T> {
  MealioSheetRoute({required this.builder, super.settings});

  final WidgetBuilder builder;

  @override
  Color? get barrierColor => const Color(0x59000000);

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Close';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 300);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) =>
      builder(context);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return SlideTransition(
      position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
          .animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
      child: child,
    );
  }
}

/// The sheet: 94% of the screen, rounded top, grabber, header, body. The
/// body shrinks above the keyboard.
class SheetFrame extends StatelessWidget {
  const SheetFrame({
    super.key,
    required this.theme,
    required this.title,
    this.kicker,
    required this.onClose,
    required this.child,
  });

  final MealioTheme theme;
  final String title;
  final String? kicker;
  final VoidCallback onClose;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = theme;
    final mq = MediaQuery.of(context);
    final height = mq.size.height * 0.94;
    return Align(
      alignment: Alignment.bottomCenter,
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: Material(
          color: t.background,
          clipBehavior: Clip.antiAlias,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          child: withMaterialDefaults(
            context,
            Padding(
              padding: EdgeInsets.only(bottom: math.max(0, mq.viewInsets.bottom)),
              child: MediaQuery.removeViewInsets(
                context: context,
                removeBottom: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Center(
                      child: Container(
                        margin: const EdgeInsets.only(top: 8),
                        width: 36,
                        height: 5,
                        decoration: BoxDecoration(color: t.border, borderRadius: BorderRadius.circular(3)),
                      ),
                    ),
                    SheetHeader(theme: t, kicker: kicker, title: title, onClose: onClose),
                    Expanded(child: child),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class SheetHeader extends StatelessWidget {
  const SheetHeader({super.key, required this.theme, this.kicker, required this.title, required this.onClose});

  final MealioTheme theme;
  final String? kicker;
  final String title;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final t = theme;
    final k = kicker;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (k != null && k.isNotEmpty)
                  Text(k,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.style(size: 13, weight: FontWeight.w500, color: t.muted)),
                Semantics(
                  header: true,
                  child: Text(title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: t.style(size: 22, height: 28 / 22, weight: FontWeight.w700)),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Semantics(
            button: true,
            label: 'Close',
            excludeSemantics: true,
            child: Material(
              color: t.surface,
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onClose,
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: Center(child: Text('✕', style: t.style(size: 16))),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The accent call to action, 52 tall.
class Cta extends StatelessWidget {
  const Cta({
    super.key,
    required this.theme,
    required this.label,
    this.onTap,
    this.busy = false,
    this.quiet = false,
  });

  final MealioTheme theme;
  final String label;
  final VoidCallback? onTap;
  final bool busy;
  final bool quiet;

  @override
  Widget build(BuildContext context) {
    final t = theme;
    final off = onTap == null || busy;
    return Semantics(
      button: true,
      enabled: !off,
      label: busy ? 'Adding' : label,
      excludeSemantics: true,
      child: Opacity(
        opacity: off ? 0.5 : 1,
        child: Material(
          color: quiet ? t.surface : t.accent,
          borderRadius: BorderRadius.circular(t.radius),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: off ? null : onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 52),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Center(
                  child: busy
                      ? SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2.5, color: t.onAccent),
                        )
                      : Text(
                          label,
                          textAlign: TextAlign.center,
                          style: t.style(size: 16, weight: FontWeight.w700, color: quiet ? t.text : t.onAccent),
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A product picture on white, or a surface-colored box.
class ProductThumb extends StatelessWidget {
  const ProductThumb({super.key, required this.theme, required this.product, this.dim = false, this.big = false});

  final MealioTheme theme;
  final Product? product;
  final bool dim;
  final bool big;

  @override
  Widget build(BuildContext context) {
    final t = theme;
    final url = product?.imageUrl;
    final placeholder = Container(color: t.surface);
    final Widget inner = url == null || url.isEmpty
        ? placeholder
        : Container(
            color: const Color(0xFFFFFFFF),
            child: Image.network(
              url,
              fit: BoxFit.contain,
              excludeFromSemantics: true,
              errorBuilder: (BuildContext context, Object error, StackTrace? stack) => placeholder,
            ),
          );
    return Opacity(
      opacity: dim ? 0.45 : 1,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(width: big ? double.infinity : 48, height: big ? 72 : 48, child: inner),
      ),
    );
  }
}

/// The amber note box.
class WarnBox extends StatelessWidget {
  const WarnBox({super.key, required this.theme, required this.text, this.margin = EdgeInsets.zero});

  final MealioTheme theme;
  final String text;
  final EdgeInsets margin;

  @override
  Widget build(BuildContext context) {
    final t = theme;
    return Container(
      margin: margin,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: t.warnBackground, borderRadius: BorderRadius.circular(10)),
      child: Text(text, style: t.style(size: 13, height: 18 / 13, color: t.warnText)),
    );
  }
}

class _StepDef {
  const _StepDef(this.steps, this.label);
  final List<MealioStep> steps;
  final String Function(int n, String store) label;
}

final List<_StepDef> _loadingSteps = <_StepDef>[
  _StepDef(
    const <MealioStep>[MealioStep.connecting, MealioStep.checkingSignIn, MealioStep.signingIn],
    (int n, String store) => 'Checking your $store sign-in',
  ),
  _StepDef(const <MealioStep>[MealioStep.searching], (int n, String store) => 'Finding your ${plural(n, 'ingredient')}'),
];

/// Progress steps and three skeleton cards.
class LoadingView extends StatelessWidget {
  const LoadingView({super.key, required this.theme, required this.step, required this.storeName, required this.count});

  final MealioTheme theme;
  final MealioStep step;
  final String storeName;
  final int count;

  @override
  Widget build(BuildContext context) {
    final t = theme;
    final at = _loadingSteps.indexWhere((_StepDef d) => d.steps.contains(step));
    Widget dot(int i) {
      if (i < at) {
        return Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(color: t.accent, shape: BoxShape.circle),
          alignment: Alignment.center,
          child: Text('✓', style: t.style(size: 13, weight: FontWeight.w800, color: t.onAccent)),
        );
      }
      if (i == at) {
        return SizedBox(
          width: 24,
          height: 24,
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: CircularProgressIndicator(strokeWidth: 2.5, color: t.accent),
          ),
        );
      }
      return Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: t.border, width: 2)),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: gapped(<Widget>[
          Text('Checking prices and stock at $storeName.', style: t.style(size: 14, color: t.muted)),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: gapped(<Widget>[
                for (var i = 0; i < _loadingSteps.length; i += 1)
                  Semantics(
                    liveRegion: i == at,
                    child: Row(
                      children: <Widget>[
                        dot(i),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _loadingSteps[i].label(count, storeName),
                            style: t.style(
                              size: 15,
                              weight: i == at ? FontWeight.w700 : FontWeight.w400,
                              color: i > at ? t.muted : t.text,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ], 18),
            ),
          ),
          for (var i = 0; i < 3; i += 1)
            ExcludeSemantics(
              child: Container(
                height: 72,
                decoration: BoxDecoration(color: t.surface, borderRadius: BorderRadius.circular(t.radius + 2)),
              ),
            ),
        ], 12),
      ),
    );
  }
}

/// "0.75 lb", "1 lb".
String lbText(double lb) {
  var n = lb.toStringAsFixed(2);
  if (n.contains('.')) n = n.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  return '$n lb';
}

/// "A, B or C".
String listOr(List<String> xs) {
  if (xs.length <= 1) return xs.isEmpty ? '' : xs.first;
  return '${xs.sublist(0, xs.length - 1).join(', ')} or ${xs.last}';
}

/// The price as a row shows it. Sold by the pound: "\$9.99/lb est.".
String priceText(Product p) {
  final perLb = p.pricePerLb;
  if ((p.soldByWeight ?? false) && perLb != null) return '${mealioMoney(perLb)}/lb est.';
  return '${p.price ?? ''}${p.estimated ? ' est.' : ''}'.trim();
}

String reasonText(String r) {
  if (r == 'not_confirmed') return 'not confirmed in your cart';
  if (r == 'weight_not_supported') return 'sold by weight, which this store cannot take here';
  if (RegExp('stock').hasMatch(r)) return 'out of stock';
  if (RegExp('timeout|no_answer').hasMatch(r)) return 'the store did not answer';
  return 'the store refused it';
}

/// The finished run. What the store took, row by row (image, product, the
/// recipe line, amount, price), then what was left out. No total unless every
/// added item has a price. No open-cart button: the user's next step is the
/// store's own app or site, not ours.
class DoneView extends StatefulWidget {
  const DoneView({
    super.key,
    required this.theme,
    required this.session,
    required this.result,
    required this.storeName,
    required this.onDone,
    this.extra,
  });

  final MealioTheme theme;
  final CartSession session;
  final AddResult result;
  final String storeName;
  final VoidCallback onDone;

  /// An extra button above Done (MealioCartSheet's deprecated "Open store cart").
  final Widget? extra;

  @override
  State<DoneView> createState() => _DoneViewState();
}

class _DoneViewState extends State<DoneView> {
  // "Left out this time" opens on its own when something failed.
  late bool _open = widget.result.failed.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    final r = widget.result;
    final cart = widget.session;
    final n = r.added.length;
    final sum = cart.addedTotal(r);
    final left = _leftOut(cart, r, widget.storeName);
    final subtitle = <String>[
      if (sum.total != null) '${sum.estimated ? 'about ' : ''}${mealioMoney(sum.total!)}' else 'Prices at checkout',
    ].join(' · ');
    final title = n > 0 ? '${plural(n, 'item')} added' : 'Nothing was added';
    final small = t.style(size: 12, height: 17 / 12, color: t.muted);
    final cardRadius = BorderRadius.circular(t.radius + 2);
    final labels = left.map((_LeftOut x) => x.label).join(', ');

    final banner = Semantics(
      container: true,
      liveRegion: true,
      label: n > 0 ? '$title, $subtitle' : '$title. Your cart did not change.',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        decoration: BoxDecoration(
          color: n > 0 ? t.accent.withAlpha(0x1A) : t.warnBackground,
          borderRadius: cardRadius,
        ),
        child: Row(
          children: <Widget>[
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: n > 0 ? t.accent : t.warnText, shape: BoxShape.circle),
              alignment: Alignment.center,
              child: Icon(n > 0 ? Icons.check : Icons.priority_high, size: 20, color: t.onAccent),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title, style: t.style(size: 15, weight: FontWeight.w700, color: n > 0 ? t.text : t.warnText)),
                  Opacity(
                    opacity: 0.85,
                    child: Text(
                      n > 0 ? subtitle : 'Your cart did not change.',
                      style: t.style(size: 13, height: 18 / 13, color: n > 0 ? t.text : t.warnText),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    BoxDecoration card() => BoxDecoration(
          color: t.background,
          borderRadius: cardRadius,
          border: Border.all(color: t.border),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: gapped(<Widget>[
                banner,
                if (n > 0)
                  Container(
                    clipBehavior: Clip.antiAlias,
                    decoration: card(),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        for (var i = 0; i < n; i += 1)
                          _AddedRow(key: ValueKey<String>(r.added[i].key), theme: t, session: cart, item: r.added[i], first: i == 0),
                      ],
                    ),
                  ),
                if (left.isNotEmpty)
                  Container(
                    clipBehavior: Clip.antiAlias,
                    decoration: card(),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Semantics(
                          button: true,
                          expanded: _open,
                          label: 'Left out this time: $labels',
                          excludeSemantics: true,
                          child: Material(
                            type: MaterialType.transparency,
                            child: InkWell(
                              onTap: () => setState(() => _open = !_open),
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(minHeight: 56),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
                                  child: Row(
                                    children: <Widget>[
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: <Widget>[
                                            Text('Left out this time', style: t.style(size: 14, weight: FontWeight.w600)),
                                            if (!_open)
                                              Text(_sentence(labels),
                                                  maxLines: 2, overflow: TextOverflow.ellipsis, style: small),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Icon(_open ? Icons.expand_less : Icons.expand_more, size: 22, color: t.muted),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (_open)
                          for (final _LeftOut x in left)
                            Semantics(
                              key: ValueKey<String>('left-${x.key}'),
                              container: true,
                              label: '${x.label}, ${x.why}',
                              excludeSemantics: true,
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
                                decoration: BoxDecoration(border: Border(top: BorderSide(color: t.border))),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Text(_sentence(x.label),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: t.style(size: 14, weight: FontWeight.w500)),
                                    const SizedBox(height: 2),
                                    Text(x.why, style: x.failed ? small.copyWith(color: t.warnText) : small),
                                  ],
                                ),
                              ),
                            ),
                      ],
                    ),
                  ),
              ], 16),
            ),
          ),
        ),
        Footer(
          theme: t,
          border: false,
          gap: 10,
          children: <Widget>[
            if (widget.extra != null) widget.extra!,
            Cta(theme: t, label: 'Done', onTap: widget.onDone),
            Text('Cart by Mealio', textAlign: TextAlign.center, style: small),
          ],
        ),
      ],
    );
  }
}

/// One line the store took: 44px image (or initials), product, the recipe
/// line, an amount pill and the price.
class _AddedRow extends StatelessWidget {
  const _AddedRow({super.key, required this.theme, required this.session, required this.item, required this.first});

  final MealioTheme theme;
  final CartSession session;
  final AddedItem item;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final t = theme;
    final product = session.selected(item.key);
    final image = _nonEmpty(item.imageUrl) ?? _nonEmpty(product?.imageUrl);
    String line = _nonEmpty(item.ingredient) ?? '';
    if (line.isEmpty) {
      for (final CartItem i in session.items) {
        if (i.key == item.key) line = i.ingredient;
      }
    }
    final lb = item.weightLb;
    final amount = lb != null ? lbText(lb) : '×${item.quantity}';
    final p = session.addedPrice(item);
    final price = p == null ? '' : '${p.estimated ? 'about ' : ''}${mealioMoney(p.amount)}';
    final spoken = <String>[
      item.name,
      if (line.isNotEmpty) 'for $line',
      if (lb != null) '${lbText(lb).replaceFirst(' lb', '')} pounds' else 'quantity ${item.quantity}',
      if (price.isNotEmpty) price,
    ].join(', ');
    final small = t.style(size: 12, height: 17 / 12, color: t.muted);
    final initials = Container(
      color: t.surface,
      alignment: Alignment.center,
      child: Text(_monogram(item.name), style: t.style(size: 13, weight: FontWeight.w700, color: t.muted)),
    );
    return Semantics(
      container: true,
      label: spoken,
      excludeSemantics: true,
      child: Container(
        constraints: const BoxConstraints(minHeight: 68),
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
        decoration: first ? null : BoxDecoration(border: Border(top: BorderSide(color: t.border))),
        child: Row(
          children: <Widget>[
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 44,
                height: 44,
                child: image == null
                    ? initials
                    : Container(
                        color: const Color(0xFFFFFFFF),
                        child: Image.network(
                          image,
                          fit: BoxFit.contain,
                          excludeFromSemantics: true,
                          errorBuilder: (BuildContext context, Object error, StackTrace? stack) => initials,
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.style(size: 14, height: 19 / 14, weight: FontWeight.w600)),
                  if (line.isNotEmpty) Text(line, maxLines: 1, overflow: TextOverflow.ellipsis, style: small),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 8),
                  decoration: BoxDecoration(color: t.surface, borderRadius: BorderRadius.circular(999)),
                  child: Text(amount, style: t.style(size: 12, weight: FontWeight.w700)),
                ),
                if (price.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(price, style: small),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _LeftOut {
  const _LeftOut({required this.key, required this.label, required this.why, required this.failed});
  final String key;
  final String label;
  final String why;
  final bool failed;
}

/// Everything the store did not take this run: unchecked, skipped, or failed
/// (with its reason).
List<_LeftOut> _leftOut(CartSession cart, AddResult result, String storeName) {
  CartItem? item(String key) {
    for (final CartItem i in cart.items) {
      if (i.key == key) return i;
    }
    return null;
  }

  final out = <_LeftOut>[];
  for (final FailedItem f in result.failed) {
    out.add(_LeftOut(
      key: f.key,
      label: _nonEmpty(item(f.key)?.ingredient) ?? f.name,
      why: _sentence('${f.name}: ${reasonText(f.reason)}'),
      failed: true,
    ));
  }
  for (final SkippedItem x in result.skipped) {
    final it = item(x.key);
    final why = it?.status == ItemStatus.unavailable
        ? 'Not found at $storeName'
        : x.reason == 'preference_required'
            ? 'Needed an option chosen'
            : x.reason == 'deselected'
                ? 'Unchecked this time'
                : 'Not chosen';
    out.add(_LeftOut(key: x.key, label: _nonEmpty(it?.ingredient) ?? x.key, why: why, failed: false));
  }
  return out;
}

String? _nonEmpty(String? s) => s == null || s.isEmpty ? null : s;

/// First letter up: "Corn tortillas, chipotle peppers".
String _sentence(String x) => x.isEmpty ? x : x[0].toUpperCase() + x.substring(1);

/// Two letters for an image-less product tile: "Fresh Yellow Onion" -> "FY".
String _monogram(String name) {
  final w = name.replaceAll(RegExp('[^A-Za-z0-9 ]+'), ' ').trim().split(RegExp(r'\s+')).where((String x) => x.isNotEmpty).toList();
  return ((w.isNotEmpty ? w[0][0] : '') + (w.length > 1 ? w[1][0] : '')).toUpperCase();
}

/// The bar under a sheet's list.
class Footer extends StatelessWidget {
  const Footer({super.key, required this.theme, required this.children, this.border = true, this.gap = 8});

  final MealioTheme theme;
  final List<Widget> children;

  /// A rule above the bar. The done screen has none.
  final bool border;
  final double gap;

  @override
  Widget build(BuildContext context) {
    final bottom = math.max(28.0, MediaQuery.viewPaddingOf(context).bottom + 12);
    return Container(
      padding: EdgeInsets.fromLTRB(16, 12, 16, bottom),
      decoration: BoxDecoration(
        color: theme.background,
        border: border ? Border(top: BorderSide(color: theme.border)) : null,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: gapped(children, gap),
      ),
    );
  }
}

/// The message, Try again, Close.
class ErrorView extends StatelessWidget {
  const ErrorView({
    super.key,
    required this.theme,
    required this.code,
    required this.message,
    required this.onRetry,
    required this.onClose,
  });

  final MealioTheme theme;
  final String? code;
  final String? message;
  final VoidCallback onRetry;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final t = theme;
    final msg = code == 'login_cancelled'
        ? 'Sign-in was closed before it finished.'
        : (message == null || message!.isEmpty ? 'Something went wrong.' : message!);
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Semantics(liveRegion: true, child: Text(msg, style: t.style(size: 15))),
          const Spacer(),
          Cta(theme: t, label: 'Try again', onTap: onRetry),
          const SizedBox(height: 12),
          Cta(theme: t, label: 'Close', onTap: onClose, quiet: true),
        ],
      ),
    );
  }
}
