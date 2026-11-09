// A scripted fake Mealio for partner tests: the server (an http.Client), a
// store page (a MealioHost), and the protocol TEST key to trust. Mirrors
// createFakeMealio in packages/core/src/testing.ts, with the same scripts.
// Exported by package:mealio_sdk/testing.dart, never by mealio_sdk.dart.

import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'allowlist.dart' show bundledStores;
import 'client.dart';
import 'host.dart';
import 'protocol.dart';

/// The protocol test key (protocol/test-vectors.json), kid `ktest`. Only a
/// test configuration trusts it: the bundled keys hold the production key alone.
const Map<String, String> mealioTestKeys = <String, String>{'ktest': '6kpsY+KcUgq+9VB7Ey7F+ZVHdq6+vnuSQh7qaRRG0iw='};

/// Where the fake answers. Any base URL works; this one is the default.
const String mealioFakeBaseUrl = 'https://mealio.test';

final List<int> _testSeed = List<int>.filled(32, 7);
final Ed25519 _ed = Ed25519();

/// An instructions envelope signed with the test key, for tests that script
/// instructions themselves.
Future<Envelope> signMealioTestEnvelope(String job, int seq, String store, List<Object?> instructions) async {
  final payload = jsonEncode(<String, Object?>{
    'v': 1,
    'kind': 'instructions',
    'job': job,
    'seq': seq,
    'exp': 4102444800,
    'store': store,
    'instructions': instructions,
  });
  final sig = await _ed.sign(utf8.encode(payload), keyPair: await _ed.newKeyPairFromSeed(_testSeed));
  return Envelope(payload: payload, sig: base64Encode(sig.bytes), kid: 'ktest');
}

/// An error by code. With `status` Mealio answers it as an HTTP error;
/// without, the job starts and then fails with it.
class MealioFakeError {
  const MealioFakeError(this.code, {this.message, this.status});

  /// From the TypeScript kit's JSON: a code, or `{code, message?, status?}`.
  factory MealioFakeError.fromJson(Object? json) {
    _checkError(json, 'error');
    if (json is String) return MealioFakeError(json);
    final m = _map(json, 'error');
    return MealioFakeError(
      m['code']! as String,
      message: m['message'] as String?,
      status: (m['status'] as num?)?.toInt(),
    );
  }

  final String code;
  final String? message;
  final int? status;
}

Map<String, Object?> _map(Object? json, String what) {
  if (json is Map) return json.cast<String, Object?>();
  throw FormatException('MealioFakeScript: $what must be an object');
}

List<Object?> _listOf(Object? json, String what) {
  if (json is List) return json;
  throw FormatException('MealioFakeScript: $what must be a list');
}

// ── Strict checks: the TypeScript types, field by field ─────────────────
// The same checks as FakeScriptJson.kt. `null` is allowed only where the
// TypeScript type says `| null`; an absent optional field is always fine.

const Set<String> _errorKinds = <String>{'prepare', 'search', 'add', 'warm', 'stores', 'preferences', 'locations', 'session'};

Never _bad(String path, String what) => throw FormatException('MealioFakeScript: $path $what');

class _Fields {
  _Fields(Object? json, this.path, Set<String>? known, [Set<String> required = const <String>{}])
      : o = json is Map ? json : _bad(path, 'must be an object') {
    for (final Object? k in o.keys) {
      if (known != null && !known.contains(k)) _bad('$path.$k', 'is not a known field');
    }
    for (final String k in required) {
      if (!o.containsKey(k)) _bad('$path.$k', 'is required');
    }
  }

  final Map<Object?, Object?> o;
  final String path;

  String at(String k) => '$path.$k';
  bool skip(String k, bool nullable) => !o.containsKey(k) || (nullable && o[k] == null);

  void string(String k, {bool nullable = false, Set<String>? oneOf}) {
    if (skip(k, nullable)) return;
    final v = o[k];
    if (v is! String) _bad(at(k), nullable ? 'must be a string or null' : 'must be a string');
    if (oneOf != null && !oneOf.contains(v)) _bad(at(k), 'must be one of ${oneOf.join(', ')}, not "$v"');
  }

  void number(String k, {bool nullable = false, bool integer = false}) {
    if (skip(k, nullable)) return;
    final v = o[k];
    if (v is! num) _bad(at(k), nullable ? 'must be a number or null' : 'must be a number');
    if (integer && (v is double && (!v.isFinite || v != v.floorToDouble()))) _bad(at(k), 'must be a whole number');
  }

  void boolean(String k, {bool nullable = false}) {
    if (skip(k, nullable)) return;
    if (o[k] is! bool) _bad(at(k), nullable ? 'must be true, false or null' : 'must be true or false');
  }

