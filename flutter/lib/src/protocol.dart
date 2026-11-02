// The relay protocol, as Dart types. PROTOCOL.md is the prose version and wins
// any disagreement. packages/core/src/protocol.ts is the reference these
// classes mirror.
//
// Arbitrary JSON is typed `Object?` (null, bool, num, String, List, Map).
// Parsing is lenient on purpose: a field of the wrong type becomes a safe
// default instead of throwing, the same way the TypeScript reference passes
// `undefined` through. The allowlist and the verifier are what refuse bad
// input, not the parsers.

/// The protocol version this SDK speaks.
const int protocolVersion = 1;

/// Max instructions the SDK will accept in one envelope.
const int maxInstructions = 64;

/// Clock skew allowed when checking `exp`, in seconds.
const int expSkewSeconds = 120;

/// Every `op` this SDK can carry out.
const List<String> supportedOps = <String>[
  'page_open',
  'page_script',
  'show_login',
  'fetch',
  'done',
  'fail',
];

/// A JSON object posted by a page script.
typedef JsonMessage = Map<String, Object?>;

// ── lenient readers ────────────────────────────────────────────────────────

String _str(Object? v, [String fallback = '']) => v is String ? v : fallback;
String? _strOrNull(Object? v) => v is String ? v : null;
int _int(Object? v, int fallback) => v is num ? v.toInt() : fallback;
int? _intOrNull(Object? v) => v is num ? v.toInt() : null;
bool _bool(Object? v, [bool fallback = false]) => v is bool ? v : fallback;

Map<String, Object?>? _mapOrNull(Object? v) {
  if (v is! Map) return null;
  final out = <String, Object?>{};
  for (final MapEntry<Object?, Object?> e in v.entries) {
    final k = e.key;
    if (k is String) out[k] = e.value;
  }
  return out;
}

List<Object?> _list(Object? v) => v is List ? List<Object?>.of(v) : <Object?>[];

Map<String, String> _stringMap(Object? v) {
  final m = _mapOrNull(v);
  if (m == null) return <String, String>{};
  final out = <String, String>{};
  for (final MapEntry<String, Object?> e in m.entries) {
    final val = e.value;
    if (val != null) out[e.key] = val is String ? val : val.toString();
  }
  return out;
}

/// Puts `value` in `out` under `key` only when it is not null, the way
/// `JSON.stringify` drops `undefined` fields in the reference.
void _put(Map<String, Object?> out, String key, Object? value) {
  if (value != null) out[key] = value;
}

// ── envelope ───────────────────────────────────────────────────────────────

/// `{ payload, sig, kid }` as it arrived. Fields are nullable because the
/// shape check lives in `openEnvelope`, which refuses with `shape`.
class Envelope {
  const Envelope({required this.payload, required this.sig, required this.kid});

  /// Never throws. A missing or mistyped field is kept as null (or `''` for
  /// `kid`, which `openEnvelope` then refuses as `unknown_kid`).
  factory Envelope.fromJson(Object? json) {
    final m = _mapOrNull(json);
    if (m == null) return const Envelope(payload: null, sig: null, kid: '');
    return Envelope(
      payload: _strOrNull(m['payload']),
      sig: _strOrNull(m['sig']),
      kid: _str(m['kid']),
    );
  }

  /// The payload JSON string, exactly as received. The signature covers its
  /// UTF-8 bytes, so it must never be re-serialized.
  final String? payload;
  final String? sig;
  final String kid;

  Map<String, Object?> toJson() => <String, Object?>{'payload': payload, 'sig': sig, 'kid': kid};
}

// ── matcher ────────────────────────────────────────────────────────────────

/// `{ type, eq?, ne? }`. See PROTOCOL.md "Matcher".
class MessageMatcher {
  const MessageMatcher({required this.type, this.eq, this.ne});

  factory MessageMatcher.fromJson(Object? json) {
    final m = _mapOrNull(json) ?? const <String, Object?>{};
    return MessageMatcher(type: _str(m['type']), eq: _mapOrNull(m['eq']), ne: _mapOrNull(m['ne']));
  }

  final String type;
  final Map<String, Object?>? eq;
  final Map<String, Object?>? ne;

