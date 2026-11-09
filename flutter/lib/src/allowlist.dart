// The allowlist. It lives in the SDK so a compromised server cannot turn it
// off. PROTOCOL.md "Allowlist" is the spec; packages/core/src/allowlist.ts is
// the reference this mirrors.

import 'dart:convert';

import 'protocol.dart';

/// Never relaxed remotely. Case-insensitive, tested against path + query.
const List<String> blockedPatterns = <String>[
  'checkout',
  'payment',
  'billing',
  'wallet',
  'place[-_]?order',
  'submit[-_]?order',
  'order[-_]?confirm',
  'gift-?card',
  '/account/(delete|close|security|password)',
  '/addresses?/(add|edit|delete|new)',
  r'/orders?/(submit|place)(/|\?|$)',
  '/cart/confirm',
  r'/purchase(/|\?|$)',
];

final RegExp _blockedRe = RegExp(blockedPatterns.join('|'), caseSensitive: false);

/// A store's hosts.
class StoreHosts {
  StoreHosts({required List<String> hosts, required List<String> authHosts})
      : hosts = List<String>.of(hosts),
        authHosts = List<String>.of(authHosts);

  /// The store's own hosts. Subdomains are allowed too.
  final List<String> hosts;

  /// Hosts the login sheet may visit (identity providers).
  final List<String> authHosts;

  StoreHosts copy() => StoreHosts(hosts: hosts, authHosts: authHosts);
}

/// Hosts every store's login may return to.
const List<String> mealioHosts = <String>['mealio.co'];

/// Identity providers a store's login page may hand off to, for every store.
/// Only TOP-FRAME navigations in the login sheet are checked; captcha and
/// consent iframes inside a store page are not navigations of the sheet.
const List<String> commonAuthHosts = <String>['accounts.google.com', 'appleid.apple.com', 'facebook.com'];

/// Multi-tenant identity providers, ONLY for the store that uses them. Anyone
/// can register a tenant on okta.com or b2clogin.com, so allowing the whole
/// provider for every store let any tenant's page into the sign-in sheet.
/// Albertsons signs in through its own Okta tenant. Wegmans uses Azure AD B2C,
/// whose tenant host the page reads at run time, so B2C stays provider-wide but
/// for Wegmans alone.
const List<String> albertsonsAuthHosts = <String>['albertsons.com', 'albertsons.okta.com'];
const List<String> wegmansAuthHosts = <String>['b2clogin.com', 'ciamlogin.com', 'login.microsoftonline.com'];

// Store ids match mealio_app/src/constants/stores.ts and the server catalog.
const Map<String, String> _albertsonsBanners = <String, String>{
  'albertsons': 'albertsons.com',
  'safeway': 'safeway.com',
  'vons': 'vons.com',
  'jewel_osco': 'jewelosco.com',
  'shaws': 'shaws.com',
  'acme': 'acmemarkets.com',
  'tom_thumb': 'tomthumb.com',
  'randalls': 'randalls.com',
  'pavilions': 'pavilions.com',
  'star_market': 'starmarket.com',
  'haggen': 'haggen.com',
  'carrs': 'carrsqc.com',
  'kings': 'kingsfoodmarkets.com',
  'balduccis': 'balduccis.com',
  'united': 'shopunitedsupermarkets.com',
};

const Map<String, String> _instacartTenants = <String, String>{
  'aldi': 'aldi.us',
  'publix': 'delivery.publix.com',
  'bristol_farms': 'shop.bristolfarms.com',
  'save_mart': 'shop.savemart.com',
  'gelsons': 'shop.gelsons.com',
  'dierbergs': 'shop.dierbergs.com',
  'sprouts': 'shop.sprouts.com',
  'the_fresh_market': 'shop.thefreshmarket.com',
  'costco_sameday': 'sameday.costco.com',
};