  void obj(String k, void Function(Object? v, String path) check, {bool nullable = false}) {
    if (skip(k, nullable)) return;
    if (o[k] is! Map) _bad(at(k), nullable ? 'must be an object or null' : 'must be an object');
    check(o[k], at(k));
  }

  void list(String k, void Function(Object? v, String path) each) {
    if (!o.containsKey(k)) return;
    final a = o[k];
    if (a is! List) _bad(at(k), 'must be an array');
    for (var i = 0; i < a.length; i++) {
      each(a[i], '${at(k)}[$i]');
    }
  }
}

void _checkScript(Object? json) {
  final f = _Fields(json, 'script', const <String>{
    'store', 'storeName', 'items', 'recipes', 'warnings', 'search', 'add', 'signIn',
    'errors', 'stores', 'preferences', 'locations', 'warm',
  });
  f.string('store');
  f.string('storeName');
  f.list('items', _checkItem);
  f.list('recipes', (Object? r, String p) {
    _Fields(r, p, const <String>{'id', 'title'}, const <String>{'id', 'title'})
      ..string('id')
      ..string('title', nullable: true);
  });
  f.list('warnings', (Object? w, String p) {
    _Fields(w, p, const <String>{'code', 'message'}, const <String>{'code', 'message'})
      ..string('code')
      ..string('message');
  });
  f.obj('search', (Object? m, String p) {
    final g = _Fields(m, p, null);
    for (final Object? q in g.o.keys) {
      g.list('$q', _checkProduct);
    }
  });
  f.obj('add', (Object? a, String p) {
    _Fields(a, p, const <String>{'fail'}, const <String>{'fail'});
    _checkError((a! as Map)['fail'], '$p.fail');
  });
  f.string('signIn', nullable: true, oneOf: const <String>{'signed_in', 'cancelled', 'timeout'});
  f.obj('errors', (Object? m, String p) {
    final g = _Fields(m, p, _errorKinds);
    for (final MapEntry<Object?, Object?> e in g.o.entries) {
      _checkError(e.value, '$p.${e.key}');
    }
  });
  f.list('stores', (Object? s, String p) {
    _Fields(s, p, const <String>{'id', 'name', 'via'}, const <String>{'id', 'name', 'via'})
      ..string('id')
      ..string('name')
      ..string('via', oneOf: const <String>{'device', 'kroger_api'});
  });
  f.obj('preferences', (Object? s, String p) {
    _Fields(s, p, const <String>{'defaultStore', 'location'}, const <String>{'defaultStore', 'location'})
      ..string('defaultStore', nullable: true)
      ..obj('location', _checkLocation, nullable: true);
  });
  f.list('locations', _checkLocation);
  f.obj('warm', (Object? w, String p) => _Fields(w, p, const <String>{'signedIn'}).boolean('signedIn', nullable: true), nullable: true);
}

void _checkItem(Object? json, String path) {
  _Fields(json, path, const <String>{
    'key', 'ingredient', 'quantity', 'options', 'remembered', 'rememberedPreferenceId', 'rememberedUnavailable',
    'startUnchecked', 'weightLb', 'recipes', 'unavailable',
  }, const <String>{'key'})
    ..string('key')
    ..string('ingredient')
    // A number in TypeScript, so 1.5 is accepted and kept (quantityExact);
    // the cart sends it as TypeScript does.
    ..number('quantity')
    ..list('options', _checkProduct)
    ..string('remembered', nullable: true)
    ..string('rememberedPreferenceId', nullable: true)
    ..boolean('rememberedUnavailable')
    ..boolean('startUnchecked')
    ..number('weightLb')
    ..list('recipes', (Object? r, String p) {
      _Fields(r, p, const <String>{'id', 'title', 'quantity'}, const <String>{'id', 'title', 'quantity'})
        ..string('id')
        ..string('title', nullable: true)
        ..number('quantity');
    })
    ..string('unavailable');
}

void _checkProduct(Object? json, String path) {
  _Fields(json, path, const <String>{
    'id', 'name', 'price', 'imageUrl', 'size', 'outOfStock', 'badge', 'badgeLabel', 'preferences', 'unitPrice',
    'estimated', 'maxQuantity', 'soldByWeight', 'weightOptions', 'pricePerLb',
  }, const <String>{'id', 'name'})
    ..string('id')
    ..string('name')
    ..string('price', nullable: true)
    ..string('imageUrl', nullable: true)
    ..string('size', nullable: true)
    ..boolean('outOfStock')
    ..string('badge', nullable: true, oneOf: const <String>{'picked_before', 'popular', 'partner_pick'})
    ..string('badgeLabel', nullable: true)
    ..list('preferences', (Object? p, String at) {
      _Fields(p, at, const <String>{'id', 'label'}, const <String>{'id', 'label'})
        ..string('id')
        ..string('label');
    })
    ..number('unitPrice', nullable: true)
    ..boolean('estimated')
    ..number('maxQuantity', nullable: true, integer: true)
    ..boolean('soldByWeight')
    ..list('weightOptions', (Object? v, String at) {
      if (v is! num) _bad(at, 'must be a number');
    })
    ..number('pricePerLb', nullable: true);
}