  Map<String, Object?> toJson() {
    final out = <String, Object?>{'type': type};
    _put(out, 'eq', eq);
    _put(out, 'ne', ne);
    return out;
  }
}

List<MessageMatcher> _matchers(Object? v) => _list(v).map(MessageMatcher.fromJson).toList();

// ── instructions ───────────────────────────────────────────────────────────

/// One instruction from a signed envelope.
sealed class Instruction {
  const Instruction({required this.id});

  /// Builds the typed instruction. Call only after `checkInstructions` has
  /// confirmed `op` is supported and `id` is a string.
  factory Instruction.fromJson(Map<String, Object?> m) {
    final id = _str(m['id']);
    switch (m['op']) {
      case 'page_open':
        return PageOpen(id: id, url: _str(m['url']), timeoutMs: _int(m['timeoutMs'], 15000));
      case 'page_script':
        return PageScript(
          id: id,
          script: _str(m['script']),
          until: _matchers(m['until']),
          timeoutMs: _int(m['timeoutMs'], 20000),
        );
      case 'show_login':
        final check = _mapOrNull(m['check']);
        return ShowLogin(
          id: id,
          url: _str(m['url']),
          title: _str(m['title']),
          check: check == null
              ? null
              : LoginCheck(script: _str(check['script']), intervalMs: _int(check['intervalMs'], 3000)),
          doneWhen: _matchers(m['doneWhen']),
          doneWhenUrl: _strOrNull(m['doneWhenUrl']),
          timeoutMs: _int(m['timeoutMs'], 600000),
        );
      case 'fetch':
        return FetchOp(
          id: id,
          request: FetchRequest.fromJson(m['request']),
          timeoutMs: _int(m['timeoutMs'], 12000),
          maxBytes: _int(m['maxBytes'], 400000),
        );
      case 'done':
        return DoneOp(id: id, result: m['result']);
      case 'fail':
        return FailOp(id: id, code: _str(m['code'], 'server'), message: _str(m['message']));
      default:
        throw ArgumentError.value(m['op'], 'op', 'unsupported');
    }
  }

  final String id;

  String get op;

  Map<String, Object?> toJson();
}

class PageOpen extends Instruction {
  const PageOpen({required super.id, required this.url, required this.timeoutMs});
  final String url;
  final int timeoutMs;
  @override
  String get op => 'page_open';
  @override
  Map<String, Object?> toJson() => <String, Object?>{'op': op, 'id': id, 'url': url, 'timeoutMs': timeoutMs};
}

class PageScript extends Instruction {
  const PageScript({required super.id, required this.script, required this.until, required this.timeoutMs});
  final String script;
  final List<MessageMatcher> until;
  final int timeoutMs;
  @override
  String get op => 'page_script';
  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'op': op,
        'id': id,
        'script': script,
        'until': until.map((MessageMatcher m) => m.toJson()).toList(),
        'timeoutMs': timeoutMs,
      };
}

/// `check` on a `show_login` instruction.
class LoginCheck {
  const LoginCheck({required this.script, required this.intervalMs});
  final String script;
  final int intervalMs;
  Map<String, Object?> toJson() => <String, Object?>{'script': script, 'intervalMs': intervalMs};
}

class ShowLogin extends Instruction {
  const ShowLogin({
    required super.id,
    required this.url,
    required this.title,
    required this.check,
    required this.doneWhen,
    required this.doneWhenUrl,
    required this.timeoutMs,
  });
  final String url;
  final String title;
  final LoginCheck? check;
  final List<MessageMatcher> doneWhen;

  /// A regex source. A navigation whose URL matches it means signed in.
  final String? doneWhenUrl;
  final int timeoutMs;
  @override
  String get op => 'show_login';
  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'op': op,
        'id': id,
        'url': url,
        'title': title,
        'check': check?.toJson(),
        'doneWhen': doneWhen.map((MessageMatcher m) => m.toJson()).toList(),
        'doneWhenUrl': doneWhenUrl,
        'timeoutMs': timeoutMs,
      };
}

/// The HTTP request inside a `fetch` instruction.
class FetchRequest {
  const FetchRequest({required this.method, required this.url, this.headers = const <String, String>{}, this.body});