const List<String> _krogerBanners = <String>[
  'kroger',
  'bakers',
  'city_market',
  'dillons',
  'fred_meyer',
  'frys',
  'harris_teeter',
  'king_soopers',
  'marianos',
  'metro_market',
  'pay_less',
  'pick_n_save',
  'qfc',
  'ralphs',
  'smiths',
];

Map<String, StoreHosts> _bundled() {
  final out = <String, StoreHosts>{
    'heb': StoreHosts(hosts: <String>['heb.com'], authHosts: <String>[]),
    'wegmans': StoreHosts(hosts: <String>['wegmans.com'], authHosts: wegmansAuthHosts),
  };
  for (final MapEntry<String, String> e in _albertsonsBanners.entries) {
    out[e.key] = StoreHosts(hosts: <String>[e.value], authHosts: albertsonsAuthHosts);
  }
  for (final MapEntry<String, String> e in _instacartTenants.entries) {
    out[e.key] = StoreHosts(hosts: <String>[e.value], authHosts: <String>['instacart.com']);
  }
  // The Kroger family is server-side through Kroger's API. The SDK only ever
  // shows Kroger's OAuth consent page.
  for (final String id in _krogerBanners) {
    out[id] = StoreHosts(hosts: <String>[], authHosts: <String>['api.kroger.com', 'login.kroger.com', 'kroger.com']);
  }
  return out;
}

/// The bundled store list. Treat as read-only; `Allowlist` copies it.
final Map<String, StoreHosts> bundledStores = _bundled();

/// Last two labels, with a short list of two-label public suffixes.
String registrableDomain(String host) {
  final parts = host.toLowerCase().split('.').where((String p) => p.isNotEmpty).toList();
  if (parts.length <= 2) return parts.join('.');
  final last2 = parts.sublist(parts.length - 2).join('.');
  if (const <String>['co.uk', 'com.au', 'co.nz'].contains(last2)) {
    return parts.sublist(parts.length - 3).join('.');
  }
  return last2;
}

bool _hostMatches(String host, String allowed) {
  final h = host.toLowerCase();
  final a = allowed.toLowerCase();
  return h == a || h.endsWith('.$a');
}

/// What a URL is about to be used for.
enum UrlUse { page, fetch, login }

/// Why a URL was refused. `null` reason means allowed.
class UrlVerdict {
  const UrlVerdict.allowed()
      : ok = true,
        reason = null;
  const UrlVerdict.refused(String this.reason) : ok = false;

  final bool ok;

  /// `bad_url`, `not_https`, `host`, `blocked_path` or `unknown_store`.
  final String? reason;
}

class Allowlist {
  Allowlist([Map<String, StoreHosts>? base]) {
    for (final MapEntry<String, StoreHosts> e in (base ?? bundledStores).entries) {
      _stores[e.key] = e.value.copy();
    }
  }

  final Map<String, StoreHosts> _stores = <String, StoreHosts>{};

  /// Widen hosts from a signed allowlist payload. A new host must share a
  /// registrable domain with a host already listed for that store; anything
  /// else is ignored. Stores the SDK does not know are ignored.
  void widen(AllowlistPayload p) {
    for (final MapEntry<String, StoreHostsUpdate> e in p.stores.entries) {
      final cur = _stores[e.key];
      final add = e.value;
      if (cur == null) continue;
      final known = <String>{...cur.hosts, ...cur.authHosts}.map(registrableDomain).toSet();
      for (final String h in add.hosts) {
        if (known.contains(registrableDomain(h)) && !cur.hosts.contains(h)) cur.hosts.add(h);
      }
      for (final String h in add.authHosts) {
        if (known.contains(registrableDomain(h)) && !cur.authHosts.contains(h)) cur.authHosts.add(h);
      }
    }
  }

  /// A copy of the store's current hosts, or null for an unknown store.
  StoreHosts? hostsFor(String store) => _stores[store]?.copy();