void _checkLocation(Object? json, String path) {
  _Fields(json, path, const <String>{'id', 'name', 'address', 'zip'}, const <String>{'id', 'name', 'address', 'zip'})
    ..string('id')
    ..string('name')
    ..string('address')
    ..string('zip', nullable: true);
}

void _checkError(Object? v, String path) {
  if (v is String) return;
  if (v is! Map) _bad(path, 'must be a code or {code, message?, status?}');
  _Fields(v, path, const <String>{'code', 'message', 'status'}, const <String>{'code'})
    ..string('code')
    ..string('message')
    ..number('status', integer: true);
}

// A quantity as the client reads one from the server: whole packages. 1e400 is
// Infinity, which JSON.stringify sends as null, so it is no quantity.
int? _wholeOrNull(Object? v) => v is num && v.isFinite ? v.toInt() : null;

// The exact number, when it is not a whole one quantity already holds (1.5,
// 3e20, Infinity, -0), as TypeScript keeps it. Null for a whole int.
double? _exactOrNull(Object? v) {
  if (v is! num) return null;
  if (v is int) return null;
  final d = v.toDouble();
  if (d.isFinite && d == d.truncateToDouble() && d.abs() < 9007199254740992.0 && !(d == 0 && d.isNegative)) return null;
  return d;
}

// A number as JSON.stringify writes it: a whole one as an int, a non-finite one as null.
Object? _wire(double d) {
  if (!d.isFinite) return null;
  if (d == d.truncateToDouble() && d.abs() < 9007199254740992.0) return d.toInt();
  return d;
}

List<Product> _products(Object? json, String what) => _listOf(json, what).map(Product.fromJson).toList();

/// One line of a cart script.
class MealioFakeItem {
  const MealioFakeItem({
    required this.key,
    this.ingredient,
    this.quantity,
    this.quantityExact,
    this.options = const <Product>[],
    this.remembered,
    this.rememberedPreferenceId,
    this.rememberedUnavailable = false,
    this.startUnchecked = false,
    this.weightLb,
    this.recipes,
    this.unavailable,
  });

  /// From the TypeScript kit's JSON (`FakeItem`), with its field names.
  factory MealioFakeItem.fromJson(Object? json) {
    _checkItem(json, 'item');
    final m = _map(json, 'item');
    return MealioFakeItem(
      key: m['key']! as String,
      ingredient: m['ingredient'] as String?,
      quantity: _wholeOrNull(m['quantity']),
      quantityExact: _exactOrNull(m['quantity']),
      options: m['options'] == null ? const <Product>[] : _products(m['options'], 'options'),
      remembered: m['remembered'] as String?,
      rememberedPreferenceId: m['rememberedPreferenceId'] as String?,
      rememberedUnavailable: m['rememberedUnavailable'] == true,
      startUnchecked: m['startUnchecked'] == true,
      weightLb: (m['weightLb'] as num?)?.toDouble(),
      recipes: m['recipes'] == null ? null : _listOf(m['recipes'], 'recipes').map(ItemRecipe.fromJson).toList(),
      unavailable: m['unavailable'] as String?,
    );
  }

  final String key;
  final String? ingredient;
  final int? quantity;

  /// Packages exactly, as TypeScript's `quantity?: number`: part of a
  /// package (1.5), or past what [quantity] holds. Wins over [quantity] on
  /// the wire; a non-finite one is sent as null, as JSON.stringify does. A
  /// script's quantity that is not a whole int lands here too.
  final double? quantityExact;
  final List<Product> options;

  /// The remembered product's id. In [options] and in stock: status
  /// remembered, pre-selected.
  final String? remembered;
  final String? rememberedPreferenceId;

  /// The remembered product is gone this time: status
  /// remembered_unavailable, nothing pre-selected.
  final bool rememberedUnavailable;

  /// Pantry or optional: starts unticked.
  final bool startUnchecked;

  /// The recipe's own weight, lb.
  final double? weightLb;
  final List<ItemRecipe>? recipes;

  /// Nothing found: status unavailable with this reason.
  final String? unavailable;
}

/// What a warm-up finds.
class MealioFakeWarm {
  const MealioFakeWarm({required this.signedIn});
  final bool signedIn;
}

