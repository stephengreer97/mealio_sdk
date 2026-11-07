// The allowlist. It lives in the SDK so a compromised server cannot turn it
// off. PROTOCOL.md "Allowlist" is the spec.

import type { AllowlistPayload } from './protocol';

/** Never relaxed remotely. Case-insensitive, tested against path + query. */
export const BLOCKED_PATTERNS: readonly string[] = [
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
  '/orders?/(submit|place)(/|\\?|$)',
  '/cart/confirm',
  '/purchase(/|\\?|$)',
];

const BLOCKED_RE = new RegExp(BLOCKED_PATTERNS.join('|'), 'i');

export interface StoreHosts {
  /** The store's own hosts. Subdomains are allowed too. */
  hosts: string[];
  /** Hosts the login sheet may visit (identity providers). */
  authHosts: string[];
}

/** Hosts every store's login may return to. */
export const MEALIO_HOSTS = ['mealio.co'];

/**
 * Identity providers a store's login page may hand off to, for every store.
 * Only TOP-FRAME navigations in the login sheet are checked; captcha and
 * consent iframes inside a store page are not navigations of the sheet.
 */
export const COMMON_AUTH_HOSTS = ['accounts.google.com', 'appleid.apple.com', 'facebook.com'];

/**
 * Multi-tenant identity providers, ONLY for the store that uses them. Anyone
 * can register a tenant on okta.com or b2clogin.com, so allowing the whole
 * provider for every store let any tenant's page into the sign-in sheet.
 * Albertsons signs in through its own Okta tenant. Wegmans uses Azure AD B2C,
 * whose tenant host the page reads at run time, so B2C stays provider-wide but
 * for Wegmans alone.
 */
export const ALBERTSONS_AUTH_HOSTS = ['albertsons.com', 'albertsons.okta.com'];
export const WEGMANS_AUTH_HOSTS = ['b2clogin.com', 'ciamlogin.com', 'login.microsoftonline.com'];

// Store ids match mealio_app/src/constants/stores.ts and the server catalog.
const ALBERTSONS_BANNERS: Record<string, string> = {
  albertsons: 'albertsons.com', safeway: 'safeway.com', vons: 'vons.com', jewel_osco: 'jewelosco.com',
  shaws: 'shaws.com', acme: 'acmemarkets.com', tom_thumb: 'tomthumb.com', randalls: 'randalls.com',
  pavilions: 'pavilions.com', star_market: 'starmarket.com', haggen: 'haggen.com', carrs: 'carrsqc.com',
  kings: 'kingsfoodmarkets.com', balduccis: 'balduccis.com', united: 'shopunitedsupermarkets.com',
};

const INSTACART_TENANTS: Record<string, string> = {
  aldi: 'aldi.us', publix: 'delivery.publix.com', bristol_farms: 'shop.bristolfarms.com',
  save_mart: 'shop.savemart.com', gelsons: 'shop.gelsons.com', dierbergs: 'shop.dierbergs.com',
  sprouts: 'shop.sprouts.com', the_fresh_market: 'shop.thefreshmarket.com', costco_sameday: 'sameday.costco.com',
};

const KROGER_BANNERS = [
  'kroger', 'bakers', 'city_market', 'dillons', 'fred_meyer', 'frys', 'harris_teeter', 'king_soopers',
  'marianos', 'metro_market', 'pay_less', 'pick_n_save', 'qfc', 'ralphs', 'smiths',
];

function bundled(): Record<string, StoreHosts> {
  const out: Record<string, StoreHosts> = {
    heb: { hosts: ['heb.com'], authHosts: [] },
    wegmans: { hosts: ['wegmans.com'], authHosts: [...WEGMANS_AUTH_HOSTS] },
  };
  for (const [id, d] of Object.entries(ALBERTSONS_BANNERS)) {
    out[id] = { hosts: [d], authHosts: [...ALBERTSONS_AUTH_HOSTS] };
  }
  for (const [id, d] of Object.entries(INSTACART_TENANTS)) {
    out[id] = { hosts: [d], authHosts: ['instacart.com'] };
  }
  // The Kroger family is server-side through Kroger's API. The SDK only ever
  // shows Kroger's OAuth consent page.
  for (const id of KROGER_BANNERS) out[id] = { hosts: [], authHosts: ['api.kroger.com', 'login.kroger.com', 'kroger.com'] };
  return out;
}

export const STORES: Record<string, StoreHosts> = bundled();

/** Last two labels, with a short list of two-label public suffixes. */
export function registrableDomain(host: string): string {
  const parts = host.toLowerCase().split('.').filter(Boolean);
  if (parts.length <= 2) return parts.join('.');
  const last2 = parts.slice(-2).join('.');
  if (['co.uk', 'com.au', 'co.nz'].includes(last2)) return parts.slice(-3).join('.');
  return last2;
}

