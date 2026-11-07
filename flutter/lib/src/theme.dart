// The drop-in's look, set once with MealioCart.configure(theme: ...) or
// MealioScope(theme: ...). Partners match their brand with a handful of
// values; everything else follows from them. Mirrors
// packages/react-native/src/theme.ts.

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/widgets.dart';

import 'events.dart';
import 'ui.dart';
import 'webview_host.dart';

/// Which colors the drop-in uses. `auto` follows the phone.
enum MealioColorScheme { light, dark, auto }

@immutable
class MealioTheme {
  const MealioTheme({
    this.accent = const Color(0xFF1F6B47),
    this.onAccent = const Color(0xFFFFFFFF),
    this.background = const Color(0xFFFFFFFF),
    this.surface = const Color(0xFFF2F1EE),
    this.text = const Color(0xFF1B1B1A),
    this.muted = const Color(0xFF5F5D58),
    this.border = const Color(0xFFE4E2DD),
    double? radius,
    this.fontFamily,
    this.warnBackground = const Color(0xFFFFF4E5),
    this.warnText = const Color(0xFF7A4A06),
  })  : radius = radius ?? 14,
        _radiusSet = radius != null;

  /// A theme for dark mode: the dark defaults, with what you set laid over
  /// them. Pass it as `darkTheme`. `radius` and `fontFamily` carry over from
  /// the light theme unless you set them here.
  const MealioTheme.dark({
    this.accent = const Color(0xFF5FBF8F),
    this.onAccent = const Color(0xFF0E1A14),
    this.background = const Color(0xFF1B1B1A),
    this.surface = const Color(0xFF2A2A28),
    this.text = const Color(0xFFF2F1EE),
    this.muted = const Color(0xFFB4B2AC),
    this.border = const Color(0xFF3A3A37),
    double? radius,
    this.fontFamily,
    this.warnBackground = const Color(0xFF3B2A10),
    this.warnText = const Color(0xFFF5C27A),
  })  : radius = radius ?? 14,
        _radiusSet = radius != null;

  /// The defaults.
  static const MealioTheme standard = MealioTheme();

  /// The dark defaults.
  static const MealioTheme standardDark = MealioTheme.dark();

  /// Buttons, checkmarks, selected rings.
  final Color accent;

  /// Text on the accent color.
  final Color onAccent;

  /// Sheet background.
  final Color background;

  /// Page behind cards, search box, thumbnails.
  final Color surface;
  final Color text;

  /// Secondary text. Keep 4.5:1 against background.
  final Color muted;
  final Color border;

  /// Corner radius of cards and buttons, in logical pixels.
  final double radius;

  /// Whether [radius] was given, so a dark theme can carry over the light one.
  final bool _radiusSet;

  /// Font family for every text, or null for the app's font.
  final String? fontFamily;

  /// Out-of-stock warning colors.
  final Color warnBackground;
  final Color warnText;

  MealioTheme copyWith({
    Color? accent,
    Color? onAccent,
    Color? background,
    Color? surface,
    Color? text,
    Color? muted,
    Color? border,
    double? radius,
    String? fontFamily,
    Color? warnBackground,
    Color? warnText,
  }) {
    return MealioTheme(
      accent: accent ?? this.accent,
      onAccent: onAccent ?? this.onAccent,
      background: background ?? this.background,
      surface: surface ?? this.surface,
      text: text ?? this.text,
      muted: muted ?? this.muted,
      border: border ?? this.border,
      radius: radius ?? (_radiusSet ? this.radius : null),
      fontFamily: fontFamily ?? this.fontFamily,
      warnBackground: warnBackground ?? this.warnBackground,
      warnText: warnText ?? this.warnText,
    );
  }

  /// The colors in force. `auto` follows `platformBrightness`. A dark sheet
  /// takes `radius` and `fontFamily` from `light` unless `dark` sets them.
  static MealioTheme resolve({
    MealioTheme? light,
    MealioTheme? dark,
    MealioColorScheme colorScheme = MealioColorScheme.light,
    Brightness? platformBrightness,
  }) {
    final l = light ?? standard;
    final isDark = colorScheme == MealioColorScheme.dark ||
        (colorScheme == MealioColorScheme.auto && platformBrightness == Brightness.dark);
    if (!isDark) return l;
    final d = dark ?? standardDark;
    return d.copyWith(radius: d._radiusSet ? d.radius : l.radius, fontFamily: d.fontFamily ?? l.fontFamily);
  }

  /// The theme in force at `context`: the nearest [MealioThemeScope], then the
  /// mounted MealioScope, then `MealioCart.configure`, then the defaults. In
  /// `auto` it rebuilds its caller when the phone changes.
  static MealioTheme of(BuildContext context) {
    final look = MealioLook.of(context);
    final scheme = look.colorScheme ?? MealioColorScheme.light;
    return resolve(
      light: look.theme,
      dark: look.darkTheme,
      colorScheme: scheme,
      platformBrightness: scheme == MealioColorScheme.auto
          // Null above the app's MediaQuery.
          ? MediaQuery.maybePlatformBrightnessOf(context) ??
              WidgetsBinding.instance.platformDispatcher.platformBrightness
          : null,
    );
  }

