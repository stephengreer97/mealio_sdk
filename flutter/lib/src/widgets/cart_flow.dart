// The drop-in: ONE sheet that runs the whole add-to-cart flow over the
// partner's app, for one recipe or several in one cart. Loading, store
// sign-in, the list, adding, done. Mirrors
// packages/react-native/src/MealioCartFlow.tsx and MealioCartButton.tsx.

import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../cart_session.dart';
import '../client.dart';
import '../errors.dart';
import '../events.dart';
import '../mealio_cart.dart';
import '../protocol.dart';
import '../runner.dart' show CancelToken;
import '../theme.dart';
import '../ui.dart';
import '../webview_host.dart';
import 'cart_list.dart';
import 'flow_parts.dart';
import 'location_picker.dart';

/// Starts a cart for one recipe. The default is
/// `MealioCart.instance.prepareCart`. The drop-in passes no `zip`: the user
/// chooses their store. It is called inside [runCancellable], so a
/// `MealioClient.prepareCart` it makes stops when the sheet closes.
typedef PrepareCart = Future<CartSession> Function({
  String? store,
  required Recipe recipe,
  String? zip,
  StepListener? onStep,
});

/// Starts a cart for one or more recipes. The default is
/// `MealioCart.instance.prepareCart`, which also fits this type. The drop-in
/// passes no `zip`: the user chooses their store.
typedef PrepareCarts = Future<CartSession> Function({
  String? store,
  required List<Recipe> recipes,
  String? zip,
  StepListener? onStep,
});

/// `recipes` when given, else `recipe` as a list of one.
List<Recipe> _recipeList(Recipe? recipe, List<Recipe>? recipes) =>
    recipes ?? (recipe == null ? const <Recipe>[] : <Recipe>[recipe]);

/// How many times in a row the sheet starts its cart again after something
/// outside it cancelled the prepare, before it shows the error screen.
const int maxOutsideRestarts = 3;

/// Lists the stores. The default is `MealioCart.instance.stores`.
typedef LoadStores = Future<List<StoreInfo>> Function();

