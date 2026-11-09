// SHARED_IDENTITY_HOSTS and the rule that says which of a store's hosts native
// network blocking runs on. protocol/shared-identity-hosts.json is the source:
// every SDK carries the same list, and each one's tests run that file's
// vectors. PROTOCOL.md "Native blocking hosts" is the spec. React Native and
// Flutter have no native blocking; this is here as the reference the native
// SDKs port, and for partners who want to know which hosts are covered.

import { registrableDomain, type StoreHosts } from './allowlist';

/** Identity providers many stores share. Native blocking never runs on them. */
export const SHARED_IDENTITY_HOSTS: readonly string[] = [
  'google.com',
  'gstatic.com',
  'apple.com',
  'facebook.com',
  'microsoftonline.com',
  'b2clogin.com',
  'ciamlogin.com',
  'live.com',
  'okta.com',
  'auth0.com',
  'mealio.co',
];

function norm(host: string): string {
  const h = host.toLowerCase();
  return h.endsWith('.') ? h.slice(0, -1) : h;
}

/** The list entry a host is under (equal, or a subdomain by whole labels), or null. */
function sharedEntry(host: string): string | null {
  for (const e of SHARED_IDENTITY_HOSTS) if (host === e || host.endsWith('.' + e)) return e;
  return null;
}

/** The first label of the registrable domain of each of the store's own (not shared) hosts. */
export function storeNames(store: StoreHosts): string[] {
  const out: string[] = [];
  for (const h of [...store.hosts, ...store.authHosts]) {
    const n = norm(h);
    if (sharedEntry(n)) continue;
    const label = registrableDomain(n).split('.')[0];
    if (label && !out.includes(label)) out.push(label);
  }
  return out;
}

/**
 * True when `host` belongs to a shared identity provider, for this store: it
 * is under a SHARED_IDENTITY_HOSTS entry, and it is not a tenant of that
 * provider whose tenant label (the label just left of the entry) names the
 * store (albertsons.okta.com, for an Albertsons banner).
 */
export function isSharedIdentityHost(host: string, store: StoreHosts): boolean {
  const h = norm(host);
  const e = sharedEntry(h);
  if (!e) return false;
  if (h === e) return true;
  const under = h.slice(0, h.length - e.length - 1).split('.');
  return !storeNames(store).includes(under[under.length - 1]);
}

/** The hosts native blocking runs on for a store: its hosts then authHosts, no repeats, no shared identity host. */
export function nativeBlockHosts(store: StoreHosts): string[] {
  const out: string[] = [];
  for (const h of [...store.hosts, ...store.authHosts]) {
    const n = norm(h);
    if (!out.includes(n) && !isSharedIdentityHost(n, store)) out.push(n);
  }
  return out;
}