  UrlVerdict check(String store, String url, UrlUse use) {
    final s = _stores[store];
    if (s == null) return const UrlVerdict.refused('unknown_store');
    final p = parseUrl(url);
    if (p == null) return const UrlVerdict.refused('bad_url');
    if (p.scheme != 'https') return const UrlVerdict.refused('not_https');
    final host = p.host;
    final rest = p.rest;
    final own = s.hosts.any((String a) => _hostMatches(host, a));
    final auth = use == UrlUse.login &&
        <String>[...s.authHosts, ...commonAuthHosts, ...mealioHosts].any((String a) => _hostMatches(host, a));
    if (!own && !auth) return const UrlVerdict.refused('host');
    if (isBlockedPath(rest)) return const UrlVerdict.refused('blocked_path');
    return const UrlVerdict.allowed();
  }
}

/// A URL split into scheme, host and path + query (no fragment).
class ParsedUrl {
  const ParsedUrl({required this.scheme, required this.host, required this.rest});

  /// Lower-cased.
  final String scheme;

  /// Lower-cased, without the port.
  final String host;

  /// Path and query, `/` when empty.
  final String rest;
}

final RegExp _badUrlCharRe = RegExp(r'[\\\s\u0000-\u001f\u007f]');
final RegExp _urlRe = RegExp(r'^([a-z][a-z0-9+.-]*)://([^/?#]*)([^#]*)', caseSensitive: false);
final RegExp _authorityRe = RegExp(r'^([a-z0-9-]+(?:\.[a-z0-9-]+)*)(?::\d{1,5})?$', caseSensitive: false);

/// Split a URL into scheme, host and path + query, or null if it is not one we
/// will reason about. STRICT on purpose: the authority must be a bare host name
/// with an optional port. A browser reads `https://www.heb.com:x@evil.com/` as
/// host evil.com, and `https://evil.com\.heb.com/` as host evil.com too, while
/// a looser pattern read both as heb.com. So userinfo (@), backslashes,
/// whitespace and control characters anywhere are refused outright, as is any
/// host that is not plain ASCII letters, digits, dots and hyphens.
ParsedUrl? parseUrl(String? url) {
  final raw = url ?? '';
  if (_badUrlCharRe.hasMatch(raw)) return null;
  final m = _urlRe.firstMatch(raw);
  if (m == null) return null;
  final a = _authorityRe.firstMatch(m.group(2) ?? '');
  if (a == null) return null;
  var rest = m.group(3) ?? '';
  if (rest.isEmpty) rest = '/';
  if (!rest.startsWith('/') && !rest.startsWith('?')) rest = '/$rest';
  return ParsedUrl(scheme: m.group(1)!.toLowerCase(), host: a.group(1)!.toLowerCase(), rest: rest);
}

final RegExp _percentRe = RegExp('%([0-9a-f]{2})', caseSensitive: false);

/// Percent-decoding, twice, of %XX only: a server decodes `%63heckout` to `checkout`.
String decodePercent(String s) {
  var out = s;
  for (var i = 0; i < 2; i += 1) {
    out = out.replaceAllMapped(_percentRe, (Match m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)));
  }
  return out;
}

bool isBlockedPath(String pathAndQuery) =>
    _blockedRe.hasMatch(pathAndQuery) || _blockedRe.hasMatch(decodePercent(pathAndQuery));

/// Operation and field names no request may carry (case-insensitive regex
/// source). Every SDK and the guard script use this exact list.
const String blockedGraphqlOperation =
    'check_?out|place_?order|submit_?order|confirm_?order|create_?order|purchase|payment';

final RegExp _opsRe = RegExp(blockedGraphqlOperation, caseSensitive: false);
/// A field of a multipart/form-data body sent as raw text (a string with the
/// boundaries in it, not form data). Group 1 is the field's name, group 2 its
/// value: everything after the part's blank line up to the next boundary line
/// or the end. Parts named operationName, query and operations are judged as
/// the form fields of the same names. The name may be double-quoted,
/// single-quoted or bare (`name=operations`), as servers accept all three; a
/// longer name (`operationsX`) is a different field. MULTIPART_FIELD in allowlist.ts.
const String multipartField =
    r'''name=["']?(operationName|query|operations)(?=["';\s]|$)[^\r\n]*\r?\n(?:[^\r\n]+\r?\n)*\r?\n([\s\S]*?)(?=\r?\n--|$)''';

