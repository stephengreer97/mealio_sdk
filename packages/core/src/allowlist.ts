// The allowlist. It lives in the SDK so a compromised server cannot turn it
// off. PROTOCOL.md "Allowlist" is the spec.

import type { AllowlistPayload } from './protocol';

/** Never relaxed remotely. Case-insensitive, tested against path + query. */
export const BLOCKED_PATTERNS: readonly string[] = [
  'checkout',
  'payment',
  'billing',
  'wallet',
  'place-?order',
  'submit-?order',
  'order-?confirm',
  'gift-?card',
  '/account/(delete|close|security|password)',
  '/addresses?/(add|edit|delete|new)',
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
export const COMMON_AUTH_HOSTS = [
  'b2clogin.com', 'ciamlogin.com', 'login.microsoftonline.com', 'okta.com', 'auth0.com',
  'accounts.google.com', 'appleid.apple.com', 'facebook.com',
];

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
    wegmans: { hosts: ['wegmans.com'], authHosts: [] },
  };
  for (const [id, d] of Object.entries(ALBERTSONS_BANNERS)) {
    out[id] = { hosts: [d], authHosts: ['albertsons.com'] };
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
    const m = /^([a-z][a-z0-9+.-]*):\/\/([^/?#:]+)(?::\d+)?([^#]*)/i.exec(url || '');
    if (!m) return { ok: false, reason: 'bad_url' };
    if (m[1].toLowerCase() !== 'https') return { ok: false, reason: 'not_https' };
    const host = m[2];
    const rest = m[3] || '/';
    const own = s.hosts.some((a) => hostMatches(host, a));
    const auth = use === 'login' && [...s.authHosts, ...COMMON_AUTH_HOSTS, ...MEALIO_HOSTS].some((a) => hostMatches(host, a));
    if (!own && !auth) return { ok: false, reason: 'host' };
    if (isBlockedPath(rest)) return { ok: false, reason: 'blocked_path' };
    return { ok: true };
  }
}

export function isBlockedPath(pathAndQuery: string): boolean {
  return BLOCKED_RE.test(pathAndQuery || '');
}