  factory FetchRequest.fromJson(Object? json) {
    final m = _mapOrNull(json) ?? const <String, Object?>{};
    return FetchRequest(
      method: _str(m['method'], 'GET'),
      url: _str(m['url']),
      headers: _stringMap(m['headers']),
      body: _strOrNull(m['body']),
    );
  }

  final String method;
  final String url;
  final Map<String, String> headers;
  final String? body;

  Map<String, Object?> toJson() => <String, Object?>{'method': method, 'url': url, 'headers': headers, 'body': body};
}

class FetchOp extends Instruction {
  const FetchOp({required super.id, required this.request, required this.timeoutMs, required this.maxBytes});
  final FetchRequest request;
  final int timeoutMs;
  final int maxBytes;
  @override
  String get op => 'fetch';
  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'op': op,
        'id': id,
        'request': request.toJson(),
        'timeoutMs': timeoutMs,
        'maxBytes': maxBytes,
      };
}

class DoneOp extends Instruction {
  const DoneOp({required super.id, required this.result});
  final Object? result;
  @override
  String get op => 'done';
  @override
  Map<String, Object?> toJson() => <String, Object?>{'op': op, 'id': id, 'result': result};
}

class FailOp extends Instruction {
  const FailOp({required super.id, required this.code, required this.message});
  final String code;
  final String message;
  @override
  String get op => 'fail';
  @override
  Map<String, Object?> toJson() => <String, Object?>{'op': op, 'id': id, 'code': code, 'message': message};
}

// ── payloads ───────────────────────────────────────────────────────────────

/// A payload whose signature, version and expiry have been checked, before
/// its kind-specific checks. `raw` is the parsed payload object.
class Payload {
  const Payload(this.raw);
  final Map<String, Object?> raw;
  Object? get v => raw['v'];
  Object? get kind => raw['kind'];
  Object? get exp => raw['exp'];
}

/// `kind: "instructions"`, after `checkInstructions`.
class InstructionsPayload {
  const InstructionsPayload({
    required this.v,
    required this.job,
    required this.seq,
    required this.exp,
    required this.store,
    required this.instructions,
  });
  final int v;
  final String job;
  final int seq;
  final num exp;
  final String store;
  final List<Instruction> instructions;
  String get kind => 'instructions';
}

/// Host additions for one store in an allowlist envelope.
class StoreHostsUpdate {
  const StoreHostsUpdate({this.hosts = const <String>[], this.authHosts = const <String>[]});
  final List<String> hosts;
  final List<String> authHosts;
}

/// `kind: "allowlist"`: widens store hosts. See PROTOCOL.md "Allowlist".
class AllowlistPayload {
  const AllowlistPayload({required this.v, required this.exp, required this.stores});

  factory AllowlistPayload.fromJson(Map<String, Object?> m) {
    final stores = <String, StoreHostsUpdate>{};
    final entries = (_mapOrNull(m['stores']) ?? const <String, Object?>{}).entries;
    for (final MapEntry<String, Object?> e in entries) {
      final s = _mapOrNull(e.value) ?? const <String, Object?>{};
      stores[e.key] = StoreHostsUpdate(
        hosts: _list(s['hosts']).whereType<String>().toList(),
        authHosts: _list(s['authHosts']).whereType<String>().toList(),
      );
    }
    return AllowlistPayload(v: _int(m['v'], 0), exp: m['exp'] is num ? m['exp']! as num : 0, stores: stores);
  }

  final int v;
  final num exp;
  final Map<String, StoreHostsUpdate> stores;
  String get kind => 'allowlist';
}

// ── results ────────────────────────────────────────────────────────────────

/// One result per instruction, in order. `toJson` is the wire form.
sealed class InstructionResult {
  const InstructionResult({required this.id, required this.ok, required this.ms, this.error, this.skipped = false});
  final String id;
  final bool ok;
  final int ms;
  final String? error;
  final bool skipped;

  Map<String, Object?> toJson();

  Map<String, Object?> _base() {
    final out = <String, Object?>{'id': id, 'ok': ok};
    return out;
  }

  Map<String, Object?> _tail(Map<String, Object?> out) {
    _put(out, 'error', error);
    out['ms'] = ms;
    if (skipped) out['skipped'] = true;
    return out;
  }
}