/// What the fake Mealio answers. Plain data; change it between calls.
class MealioFakeScript {
  MealioFakeScript({
    this.store,
    this.storeName,
    this.items = const <MealioFakeItem>[],
    this.recipes,
    this.warnings = const <CartWarning>[],
    this.search = const <String, List<Product>>{},
    this.onSearch,
    this.addFailure,
    this.onAdd,
    this.signIn,
    this.errors = const <String, MealioFakeError>{},
    this.stores,
    this.preferences,
    this.locations = const <StoreLocation>[],
    this.warm = const MealioFakeWarm(signedIn: true),
  });

  /// The script format of `createFakeMealio` (`@mealio/sdk-core/testing`)
  /// and Swift's `FakeMealio(json:)`, with the same field names, as decoded
  /// JSON (`jsonDecode(text)`). `add` is `{"fail": error}`; an error is a code
  /// or `{"code", "message", "status"}`; `"warm": null` means nothing to warm.
  /// `onSearch` and `onAdd` are functions and have no JSON form. Loads
  /// protocol/fake-script.json, the script every platform's kit runs.
  ///
  /// Strict at every level, as the TypeScript types: an unknown field, a
  /// missing required field (an item's `key`) or a value of the wrong type
  /// throws a FormatException naming it (`script.items[0].remebered`).
  factory MealioFakeScript.fromJson(Object? json) {
    _checkScript(json);
    final m = _map(json, 'script');
    final add = m['add'];
    return MealioFakeScript(
      store: m['store'] as String?,
      storeName: m['storeName'] as String?,
      items: m['items'] == null ? const <MealioFakeItem>[] : _listOf(m['items'], 'items').map(MealioFakeItem.fromJson).toList(),
      recipes: m['recipes'] == null ? null : _listOf(m['recipes'], 'recipes').map(CartRecipe.fromJson).toList(),
      warnings: m['warnings'] == null ? const <CartWarning>[] : _listOf(m['warnings'], 'warnings').map(CartWarning.fromJson).toList(),
      search: m['search'] == null
          ? const <String, List<Product>>{}
          : _map(m['search'], 'search').map((String q, Object? v) => MapEntry<String, List<Product>>(q, _products(v, 'search'))),
      addFailure: add == null ? null : MealioFakeError.fromJson(_map(add, 'add')['fail']),
      signIn: m['signIn'] as String?,
      errors: m['errors'] == null
          ? const <String, MealioFakeError>{}
          : _map(m['errors'], 'errors').map((String k, Object? v) => MapEntry<String, MealioFakeError>(k, MealioFakeError.fromJson(v))),
      stores: m['stores'] == null ? null : _listOf(m['stores'], 'stores').map(StoreInfo.fromJson).toList(),
      preferences: m['preferences'] == null ? null : StorePreferences.fromJson(m['preferences']),
      locations: m['locations'] == null ? const <StoreLocation>[] : _listOf(m['locations'], 'locations').map(StoreLocation.fromJson).toList(),
      warm: !m.containsKey('warm')
          ? const MealioFakeWarm(signedIn: true)
          : m['warm'] == null
              ? null
              // TS: `warm?.signedIn ?? true`, so `{}` is signed in.
              : MealioFakeWarm(signedIn: _map(m['warm'], 'warm')['signedIn'] != false),
    );
  }

  String? store;
  String? storeName;
  List<MealioFakeItem> items;
  List<CartRecipe>? recipes;
  List<CartWarning> warnings;

  /// Results per query (exact, case-insensitive). An unlisted query finds nothing.
  Map<String, List<Product>> search;

  /// Results by function instead of [search].
  List<Product> Function(String query, String key)? onSearch;

  /// The add fails with this.
  MealioFakeError? addFailure;

  /// What an add does instead. By default each selection whose product this
  /// cart offered (its prepare, or a search on THIS cart) is added with its
  /// price, and any other product fails as `not_offered`, as the server does.
  AddResult Function(List<Selection> selections, List<Product> offered)? onAdd;

  /// Prepare asks the user to sign in, and the fake store page answers this:
  /// `signed_in`, `cancelled` or `timeout`. Null: already signed in.
  String? signIn;

  /// Errors by call: `prepare`, `search`, `add`, `warm`, `stores`,
  /// `preferences`, `locations`, `session` (the session token provider).
  Map<String, MealioFakeError> errors;
  List<StoreInfo>? stores;
  StorePreferences? preferences;
  List<StoreLocation> locations;

  /// What a warm-up finds. Null: Mealio has nothing to warm.
  MealioFakeWarm? warm;
}

/// One request the client sent.
class MealioFakeRequest {
  const MealioFakeRequest(this.kind, this.path, this.body, this.token);

