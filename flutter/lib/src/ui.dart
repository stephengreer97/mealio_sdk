// The drop-in's words, prices and sheet options, resolved from what the partner
// set beside the theme. Mirrors MealioUi in
// packages/react-native/src/MealioProvider.tsx.

import 'package:flutter/widgets.dart';

import 'protocol.dart';
import 'strings.dart';
import 'theme.dart';

/// How prices read. Set it with `formatMoney`, beside the theme.
typedef MealioMoneyFormat = String Function(double amount);

/// How tall the sheet is: [auto], [full], or [MealioSheetHeight.fraction].
@immutable
class MealioSheetHeight {
  const MealioSheetHeight._(this.fraction, {this.square = false});

  /// A share of the screen, clamped to 0.5..1. The top corners stay round.
  factory MealioSheetHeight.fraction(double fraction) =>
      MealioSheetHeight._(fraction.clamp(0.5, 1.0).toDouble());

  /// The sheet's own tall height.
  static const MealioSheetHeight auto = MealioSheetHeight._(0.94);

  /// Fills the screen, with square corners.
  static const MealioSheetHeight full = MealioSheetHeight._(1, square: true);

  /// The share of the screen the sheet takes.
  final double fraction;

  /// True when the top corners are square.
  final bool square;

  @override
  bool operator ==(Object other) =>
      other is MealioSheetHeight && other.fraction == fraction && other.square == square;

  @override
  int get hashCode => Object.hash(fraction, square);
}

/// How the sheet looks and behaves. Set it with `sheet`, beside the theme.
@immutable
class MealioSheetOptions {
  const MealioSheetOptions({this.showTotal = true, this.height = MealioSheetHeight.auto, this.logo});

  /// Show the list total and the done screen prices. Options keep their own
  /// prices.
  final bool showTotal;

  final MealioSheetHeight height;

  /// Your logo, shown at the top of the sheet.
  final ImageProvider<Object>? logo;

  @override
  bool operator ==(Object other) =>
      other is MealioSheetOptions && other.showTotal == showTotal && other.height == height && other.logo == logo;

  @override
  int get hashCode => Object.hash(showTotal, height, logo);
}

/// A button of your own on the done screen, like "Back to meal plan". It
/// becomes the main button and Done turns quiet. Tapping it closes the sheet,
/// then calls [onPress].
@immutable
class MealioDoneAction {
  const MealioDoneAction({required this.label, required this.onPress});

  final String label;
  final void Function(AddResult result) onPress;
}

/// The words, prices and sheet options in force.
@immutable
class MealioUi {
  const MealioUi({Map<String, String>? strings, MealioMoneyFormat? formatMoney, this.sheet = const MealioSheetOptions()})
      : _strings = strings,
        _formatMoney = formatMoney;

  /// What is in force at `context`, set by the nearest `MealioThemeScope`,
  /// then `MealioScope`, then `MealioCart.configure`. Each setting falls back
  /// on its own.
  static MealioUi of(BuildContext context) {
    final look = MealioLook.of(context);
    return MealioUi(
      strings: look.strings,
      formatMoney: look.formatMoney,
      sheet: look.sheet ?? const MealioSheetOptions(),
    );
  }

  final Map<String, String>? _strings;
  final MealioMoneyFormat? _formatMoney;
  final MealioSheetOptions sheet;

  /// True when the partner set `formatMoney`, so prices are built from
  /// numbers, not the store's text.
  bool get customMoney => _formatMoney != null;

  /// The text for a key, filled in. See [mealioDefaultStrings] for the keys.
  String tr(String key, [Map<String, Object?> vars = const <String, Object?>{}]) =>
      mealioFillText(_strings?[key] ?? mealioDefaultStrings[key] ?? key, vars);

  /// `base_one` for 1, `base_other` otherwise. `count` is filled in for you.
  String plural(String base, int count, [Map<String, Object?> vars = const <String, Object?>{}]) =>
      tr('${base}_${count == 1 ? 'one' : 'other'}', <String, Object?>{'count': count, ...vars});

  /// A price, as the partner wants it read. Defaults to [mealioMoney].
  String money(double amount) => (_formatMoney ?? mealioMoney)(amount);
}