class PageOpenResult extends InstructionResult {
  const PageOpenResult({required super.id, required super.ok, required super.ms, this.finalUrl, super.error, super.skipped});
  final String? finalUrl;
  @override
  Map<String, Object?> toJson() {
    final out = _base();
    _put(out, 'finalUrl', finalUrl);
    return _tail(out);
  }
}

class PageScriptResult extends InstructionResult {
  const PageScriptResult({
    required super.id,
    required super.ok,
    required super.ms,
    required this.messages,
    required this.timedOut,
    super.error,
    super.skipped,
  });
  final List<JsonMessage> messages;
  final bool timedOut;
  @override
  Map<String, Object?> toJson() {
    final out = _base();
    out['messages'] = messages;
    out['timedOut'] = timedOut;
    return _tail(out);
  }
}

/// How a login sheet ended.
enum LoginOutcome {
  signedIn('signed_in'),
  cancelled('cancelled'),
  timeout('timeout');

  const LoginOutcome(this.wire);

  /// The string on the wire.
  final String wire;
}

class ShowLoginResult extends InstructionResult {
  const ShowLoginResult({
    required super.id,
    required super.ok,
    required super.ms,
    required this.outcome,
    required this.messages,
    super.error,
    super.skipped,
  });
  final LoginOutcome outcome;
  final List<JsonMessage> messages;
  @override
  Map<String, Object?> toJson() {
    final out = _base();
    out['outcome'] = outcome.wire;
    out['messages'] = messages;
    return _tail(out);
  }
}

class FetchResult extends InstructionResult {
  const FetchResult({
    required super.id,
    required super.ok,
    required super.ms,
    this.status,
    this.headers,
    this.body,
    this.truncated,
    super.error,
    super.skipped,
  });
  final int? status;
  final Map<String, String>? headers;
  final String? body;
  final bool? truncated;
  @override
  Map<String, Object?> toJson() {
    final out = _base();
    _put(out, 'status', status);
    _put(out, 'headers', headers);
    _put(out, 'body', body);
    _put(out, 'truncated', truncated);
    return _tail(out);
  }
}

/// Body of `POST /api/v1/sdk/jobs/{job}/step`.
class StepRequest {
  const StepRequest({required this.seq, required this.results});
  final int seq;
  final List<InstructionResult> results;
  Map<String, Object?> toJson() => <String, Object?>{
        'seq': seq,
        'results': results.map((InstructionResult r) => r.toJson()).toList(),
      };
}

// ── what the server hands back from a finished job ─────────────────────────

/// A product variant the user must pick (H-E-B: "sliced or shaved?").
class ProductPreference {
  const ProductPreference({required this.id, required this.label});
  factory ProductPreference.fromJson(Object? json) {
    final m = _mapOrNull(json) ?? const <String, Object?>{};
    return ProductPreference(id: _str(m['id']), label: _str(m['label']));
  }
  final String id;
  final String label;
  Map<String, Object?> toJson() => <String, Object?>{'id': id, 'label': label};
}

class Product {
  const Product({
    required this.id,
    required this.name,
    this.price,
    this.imageUrl,
    this.size,
    this.outOfStock = false,
    this.badge,
    this.preferences = const <ProductPreference>[],
  });

  factory Product.fromJson(Object? json) {
    final m = _mapOrNull(json) ?? const <String, Object?>{};
    return Product(
      id: _str(m['id']),
      name: _str(m['name']),
      price: _strOrNull(m['price']),
      imageUrl: _strOrNull(m['imageUrl']),
      size: _strOrNull(m['size']),
      outOfStock: _bool(m['outOfStock']),
      badge: _strOrNull(m['badge']),
      preferences: _list(m['preferences']).map(ProductPreference.fromJson).toList(),
    );
  }

  final String id;
  final String name;
  final String? price;
  final String? imageUrl;
  final String? size;
  final bool outOfStock;

  /// Why this option sits where it does: `picked_before`, `popular` or
  /// `partner_pick`. Ranking only, never an automatic pick.
  final String? badge;

  /// Variants the user must pick one of before this product can be added.
  /// Pass the chosen id as `preferenceId`.
  final List<ProductPreference> preferences;