  /// prepare, search, add, warm, step, stores, preferences, locations or other.
  final String kind;
  final String path;
  final Map<String, Object?>? body;
  final String? token;
}

/// A cart item from a script line, as the server builds it.
CartItem mealioFakeCartItem(MealioFakeItem f) => CartItem.fromJson(_itemJson(f));

Map<String, Object?> _itemJson(MealioFakeItem f) {
  final options = f.options;
  Product? rem;
  final r = f.remembered;
  if (r != null && r.isNotEmpty) {
    rem = options.firstWhere((Product p) => p.id == r, orElse: () => Product(id: r, name: r));
  }
  final usable = rem != null && !f.rememberedUnavailable && !rem.outOfStock && options.any((Product p) => p.id == rem!.id);
  final status = f.unavailable != null || options.isEmpty
      ? 'unavailable'
      : usable
          ? 'remembered'
          : rem != null
              ? 'remembered_unavailable'
              : 'choose';
  return <String, Object?>{
    'key': f.key,
    'ingredient': f.ingredient ?? f.key,
    'quantity': f.quantityExact != null ? _wire(f.quantityExact!) : f.quantity ?? 1,
    'status': status,
    'options': options.map((Product p) => p.toJson()).toList(),
    'selectedId': usable ? rem.id : null,
    'remembered': rem == null ? null : <String, Object?>{...rem.toJson(), if (!usable) 'outOfStock': true},
    if (f.rememberedPreferenceId != null) 'rememberedPreferenceId': f.rememberedPreferenceId,
    if (f.startUnchecked) 'startUnchecked': true,
    if (f.weightLb != null) 'weightLb': f.weightLb,
    if (f.recipes != null) 'recipes': f.recipes!.map((ItemRecipe x) => x.toJson()).toList(),
    if (status == 'unavailable') 'reason': f.unavailable ?? 'not_found',
  };
}

class _Cart {
  _Cart(this.store, this.offered);
  final String store;
  final List<Product> offered;
}

class _Job {
  _Job(this.store, this.finish);
  final String store;
  final List<Object?> Function(String? outcome) finish;
}

/// A scripted Mealio: [httpClient] plays the server, [host] the store page,
/// and [keys] is the test key to trust. [client] makes a real
/// [MealioClient] on it; `configureMealioForTesting(fake: ...)` makes
/// `MealioCart` and its widgets use it.
///
/// ```dart
/// final fake = MealioFake(MealioFakeScript(items: <MealioFakeItem>[
///   MealioFakeItem(key: 'milk', options: <Product>[Product(id: 'm1', name: 'Milk', unitPrice: 3)], remembered: 'm1'),
/// ]));
/// final cart = await fake.client().prepareCart(recipe: recipe);
/// ```
class MealioFake {
  MealioFake([MealioFakeScript? script]) : script = script ?? MealioFakeScript() {
    host = _FakeHost(this);
    httpClient = _HoldingHttp(this, MockClient(_handle));
  }

  /// The script in force. Change it, or its fields, between calls.
  MealioFakeScript script;

  /// Every request the client sent, in order.
  final List<MealioFakeRequest> requests = <MealioFakeRequest>[];

  /// What the fake store page was asked to do: "open <url>", "script",
  /// "login", "fetch", "reset".
  final List<String> hostCalls = <String>[];

  /// The fake server.
  late final http.Client httpClient;

  /// The fake store page.
  late final MealioHost host;

  final Map<String, String> keys = Map<String, String>.unmodifiable(mealioTestKeys);
  final String baseUrl = mealioFakeBaseUrl;

  final Map<String, _Cart> _carts = <String, _Cart>{};
  final Map<String, _Job> _jobs = <String, _Job>{};
  final Map<String, List<Future<void>>> _holds = <String, List<Future<void>>>{};
  int _nJob = 0;
  int _nCart = 0;

  /// A session token provider on this fake: `session_test`, or the script's
  /// `session` error.
  Future<String> sessionToken() async {
    final e = script.errors['session'];
    if (e != null) throw Exception(e.message ?? e.code);
    return 'session_test';
  }

  /// A [ClientConfig] on this fake.
  ClientConfig config({
    Future<String> Function()? getSessionToken,
    JobQueue? queue,
    Future<int> Function()? getEpoch,
  }) =>
      ClientConfig(
        publishableKey: 'pk_test_fake',
        getSessionToken: getSessionToken ?? sessionToken,
        platform: 'flutter-test',
        sdkVersion: 'test',
        baseUrl: baseUrl,
        httpClient: httpClient,
        keys: keys,
        queue: queue,
        getEpoch: getEpoch,
      );

