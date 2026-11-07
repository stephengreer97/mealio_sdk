// Change the user's store outside a cart: the same store list and the same
// zip and location screens as the cart sheet. Mirrors
// packages/react-native/src/MealioStoreSettings.tsx.

import 'dart:async';

import 'package:flutter/material.dart';

import '../mealio_cart.dart';
import '../protocol.dart';
import '../theme.dart';
import '../ui.dart';
import 'cart_flow.dart';
import 'flow_parts.dart';
import 'location_picker.dart';

/// Reads the user's store. The default is
/// `MealioCart.instance.storePreferences`.
typedef LoadPreferences = Future<StorePreferences> Function();

/// The store settings sheet. Use [MealioStoreSettings.show], or
/// `MealioCart.instance.openStoreSettings`, which calls it.
///
/// The widget itself is the sheet's content (grabber, header, body), for apps
/// that present it in a route of their own.
class MealioStoreSettings extends StatefulWidget {
  const MealioStoreSettings({
    super.key,
    required this.onClose,
    this.onChange,
    this.theme,
    this.loadStores,
    this.loadPreferences,
    this.loadLocations,
    this.saveStore,
  });

  /// The user closed the sheet.
  final VoidCallback onClose;

  /// Called each time the user's store changes.
  final ValueChanged<StorePreferences>? onChange;

  /// Defaults to `MealioTheme.of(context)`.
  final MealioTheme? theme;

  /// Replaces `MealioCart.instance.stores`, for tests and custom clients.
  final LoadStores? loadStores;

  /// Replaces `MealioCart.instance.storePreferences`, for tests and custom
  /// clients.
  final LoadPreferences? loadPreferences;

  /// Replaces `MealioCart.instance.storeLocations`, for tests and custom
  /// clients.
  final LoadLocations? loadLocations;

  /// Replaces `MealioCart.instance.setStore`, for tests and custom clients.
  final SaveStore? saveStore;

  /// Shows the sheet over the app, for the user to change their store or zip.
  /// Resolves when it closes.
  static Future<void> show(
    BuildContext context, {
    ValueChanged<StorePreferences>? onChange,
    MealioTheme? theme,
    LoadStores? loadStores,
    LoadPreferences? loadPreferences,
    LoadLocations? loadLocations,
    SaveStore? saveStore,
  }) async {
    final carry = mealioCarryScope(context);
    await Navigator.of(context, rootNavigator: true).push<void>(
      MealioSheetRoute<void>(
        barrierLabel: MealioUi.of(context).tr('close'),
        // No theme unless one was passed: the sheet follows the phone in auto.
        builder: (BuildContext sheetContext) => carry(
          MealioStoreSettings(
            theme: theme,
            onChange: onChange,
            loadStores: loadStores,
            loadPreferences: loadPreferences,
            loadLocations: loadLocations,
            saveStore: saveStore,
            onClose: () => Navigator.of(sheetContext).pop(),
          ),
        ),
      ),
    );
  }

  @override
  State<MealioStoreSettings> createState() => _MealioStoreSettingsState();
}

class _MealioStoreSettingsState extends State<MealioStoreSettings> {
  List<StoreInfo>? _stores;
  StorePreferences? _prefs;
  StoreInfo? _picking;
  String? _saving;
  String? _problem;

  /// Set each build, for the calls that finish after it.
  MealioUi _ui = const MealioUi();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ui = MealioUi.of(context);
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final loadStores = widget.loadStores ?? MealioCart.instance.stores;
      final loadPrefs = widget.loadPreferences ?? MealioCart.instance.storePreferences;
      final got = await Future.wait<Object>(<Future<Object>>[loadStores(), loadPrefs()]);
      if (!mounted) return;
      setState(() {
        _stores = got[0] as List<StoreInfo>;
        _prefs = got[1] as StorePreferences;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stores = <StoreInfo>[];
        _problem = problemText(e, _ui.tr('couldNotLoadYourStores'));
      });
    }
  }

  /// Tells the app even if the sheet closed during the save: the store did
  /// change.
  void _changed(StorePreferences next) {
    if (mounted) setState(() => _prefs = next);
    widget.onChange?.call(next);
  }

  Future<void> _choose(StoreInfo store) async {
    // A Kroger family store is a chain: the user still has to say which one.
    if (store.via == 'kroger_api') {
      setState(() => _picking = store);
      return;
    }
    setState(() {
      _saving = store.id;
      _problem = null;
    });
    try {
      final save = widget.saveStore ?? MealioCart.instance.setStore;
      _changed(await save(store.id));
    } catch (e) {
      if (mounted) setState(() => _problem = problemText(e, _ui.tr('couldNotSaveStore')));
    }
    if (mounted) setState(() => _saving = null);
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme ?? MealioTheme.of(context);
    final ui = MealioUi.of(context);
    final picking = _picking;
    final stores = _stores;
    final Widget body;
    if (picking != null) {
      final samePick = _prefs?.defaultStore == picking.id ? _prefs?.location : null;
      body = LocationPicker(
        theme: t,
        store: picking.id,
        storeName: picking.name,
        zip: samePick?.zip,
        current: samePick?.id,
        loadLocations: widget.loadLocations,
        saveStore: widget.saveStore,
        onPicked: (StoreLocation location) {
          _changed(StorePreferences(defaultStore: picking.id, location: location));
          if (mounted) setState(() => _picking = null);
        },
        backLabel: ui.tr('backToStores'),
        onBack: () => setState(() => _picking = null),
      );
    } else if (stores == null) {
      body = Padding(
        padding: const EdgeInsets.all(20),
        child: Align(
          alignment: Alignment.topCenter,
          child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5, color: t.accent)),
        ),
      );
    } else {
      final problem = _problem;
      final prefs = _prefs;
      final location = prefs?.location;
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              children: gapped(<Widget>[
                if (problem != null) Semantics(liveRegion: true, child: Text(problem, style: t.style(size: 15))),
                for (final StoreInfo st in stores)
                  LocationOption(
                    key: ValueKey<String>('mealio-store-${st.id}'),
                    theme: t,
                    title: st.name,
                    subtitle: st.id == prefs?.defaultStore && location != null
                        ? '${location.name}, ${location.address}'
                        : null,
                    selected: st.id == prefs?.defaultStore,
                    busy: _saving == st.id,
                    onTap: _saving == null ? () => unawaited(_choose(st)) : null,
                    trailing: st.id == prefs?.defaultStore ? ui.tr(location != null ? 'change' : 'current') : null,
                  ),
              ], 10),
            ),
          ),
          Footer(theme: t, children: <Widget>[Cta(theme: t, label: ui.tr('done'), onTap: widget.onClose)]),
        ],
      );
    }
    return SheetFrame(
      theme: t,
      title: picking != null
          ? ui.tr('titleLocation', <String, Object?>{'store': picking.name})
          : ui.tr('titleSettings'),
      onClose: widget.onClose,
      child: body,
    );
  }
}
