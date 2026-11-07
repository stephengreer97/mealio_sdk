// Which Kroger family store the user shops at: a zip box, then that chain's
// nearby stores. Used in the cart sheet and in store settings. Mirrors
// LocationPicker in packages/react-native/src/MealioCartFlow.tsx. The widgets
// here are not exported.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../errors.dart';
import '../mealio_cart.dart';
import '../protocol.dart';
import '../theme.dart';
import '../ui.dart';
import 'flow_parts.dart';

/// Lists a chain's stores near a zip. The default is
/// `MealioCart.instance.storeLocations`.
typedef LoadLocations = Future<List<StoreLocation>> Function(String store, String zip);

/// Makes a store the user's default. The default is
/// `MealioCart.instance.setStore`.
typedef SaveStore = Future<StorePreferences> Function(String store, {String? locationId});

bool _isZip(String z) => RegExp(r'^\d{5}$').hasMatch(z);

/// What to show for a failed call: the SDK's own message, else `fallback`.
String problemText(Object e, String fallback) => e is MealioException && e.message.isNotEmpty ? e.message : fallback;

/// A zip box, then the chain's stores. A zip the partner or an earlier pick
/// supplied fills the box and searches at once, and the user still taps the
/// store they want.
class LocationPicker extends StatefulWidget {
  const LocationPicker({
    super.key,
    required this.theme,
    required this.store,
    required this.storeName,
    required this.zip,
    required this.current,
    required this.onPicked,
    required this.backLabel,
    required this.onBack,
    this.loadLocations,
    this.saveStore,
  });

  final MealioTheme theme;
  final String store;
  final String storeName;

  /// Fills the zip box.
  final String? zip;

  /// The id of the location the user has now.
  final String? current;

  /// The choice is saved. Called even if this widget has since been removed.
  final ValueChanged<StoreLocation> onPicked;
  final String backLabel;
  final VoidCallback onBack;
  final LoadLocations? loadLocations;
  final SaveStore? saveStore;

  @override
  State<LocationPicker> createState() => _LocationPickerState();
}

class _LocationPickerState extends State<LocationPicker> {
  late final TextEditingController _zip = TextEditingController(text: widget.zip ?? '');
  String? _foundZip;
  List<StoreLocation>? _found;
  bool _busy = false;
  String? _saving;
  String? _problem;
  int _ask = 0;