function hostMatches(host: string, allowed: string): boolean {
  const h = host.toLowerCase();
  const a = allowed.toLowerCase();
  return h === a || h.endsWith('.' + a);
}

export type UrlUse = 'page' | 'fetch' | 'login';

export type UrlVerdict = { ok: true } | { ok: false; reason: 'bad_url' | 'not_https' | 'host' | 'blocked_path' | 'unknown_store' };

export class Allowlist {
  private stores: Record<string, StoreHosts>;

  constructor(base: Record<string, StoreHosts> = STORES) {
    this.stores = {};
    for (const [k, v] of Object.entries(base)) this.stores[k] = { hosts: [...v.hosts], authHosts: [...v.authHosts] };
  }

  /**
   * Widen hosts from a signed allowlist payload. A new host must share a
   * registrable domain with a host already listed for that store; anything
   * else is ignored. Stores the SDK does not know are ignored.
   */
  widen(p: AllowlistPayload): void {
    for (const [store, add] of Object.entries(p.stores || {})) {
      const cur = this.stores[store];
      if (!cur) continue;
      const known = new Set([...cur.hosts, ...cur.authHosts].map(registrableDomain));
      for (const h of add.hosts || []) if (known.has(registrableDomain(h)) && !cur.hosts.includes(h)) cur.hosts.push(h);
      for (const h of add.authHosts || []) if (known.has(registrableDomain(h)) && !cur.authHosts.includes(h)) cur.authHosts.push(h);
    }
  }

  hostsFor(store: string): StoreHosts | null {
    return this.stores[store] || null;
  }

  check(store: string, url: string, use: UrlUse): UrlVerdict {
    const s = this.stores[store];
    if (!s) return { ok: false, reason: 'unknown_store' };
    const p = parseUrl(url);
    if (!p) return { ok: false, reason: 'bad_url' };
    if (p.scheme !== 'https') return { ok: false, reason: 'not_https' };
    const host = p.host;
    const rest = p.rest;
    const own = s.hosts.some((a) => hostMatches(host, a));
    const auth = use === 'login' && [...s.authHosts, ...COMMON_AUTH_HOSTS, ...MEALIO_HOSTS].some((a) => hostMatches(host, a));
    if (!own && !auth) return { ok: false, reason: 'host' };
    if (isBlockedPath(rest)) return { ok: false, reason: 'blocked_path' };
    return { ok: true };
  }
}

/**
 * Split a URL into scheme, host and path + query, or null if it is not one we
 * will reason about. STRICT on purpose: the authority must be a bare host name
 * with an optional port. A browser reads `https://www.heb.com:x@evil.com/` as
 * host evil.com, and `https://evil.com\\.heb.com/` as host evil.com too, while
 * a looser pattern read both as heb.com. So userinfo (@), backslashes,
 * whitespace and control characters anywhere are refused outright, as is any
 * host that is not plain ASCII letters, digits, dots and hyphens.
 */