/// Every match of [multipartField] (all of them, as `allMatches` finds) in
/// [s], as (name, value) pairs, in one linear pass. multipartFields in
/// allowlist.ts, step for step. Run as a regex, [multipartField] is quadratic
/// (a body of `name=query\n` lines rescans every line from every name), so it
/// is the spec and this the implementation; round6_test checks them against
/// each other. Two caches keep it linear: the first line break after a name,
/// shared by every later name before it, and the end of a run of header
/// lines, which a later header ending inside the run reaches too.
List<(String, String)> multipartFields(String s) {
  final n = s.length;
  final out = <(String, String)>[];
  var nextBreak = -1; // first \r or \n at or after nextBreakFrom
  var nextBreakFrom = n + 1;
  var runFrom = n + 1, runEnd = -1; // a run of header lines from runFrom ends at runEnd
  bool isBreak(int c) => c == 0x0a || c == 0x0d;
  // `\r?\n` at i: the index after it, or -1.
  int lineBreak(int i) {
    if (i < n && s.codeUnitAt(i) == 0x0a) return i + 1;
    if (i + 1 < n && s.codeUnitAt(i) == 0x0d && s.codeUnitAt(i + 1) == 0x0a) return i + 2;
    return -1;
  }

  var from = 0;
  while (from < n) {
    final p = s.indexOf('name=', from);
    if (p < 0) break;
    from = p + 1;
    // ["']? then one of the names (at most one can match: they differ before
    // either ends), then (?=["';\s]|$).
    var i = p + 5;
    if (i < n && (s.codeUnitAt(i) == 0x22 || s.codeUnitAt(i) == 0x27)) i++;
    String? name;
    for (final String w in const <String>['operationName', 'query', 'operations']) {
      if (s.startsWith(w, i)) {
        name = w;
        break;
      }
    }
    if (name == null) continue;
    i += name.length;
    if (i < n && !_partNameEnd(s.codeUnitAt(i))) continue;
    // [^\r\n]*\r?\n: to the first break, which must be \n or \r\n.
    if (nextBreakFrom > i || nextBreak < i) {
      var j = i;
      while (j < n && !isBreak(s.codeUnitAt(j))) {
        j++;
      }
      nextBreak = j;
    }
    nextBreakFrom = i;
    final e1 = lineBreak(nextBreak);
    if (e1 < 0) continue;
    // (?:[^\r\n]+\r?\n)*: every non-empty line that ends in \n or \r\n, as
    // many as there are (giving one back never helps: the blank line cannot
    // start with a character a line has). The run from any line start inside
    // one already scanned ends where that one did.
    int f;
    if (e1 >= runFrom && e1 <= runEnd) {
      f = runEnd;
    } else {
      f = e1;
      while (true) {
        var j = f;
        while (j < n && !isBreak(s.codeUnitAt(j))) {
          j++;
        }
        if (j == f) break;
        final k = lineBreak(j);
        if (k < 0) break;
        f = k;
      }
      runFrom = e1;
      runEnd = f;
    }
    // \r?\n, the blank line.
    final vs = lineBreak(f);
    if (vs < 0) continue;
    // ([\s\S]*?)(?=\r?\n--|$): up to the first \n-- or \r\n--, or the end.
    var ve = n;
    for (var j = vs; j < n; j++) {
      final c = s.codeUnitAt(j);
      if ((c == 0x0a && s.startsWith('\n--', j)) || (c == 0x0d && s.startsWith('\r\n--', j))) {
        ve = j;
        break;
      }
    }
    out.add((name, s.substring(vs, ve)));
    from = ve; // the next match starts where this one ended
    if (from == p) from = p + 1;
  }
  return out;
}

