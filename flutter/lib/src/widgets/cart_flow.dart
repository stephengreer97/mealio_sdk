// The drop-in: ONE sheet that runs the whole add-to-cart flow over the
// partner's app, for one recipe or several in one cart. Loading, store
// sign-in, the list, adding, done. Mirrors
// packages/react-native/src/MealioCartFlow.tsx and MealioCartButton.tsx.

import 'dart:async';

import 'package:flutter/material.dart';

import '../cart_session.dart';
import '../client.dart';
import '../errors.dart';
import '../mealio_cart.dart';
import '../protocol.dart';
import '../theme.dart';
import '../webview_host.dart';
import 'cart_list.dart';
import 'flow_parts.dart';

/// Starts a cart for one recipe. The default is
/// `MealioCart.instance.prepareCart`.
typedef PrepareCart = Future<CartSession> Function({
  String? store,
  required Recipe recipe,
  String? zip,
  StepListener? onStep,
});

/// Starts a cart for one or more recipes. The default is
/// `MealioCart.instance.prepareCart`, which also fits this type.
typedef PrepareCarts = Future<CartSession> Function({
  String? store,
  required List<Recipe> recipes,
  String? zip,
  StepListener? onStep,
});

/// `recipes` when given, else `recipe` as a list of one.
List<Recipe> _recipeList(Recipe? recipe, List<Recipe>? recipes) =>
    recipes ?? (recipe == null ? const <Recipe>[] : <Recipe>[recipe]);

/// Lists the stores. The default is `MealioCart.instance.stores`.
typedef LoadStores = Future<List<StoreInfo>> Function();

enum _Phase { loading, list, adding, done, error, stores }

/// The whole flow in one sheet. Use [MealioCartFlow.show], or
/// [MealioCartButton] which calls it.
///
/// The widget itself is the sheet's content (grabber, header, body), for apps
/// that present it in a route of their own.
class MealioCartFlow extends StatefulWidget {
  const MealioCartFlow({
    super.key,
    this.recipe,
    this.recipes,
    this.store,
    this.zip,
    required this.onClose,
    this.onAdded,
    this.onError,
    this.theme,
    this.prepareCart,
    this.prepareCarts,
    this.loadStores,
  }) : assert(recipe != null || recipes != null, 'Pass recipe or recipes.');

  /// One recipe. Pass this or [recipes].
  final Recipe? recipe;

  /// Several recipes in one cart, at most [maxRecipes]. Ingredients they
  /// share become one item, each item says which recipes it is for, and a
  /// pick is remembered under every one of them. Wins over [recipe].
  final List<Recipe>? recipes;

  /// Store id from GET /api/v1/stores, e.g. "heb". Optional: without it the
  /// user's default store is used, and the sheet asks them to pick one the
  /// first time. The user can change store from the sheet either way.
  final String? store;

  /// 5-digit zip. Needed for Kroger family stores.
  final String? zip;

  /// The user closed the sheet. `result` is null when nothing was added.
  final ValueChanged<AddResult?> onClose;

  /// Called after the cart is filled, before the user taps Done.
  final ValueChanged<AddResult>? onAdded;

  /// Called when preparing or adding fails. Usually a [MealioException].
  final ValueChanged<Object>? onError;

  /// Defaults to `MealioTheme.of(context)`.
  final MealioTheme? theme;

  /// Replaces `MealioCart.instance.prepareCart` for a single recipe, for
  /// tests and custom clients. Not used for several recipes: set
  /// [prepareCarts] for those.
  final PrepareCart? prepareCart;

  /// Replaces `MealioCart.instance.prepareCart` for any number of recipes,
  /// for tests and custom clients. Wins over [prepareCart].
  final PrepareCarts? prepareCarts;

  /// Replaces `MealioCart.instance.stores`, for tests and custom clients.
  final LoadStores? loadStores;