enum _Phase { loading, list, adding, done, error, stores, location }

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
    this.loadLocations,
    this.saveStore,
    this.doneMessage,
    this.doneAction,
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

  /// 5-digit zip, if you know it. Fills the zip box when a Kroger family store
  /// asks the user which store they shop at. Without it, they type it in.
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

  /// Replaces `MealioCart.instance.storeLocations`, for tests and custom
  /// clients.
  final LoadLocations? loadLocations;

  /// Replaces `MealioCart.instance.setStore`, for tests and custom clients.
  final SaveStore? saveStore;

  /// A line of your own on the done screen, like "Enjoy your meal!".
  final String? doneMessage;

  /// A button of your own on the done screen, like "Back to meal plan".
  final MealioDoneAction? doneAction;

  /// Shows the flow over the app. Resolves with the result when something was
  /// added, else null. It never opens the store's cart. Pass `recipe` for
  /// one recipe or `recipes` for several in one cart. `onClose` is called as
  /// the sheet closes, with the same result.
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
    LoadLocations? loadLocations,
    SaveStore? saveStore,
    String? doneMessage,
    MealioDoneAction? doneAction,
    ValueChanged<AddResult?>? onClose,
  }) async {
    assert(recipe != null || recipes != null, 'Pass recipe or recipes.');
    final props = ValueNotifier<_FlowProps>(_FlowProps(
      recipe: recipe,
      recipes: recipes,
      store: store,
      zip: zip,
      onAdded: onAdded,
      onError: onError,
      theme: theme,
      prepareCart: prepareCart,
      prepareCarts: prepareCarts,
      loadStores: loadStores,
      loadLocations: loadLocations,
      saveStore: saveStore,
      doneMessage: doneMessage,
      doneAction: doneAction,
      onClose: onClose,
    ));
    // Not disposed: the sheet still listens through its closing animation.
    return _present(context, props);
  }

  /// [show], with props that may change while the sheet is up
  /// ([MealioCartButton] passes its own as they change).
  static Future<AddResult?> _present(BuildContext context, ValueListenable<_FlowProps> props) async {
    AddResult? added;
    AddResult? acted;
    final watch = _AddWatch();
    final carry = mealioCarryScope(context);
    final r = await Navigator.of(context, rootNavigator: true).push<AddResult>(
      MealioSheetRoute<AddResult>(
        barrierLabel: MealioUi.of(context).tr('close'),
        // No theme unless one was passed: the sheet follows the phone in auto.
        builder: (BuildContext sheetContext) => _ShowHooks(
          watch: watch,
          child: ValueListenableBuilder<_FlowProps>(
            valueListenable: props,
            builder: (BuildContext _, _FlowProps p, Widget? __) {
              final doneAction = p.doneAction;
              return carry(
                MealioCartFlow(
                  recipe: p.recipe,
                  recipes: p.recipes,
                  store: p.store,
                  zip: p.zip,
                  theme: p.theme,
                  prepareCart: p.prepareCart,
                  prepareCarts: p.prepareCarts,
                  loadStores: p.loadStores,
                  loadLocations: p.loadLocations,
                  saveStore: p.saveStore,
                  doneMessage: p.doneMessage,
                  // Held until the sheet is closed and reported, as on React Native.
                  doneAction: doneAction == null
                      ? null
                      : MealioDoneAction(label: doneAction.label, onPress: (AddResult a) => acted = a),
                  onAdded: (AddResult a) {
                    added = a;
                    p.onAdded?.call(a);
                  },
                  onError: p.onError,
                  onClose: (AddResult? a) => Navigator.of(sheetContext).pop(a),
                ),
              );
            },
          ),
        ),
      ),
    );
    // Hidden while adding: the add runs on, and its result still counts.
    final adding = watch.adding;
    if (r == null && added == null && adding != null) await adding;
    // A tap on the scrim or the back button pops with null; after a fill the
    // result still counts.
    final closed = r ?? added;
    final last = props.value;
    last.onClose?.call(closed);
    final tapped = acted;
    if (tapped != null) last.doneAction?.onPress(tapped);
    return closed;
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

  /// The table key shown when the error has no message of its own.
  String _errorKey = 'somethingWrongSentence';
  int _run = 0;
  WebViewHost? _host;
  MealioLoginView? _login;
  String? _store;
  List<StoreInfo>? _stores;
  _Phase _backTo = _Phase.list;
  bool _closeReported = false;

  /// The prepare under way, so closing can stop it.
  CancelToken? _preparing;

  /// Restarts in a row after a prepare was cancelled from outside the sheet.
  /// Reset by a prepare that works and by anything the user does.
  int _outsideRestarts = 0;

  /// An add under way. It runs to its end: nothing closes the sheet meanwhile.
  bool _adding = false;

  /// The cart of a failed add, so Try again keeps the user's picks.
  CartSession? _failedAdd;

  /// Who was signed in when the sheet opened ([_who]).
  String? _openedFor;

  /// Set each build, for a sheet closed from `dispose`, which cannot look it up.
  MealioUi _ui = const MealioUi();

  /// Where [MealioCartFlow.show] waits for an add the sheet was hidden during.
  _AddWatch? _watch;

  @override
  void initState() {
    super.initState();
    _follow(WebViewHost.current);
    _login = _host?.login.value;
    WebViewHost.currentListenable.addListener(_onHostChanged);
    // The current instance, whichever `configure` made it.
    _openedFor = _who();
    MealioCart.changes.addListener(_onUserChanged);
    _store = widget.store;
    // After this build: inherited widgets can't be read in initState, and a
    // listener may call setState.
    scheduleMicrotask(() {
      if (!mounted) return;
      _emit(MealioSheetOpened(recipes: _recipes.length));
      if (_login != null) _emit(MealioSigninShown(store: _store));
      unawaited(_start(_store));
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of<Object?>(context);
    if (route is MealioSheetRoute) route.onPop = _onPop;
    _watch = context.getInheritedWidgetOfExactType<_ShowHooks>()?.watch;
  }

  @override
  void didUpdateWidget(MealioCartFlow old) {
    super.didUpdateWidget(old);
    // The store prop changed while the sheet is up: a cart still loading
    // moves to it, and Try again uses it. A finished list stays what it is.
    if (old.store == widget.store) return;
    if (_phase == _Phase.loading) {
      _store = widget.store;
      scheduleMicrotask(() {
        if (mounted) unawaited(_start(widget.store));
      });
    } else if (_phase == _Phase.error) {
      _store = widget.store;
    }
  }

  @override
  void dispose() {
    // Removed without a pop we could see, for example in a partner's own route.
    _reportClose(_ui);
    // Nothing it was doing reports afterwards.
    _stop();
    WebViewHost.currentListenable.removeListener(_onHostChanged);
    MealioCart.changes.removeListener(_onUserChanged);
    // Closing the sheet cancels a sign-in it was showing.
    _follow(null);
    super.dispose();
  }

  /// Register with the host the scope now has. A remounted `MealioScope`
  /// brings a new host, and sign-ins for this sheet go to it.
  void _follow(WebViewHost? h) {
    final old = _host;
    if (identical(old, h)) return;
    if (old != null) {
      old.login.removeListener(_onLogin);
      old.flowClosed();
    }
    _host = h;
    if (h != null) {
      h.flowOpened();
      h.login.addListener(_onLogin);
    }
  }

  void _onHostChanged() {
    // The scope attaches while it builds: move after that.
    scheduleMicrotask(() {
      if (!mounted) return;
      _follow(WebViewHost.current);
      _onLogin();
    });
  }

  /// The user changed: what is on screen was theirs. An add finishes first.
  void _onUserChanged() {
    if (!mounted || _adding) return;
    final now = _who();
    if (now == _openedFor) return;
    _failedAdd = null;
    _close();
  }

  /// The signed-in user: their id, '' when users are not tracked (or the SDK
  /// is not configured), null for nobody.
  static String? _who() {
    if (!MealioCart.isConfigured) return '';
    final i = MealioCart.instance;
    return i.hasUser ? i.userId ?? '' : null;
  }

  /// Stop what can be stopped: the prepare and any search.
  void _stop() {
    _run += 1;
    _preparing?.cancel(MealioCancelReason.closed);
    _cart?.cancelSearches(MealioCancelReason.closed);
  }

  void _onLogin() {
    if (!mounted) return;
    final shown = _login != null;
    final next = _host?.login.value;
    setState(() => _login = next);
    if (!shown && next != null) _emit(MealioSigninShown(store: _store));
  }

  void _emit(MealioEvent event) => MealioUi.of(context).emit(event);

  MealioSheetStep get _stepNow {
    if (_login != null) return MealioSheetStep.signin;
    return switch (_phase) {
      _Phase.loading => MealioSheetStep.loading,
      _Phase.list => MealioSheetStep.list,
      _Phase.adding => MealioSheetStep.adding,
      _Phase.done => MealioSheetStep.done,
      _Phase.error => MealioSheetStep.error,
      _Phase.stores => MealioSheetStep.stores,
      _Phase.location => MealioSheetStep.location,
    };
  }

  /// `sheet_closed`, once, however the sheet was closed.
  void _reportClose(MealioUi ui) {
    if (_closeReported) return;
    _closeReported = true;
    final r = _result;
    ui.emit(MealioSheetClosed(step: _stepNow, added: _phase == _Phase.done && r != null ? r.added.length : 0));
  }

  /// The scrim, the back button, or the pop `_close` asked for. As with
  /// `_close`, nothing is reported after this.
  void _onPop() {
    if (!mounted) return;
    _stop();
    _reportClose(MealioUi.of(context));
  }

  Future<void> _openStores(_Phase from) async {
    // An empty list is a load that failed: try again each time.
    final retry = _stores?.isEmpty ?? true;
    setState(() {
      _backTo = from;
      _phase = _Phase.stores;
      if (retry) _stores = null;
    });
    if (!retry) return;
    List<StoreInfo> list;
    try {
      final load = widget.loadStores ?? MealioCart.instance.stores;
      list = await load();
    } catch (_) {
      list = <StoreInfo>[];
    }
    if (mounted) setState(() => _stores = list);
  }

  void _openLocation(_Phase from) {
    setState(() {
      _backTo = from;
      _phase = _Phase.location;
    });
  }

  void _askLocation(String storeId, _Phase from) {
    _emit(MealioLocationAsked(store: storeId));
    _openLocation(from);
  }

  void _pickStore(String id) {
    _emit(MealioStorePicked(store: id));
    _store = id;
    unawaited(_start(id));
  }

  /// Start (or start again) the cart. `byUser` false is the sheet's own
  /// restart after an outside cancel, which is capped ([maxOutsideRestarts]).
  Future<void> _start(String? storeId, {bool byUser = true}) async {
    if (byUser) _outsideRestarts = 0;
    final id = ++_run;
    _preparing?.cancel();
    final cancel = _preparing = CancelToken();
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
        c = await runCancellable(cancel, () => many(store: storeId, recipes: recipes, onStep: onStep));
      } else if (one != null && recipes.length == 1) {
        c = await runCancellable(cancel, () => one(store: storeId, recipe: recipes.first, onStep: onStep));
      } else {
        c = await MealioCart.instance.prepareCart(store: storeId, recipes: recipes, onStep: onStep, cancel: cancel);
      }
      if (_run != id || !mounted) return;
      final failed = _failedAdd;
      if (failed != null) {
        await c.restorePicks(failed, onStep: onStep, cancel: cancel);
        if (_run != id || !mounted) return;
        // restorePicks never throws. A cancel from outside the sheet while it
        // ran restarts the cart like any other outside cancel.
        if (cancel.cancelled) {
          throw MealioException(MealioErrorCode.cancelled, 'Cancelled', reason: cancel.reason);
        }
        _failedAdd = null;
      }
      _outsideRestarts = 0;
      setState(() {
        _store = c.store.isEmpty ? storeId : c.store;
        _cart = c;
        _phase = _Phase.list;
      });
      _emit(MealioListShown(store: _store ?? c.store, items: c.items.length));
    } catch (e) {
      if (_run != id || !mounted) return;
      if (e is MealioException && e.code == MealioErrorCode.cancelled) {
        // Cancelled by something other than this sheet (a store sign-out,
        // cancelJobs, a new configure, resetSession during the session
        // fetch) while it is still open: start again, without an error. At
        // most [maxOutsideRestarts] times in a row; then the error screen,
        // whose Try again starts over.
        if (!identical(_preparing, cancel)) return;
        if (_outsideRestarts < maxOutsideRestarts) {
          _outsideRestarts += 1;
          unawaited(_start(storeId, byUser: false));
          return;
        }
        _fail(MealioException(MealioErrorCode.cancelled, '', reason: e.reason), 'somethingWrongSentence', MealioSheetStep.loading);
        return;
      }
      if (e is MealioException && (e.code == MealioErrorCode.storeRequired || e.code == MealioErrorCode.storeNotAllowed)) {
        _store = null;
        unawaited(_openStores(_Phase.error));
        return;
      }
      if (e is MealioException && e.code == MealioErrorCode.locationRequired) {
        // Which store the user shops at is theirs to say. With no store named
        // there is nothing to look up, so they pick the chain first.
        if (storeId != null) {
          _store = storeId;
          _askLocation(storeId, _Phase.error);
        } else {
          unawaited(_openStores(_Phase.error));
        }
        return;
      }
      _fail(e, 'somethingWrongSentence', MealioSheetStep.loading);
    }
  }

  Future<void> _add() async {
    final c = _cart;
    if (c == null || _adding || c.searching) return;
    _adding = true;
    final id = _run;
    // Kept for an add the sheet is hidden during, after which none of these
    // can be looked up.
    final w = widget;
    final ui = _ui;
    final watch = _watch;
    final done = Completer<void>();
    watch?.adding = done.future;
    setState(() => _phase = _Phase.adding);
    _emit(MealioAddStarted(items: c.estimate().count));
    try {
      final r = await c.addToCart();
      if (_run != id || !mounted) {
        // The partner hid the sheet: the add ran on, and it is still reported.
        ui.emit(MealioCartAdded(store: r.store, added: r.added.length, failed: r.failed.length));
        w.onAdded?.call(r);
        if (watch == null) w.onClose(r);
        return;
      }
      setState(() {
        _result = r;
        _phase = _Phase.done;
      });
      _emit(MealioCartAdded(store: r.store, added: r.added.length, failed: r.failed.length));
      widget.onAdded?.call(r);
    } catch (e) {
      if (_run != id || !mounted) {
        ui.emit(MealioErrorEvent(code: e is MealioException ? e.code : 'error', step: MealioSheetStep.adding));
        w.onError?.call(e);
        if (watch == null) w.onClose(null);
        return;
      }
      _failedAdd = c;
      _fail(e, 'couldNotAdd', MealioSheetStep.adding);
    } finally {
      if (!done.isCompleted) done.complete();
      _adding = false;
      if (mounted) {
        // Closing is back on, and a user change held off by the add lands now.
        setState(() {});
        _onUserChanged();
      }
    }
  }

  void _fail(Object e, String fallbackKey, MealioSheetStep step) {
    final code = e is MealioException ? e.code : 'error';
    setState(() {
      _errorCode = code;
      _errorMessage = e is MealioException && e.message.isNotEmpty ? e.message : null;
      _errorKey = fallbackKey;
      _phase = _Phase.error;
    });
    _emit(MealioErrorEvent(code: code, step: step));
    widget.onError?.call(e);
  }

  List<Recipe> get _recipes => _recipeList(widget.recipe, widget.recipes);

  /// Up to 3 dish photos for the header, https only.
  List<String> get _photos => _recipes
      .map((Recipe r) => r.photoUrl)
      .whereType<String>()
      .where((String u) => u.startsWith('https://'))
      .take(3)
      .toList();

  /// The header's small line: the recipe's title, or "3 meals".
  String? _kicker(MealioUi ui) {
    final recipes = _recipes;
    if (recipes.length == 1) return recipes.first.title;
    return recipes.length > 1 ? ui.tr('meals', <String, Object?>{'count': recipes.length}) : null;
  }

  /// "Choose a different store" on the sign-in page: stop the cart that
  /// asked for it (its sign-in goes with it) and show the stores. Not while
  /// adding: an add's sign-in is for the cart already chosen.
  void _storeFromSignIn() {
    if (_adding) return;
    _stop();
    _login?.cancel();
    _login = null;
    unawaited(_openStores(_Phase.error));
  }

  void _close() {
    // Every way of closing lands here. An add cannot be stopped, so the sheet
    // stays open, but a sign-in the add asked for can still be dismissed.
    if (_adding) {
      _login?.cancel();
      return;
    }
    _stop();
    _reportClose(MealioUi.of(context));
    _login?.cancel();
    widget.onClose(_phase == _Phase.done ? _result : null);
  }

  String _title(MealioUi ui, String storeName, bool named) {
    final store = <String, Object?>{'store': storeName};
    switch (_phase) {
      case _Phase.done:
        return named ? ui.tr('titleInCart', store) : ui.tr('titleInCartPlain');
      case _Phase.loading:
        return named ? ui.tr('titleLoading', store) : ui.tr('titleLoadingPlain');
      case _Phase.error:
        return ui.tr('somethingWrong');
      case _Phase.stores:
        return ui.tr('titleStores');
      case _Phase.location:
        return ui.tr('titleLocation', store);
      case _Phase.list:
      case _Phase.adding:
        return ui.tr('titleList', store);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme ?? MealioTheme.of(context);
    final ui = _ui = MealioUi.of(context);
    final cart = _cart;
    final result = _result;
    final store = _store;
    final storeName = cart?.storeName ?? (store != null ? storeLabel(store) : ui.tr('yourStore'));
    final named = cart?.storeName != null || store != null;
    final login = _login;

    final Widget body;
    if (login != null) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              ui.tr('loginNote', <String, Object?>{'store': storeName}),
              style: t.style(size: 13, color: t.muted),
            ),
          ),
          if (!_adding)
            // Signed out of the saved store: pick another without signing in to it.
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: Semantics(
                  button: true,
                  child: GestureDetector(
                    key: const ValueKey<String>('mealio-signin-different-store'),
                    behavior: HitTestBehavior.opaque,
                    onTap: _storeFromSignIn,
                    child: Text(
                      ui.tr('differentStore'),
                      style: t.style(size: 13, weight: FontWeight.w600, color: t.accent),
                    ),
                  ),
                ),
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
    } else if (_phase == _Phase.location && store != null) {
      final toList = cart != null && _backTo == _Phase.list;
      body = LocationPicker(
        theme: t,
        store: store,
        storeName: storeName,
        zip: cart?.location?.zip ?? widget.zip,
        current: cart?.location?.id,
        loadLocations: widget.loadLocations,
        saveStore: widget.saveStore,
        onPicked: (StoreLocation _) {
          if (mounted) unawaited(_start(store));
        },
        backLabel: ui.tr(toList ? 'backToList' : 'differentStore'),
        onBack: toList
            ? () => setState(() => _phase = _Phase.list)
            : () => unawaited(_openStores(_Phase.error)),
      );
    } else if ((_phase == _Phase.list || _phase == _Phase.adding) && cart != null) {
      body = MealioCartList(
        session: cart,
        storeName: storeName,
        busy: _phase == _Phase.adding,
        onAdd: _add,
        onChangeStore: () => unawaited(_openStores(_Phase.list)),
        onChangeLocation: () {
          if (store != null) _askLocation(store, _Phase.list);
        },
        theme: t,
      );
    } else if (_phase == _Phase.done && result != null && cart != null) {
      final action = widget.doneAction;
      body = DoneView(
        theme: t,
        session: cart,
        result: result,
        storeName: storeName,
        onDone: _close,
        message: widget.doneMessage,
        action: action == null
            ? null
            : MealioDoneAction(
                label: action.label,
                onPress: (AddResult r) {
                  _close();
                  action.onPress(r);
                },
              ),
      );
    } else {
      body = ErrorView(
        theme: t,
        code: _errorCode,
        message: _errorMessage ?? ui.tr(_errorKey),
        note: _failedAdd != null ? ui.tr('addFailedNote') : null,
        onRetry: () => unawaited(_start(_store)),
        onClose: _close,
      );
    }

    // A pop by the scrim or back button disposes this state, which cancels
    // a sign-in in progress (WebViewHost.flowClosed).
    // While adding, the back button and the scrim do nothing, and the X only
    // dismisses a sign-in the add asked for.
    return PopScope(
      canPop: !_adding,
      child: SheetFrame(
        theme: t,
        kicker: _kicker(ui),
        photos: _photos,
        title: login != null ? login.title : _title(ui, storeName, named),
        onClose: _close,
        closeEnabled: !_adding || login != null,
        child: body,
      ),
    );
  }
}