  /// A real [MealioClient] on this fake.
  MealioClient client({Future<String> Function()? getSessionToken, JobQueue? queue}) =>
      MealioClient(config(getSessionToken: getSessionToken, queue: queue), host);

  /// The products a cart offered so far (prepare and its own searches).
  List<Product> offered(String cartId) => List<Product>.of(_carts[cartId]?.offered ?? const <Product>[]);

  /// Hold the next request of this kind until the returned function is called.
  ///
  /// While a request is held, no request times out: the client's 30-second
  /// limit counts only time Mealio would take to answer. A widget test can
  /// therefore pump for as long as it likes. `pumpAndSettle` still never
  /// returns while the sheet shows its loading spinner, so pump a few frames
  /// (`tester.pump(const Duration(milliseconds: 100))`) instead until you
  /// release it.
  void Function() hold(String kind) {
    final c = Completer<void>();
    (_holds[kind] ??= <Future<void>>[]).add(c.future);
    return () {
      if (!c.isCompleted) c.complete();
    };
  }

  StorePreferences _prefs() => script.preferences ?? StorePreferences(defaultStore: script.store ?? 'heb', location: null);

  static String _home(String store) => 'https://www.${bundledStores[store]?.hosts.firstOrNull ?? 'heb.com'}/';

  static String _loginUrl(String store) {
    final s = bundledStores[store];
    final h = s?.hosts.firstOrNull;
    return h != null ? 'https://www.$h/login' : 'https://${s?.authHosts.firstOrNull ?? 'www.heb.com'}/login';
  }

  static http.Response _reply(Object? body, [int status = 200]) => http.Response.bytes(
        utf8.encode(jsonEncode(body)),
        status,
        headers: <String, String>{'content-type': 'application/json'},
      );

  static Map<String, Object?> _err(MealioFakeError e) => <String, Object?>{
        'error': <String, Object?>{'code': e.code, 'message': e.message ?? e.code},
      };

  static Map<String, Object?> _failOp(MealioFakeError e) =>
      <String, Object?>{'op': 'fail', 'id': 'fail-1', 'code': e.code, 'message': e.message ?? e.code};

  static Map<String, Object?> _done(Object? result) => <String, Object?>{'op': 'done', 'id': 'done-1', 'result': result};

  Future<http.Response> _start(String store, List<Object?> instructions, [List<Object?> Function(String?)? finish]) async {
    final job = 'job_${++_nJob}';
    if (finish != null) _jobs[job] = _Job(store, finish);
    final env = await signMealioTestEnvelope(job, 1, store, instructions);
    return _reply(<String, Object?>{'job': job, 'envelope': env.toJson()});
  }

  Future<http.Response> _jobError(String store, MealioFakeError e) async {
    final status = e.status;
    if (status != null) return _reply(_err(e), status);
    return _start(store, <Object?>[_failOp(e)]);
  }

  http.Response _httpError(MealioFakeError e) => _reply(_err(e), e.status ?? 400);

  Future<http.Response> _prepare(Map<String, Object?> body) async {
    final s = script;
    final store = body['store'] as String? ?? s.store ?? _prefs().defaultStore;
    if (store == null) {
      return _httpError(const MealioFakeError('store_required', message: 'Pick a store', status: 400));
    }
    final e = s.errors['prepare'];
    if (e != null) return _jobError(store, e);
    final items = s.items.map(_itemJson).toList();
    final cartId = 'cart_${++_nCart}';
    _carts[cartId] = _Cart(store, <Product>[for (final MealioFakeItem i in s.items) ...i.options]);
    final Object? sentRecipes = body['recipes'] ?? (body['recipe'] == null ? null : <Object?>[body['recipe']]);
    final cart = <String, Object?>{
      'cartId': cartId,
      'store': store,
      'storeName': s.storeName ?? (store == 'heb' ? 'H-E-B' : store),
      'items': items,
      'ready': <Object?>[],
      'needsChoice': <Object?>[],
      'unavailable': <Object?>[],
      'recipes': s.recipes?.map((CartRecipe r) => r.toJson()).toList() ??
          <Object?>[
            for (final Object? r in sentRecipes is List ? sentRecipes : const <Object?>[])
              if (r is Map) <String, Object?>{'id': r['id'], 'title': r['title']},
          ],
      'warnings': s.warnings.map((CartWarning w) => w.toJson()).toList(),
    };
    // A Kroger family store has no page of its own: only its sign-in.
    final open = bundledStores[store]?.hosts.isNotEmpty ?? false
        ? <Object?>[
            <String, Object?>{'op': 'page_open', 'id': 'open-1', 'url': _home(store), 'timeoutMs': 15000},
          ]
        : <Object?>[];
    if (s.signIn == null) return _start(store, <Object?>[...open, _done(cart)]);
    final login = <String, Object?>{
      'op': 'show_login',
      'id': 'login-1',
      'url': _loginUrl(store),
      'title': 'Sign in',
      'doneWhen': <Object?>[
        <String, Object?>{'type': 'FAKE_SIGNED_IN'},
      ],
      'timeoutMs': 120000,
    };
    return _start(
      store,
      <Object?>[...open, login],
      (String? outcome) => outcome == 'signed_in'
          ? <Object?>[_done(cart)]
          : <Object?>[_failOp(const MealioFakeError('login_cancelled', message: 'Sign-in was closed'))],
    );
  }