  /// Shows the flow over the app. Resolves with the result when something was
  /// added, else null. It never opens the store's cart. Pass `recipe` for
  /// one recipe or `recipes` for several in one cart.
  static Future<AddResult?> show(
    BuildContext context, {
    Recipe? recipe,
    List<Recipe>? recipes,
    String? store,
    String? zip,
    ValueChanged<AddResult>? onAdded,
    ValueChanged<Object>? onError,
    MealioTheme? theme,
    PrepareCart? prepareCart,
    PrepareCarts? prepareCarts,
    LoadStores? loadStores,
  }) async {
    assert(recipe != null || recipes != null, 'Pass recipe or recipes.');
    final t = theme ?? MealioTheme.of(context);
    AddResult? added;
    final r = await Navigator.of(context, rootNavigator: true).push<AddResult>(
      MealioSheetRoute<AddResult>(
        builder: (BuildContext sheetContext) => MealioCartFlow(
          recipe: recipe,
          recipes: recipes,
          store: store,
          zip: zip,
          theme: t,
          prepareCart: prepareCart,
          prepareCarts: prepareCarts,
          loadStores: loadStores,
          onAdded: (AddResult a) {
            added = a;
            onAdded?.call(a);
          },
          onError: onError,
          onClose: (AddResult? a) => Navigator.of(sheetContext).pop(a),
        ),
      ),
    );
    // A tap on the scrim or the back button pops with null; after a fill the
    // result still counts.
    return r ?? added;
  }

  @override
  State<MealioCartFlow> createState() => _MealioCartFlowState();
}

class _MealioCartFlowState extends State<MealioCartFlow> {
  _Phase _phase = _Phase.loading;
  MealioStep _step = MealioStep.connecting;
  CartSession? _cart;
  AddResult? _result;
  String? _errorCode;
  String? _errorMessage;
  int _run = 0;
  WebViewHost? _host;
  MealioLoginView? _login;
  String? _store;
  List<StoreInfo>? _stores;
  _Phase _backTo = _Phase.list;

  @override
  void initState() {
    super.initState();
    final h = WebViewHost.current;
    if (h != null) {
      _host = h;
      h.flowOpened();
      h.login.addListener(_onLogin);
      _login = h.login.value;
    }
    _store = widget.store;
    unawaited(_start(_store));
  }

  @override
  void dispose() {
    _run += 1;
    final h = _host;
    if (h != null) {
      h.login.removeListener(_onLogin);
      // Closing the sheet cancels a sign-in it was showing.
      h.flowClosed();
    }
    super.dispose();
  }

  void _onLogin() {
    if (mounted) setState(() => _login = _host?.login.value);
  }

  Future<void> _openStores(_Phase from) async {
    setState(() {
      _backTo = from;
      _phase = _Phase.stores;
    });
    if (_stores != null) return;
    List<StoreInfo> list;
    try {
      final load = widget.loadStores ?? MealioCart.instance.stores;
      list = await load();
    } catch (_) {
      list = <StoreInfo>[];
    }
    if (mounted) setState(() => _stores = list);
  }

  void _pickStore(String id) {
    _store = id;
    unawaited(_start(id));
  }

  Future<void> _start(String? storeId) async {
    final id = ++_run;
    setState(() {
      _phase = _Phase.loading;
      _step = MealioStep.connecting;
      _cart = null;
      _result = null;
      _errorCode = null;
      _errorMessage = null;
    });
    try {
      void onStep(MealioStep s, Instruction _) {
        if (_run == id && mounted) setState(() => _step = s);
      }

      final recipes = _recipes;
      final many = widget.prepareCarts;
      final one = widget.prepareCart;
      final CartSession c;
      if (many != null) {
        c = await many(store: storeId, recipes: recipes, zip: widget.zip, onStep: onStep);
      } else if (one != null && recipes.length == 1) {
        c = await one(store: storeId, recipe: recipes.first, zip: widget.zip, onStep: onStep);
      } else {
        c = await MealioCart.instance.prepareCart(store: storeId, recipes: recipes, zip: widget.zip, onStep: onStep);
      }
      if (_run != id || !mounted) return;
      setState(() {
        _store = c.store.isEmpty ? storeId : c.store;
        _cart = c;
        _phase = _Phase.list;
      });
    } catch (e) {
      if (_run != id || !mounted) return;
      if (e is MealioException && e.code == MealioErrorCode.storeRequired) {
        unawaited(_openStores(_Phase.error));
        return;
      }
      _fail(e, 'Something went wrong.');
    }
  }

  Future<void> _add() async {
    final c = _cart;
    if (c == null || _phase == _Phase.adding) return;
    final id = _run;
    setState(() => _phase = _Phase.adding);
    try {
      final r = await c.addToCart();
      if (_run != id || !mounted) return;
      setState(() {
        _result = r;
        _phase = _Phase.done;
      });
      widget.onAdded?.call(r);
    } catch (e) {
      if (_run != id || !mounted) return;
      _fail(e, 'Could not add to your cart.');
    }
  }

