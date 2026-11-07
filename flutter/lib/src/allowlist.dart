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
final RegExp _rawOperationRe = RegExp(r'"operationName"\s*:\s*"([^"]*)"');
final RegExp _ignoredRe = RegExp(r'"""[\s\S]*?"""|"(?:[^"\\]|\\.)*"|#[^\n\r]*');
final RegExp _tokenRe = RegExp(r'[A-Za-z_][A-Za-z0-9_]*|[{}()]');
final RegExp _formRe = RegExp(r'(?:^|&)(operationName|query)=([^&]*)');
const Set<String> _definitions = <String>{'mutation', 'query', 'subscription', 'fragment'};

/// Every name a GraphQL document's mutations use: the operation's name and the
/// fields it selects at any depth, aliases included, plus the fields of its
/// fragments. Arguments and `on Type` conditions are not fields. Empty when the
/// document has no mutation, so a query may read a field called paymentMethods.
List<String> mutationNames(String doc) {
  final text = doc.replaceAll(_ignoredRe, ' ');
  final names = <String>[];
  var braces = 0, parens = 0;
  var kind = '';
  var mutation = false, afterOn = false;
  for (final Match m in _tokenRe.allMatches(text)) {
    final t = m.group(0)!;
    if (t == '(') {
      parens += 1;
    } else if (t == ')') {
      parens = parens > 0 ? parens - 1 : 0;
    } else if (parens > 0) {
      continue;
    } else if (t == '{') {
      braces += 1;
    } else if (t == '}') {
      braces = braces > 0 ? braces - 1 : 0;
      if (braces == 0) kind = '';
    } else if (braces == 0 && kind.isEmpty && _definitions.contains(t)) {
      kind = t;
      if (t == 'mutation') mutation = true;
    } else if (afterOn) {
      afterOn = false;
    } else if (t == 'on') {
      afterOn = true;
    } else if (kind == 'mutation' || kind == 'fragment') {
      names.add(t);
    }
  }
  return mutation ? names : const <String>[];
}

/// Does a request body name a blocked operation? Reads `operationName` the way
/// the server will (after JSON parsing, so `\u004f` escapes do not hide it),
/// for a single request or a batch, or form-encoded, and every name in any
/// mutation (see [mutationNames]). A persisted query that sends only an
/// innocent name and a hash cannot be read here; the signature on the
/// envelope covers it. The guard script applies the same rule to requests a
/// page script makes; this applies it to the runner's own `fetch` op, which
/// never passes through the page.
bool bodyBlocked(String? body) {
  if (body == null || body.isEmpty) return false;
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
    // Not JSON: form-encoded, or a bare GraphQL document.
    docs.add(body);
    for (final Match m in _formRe.allMatches(body)) {
      final v = decodePercent(m.group(2)!.replaceAll('+', ' '));
      if (m.group(1) == 'query') {
        docs.add(v);
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