  Future<http.Response> _search(String cartId, Map<String, Object?> body) async {
    final c = _carts[cartId];
    final store = c?.store ?? 'heb';
    final e = script.errors['search'];
    if (e != null) return _jobError(store, e);
    final query = '${body['query']}';
    final key = '${body['key']}';
    final fn = script.onSearch;
    final List<Product> found;
    if (fn != null) {
      found = fn(query, key);
    } else {
      found = script.search.entries
              .where((MapEntry<String, List<Product>> m) => m.key.toLowerCase() == query.toLowerCase())
              .firstOrNull
              ?.value ??
          const <Product>[];
    }
    c?.offered.addAll(found);
    return _start(store, <Object?>[
      _done(<String, Object?>{'key': key, 'query': query, 'options': found.map((Product p) => p.toJson()).toList()}),
    ]);
  }

  Future<http.Response> _add(String cartId, Map<String, Object?> body) async {
    final c = _carts[cartId];
    final store = c?.store ?? 'heb';
    final e = script.errors['add'] ?? script.addFailure;
    if (e != null) return _jobError(store, e);
    final offered = c?.offered ?? const <Product>[];
    final Object? raw = body['selections'];
    final selections = raw is List ? raw.map(Selection.fromJson).toList() : <Selection>[];
    final fn = script.onAdd;
    if (fn != null) return _start(store, <Object?>[_done(fn(selections, offered).toJson())]);
    final added = <Object?>[];
    final skipped = <Object?>[];
    final failed = <Object?>[];
    for (final Selection sel in selections) {
      final id = sel.productId;
      if (id == null || id.isEmpty) {
        skipped.add(<String, Object?>{'key': sel.key, 'reason': 'not_selected'});
        continue;
      }
      final p = offered.where((Product o) => o.id == id).firstOrNull;
      if (p == null) {
        failed.add(<String, Object?>{'key': sel.key, 'productId': id, 'name': id, 'reason': 'not_offered'});
        continue;
      }
      added.add(<String, Object?>{
        'key': sel.key,
        'productId': p.id,
        'name': p.name,
        'quantity': sel.quantity ?? 1,
        if (sel.weightLb != null) 'weightLb': sel.weightLb,
        if (p.unitPrice != null) 'unitPrice': p.unitPrice,
        if (p.pricePerLb != null) 'pricePerLb': p.pricePerLb,
        if (p.estimated) 'estimated': true,
      });
    }
    return _start(store, <Object?>[
      _done(<String, Object?>{
        'cartId': cartId,
        'store': store,
        'added': added,
        'skipped': skipped,
        'failed': failed,
        'storeCartUrl': '${_home(store)}cart',
        'verified': true,
      }),
    ]);
  }