  void _fail(Object e, String fallback) {
    setState(() {
      _errorCode = e is MealioException ? e.code : 'error';
      _errorMessage = e is MealioException && e.message.isNotEmpty ? e.message : fallback;
      _phase = _Phase.error;
    });
    widget.onError?.call(e);
  }

  List<Recipe> get _recipes => _recipeList(widget.recipe, widget.recipes);

  /// The header's small line: the recipe's title, or "3 meals".
  String? get _kicker {
    final recipes = _recipes;
    if (recipes.length == 1) return recipes.first.title;
    return recipes.length > 1 ? '${recipes.length} meals' : null;
  }

  void _close() {
    _run += 1;
    _login?.cancel();
    widget.onClose(_phase == _Phase.done ? _result : null);
  }

  String _title(String storeName) {
    switch (_phase) {
      case _Phase.done:
        return storeName == 'your store' ? 'In your cart' : 'In your $storeName cart';
      case _Phase.loading:
        return storeName == 'your store' ? 'Getting your cart ready' : 'Getting your $storeName cart ready';
      case _Phase.error:
        return 'Something went wrong';
      case _Phase.stores:
        return 'Choose your store';
      case _Phase.list:
      case _Phase.adding:
        return 'Your $storeName list';
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme ?? MealioTheme.of(context);
    final cart = _cart;
    final result = _result;
    final store = _store;
    final storeName = cart?.storeName ?? (store != null ? storeLabel(store) : 'your store');
    final login = _login;

    final Widget body;
    if (login != null) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              "Sign in on $storeName's own page. Mealio never sees your password.",
              style: t.style(size: 13, color: t.muted),
            ),
          ),
          Expanded(
            child: Container(
              decoration: BoxDecoration(border: Border(top: BorderSide(color: t.border, width: 0.5))),
              child: login.webview,
            ),
          ),
        ],
      );
    } else if (_phase == _Phase.loading) {
      body = LoadingView(
        theme: t,
        step: _step,
        storeName: storeName,
        count: _recipes.fold<int>(0, (int n, Recipe r) => n + r.ingredients.length),
      );
    } else if (_phase == _Phase.stores) {
      body = _StorePicker(
        theme: t,
        stores: _stores,
        current: store,
        onPick: _pickStore,
        onBack: cart != null && _backTo == _Phase.list ? () => setState(() => _phase = _Phase.list) : null,
      );
    } else if ((_phase == _Phase.list || _phase == _Phase.adding) && cart != null) {
      body = MealioCartList(
        session: cart,
        storeName: storeName,
        busy: _phase == _Phase.adding,
        onAdd: _add,
        onChangeStore: () => unawaited(_openStores(_Phase.list)),
        theme: t,
      );
    } else if (_phase == _Phase.done && result != null && cart != null) {
      body = DoneView(theme: t, session: cart, result: result, storeName: storeName, onDone: _close);
    } else {
      body = ErrorView(
        theme: t,
        code: _errorCode,
        message: _errorMessage,
        onRetry: () => unawaited(_start(_store)),
        onClose: _close,
      );
    }

    // A pop by the scrim or back button disposes this state, which cancels
    // a sign-in in progress (WebViewHost.flowClosed).
    return SheetFrame(
      theme: t,
      kicker: _kicker,
      title: login != null ? login.title : _title(storeName),
      onClose: _close,
      child: body,
    );
  }
}

/// One row per store; the current one has an accent ring and "Current".
class _StorePicker extends StatelessWidget {
  const _StorePicker({
    required this.theme,
    required this.stores,
    required this.current,
    required this.onPick,
    required this.onBack,
  });