  /// Set by `MealioCart.configure(theme: ...)`.
  static MealioTheme? get configured => MealioLook.configured?.theme;

  TextStyle style({double? size, FontWeight? weight, Color? color, double? height, TextDecoration? decoration}) {
    return TextStyle(
      fontFamily: fontFamily,
      fontSize: size,
      fontWeight: weight,
      color: color ?? text,
      height: height,
      decoration: decoration,
      decorationColor: color ?? text,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MealioTheme &&
      other.accent == accent &&
      other.onAccent == onAccent &&
      other.background == background &&
      other.surface == surface &&
      other.text == text &&
      other.muted == muted &&
      other.border == border &&
      other.radius == radius &&
      other.fontFamily == fontFamily &&
      other.warnBackground == warnBackground &&
      other.warnText == warnText;

  @override
  int get hashCode => Object.hash(
      accent, onAccent, background, surface, text, muted, border, radius, fontFamily, warnBackground, warnText);
}

/// Everything a partner sets once, at one level: `MealioCart.configure`,
/// `MealioScope` or `MealioThemeScope`. Not exported.
@immutable
class MealioLook {
  const MealioLook({
    this.theme,
    this.darkTheme,
    this.colorScheme,
    this.strings,
    this.formatMoney,
    this.sheet,
    this.onEvent,
  });

  /// Set by `MealioCart.configure`.
  static MealioLook? configured;

  final MealioTheme? theme;
  final MealioTheme? darkTheme;
  final MealioColorScheme? colorScheme;
  final Map<String, String>? strings;
  final MealioMoneyFormat? formatMoney;
  final MealioSheetOptions? sheet;
  final MealioEventListener? onEvent;

  /// This level, with `base` filling in what it left unset.
  MealioLook over(MealioLook? base) => base == null
      ? this
      : MealioLook(
          theme: theme ?? base.theme,
          darkTheme: darkTheme ?? base.darkTheme,
          colorScheme: colorScheme ?? base.colorScheme,
          strings: strings ?? base.strings,
          formatMoney: formatMoney ?? base.formatMoney,
          sheet: sheet ?? base.sheet,
          onEvent: onEvent ?? base.onEvent,
        );

  /// What is in force at `context`.
  static MealioLook of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<MealioThemeScope>()?.look ?? const MealioLook();
    return scope.over(WebViewHost.current?.look).over(configured);
  }
}

/// Provides the look to the Mealio widgets below it: [theme] and everything
/// else that can be set beside it. What is left null falls back to
/// `MealioScope`, then `MealioCart.configure`.
class MealioThemeScope extends InheritedWidget {
  const MealioThemeScope({
    super.key,
    this.theme,
    this.darkTheme,
    this.colorScheme,
    this.strings,
    this.formatMoney,
    this.sheet,
    this.onEvent,
    required super.child,
  });

  final MealioTheme? theme;

  /// Colors for dark mode. Only used when [colorScheme] is `dark`, or `auto`
  /// on a phone set to dark. Start from `MealioTheme.dark()`.
  final MealioTheme? darkTheme;

  /// `auto` follows the phone. Defaults to `light`.
  final MealioColorScheme? colorScheme;

  /// Change or translate any word. See `mealioDefaultStrings` for the keys.
  final Map<String, String>? strings;

  /// How prices read. Defaults to "\$12.50".
  final MealioMoneyFormat? formatMoney;

  /// How the sheet looks and behaves.
  final MealioSheetOptions? sheet;

  /// Every step of the sheet, for your analytics. Nothing is sent to Mealio.
  final MealioEventListener? onEvent;

  MealioLook get look => MealioLook(
        theme: theme,
        darkTheme: darkTheme,
        colorScheme: colorScheme,
        strings: strings,
        formatMoney: formatMoney,
        sheet: sheet,
        onEvent: onEvent,
      );

  /// This scope again around `child`. A sheet's route may sit outside it.
  MealioThemeScope around(Widget child) => MealioThemeScope(
        theme: theme,
        darkTheme: darkTheme,
        colorScheme: colorScheme,
        strings: strings,
        formatMoney: formatMoney,
        sheet: sheet,
        onEvent: onEvent,
        child: child,
      );

  // Not onEvent: the sheet reads it when it emits, so an inline listener does
  // not rebuild every Mealio widget on each build.
  @override
  bool updateShouldNotify(MealioThemeScope oldWidget) =>
      theme != oldWidget.theme ||
      darkTheme != oldWidget.darkTheme ||
      colorScheme != oldWidget.colorScheme ||
      !mapEquals(strings, oldWidget.strings) ||
      formatMoney != oldWidget.formatMoney ||
      sheet != oldWidget.sheet;
}

/// Puts the [MealioThemeScope] at `context` around a sheet about to be pushed
/// from there. Call it before the push: a route rebuilds after `context` may
/// be gone.
Widget Function(Widget child) mealioCarryScope(BuildContext context) {
  final scope = context.getInheritedWidgetOfExactType<MealioThemeScope>();
  return (Widget child) => scope?.around(child) ?? child;
}

/// "$31.20" style money, two decimals.
String mealioMoney(double n) => '\$${n.toStringAsFixed(2)}';