// ["';\s] in a JavaScript regex: quote, apostrophe, semicolon, or whitespace.
bool _partNameEnd(int c) =>
    c == 0x22 || c == 0x27 || c == 0x3b || c == 0x20 || (c >= 0x09 && c <= 0x0d) || c == 0xa0 || c == 0x1680 ||
    (c >= 0x2000 && c <= 0x200a) || c == 0x2028 || c == 0x2029 || c == 0x202f || c == 0x205f || c == 0x3000 ||
    c == 0xfeff;

final RegExp _rawOperationRe = RegExp(r'"operationName"\s*:\s*"([^"]*)"');
final RegExp _ignoredRe = RegExp(r'"""(?:\\"""|[\s\S])*?"""|"(?:[^"\\]|\\.)*"|#[^\n\r]*');
final RegExp _tokenRe = RegExp(r'[A-Za-z_][A-Za-z0-9_]*|\.\.\.|[{}():@]');
final RegExp _formRe = RegExp(r'(?:^|&)(operationName|query|operations)=([^&]*)');
const Set<String> _definitions = <String>{'mutation', 'query', 'subscription', 'fragment'};

class _Def {
  _Def(this.kind);
  final String kind;
  String name = '';
  final List<String> fields = <String>[];
  final List<String> spreads = <String>[];
}

/// The names a GraphQL document's mutations are judged by: each mutation's own
/// name, and its ROOT fields. A root field is a field in the mutation's top
/// selection set, in an inline fragment at that level (`... on Mutation { x }`),
/// or at the top of a fragment spread there (followed through further spreads).
/// Aliases, nested fields, arguments, variables, directives, strings and
/// comments are never names. A query, subscription or fragment on its own gives
/// none, so a mutation may select `cart { checkoutUrl }` and a query may read
/// `paymentMethods`. Mirrors mutationNames in packages/core/src/allowlist.ts.
List<String> mutationNames(String doc) {
  final text = doc.replaceAll(_ignoredRe, ' ');
  final defs = <_Def>[];
  _Def? def;
  // One entry per open selection set: true when it is at its definition's root.
  final sets = <bool>[];
  var parens = 0;
  var inline = false, pushed = false;
  var expect = '';
  for (final Match m in _tokenRe.allMatches(text)) {
    final t = m.group(0)!;
    final was = pushed;
    pushed = false;
    if (t == '(') {
      parens += 1;
      continue;
    }
    if (t == ')') {
      parens = parens > 0 ? parens - 1 : 0;
      continue;
    }
    if (parens > 0) continue;
    if (t == '@') {
      expect = 'directive';
      continue;
    }
    if (t == '{') {
      if (def == null) defs.add(def = _Def('query'));
      sets.add(sets.isEmpty || (inline && sets.last));
      inline = false;
      expect = '';
      continue;
    }
    if (t == '}') {
      if (sets.isNotEmpty) sets.removeLast();
      inline = false;
      expect = '';
      if (sets.isEmpty) def = null;
      continue;
    }
    if (sets.isEmpty) {
      // A definition's header: its keyword, its name, and nothing else counts.
      if (expect == 'directive') {
        expect = '';
      } else if (def == null && _definitions.contains(t)) {
        defs.add(def = _Def(t));
      } else if (def != null && def.name.isEmpty && t != 'on' && t != ':' && t != '...') {
        def.name = t;
      }
      continue;
    }
    final root = sets.last;
    if (t == '...') {
      expect = 'spread';
      inline = true;
      continue;
    }
    if (t == ':') {
      if (was && def != null) def.fields.removeLast();
      continue;
    }
    if (expect == 'directive' || expect == 'type') {
      expect = '';
      continue;
    }
    if (expect == 'spread') {
      expect = '';
      if (t == 'on') {
        expect = 'type';
        continue;
      }
      inline = false;
      if (root && def != null) def.spreads.add(t);
      continue;
    }
    inline = false;
    if (root && def != null) {
      def.fields.add(t);
      pushed = true;
    }
  }
  final fragments = <String, _Def>{
    for (final _Def d in defs)
      if (d.kind == 'fragment') d.name: d,
  };
  final names = <String>[];
  for (final _Def d in defs) {
    if (d.kind != 'mutation') continue;
    if (d.name.isNotEmpty) names.add(d.name);
    final seen = <String>{};
    void walk(_Def x) {
      names.addAll(x.fields);
      for (final String sp in x.spreads) {
        final f = fragments[sp];
        if (f != null && seen.add(sp)) walk(f);
      }
    }

    walk(d);
  }
  return names;
}