/// What [MealioCartFlow.show] builds the sheet from.
class _FlowProps {
  const _FlowProps({
    this.recipe,
    this.recipes,
    this.store,
    this.zip,
    this.onAdded,
    this.onError,
    this.theme,
    this.prepareCart,
    this.prepareCarts,
    this.loadStores,
    this.loadLocations,
    this.saveStore,
    this.doneMessage,
    this.doneAction,
    this.onClose,
  });

  final Recipe? recipe;
  final List<Recipe>? recipes;
  final String? store;
  final String? zip;
  final ValueChanged<AddResult>? onAdded;
  final ValueChanged<Object>? onError;
  final MealioTheme? theme;
  final PrepareCart? prepareCart;
  final PrepareCarts? prepareCarts;
  final LoadStores? loadStores;
  final LoadLocations? loadLocations;
  final SaveStore? saveStore;
  final String? doneMessage;
  final MealioDoneAction? doneAction;
  final ValueChanged<AddResult?>? onClose;
}

/// An add under way in a sheet [MealioCartFlow.show] opened.
class _AddWatch {
  Future<void>? adding;
}

class _ShowHooks extends InheritedWidget {
  const _ShowHooks({required this.watch, required super.child});

  final _AddWatch watch;

  @override
  bool updateShouldNotify(_ShowHooks old) => !identical(watch, old.watch);
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
    final ui = MealioUi.of(context);
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
                Text(ui.tr('couldNotLoadStores'), style: t.style(size: 14, color: t.muted)),
              for (final StoreInfo st in list)
                Semantics(
                  inMutuallyExclusiveGroup: true,
                  checked: st.id == current,
                  button: true,
                  label: st.id == current ? '${st.name}, ${ui.tr('current')}' : st.name,
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
                            Text(ui.tr('current'), style: t.style(size: 12, height: 17 / 12, color: t.accent)),
                        ],
                      ),
                    ),
                  ),
                ),
            ], 10),
          ),
        ),
        if (onBack != null)
          Footer(theme: t, children: <Widget>[Cta(theme: t, label: ui.tr('backToList'), quiet: true, onTap: onBack)]),
      ],
    );
  }
}