  Future<http.Response> _answer(String kind, String path, Map<String, Object?>? body) async {
    final s = script;
    final b = body ?? const <String, Object?>{};
    final seg = path.split('/');
    switch (kind) {
      case 'stores':
        final e = s.errors['stores'];
        if (e != null) return _httpError(e);
        return _reply(<String, Object?>{
          'stores': (s.stores ?? const <StoreInfo>[StoreInfo(id: 'heb', name: 'H-E-B', via: 'device')])
              .map((StoreInfo x) => x.toJson())
              .toList(),
        });
      case 'preferences':
        final e = s.errors['preferences'];
        if (e != null) return _httpError(e);
        final store = b['store'];
        if (store is String) {
          final loc = b['locationId'];
          s.preferences = StorePreferences(
            defaultStore: store,
            location: loc is String ? s.locations.where((StoreLocation l) => l.id == loc).firstOrNull : _prefs().location,
          );
        }
        return _reply(_prefs().toJson());
      case 'locations':
        final e = s.errors['locations'];
        if (e != null) return _httpError(e);
        return _reply(<String, Object?>{'locations': s.locations.map((StoreLocation l) => l.toJson()).toList()});
      case 'warm':
        final store = b['store'] as String? ?? _prefs().defaultStore;
        final w = s.warm;
        if (store == null || w == null) return _reply(<String, Object?>{'warm': null});
        final e = s.errors['warm'];
        if (e != null) return _jobError(store, e);
        return _start(store, <Object?>[
          _done(<String, Object?>{'store': store, 'signedIn': w.signedIn}),
        ]);
      case 'prepare':
        return _prepare(b);
      case 'search':
        return _search(Uri.decodeComponent(seg[5]), b);
      case 'add':
        return _add(Uri.decodeComponent(seg[5]), b);
      case 'step':
        final job = Uri.decodeComponent(seg[5]);
        final j = _jobs.remove(job);
        if (j == null) {
          return _reply(<String, Object?>{
            'error': <String, Object?>{'code': 'unknown_job', 'message': 'No such job'},
          }, 404);
        }
        final Object? results = b['results'];
        String? outcome;
        if (results is List) {
          for (final Object? r in results) {
            if (r is Map && r['outcome'] is String) outcome = r['outcome']! as String;
          }
        }
        final seq = b['seq'] is num ? (b['seq']! as num).toInt() : 1;
        final env = await signMealioTestEnvelope(job, seq + 1, j.store, j.finish(outcome));
        return _reply(<String, Object?>{'envelope': env.toJson()});
      default:
        return _reply(<String, Object?>{});
    }
  }

  static String _kindOf(String path) {
    if (path == '/api/v1/stores') return 'stores';
    if (path == '/api/v1/sdk/preferences') return 'preferences';
    if (path == '/api/v1/sdk/locations') return 'locations';
    if (path == '/api/v1/sdk/warm') return 'warm';
    if (path == '/api/v1/sdk/carts') return 'prepare';
    if (RegExp(r'^/api/v1/sdk/carts/[^/]+/search$').hasMatch(path)) return 'search';
    if (RegExp(r'^/api/v1/sdk/carts/[^/]+/add$').hasMatch(path)) return 'add';
    if (RegExp(r'^/api/v1/sdk/jobs/[^/]+/step$').hasMatch(path)) return 'step';
    return 'other';
  }

  Future<http.Response> _handle(http.Request r) async {
    final path = r.url.path;
    Map<String, Object?>? body;
    if (r.body.isNotEmpty) {
      final Object? j = jsonDecode(r.body);
      if (j is Map<String, Object?>) body = j;
    }
    final auth = r.headers['Authorization'] ?? r.headers['authorization'];
    final kind = _kindOf(path);
    requests.add(MealioFakeRequest(kind, path, body, auth?.replaceFirst('Bearer ', '')));
    final held = _holds[kind];
    if (held != null && held.isNotEmpty) {
      _holding += 1;
      try {
        await held.removeAt(0);
      } finally {
        _holding -= 1;
      }
    }
    return _answer(kind, path, body);
  }

  int _holding = 0;
}

/// The fake server's http.Client: tells the client when a request is held.
class _HoldingHttp extends http.BaseClient implements MealioHoldingClient {
  _HoldingHttp(this._fake, this._inner);
  final MealioFake _fake;
  final http.Client _inner;

  @override
  int get holding => _fake._holding;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => _inner.send(request);

  @override
  void close() => _inner.close();
}

class _FakeHost implements MealioHost, MealioPageReset {
  _FakeHost(this._fake);
  final MealioFake _fake;

  @override
  Future<PageLoad> openPage(String store, String url, int timeoutMs) async {
    _fake.hostCalls.add('open $url');
    return PageLoad(ok: true, finalUrl: url);
  }

  @override
  Future<ScriptRun> runScript(String store, String guard, String script, List<MessageMatcher> until, int timeoutMs) async {
    _fake.hostCalls.add('script');
    return const ScriptRun(messages: <JsonMessage>[], timedOut: false);
  }

  @override
  Future<LoginResult> showLogin(LoginRequest request) async {
    _fake.hostCalls.add('login');
    if (request.cancel?.cancelled ?? false) {
      return const LoginResult(outcome: LoginOutcome.cancelled, messages: <JsonMessage>[]);
    }
    final want = _fake.script.signIn ?? 'signed_in';
    final outcome = LoginOutcome.values.firstWhere((LoginOutcome o) => o.wire == want, orElse: () => LoginOutcome.signedIn);
    return LoginResult(outcome: outcome, messages: const <JsonMessage>[]);
  }

  @override
  Future<HttpResult> fetch(String store, FetchRequest request, int timeoutMs, int maxBytes) async {
    _fake.hostCalls.add('fetch');
    return const HttpResult(ok: true, status: 200, headers: <String, String>{}, body: '');
  }

  @override
  Future<void> resetPage() async => _fake.hostCalls.add('reset');
}