  final MealioTheme theme;
  final List<StoreInfo>? stores;
  final String? current;
  final ValueChanged<String> onPick;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final t = theme;
    final list = stores;
    if (list == null) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Align(
          alignment: Alignment.topCenter,
          child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5, color: t.accent)),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            children: gapped(<Widget>[
              if (list.isEmpty)
                Text('Could not load stores. Close and try again.', style: t.style(size: 14, color: t.muted)),
              for (final StoreInfo st in list)
                Semantics(
                  inMutuallyExclusiveGroup: true,
                  checked: st.id == current,
                  button: true,
                  label: st.id == current ? '${st.name}, current store' : st.name,
                  excludeSemantics: true,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => onPick(st.id),
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 56),
                      margin: EdgeInsets.all(st.id == current ? 0 : 1),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        color: t.background,
                        borderRadius: BorderRadius.circular(t.radius),
                        border: Border.all(
                          color: st.id == current ? t.accent : t.border,
                          width: st.id == current ? 2 : 1,
                        ),
                      ),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(st.name, style: t.style(size: 15, height: 20 / 15, weight: FontWeight.w600)),
                          ),
                          if (st.id == current)
                            Text('Current', style: t.style(size: 12, height: 17 / 12, color: t.accent)),
                        ],
                      ),
                    ),
                  ),
                ),
            ], 10),
          ),
        ),
        if (onBack != null)
          Footer(theme: t, children: <Widget>[Cta(theme: t, label: 'Back to your list', quiet: true, onTap: onBack)]),
      ],
    );
  }
}

/// The one-line integration:
///
/// ```dart
/// MealioCartButton(recipe: recipe, store: 'heb')
/// // Several meals in one cart:
/// MealioCartButton(recipes: <Recipe>[tacos, pasta], store: 'heb')
/// ```
///
/// A themed button that runs the whole flow in one sheet.
class MealioCartButton extends StatefulWidget {
  const MealioCartButton({
    super.key,
    this.recipe,
    this.recipes,
    this.store,
    this.zip,
    this.label,
    this.onAdded,
    this.onClose,
    this.onError,
    this.disabled = false,
    this.theme,
  }) : assert(recipe != null || recipes != null, 'Pass recipe or recipes.');

  /// One recipe. Pass this or [recipes].
  final Recipe? recipe;

  /// Several recipes in one cart, at most [maxRecipes]. Wins over [recipe].
  final List<Recipe>? recipes;

  /// Store id, e.g. "heb". Optional: without it the user's default store is
  /// used, and the sheet asks them to pick one the first time.
  final String? store;
  final String? zip;

  /// Defaults to "Add to my grocery cart".
  final String? label;

  /// Called after the cart is filled, before the user taps Done.
  final ValueChanged<AddResult>? onAdded;

  /// Called when the sheet closes, with the result or null.
  final ValueChanged<AddResult?>? onClose;

  /// Called when preparing or adding fails. Usually a [MealioException].
  final ValueChanged<Object>? onError;
  final bool disabled;

  /// Defaults to `MealioTheme.of(context)`.
  final MealioTheme? theme;

  @override
  State<MealioCartButton> createState() => _MealioCartButtonState();
}

class _MealioCartButtonState extends State<MealioCartButton> {
  bool _open = false;

  // WARM THE LOGIN CHECK while the user reads the recipe. Only for a known
  // user with a store on file: the server answers "nothing to warm"
  // otherwise. The client runs it at most once every few minutes.
  @override
  void initState() {
    super.initState();
    _warm();
  }

  @override
  void didUpdateWidget(MealioCartButton old) {
    super.didUpdateWidget(old);
    if (old.store != widget.store || (old.disabled && !widget.disabled)) _warm();
  }

  void _warm() {
    if (widget.disabled || !MealioCart.isConfigured) return;
    MealioCart.instance.warm(store: widget.store).ignore();
  }

  Future<void> _tap() async {
    if (_open) return;
    _open = true;
    try {
      final r = await MealioCartFlow.show(
        context,
        recipe: widget.recipe,
        recipes: widget.recipes,
        store: widget.store,
        zip: widget.zip,
        theme: widget.theme,
        onAdded: widget.onAdded,
        onError: widget.onError,
      );
      widget.onClose?.call(r);
    } finally {
      _open = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme ?? MealioTheme.of(context);
    final label = widget.label ?? 'Add to my grocery cart';
    return Semantics(
      button: true,
      enabled: !widget.disabled,
      label: label,
      excludeSemantics: true,
      child: Opacity(
        opacity: widget.disabled ? 0.5 : 1,
        child: Material(
          color: t.accent,
          borderRadius: BorderRadius.circular(t.radius),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: widget.disabled ? null : _tap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 52),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Center(
                  widthFactor: 1,
                  child: Text(label, style: t.style(size: 16, weight: FontWeight.w700, color: t.onAccent)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