  Map<String, Object?> toJson() {
    final out = <String, Object?>{'id': id, 'name': name};
    _put(out, 'price', price);
    _put(out, 'imageUrl', imageUrl);
    _put(out, 'size', size);
    out['outOfStock'] = outOfStock;
    _put(out, 'badge', badge);
    if (preferences.isNotEmpty) out['preferences'] = preferences.map((ProductPreference p) => p.toJson()).toList();
    return out;
  }
}

class CartItem {
  const CartItem({
    required this.key,
    required this.ingredient,
    required this.quantity,
    this.chosen,
    this.options = const <Product>[],
    this.reason,
  });

  factory CartItem.fromJson(Object? json) {
    final m = _mapOrNull(json) ?? const <String, Object?>{};
    return CartItem(
      key: _str(m['key']),
      ingredient: _str(m['ingredient']),
      quantity: _int(m['quantity'], 1),
      chosen: m['chosen'] == null ? null : Product.fromJson(m['chosen']),
      options: _list(m['options']).map(Product.fromJson).toList(),
      reason: _strOrNull(m['reason']),
    );
  }

  final String key;
  final String ingredient;
  final int quantity;

  /// Set when the user chose this product before for this recipe and it is in stock.
  final Product? chosen;

  /// Up to 8 options, best first. Present when the user still has to choose.
  final List<Product> options;

  /// Why nothing could be offered, e.g. "no_results".
  final String? reason;

  Map<String, Object?> toJson() {
    final out = <String, Object?>{'key': key, 'ingredient': ingredient, 'quantity': quantity};
    _put(out, 'chosen', chosen?.toJson());
    out['options'] = options.map((Product p) => p.toJson()).toList();
    _put(out, 'reason', reason);
    return out;
  }
}

List<CartItem> _items(Object? v) => _list(v).map(CartItem.fromJson).toList();

class PreparedCart {
  const PreparedCart({
    required this.cartId,
    required this.store,
    required this.ready,
    required this.needsChoice,
    required this.unavailable,
  });

  factory PreparedCart.fromJson(Object? json) {
    final m = _mapOrNull(json) ?? const <String, Object?>{};
    return PreparedCart(
      cartId: _str(m['cartId']),
      store: _str(m['store']),
      ready: _items(m['ready']),
      needsChoice: _items(m['needsChoice']),
      unavailable: _items(m['unavailable']),
    );
  }

  final String cartId;
  final String store;
  final List<CartItem> ready;
  final List<CartItem> needsChoice;
  final List<CartItem> unavailable;

  Map<String, Object?> toJson() => <String, Object?>{
        'cartId': cartId,
        'store': store,
        'ready': ready.map((CartItem i) => i.toJson()).toList(),
        'needsChoice': needsChoice.map((CartItem i) => i.toJson()).toList(),
        'unavailable': unavailable.map((CartItem i) => i.toJson()).toList(),
      };
}

class AddedItem {
  const AddedItem({required this.key, required this.productId, required this.name, required this.quantity});
  factory AddedItem.fromJson(Object? json) {
    final m = _mapOrNull(json) ?? const <String, Object?>{};
    return AddedItem(
      key: _str(m['key']),
      productId: _str(m['productId']),
      name: _str(m['name']),
      quantity: _int(m['quantity'], 1),
    );
  }
  final String key;
  final String productId;
  final String name;
  final int quantity;
  Map<String, Object?> toJson() =>
      <String, Object?>{'key': key, 'productId': productId, 'name': name, 'quantity': quantity};
}

class SkippedItem {
  const SkippedItem({required this.key, required this.reason});
  factory SkippedItem.fromJson(Object? json) {
    final m = _mapOrNull(json) ?? const <String, Object?>{};
    return SkippedItem(key: _str(m['key']), reason: _str(m['reason']));
  }
  final String key;
  final String reason;
  Map<String, Object?> toJson() => <String, Object?>{'key': key, 'reason': reason};
}

class FailedItem {
  const FailedItem({required this.key, required this.productId, required this.name, required this.reason});
  factory FailedItem.fromJson(Object? json) {
    final m = _mapOrNull(json) ?? const <String, Object?>{};
    return FailedItem(
      key: _str(m['key']),
      productId: _str(m['productId']),
      name: _str(m['name']),
      reason: _str(m['reason']),
    );
  }
  final String key;
  final String productId;
  final String name;
  final String reason;
  Map<String, Object?> toJson() =>
      <String, Object?>{'key': key, 'productId': productId, 'name': name, 'reason': reason};
}

