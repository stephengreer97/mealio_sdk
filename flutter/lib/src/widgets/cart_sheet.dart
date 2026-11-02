// 0.1 compatibility: the list for an already prepared cart, with an add
// button and the done screen. New integrations use MealioCartButton or
// MealioCartFlow, which also prepare the cart and host the store sign-in.

import 'package:flutter/material.dart';

import '../cart_session.dart';
import '../errors.dart';
import '../protocol.dart';
import '../theme.dart';
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
    final t = theme ?? MealioTheme.of(context);
    final storeName = session.storeName ?? storeLabel(session.store);
    AddResult? added;
    final r = await Navigator.of(context, rootNavigator: true).push<AddResult>(
      MealioSheetRoute<AddResult>(
        builder: (BuildContext sheetContext) => SheetFrame(
          theme: t,
          title: 'Your $storeName list',
          onClose: () => Navigator.of(sheetContext).pop(added),
          child: MealioCartSheet(
            session: session,
            theme: t,
            // ignore: deprecated_member_use_from_same_package
            onOpenStoreCart: onOpenStoreCart,
            onAdded: (AddResult a) => added = a,
            onDone: (AddResult a) => Navigator.of(sheetContext).pop(a),
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

  Future<void> _add() async {
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
        _error = e.message.isEmpty ? 'Could not add to your cart.' : e.message;
        _adding = false;
      });
      widget.onError?.call(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme ?? MealioTheme.of(context);
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