export function parseUrl(url: string | null | undefined): { scheme: string; host: string; rest: string } | null {
  const raw = String(url ?? '');
  if (/[\\\s\u0000-\u001f\u007f]/.test(raw)) return null;
  const m = /^([a-z][a-z0-9+.-]*):\/\/([^/?#]*)([^#]*)/i.exec(raw);
  if (!m) return null;
  const a = /^([a-z0-9-]+(?:\.[a-z0-9-]+)*)(?::\d{1,5})?$/i.exec(m[2]);
  if (!a) return null;
  const rest = m[3] || '/';
  return { scheme: m[1].toLowerCase(), host: a[1].toLowerCase(), rest: rest.startsWith('/') || rest.startsWith('?') ? rest : '/' + rest };
}

/** Percent-decoding, twice, of %XX only: a server decodes `%63heckout` to `checkout`. */
export function decodePercent(s: string): string {
  let out = s;
  for (let i = 0; i < 2; i += 1) out = out.replace(/%([0-9a-f]{2})/gi, (_, h: string) => String.fromCharCode(parseInt(h, 16)));
  return out;
}

export function isBlockedPath(pathAndQuery: string): boolean {
  const s = pathAndQuery || '';
  return BLOCKED_RE.test(s) || BLOCKED_RE.test(decodePercent(s));
}

/**
 * Operation and field names no request may carry (case-insensitive regex
 * source). Every SDK and the guard script use this exact list.
 */
export const BLOCKED_GRAPHQL_OPERATION = 'check_?out|place_?order|submit_?order|confirm_?order|create_?order|purchase|payment';
const OPS_RE = new RegExp(BLOCKED_GRAPHQL_OPERATION, 'i');

/**
 * The names a GraphQL document's mutations are judged by: each mutation's own
 * name, and its ROOT fields. A root field is a field in the mutation's top
 * selection set, in an inline fragment at that level (`... on Mutation { x }`),
 * or at the top of a fragment spread there (followed through further spreads).
 * Aliases, nested fields, arguments, variables, directives, strings and
 * comments are never names. A query, subscription or fragment on its own gives
 * none, so a mutation may select `cart { checkoutUrl }` and a query may read
 * `paymentMethods`.
 */
export function mutationNames(doc: string): string[] {
  const text = doc.replace(/"""(?:\\"""|[\s\S])*?"""|"(?:[^"\\]|\\.)*"|#[^\n\r]*/g, ' ');
  const tokens = text.match(/[A-Za-z_][A-Za-z0-9_]*|\.\.\.|[{}():@]/g) || [];
  type Def = { kind: string; name: string; fields: string[]; spreads: string[] };
  const defs: Def[] = [];
  let def: Def | null = null;
  // One entry per open selection set: true when it is at its definition's root.
  const sets: boolean[] = [];
  let parens = 0, inline = false, expect = '', pushed = false;
  for (const t of tokens) {
    const was = pushed;
    pushed = false;
    if (t === '(') { parens += 1; continue; }
    if (t === ')') { parens = Math.max(0, parens - 1); continue; }
    if (parens > 0) continue;
    if (t === '@') { expect = 'directive'; continue; }
    if (t === '{') {
      if (!def) { def = { kind: 'query', name: '', fields: [], spreads: [] }; defs.push(def); }
      sets.push(sets.length === 0 || (inline && sets[sets.length - 1]));
      inline = false; expect = '';
      continue;
    }
    if (t === '}') {
      sets.pop();
      inline = false; expect = '';
      if (sets.length === 0) def = null;
      continue;
    }
    if (sets.length === 0) {
      // A definition's header: its keyword, its name, and nothing else counts.
      if (expect === 'directive') expect = '';
      else if (!def && /^(query|mutation|subscription|fragment)$/.test(t)) { def = { kind: t, name: '', fields: [], spreads: [] }; defs.push(def); }
      else if (def && !def.name && t !== 'on' && t !== ':' && t !== '...') def.name = t;
      continue;
    }
    const root = sets[sets.length - 1];
    if (t === '...') { expect = 'spread'; inline = true; continue; }
    if (t === ':') { if (was && def) def.fields.pop(); continue; }
    if (expect === 'directive' || expect === 'type') { expect = ''; continue; }
    if (expect === 'spread') {
      expect = '';
      if (t === 'on') { expect = 'type'; continue; }
      inline = false;
      if (root && def) def.spreads.push(t);
      continue;
    }
    inline = false;
    if (root && def) { def.fields.push(t); pushed = true; }
  }
  const fragments = new Map(defs.filter((d) => d.kind === 'fragment').map((d) => [d.name, d] as const));
  const names: string[] = [];
  for (const d of defs) {
    if (d.kind !== 'mutation') continue;
    if (d.name) names.push(d.name);
    const seen = new Set<string>();
    const walk = (x: Def) => {
      names.push(...x.fields);
      for (const s of x.spreads) {
        const f = fragments.get(s);
        if (f && !seen.has(s)) { seen.add(s); walk(f); }
      }
    };
    walk(d);
  }
  return names;
}

/**
 * Does a request body name a blocked operation? Reads `operationName` the way
 * the server will (after JSON parsing, so `\\u004f` escapes do not hide it),
 * for a single request or a batch, or form-encoded, and the names of every
 * mutation it carries (see mutationNames). A GraphQL multipart upload's
 * `operations` field is JSON and is judged like a JSON body. A persisted query
 * that sends only an innocent name and a hash cannot be read here; the
 * signature on the envelope covers it. The guard script applies the same rule
 * to requests a page script makes; this applies it to the runner's own `fetch`
 * op, which never passes through the page.
 */
export function bodyBlocked(body: string | null | undefined): boolean {
  if (typeof body !== 'string' || !body) return false;
  const names: string[] = [];
  const docs: string[] = [];
  const raw = /"operationName"\s*:\s*"([^"]*)"/g;
  for (let m = raw.exec(body); m; m = raw.exec(body)) names.push(m[1]);
  try {
    const j = JSON.parse(body);
    for (const o of Array.isArray(j) ? j : [j]) {
      if (!o || typeof o !== 'object') continue;
      if (typeof o.operationName === 'string') names.push(o.operationName);
      if (typeof o.query === 'string') docs.push(o.query);
    }
  } catch {
    // Not JSON: form-encoded, or a bare GraphQL document.
    docs.push(body);
    const form = /(?:^|&)(operationName|query|operations)=([^&]*)/g;
    for (let m = form.exec(body); m; m = form.exec(body)) {
      const v = decodePercent(m[2].replace(/\+/g, ' '));
      if (m[1] === 'query') docs.push(v);
      else if (m[1] === 'operations') { if (bodyBlocked(v)) return true; }
      else names.push(v);
    }
  }
  for (const d of docs) names.push(...mutationNames(d));
  return names.some((n) => OPS_RE.test(n));
}
