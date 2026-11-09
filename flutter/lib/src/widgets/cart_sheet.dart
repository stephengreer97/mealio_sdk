// 0.1 compatibility: the list for an already prepared cart, with an add
// button and the done screen. New integrations use MealioCartButton or
// MealioCartFlow, which also prepare the cart and host the store sign-in.

import 'package:flutter/material.dart';

import '../cart_session.dart';
import '../errors.dart';
import '../protocol.dart';
import '../theme.dart';
import '../ui.dart';
import 'cart_list.dart';
import 'flow_parts.dart';

class MealioCartSheet extends StatefulWidget {
  const MealioCartSheet({
    super.key,
    required this.session,
    this.onAdded,
    this.onError,
    this.onDone,
    @Deprecated('The drop-in never opens the store cart') this.onOpenStoreCart,
    this.theme,
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
  @Deprecated('The drop-in never opens the store cart')
  final ValueChanged<String>? onOpenStoreCart;

  /// Defaults to `MealioTheme.of(context)`.
  final MealioTheme? theme;

  /// Shows the sheet over the app. Resolves with the result after the user
  /// taps Done, or null if they close it first.
  static Future<AddResult?> show(
    BuildContext context,
    CartSession session, {
    @Deprecated('The drop-in never opens the store cart') ValueChanged<String>? onOpenStoreCart,
    MealioTheme? theme,
  }) async {
    final storeName = session.storeName ?? storeLabel(session.store);
    AddResult? added;
    final carry = mealioCarryScope(context);
    final r = await Navigator.of(context, rootNavigator: true).push<AddResult>(
      MealioSheetRoute<AddResult>(
        barrierLabel: MealioUi.of(context).tr('close'),
        builder: (BuildContext sheetContext) => carry(
          Builder(
            // No theme unless one was passed: the sheet follows the phone in auto.
            builder: (BuildContext inner) => SheetFrame(
              theme: theme ?? MealioTheme.of(inner),
              title: MealioUi.of(inner).tr('titleList', <String, Object?>{'store': storeName}),
              onClose: () => Navigator.of(sheetContext).pop(added),
              child: MealioCartSheet(
                session: session,
                theme: theme,
                // ignore: deprecated_member_use_from_same_package
                onOpenStoreCart: onOpenStoreCart,
                onAdded: (AddResult a) => added = a,
                onDone: (AddResult a) => Navigator.of(sheetContext).pop(a),
              ),
            ),
          ),
        ),
      ),
    );
    return r ?? added;
  }

  @override
  State<MealioCartSheet> createState() => _MealioCartSheetState();
}

class _MealioCartSheetState extends State<MealioCartSheet> {
  bool _adding = false;
  AddResult? _result;
  String? _error;

  /// Set each build, for the add that fails after it.
  MealioUi _ui = const MealioUi();

  Future<void> _add() async {
    // Two taps before a rebuild add once.
    if (_adding) return;
    setState(() {
      _adding = true;
      _error = null;
    });
    try {
      final r = await widget.session.addToCart();
      if (!mounted) return;
      setState(() {
        _result = r;
        _adding = false;
      });
      widget.onAdded?.call(r);
    } on MealioException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message.isEmpty ? _ui.tr('couldNotAdd') : e.message;
        _adding = false;
      });
      widget.onError?.call(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme ?? MealioTheme.of(context);
    _ui = MealioUi.of(context);
    final s = widget.session;
    final storeName = s.storeName ?? storeLabel(s.store);
    final result = _result;
    if (result != null) {
      // ignore: deprecated_member_use_from_same_package
      final open = widget.onOpenStoreCart;
      final url = result.storeCartUrl;
      return Material(
        color: t.background,
        child: DoneView(
          theme: t,
          session: s,
          result: result,
          storeName: storeName,
          onDone: () => widget.onDone?.call(result),
          extra: open != null && url != null
              ? Cta(theme: t, label: 'Open store cart', quiet: true, onTap: () => open(url))
              : null,
        ),
      );
    }
    final error = _error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (error != null)
          WarnBox(theme: t, text: error, margin: const EdgeInsets.fromLTRB(16, 0, 16, 8)),
        Expanded(
          child: MealioCartList(session: s, storeName: storeName, busy: _adding, onAdd: _add, theme: t),
        ),
      ],
    );
  }
}