  /// Set each build, for the calls that finish after it. Empty until then.
  MealioUi _ui = const MealioUi();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ui = MealioUi.of(context);
  }

  @override
  void initState() {
    super.initState();
    _zip.addListener(_onZip);
    final start = widget.zip;
    if (start != null && _isZip(start)) unawaited(_find(start));
  }

  @override
  void dispose() {
    _ask += 1;
    _zip.dispose();
    super.dispose();
  }

  void _onZip() => setState(() {});

  Future<void> _find(String zip) async {
    final id = ++_ask;
    setState(() {
      _busy = true;
      _problem = null;
      _found = null;
    });
    try {
      final load = widget.loadLocations ?? MealioCart.instance.storeLocations;
      final locations = await load(widget.store, zip);
      if (_ask != id) return;
      setState(() {
        _foundZip = zip;
        _found = locations;
        _busy = false;
      });
    } catch (e) {
      if (_ask != id) return;
      setState(() {
        _problem = problemText(e, _ui.tr('couldNotLookUp'));
        _busy = false;
      });
    }
  }

  Future<void> _pick(StoreLocation l) async {
    setState(() {
      _saving = l.id;
      _problem = null;
    });
    final onPicked = widget.onPicked;
    try {
      final save = widget.saveStore ?? MealioCart.instance.setStore;
      await save(widget.store, locationId: l.id);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _problem = problemText(e, _ui.tr('couldNotSaveStore'));
        _saving = null;
      });
      return;
    }
    onPicked(l);
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    final ui = MealioUi.of(context);
    final store = <String, Object?>{'store': widget.storeName};
    final zipCode = ui.tr('zipCode');
    final findStores = ui.tr('findStores');
    final found = _found;
    final problem = _problem;
    final canFind = _isZip(_zip.text) && !_busy;
    void find() => unawaited(_find(_zip.text));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.manual,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            children: gapped(<Widget>[
              Text(ui.tr('zipPrompt', store),
                  style: t.style(size: 14, color: t.muted)),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Semantics(
                      label: zipCode,
                      child: TextField(
                        key: const ValueKey<String>('mealio-zip'),
                        controller: _zip,
                        keyboardType: TextInputType.number,
                        textInputAction: TextInputAction.search,
                        inputFormatters: <TextInputFormatter>[
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(5),
                        ],
                        onSubmitted: (String zip) {
                          if (_isZip(zip)) unawaited(_find(zip));
                        },
                        style: t.style(size: 16),
                        cursorColor: t.accent,
                        decoration: InputDecoration(
                          hintText: zipCode,
                          hintStyle: t.style(size: 16, color: t.muted),
                          isDense: true,
                          filled: true,
                          fillColor: t.surface,
                          constraints: const BoxConstraints(minHeight: 48),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
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
                    enabled: canFind,
                    label: findStores,
                    onTap: canFind ? find : null,
                    excludeSemantics: true,
                    child: Opacity(
                      opacity: canFind ? 1 : 0.5,
                      child: Material(
                        color: t.accent,
                        borderRadius: BorderRadius.circular(t.radius - 2),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          key: const ValueKey<String>('mealio-find-stores'),
                          onTap: canFind ? find : null,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 48),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              child: Center(
                                widthFactor: 1,
                                heightFactor: 1,
                                child: Text(findStores,
                                    style: t.style(size: 16, weight: FontWeight.w700, color: t.onAccent)),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              if (_busy)
                Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2.5, color: t.accent),
                  ),
                ),
              if (problem != null) Semantics(liveRegion: true, child: Text(problem, style: t.style(size: 15))),
              if (found != null && found.isEmpty)
                Text(ui.tr('noStoresNear', <String, Object?>{...store, 'zip': _foundZip}),
                    style: t.style(size: 14, color: t.muted)),
              if (found != null)
                for (final StoreLocation l in found)
                  LocationOption(
                    key: ValueKey<String>('mealio-location-${l.id}'),
                    theme: t,
                    title: l.name,
                    subtitle: l.address,
                    selected: l.id == widget.current,
                    busy: _saving == l.id,
                    onTap: _saving == null ? () => unawaited(_pick(l)) : null,
                    trailing: l.id == widget.current ? ui.tr('current') : null,
                  ),
            ], 10),
          ),
        ),
        Footer(
          theme: t,
          children: <Widget>[
            // Held while saving: the save restarts the cart, so a list
            // reached from here would be gone a moment later.
            Cta(theme: t, label: widget.backLabel, quiet: true, onTap: _saving == null ? widget.onBack : null),
          ],
        ),
      ],
    );
  }
}

/// One choosable row, with a title, an optional line under it, and a status
/// at the end. The chosen one has an accent ring.
class LocationOption extends StatelessWidget {
  const LocationOption({
    super.key,
    required this.theme,
    required this.title,
    this.subtitle,
    required this.selected,
    this.busy = false,
    this.onTap,
    this.trailing,
  });

  final MealioTheme theme;
  final String title;
  final String? subtitle;
  final bool selected;

  /// Shows a spinner in place of [trailing].
  final bool busy;
  final VoidCallback? onTap;

  /// Accent text at the end, like "Current".
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final t = theme;
    final sub = subtitle;
    final end = trailing;
    final small = t.style(size: 12, height: 17 / 12, color: t.muted);
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      button: true,
      enabled: onTap != null,
      label: <String>[title, if (sub != null) sub, if (end != null) end].join(', '),
      onTap: onTap,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          margin: EdgeInsets.all(selected ? 0 : 1),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: t.background,
            borderRadius: BorderRadius.circular(t.radius),
            border: Border.all(color: selected ? t.accent : t.border, width: selected ? 2 : 1),
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(title, style: t.style(size: 15, height: 20 / 15, weight: FontWeight.w600)),
                    if (sub != null) Text(sub, style: small),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              if (busy)
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2.5, color: t.accent),
                )
              else if (end != null)
                Text(end, style: small.copyWith(color: t.accent)),
            ],
          ),
        ),
      ),
    );
  }
}
