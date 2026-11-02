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

/// What was added, what failed, what was left out, and a Done button.
class DoneView extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final t = theme;
    final r = result;
    String price(String key) {
      final p = session.selected(key);
      return p == null ? '' : priceText(p);
    }

    String ingredient(String key) {
      for (final CartItem i in session.items) {
        if (i.key == key) return i.ingredient;
      }
      return key;
    }

    Widget row(Widget left, Widget right) => Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border, width: 0.5))),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[Expanded(child: left), const SizedBox(width: 12), right],
          ),
        );

    final failed = r.failed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: gapped(<Widget>[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Column(
                    children: gapped(<Widget>[
                      ExcludeSemantics(
                        child: Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(color: t.surface, shape: BoxShape.circle),
                          alignment: Alignment.center,
                          child: Text('✓', style: t.style(size: 28, weight: FontWeight.w800, color: t.accent)),
                        ),
                      ),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          r.added.isNotEmpty
                              ? 'Added ${plural(r.added.length, 'item')} to $storeName'
                              : 'Nothing was added to $storeName',
                          textAlign: TextAlign.center,
                          style: t.style(size: 22, height: 28 / 22, weight: FontWeight.w700),
                        ),
                      ),
                    ], 12),
                  ),
                ),
                if (failed.isNotEmpty)
                  WarnBox(
                    theme: t,
                    margin: const EdgeInsets.symmetric(horizontal: 12),
                    text: '${plural(failed.length, 'item')} could not be added: '
                        '${failed.map((FailedItem f) => '${f.name} (${reasonText(f.reason)})').join(', ')}.',
                  ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    for (final AddedItem a in r.added)
                      row(
                        Text('${a.name}${a.weightLb != null ? ', ${lbText(a.weightLb!)}' : ''}',
                            maxLines: 2, overflow: TextOverflow.ellipsis, style: t.style(size: 14)),
                        Text(price(a.key), style: t.style(weight: FontWeight.w700)),
                      ),
                    for (final SkippedItem x in r.skipped.where((SkippedItem x) => x.reason == 'deselected'))
                      row(
                        Text(ingredient(x.key), style: t.style(size: 14, color: t.muted)),
                        Text('Left out', style: t.style(size: 14, color: t.muted)),
                      ),
                  ],
                ),
              ], 12),
            ),
          ),
        ),
        Footer(
          theme: t,
          children: <Widget>[
            if (extra != null) extra!,
            Cta(theme: t, label: 'Done', onTap: onDone),
          ],
        ),
      ],
    );
  }
}

/// The bar under a sheet's list.
class Footer extends StatelessWidget {
  const Footer({super.key, required this.theme, required this.children});

  final MealioTheme theme;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final bottom = math.max(28.0, MediaQuery.viewPaddingOf(context).bottom + 12);
    return Container(
      padding: EdgeInsets.fromLTRB(16, 12, 16, bottom),
      decoration: BoxDecoration(
        color: theme.background,
        border: Border(top: BorderSide(color: theme.border)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: gapped(children, 8),
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
