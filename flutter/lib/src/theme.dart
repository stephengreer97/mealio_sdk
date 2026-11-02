// The drop-in's look, set once with MealioCart.configure(theme: ...) or
// MealioScope(theme: ...). Partners match their brand with a handful of
// values; everything else follows from them. Mirrors
// packages/react-native/src/theme.ts.

import 'package:flutter/widgets.dart';

import 'webview_host.dart';

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
    this.radius = 14,
    this.fontFamily,
    this.warnBackground = const Color(0xFFFFF4E5),
    this.warnText = const Color(0xFF7A4A06),
  });

  /// The defaults.
  static const MealioTheme standard = MealioTheme();

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
      radius: radius ?? this.radius,
      fontFamily: fontFamily ?? this.fontFamily,
      warnBackground: warnBackground ?? this.warnBackground,
      warnText: warnText ?? this.warnText,
    );
  }

  /// The theme in force at `context`: the nearest [MealioThemeScope], then
  /// the mounted MealioScope's theme, then the one given to
  /// `MealioCart.configure`, then the defaults.
  static MealioTheme of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<MealioThemeScope>();
    return scope?.theme ?? WebViewHost.current?.theme ?? configured ?? standard;
  }

  /// Set by `MealioCart.configure(theme: ...)`.
  static MealioTheme? configured;

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

/// Provides a [MealioTheme] to the Mealio widgets below it.
class MealioThemeScope extends InheritedWidget {
  const MealioThemeScope({super.key, required this.theme, required super.child});

  final MealioTheme theme;

  @override
  bool updateShouldNotify(MealioThemeScope oldWidget) => theme != oldWidget.theme;
}

/// "$31.20" style money, two decimals.
String mealioMoney(double n) => '\$${n.toStringAsFixed(2)}';