/// How [MealioCartButton] draws itself. `solid` is the default, `compact` is
/// for a recipe card, `icon` is a round cart button.
enum MealioButtonVariant { solid, outline, compact, icon }

/// What a [MealioCartButton.builder] draws with.
@immutable
class MealioCartButtonDetails {
  const MealioCartButtonDetails({required this.onPressed, required this.disabled, required this.label});

  /// Opens the sheet. Null when [disabled], as Flutter's own buttons expect.
  final VoidCallback? onPressed;
  final bool disabled;
  final String label;
}

/// Draws your own button. See [MealioCartButton.builder].
typedef MealioCartButtonBuilder = Widget Function(BuildContext context, MealioCartButtonDetails button);

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
    this.variant = MealioButtonVariant.solid,
    this.builder,
    this.doneMessage,
    this.doneAction,
    this.onSignInRequired,
  }) : assert(recipe != null || recipes != null, 'Pass recipe or recipes.');

  /// Called on tap while `MealioCart.setUser(null)` says nobody is signed in.
  /// Send the user to your sign-in. With neither this nor the one given to
  /// `MealioCart.configure`, the button is disabled then.
  final VoidCallback? onSignInRequired;

  /// One recipe. Pass this or [recipes].
  final Recipe? recipe;

  /// Several recipes in one cart, at most [maxRecipes]. Wins over [recipe].
  final List<Recipe>? recipes;

  /// Store id, e.g. "heb". Optional: without it the user's default store is
  /// used, and the sheet asks them to pick one the first time.
  final String? store;

  /// 5-digit zip, if you know it. Fills the zip box when a Kroger family store
  /// asks the user which store they shop at. Without it, they type it in.
  final String? zip;

  /// Defaults to the `addToCart` string, or `addToCartShort` on a compact
  /// button. An icon button speaks it as its accessibility label.
  final String? label;

  /// How the button looks. Ignored when [builder] is set.
  final MealioButtonVariant variant;

  /// Draw your own button. It keeps the whole flow and the warm-up: call
  /// `button.onPressed` when it is tapped.
  final MealioCartButtonBuilder? builder;

  /// A line of your own on the done screen.
  final String? doneMessage;

  /// A button of your own on the done screen. Tapping it closes the sheet.
  final MealioDoneAction? doneAction;

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
  bool _wasDisabled = true;

  /// What the open sheet is built from. Follows this button's props, so a
  /// change reaches a sheet already up and its Try again.
  ValueNotifier<_FlowProps>? _sheet;

  // WARM THE LOGIN CHECK while the user reads the recipe. Only for a known
  // user with a store on file: the server answers "nothing to warm"
  // otherwise. The client runs it at most once every few minutes.
  @override
  void initState() {
    super.initState();
    // Static, so a later `configure` still reaches this button.
    MealioCart.changes.addListener(_onUserChanged);
    _wasDisabled = _disabled;
    _warm();
  }

  @override
  void didUpdateWidget(MealioCartButton old) {
    super.didUpdateWidget(old);
    final was = _wasDisabled;
    _wasDisabled = _disabled;
    if (old.store != widget.store || (was && !_disabled)) _warm();
    final sheet = _sheet;
    if (sheet != null) {
      // Not during this build: the sheet is in another part of the tree.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (identical(_sheet, sheet) && mounted) sheet.value = _props();
      });
    }
  }

  @override
  void dispose() {
    MealioCart.changes.removeListener(_onUserChanged);
    super.dispose();
  }

  void _onUserChanged() {
    if (!mounted) return;
    setState(() => _wasDisabled = _disabled);
    // A new user, or a button that just became enabled: warm for them.
    _warm();
  }

  bool get _hasUser => !MealioCart.isConfigured || MealioCart.instance.hasUser;

  /// Who to call on tap while nobody is signed in.
  VoidCallback? get _signIn {
    if (_hasUser) return null;
    return widget.onSignInRequired ?? MealioCart.instance.onSignInRequired;
  }

  bool get _disabled => widget.disabled || (!_hasUser && _signIn == null);

  void _warm() {
    if (_disabled || !_hasUser || !MealioCart.isConfigured) return;
    MealioCart.instance.warm(store: widget.store).ignore();
  }

  Future<void> _tap() async {
    final signIn = _signIn;
    if (signIn != null) {
      signIn();
      return;
    }
    if (_open || !_hasUser) return;
    _open = true;
    final sheet = _sheet = ValueNotifier<_FlowProps>(_props());
    try {
      await MealioCartFlow._present(context, sheet);
    } finally {
      _open = false;
      _sheet = null;
    }
  }

  /// This button's props as the sheet takes them. The callbacks read the
  /// widget at call time, so the latest ones are called.
  _FlowProps _props() {
    final w = widget;
    final action = w.doneAction;
    return _FlowProps(
      recipe: w.recipe,
      recipes: w.recipes,
      store: w.store,
      zip: w.zip,
      theme: w.theme,
      onAdded: (AddResult r) => widget.onAdded?.call(r),
      onError: (Object e) => widget.onError?.call(e),
      doneMessage: w.doneMessage,
      doneAction: action == null
          ? null
          : MealioDoneAction(label: action.label, onPress: (AddResult r) => (widget.doneAction ?? action).onPress(r)),
      onClose: (AddResult? r) => widget.onClose?.call(r),
    );
  }

  @override
  Widget build(BuildContext context) {
    final variant = widget.variant;
    final ui = MealioUi.of(context);
    final given = widget.label;
    final label = given != null && given.isNotEmpty
        ? given
        : ui.tr(variant == MealioButtonVariant.compact ? 'addToCartShort' : 'addToCart');
    final disabled = _disabled;
    final onTap = disabled ? null : _tap;
    final custom = widget.builder;
    if (custom != null) {
      return custom(context, MealioCartButtonDetails(onPressed: onTap, disabled: disabled, label: label));
    }

    final t = widget.theme ?? MealioTheme.of(context);
    final compact = variant == MealioButtonVariant.compact;
    final outline = variant == MealioButtonVariant.outline;
    final Widget face;
    if (variant == MealioButtonVariant.icon) {
      face = SizedBox(
        width: 48,
        height: 48,
        child: Center(child: Icon(Icons.shopping_cart, size: 22, color: t.onAccent)),
      );
    } else {
      face = ConstrainedBox(
        constraints: BoxConstraints(minHeight: compact ? 36 : 52),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 20),
          child: Center(
            widthFactor: 1,
            heightFactor: 1,
            child: Text(
              label,
              style: t.style(size: compact ? 14 : 16, weight: FontWeight.w700, color: outline ? t.accent : t.onAccent),
            ),
          ),
        ),
      );
    }
    final Widget button = Semantics(
      button: true,
      enabled: !disabled,
      label: label,
      excludeSemantics: true,
      child: Opacity(
        opacity: disabled ? 0.5 : 1,
        child: Material(
          color: outline ? const Color(0x00000000) : t.accent,
          shape: variant == MealioButtonVariant.icon
              ? const CircleBorder()
              : RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(t.radius),
                  side: outline ? BorderSide(color: t.accent, width: 2) : BorderSide.none,
                ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(onTap: onTap, child: face),
        ),
      ),
    );
    // Compact and icon keep their own size in a parent that stretches.
    return compact || variant == MealioButtonVariant.icon
        ? Align(alignment: AlignmentDirectional.centerStart, widthFactor: 1, heightFactor: 1, child: button)
        : button;
  }
}