/// Does a request body name a blocked operation? Reads `operationName` the way
/// the server will (after JSON parsing, so `\u004f` escapes do not hide it),
/// for a single request or a batch, or form-encoded, and the names of every
/// mutation it carries (see [mutationNames]). A GraphQL multipart upload's
/// `operations` field is JSON and is judged like a JSON body, whether it
/// comes form-encoded or as raw multipart text ([multipartField]). A leading
/// byte order mark is dropped first. A persisted
/// query that sends only an innocent name and a hash cannot be read here; the
/// signature on the envelope covers it. The guard script applies the same rule to requests a
/// page script makes; this applies it to the runner's own `fetch` op, which
/// never passes through the page. A body nested deeper than [bodyMaxDepth] is
/// blocked, and so is one longer than [bodyMaxText].
bool bodyBlocked(String? body) => _judged(body, 0);

/// How many times a body may nest inside an `operations` field (form-encoded
/// or a raw multipart part) and still be read. One nested deeper is blocked.
/// BODY_MAX_DEPTH in allowlist.ts.
const int bodyMaxDepth = 8;

/// The longest body (in UTF-16 code units, after a leading byte order mark is
/// dropped) that is read. A longer one is blocked without being read: store
/// requests are far smaller, and one that size could hide a blocked name in
/// escapes no text match would see. BODY_MAX_TEXT.
const int bodyMaxText = 1048576;

bool _judged(String? body, int depth) {
  if (body == null) return false;
  // A leading byte order mark is dropped, as a server's JSON reader would.
  if (body.startsWith('\uFEFF')) body = body.substring(1);
  if (body.isEmpty) return false;
  if (depth > bodyMaxDepth) return true;
  if (body.length > bodyMaxText) return true;
  final names = <String>[
    for (final Match m in _rawOperationRe.allMatches(body)) m.group(1)!,
  ];
  final docs = <String>[];
  Object? j;
  var json = true;
  try {
    j = jsonDecode(body);
  } on FormatException {
    json = false;
  }
  if (json) {
    final List<Object?> list = j is List<Object?> ? j : <Object?>[j];
    for (final Object? o in list) {
      if (o is! Map<String, Object?>) continue;
      final op = o['operationName'];
      if (op is String) names.add(op);
      final q = o['query'];
      if (q is String) docs.add(q);
    }
  } else {
    // Not JSON: form-encoded, raw multipart, or a bare GraphQL document.
    docs.add(body);
    for (final Match m in _formRe.allMatches(body)) {
      final v = decodePercent(m.group(2)!.replaceAll('+', ' '));
      if (m.group(1) == 'query') {
        docs.add(v);
      } else if (m.group(1) == 'operations') {
        if (_judged(v, depth + 1)) return true;
      } else {
        names.add(v);
      }
    }
    for (final (String name, String v) in multipartFields(body)) {
      if (name == 'query') {
        docs.add(v);
      } else if (name == 'operations') {
        if (_judged(v, depth + 1)) return true;
      } else {
        names.add(v);
      }
    }
  }
  for (final String d in docs) {
    names.addAll(mutationNames(d));
  }
  return names.any(_opsRe.hasMatch);
}