class AddResult {
  const AddResult({
    required this.cartId,
    required this.store,
    required this.added,
    required this.skipped,
    required this.failed,
    required this.storeCartUrl,
  });

  factory AddResult.fromJson(Object? json) {
    final m = _mapOrNull(json) ?? const <String, Object?>{};
    return AddResult(
      cartId: _str(m['cartId']),
      store: _str(m['store']),
      added: _list(m['added']).map(AddedItem.fromJson).toList(),
      skipped: _list(m['skipped']).map(SkippedItem.fromJson).toList(),
      failed: _list(m['failed']).map(FailedItem.fromJson).toList(),
      storeCartUrl: _strOrNull(m['storeCartUrl']),
    );
  }

  final String cartId;
  final String store;
  final List<AddedItem> added;
  final List<SkippedItem> skipped;
  final List<FailedItem> failed;
  final String? storeCartUrl;

  Map<String, Object?> toJson() => <String, Object?>{
        'cartId': cartId,
        'store': store,
        'added': added.map((AddedItem a) => a.toJson()).toList(),
        'skipped': skipped.map((SkippedItem s) => s.toJson()).toList(),
        'failed': failed.map((FailedItem f) => f.toJson()).toList(),
        'storeCartUrl': storeCartUrl,
      };
}

/// The user's decision for one item, sent to `/carts/{cart}/add`.
class Selection {
  const Selection({required this.key, required this.productId, this.quantity, this.remember, this.preferenceId});

  factory Selection.fromJson(Object? json) {
    final m = _mapOrNull(json) ?? const <String, Object?>{};
    return Selection(
      key: _str(m['key']),
      productId: _strOrNull(m['productId']),
      quantity: _intOrNull(m['quantity']),
      remember: m['remember'] is bool ? m['remember']! as bool : null,
      preferenceId: _strOrNull(m['preferenceId']),
    );
  }

  final String key;

  /// Null means "skip this item".
  final String? productId;
  final int? quantity;

  /// Save this choice for the next time this recipe is carted. Default true.
  final bool? remember;

  /// Required when the chosen Product has `preferences`.
  final String? preferenceId;

  Map<String, Object?> toJson() {
    final out = <String, Object?>{'key': key, 'productId': productId};
    _put(out, 'quantity', quantity);
    _put(out, 'remember', remember);
    _put(out, 'preferenceId', preferenceId);
    return out;
  }
}

class RecipeIngredient {
  const RecipeIngredient({required this.name, this.quantity, this.amount, this.unit});

  factory RecipeIngredient.fromJson(Object? json) {
    final m = _mapOrNull(json) ?? const <String, Object?>{};
    return RecipeIngredient(
      name: _str(m['name']),
      quantity: _intOrNull(m['quantity']),
      amount: m['amount'] is num ? m['amount']! as num : null,
      unit: _strOrNull(m['unit']),
    );
  }

  final String name;

  /// Packages to buy. Defaults to 1 on the server.
  final int? quantity;
  final num? amount;
  final String? unit;

  Map<String, Object?> toJson() {
    final out = <String, Object?>{'name': name};
    _put(out, 'quantity', quantity);
    _put(out, 'amount', amount);
    _put(out, 'unit', unit);
    return out;
  }
}

class Recipe {
  const Recipe({required this.id, this.title, required this.ingredients});

  factory Recipe.fromJson(Object? json) {
    final m = _mapOrNull(json) ?? const <String, Object?>{};
    return Recipe(
      id: _str(m['id']),
      title: _strOrNull(m['title']),
      ingredients: _list(m['ingredients']).map(RecipeIngredient.fromJson).toList(),
    );
  }

  final String id;
  final String? title;
  final List<RecipeIngredient> ingredients;

  Map<String, Object?> toJson() {
    final out = <String, Object?>{'id': id};
    _put(out, 'title', title);
    out['ingredients'] = ingredients.map((RecipeIngredient i) => i.toJson()).toList();
    return out;
  }
}
