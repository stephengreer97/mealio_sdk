// @mealio/sdk-core/testing: run the REAL MealioClient and CartSession in Jest
// or Vitest with no network. createFakeMealio plays a scripted Mealio server
// (fetchImpl), a store page (host), and signs with the protocol TEST key
// (keys), which no production build trusts: KEYS in keys.ts holds only the
// production key, and `keys` must be passed explicitly.
//
//   const fake = createFakeMealio({ items: [{ key: 'milk', options: [{ id: 'm1', name: 'Milk', unitPrice: 3 }], remembered: 'm1' }] });
//   const client = fake.client();                  // or new MealioClient(fake.config({ ... }), fake.host)
//   const cart = await client.prepareCart({ recipe: { id: 'r', ingredients: [{ name: 'milk' }] } });
//
// React Native: <MealioProvider testing={fake} ...> runs useMealio() on it.

import { ed } from './noble';
import { STORES } from './allowlist';
import { MealioClient, type ClientConfig } from './client';
import type { Host } from './runner';
import type {
  AddResult, CartItem, CartWarning, Envelope, ItemRecipe, PreparedCart, Product, Selection, StoreInfo, StoreLocation, StorePreferences,
} from './protocol';

/** The protocol test key (protocol/test-vectors.json). Pass as ClientConfig.keys. */
export const TEST_KEYS: Readonly<Record<string, string>> = Object.freeze({ ktest: '6kpsY+KcUgq+9VB7Ey7F+ZVHdq6+vnuSQh7qaRRG0iw=' });
const TEST_SEED = new Uint8Array(32).fill(7);
export const FAKE_BASE_URL = 'https://mealio.test';

/** An error by code. A string is `{ code }`. With `status`, it is an HTTP error; without, a job that fails. */
export type FakeError = string | { code: string; message?: string; status?: number };

export interface FakeItem {
  key: string;
  ingredient?: string;
  quantity?: number;
  options?: Product[];
  /** The remembered product's id. In `options` and in stock: status remembered, pre-selected. */
  remembered?: string | null;
  rememberedPreferenceId?: string | null;
  /** The remembered product is gone this time: status remembered_unavailable, nothing pre-selected. */
  rememberedUnavailable?: boolean;
  /** Pantry or optional: starts unticked (selectedId stays as the server sends it). */
  startUnchecked?: boolean;
  /** The recipe's own weight, lb. */
  weightLb?: number;
  recipes?: ItemRecipe[];
  /** Nothing found: status unavailable with this reason. */
  unavailable?: string;
}

export interface FakeScript {
  store?: string;
  storeName?: string;
  items?: FakeItem[];
  recipes?: Array<{ id: string; title: string | null }>;
  warnings?: CartWarning[];
  /** Results per query (exact, case-insensitive), or a function. An unlisted query finds nothing. */
  search?: Record<string, Product[]> | ((query: string, key: string) => Product[]);
  /**
   * What an add does. Default: each selection whose product this cart offered
   * (prepare or a search on THIS cart) is added with its price; any other
   * product fails as `not_offered`, as the server does.
   */
  add?: { fail: FakeError } | ((selections: Selection[], offered: Product[]) => AddResult);
  /** Prepare asks the user to sign in, and the fake store page answers this. Default: already signed in. */
  signIn?: 'signed_in' | 'cancelled' | 'timeout' | null;
  errors?: Partial<Record<'prepare' | 'search' | 'add' | 'warm' | 'stores' | 'preferences' | 'locations' | 'session', FakeError>>;
  stores?: StoreInfo[];
  preferences?: StorePreferences;
  locations?: StoreLocation[];
  /** What a warm-up finds. Default: signed in to the default store. */
  warm?: { signedIn: boolean } | null;
}

export type FakeKind = 'prepare' | 'search' | 'add' | 'warm' | 'step' | 'stores' | 'preferences' | 'locations';

export interface FakeRequest { kind: FakeKind | 'other'; path: string; body: any; token: string | null }

export interface FakeMealio {
  fetchImpl: typeof fetch;
  host: Host;
  keys: Record<string, string>;
  baseUrl: string;
  /** The script in force. Change it between calls. */
  script: FakeScript;
  /** Every request the client sent, in order. */
  requests: FakeRequest[];
  /** What the fake store page was asked to do: "open <url>", "script", "login", "fetch", "reset". */
  hostCalls: string[];
  /** A ClientConfig on this fake. Pass your own getSessionToken, userId, queue... */
  config(over?: Partial<ClientConfig>): ClientConfig;
  /** A real MealioClient on this fake. */
  client(over?: Partial<ClientConfig>): MealioClient;
  /** The products a cart offered so far (prepare and its own searches). */
  offered(cartId: string): Product[];
  /** Hold the next request of this kind until the returned function is called. */
  hold(kind: FakeKind): () => void;
}

const b64 = (bytes: Uint8Array): string => {
  const A = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  let out = '';
  for (let i = 0; i < bytes.length; i += 3) {
    const n = (bytes[i] << 16) | ((bytes[i + 1] ?? 0) << 8) | (bytes[i + 2] ?? 0);
    out += A[(n >> 18) & 63] + A[(n >> 12) & 63] + (i + 1 < bytes.length ? A[(n >> 6) & 63] : '=') + (i + 2 < bytes.length ? A[n & 63] : '=');
  }
  return out;
};

/** An envelope signed with the test key. For tests that script instructions themselves. */
export function signTestEnvelope(job: string, seq: number, store: string, instructions: unknown[]): Envelope {
  const payload = JSON.stringify({ v: 1, kind: 'instructions', job, seq, exp: 4102444800, store, instructions });
  return { payload, sig: b64(ed.sign(new TextEncoder().encode(payload), TEST_SEED)), kid: 'ktest' };
}

/** A cart item from a script line, as the server builds it. */
export function fakeCartItem(f: FakeItem): CartItem {
  const options = f.options ?? [];
  const rem = f.remembered ? options.find((p) => p.id === f.remembered) ?? { id: f.remembered, name: f.remembered } : null;
  const usable = !!rem && !f.rememberedUnavailable && !rem.outOfStock && options.some((p) => p.id === rem.id);
  const status = f.unavailable || options.length === 0 ? 'unavailable' : usable ? 'remembered' : rem ? 'remembered_unavailable' : 'choose';
  return {
    key: f.key, ingredient: f.ingredient ?? f.key, quantity: f.quantity ?? 1, status, options,
    selectedId: usable ? rem!.id : null,
    remembered: rem ? { ...rem, ...(usable ? {} : { outOfStock: true }) } : null,
    ...(f.rememberedPreferenceId !== undefined ? { rememberedPreferenceId: f.rememberedPreferenceId } : {}),
    ...(f.startUnchecked ? { startUnchecked: true } : {}),
    ...(f.weightLb !== undefined ? { weightLb: f.weightLb } : {}),
    ...(f.recipes ? { recipes: f.recipes } : {}),
    ...(status === 'unavailable' ? { reason: f.unavailable ?? 'not_found' } : {}),
  };
}

interface Res { ok: boolean; status: number; json: () => Promise<unknown> }
const reply = (o: unknown, status = 200): Res => ({ ok: status < 400, status, json: async () => o });
const errOf = (e: FakeError) => (typeof e === 'string' ? { code: e } : e);

export function createFakeMealio(script: FakeScript = {}): FakeMealio {
  const requests: FakeRequest[] = [];
  const hostCalls: string[] = [];
  const carts = new Map<string, { store: string; offered: Product[] }>();
  const jobs = new Map<string, { store: string; finish: (outcome: string | undefined) => unknown[] }>();
  const holds = new Map<FakeKind, Array<Promise<void>>>();
  let nJob = 0, nCart = 0;

  const prefs = (): StorePreferences => fake.script.preferences ?? { defaultStore: fake.script.store ?? 'heb', location: null };
  const home = (store: string) => `https://www.${STORES[store]?.hosts[0] ?? 'heb.com'}/`;
  const loginUrl = (store: string) => {
    const s = STORES[store];
    return s?.hosts[0] ? `https://www.${s.hosts[0]}/login` : `https://${s?.authHosts[0] ?? 'www.heb.com'}/login`;
  };
  const start = (store: string, instructions: unknown[], finish?: (o: string | undefined) => unknown[]): Res => {
    const job = `job_${++nJob}`;
    if (finish) jobs.set(job, { store, finish });
    return reply({ job, envelope: signTestEnvelope(job, 1, store, instructions) });
  };
  const failOp = (e: FakeError) => { const x = errOf(e); return { op: 'fail', id: 'fail-1', code: x.code, message: x.message ?? x.code }; };
  const done = (result: unknown) => ({ op: 'done', id: 'done-1', result });
  /** An error for a job endpoint: HTTP when it has a status, else a job that fails. */
  const jobError = (store: string, e: FakeError): Res => {
    const x = errOf(e);
    return x.status ? reply({ error: { code: x.code, message: x.message ?? x.code } }, x.status) : start(store, [failOp(x)]);
  };
  const httpError = (e: FakeError): Res => { const x = errOf(e); return reply({ error: { code: x.code, message: x.message ?? x.code } }, x.status ?? 400); };

  function prepare(body: any): Res {
    const s = fake.script;
    const store: string | null = body.store ?? s.store ?? prefs().defaultStore;
    if (!store) return httpError({ code: 'store_required', message: 'Pick a store', status: 400 });
    if (s.errors?.prepare) return jobError(store, s.errors.prepare);
    const items = (s.items ?? []).map(fakeCartItem);
    const cartId = `cart_${++nCart}`;
    carts.set(cartId, { store, offered: items.flatMap((i) => i.options) });
    const cart: PreparedCart = {
      cartId, store, storeName: s.storeName ?? (store === 'heb' ? 'H-E-B' : store), items, ready: [], needsChoice: [], unavailable: [],
      recipes: s.recipes ?? (body.recipes ?? (body.recipe ? [body.recipe] : [])).map((r: any) => ({ id: r.id, title: r.title ?? null })),
      warnings: s.warnings ?? [],
    };
    // A Kroger family store has no page of its own: only its sign-in.
    const open = STORES[store]?.hosts[0] ? [{ op: 'page_open', id: 'open-1', url: home(store), timeoutMs: 15000 }] : [];
    if (!s.signIn) return start(store, [...open, done(cart)]);
    const login = { op: 'show_login', id: 'login-1', url: loginUrl(store), title: 'Sign in', doneWhen: [{ type: 'FAKE_SIGNED_IN' }], timeoutMs: 120000 };
    return start(store, [...open, login], (outcome) => outcome === 'signed_in'
      ? [done(cart)] : [failOp({ code: 'login_cancelled', message: 'Sign-in was closed' })]);
  }

  function search(cartId: string, body: any): Res {
    const c = carts.get(cartId);
    const store = c?.store ?? 'heb';
    if (fake.script.errors?.search) return jobError(store, fake.script.errors.search);
    const s = fake.script.search;
    const found = typeof s === 'function' ? s(body.query, body.key)
      : Object.entries(s ?? {}).find(([q]) => q.toLowerCase() === String(body.query).toLowerCase())?.[1] ?? [];
    c?.offered.push(...found);
    return start(store, [done({ key: body.key, query: body.query, options: found })]);
  }

  function add(cartId: string, body: any): Res {
    const c = carts.get(cartId);
    const store = c?.store ?? 'heb';
    const a = fake.script.add;
    if (fake.script.errors?.add) return jobError(store, fake.script.errors.add);
    if (a && typeof a === 'object' && 'fail' in a) return jobError(store, a.fail);
    const offered = c?.offered ?? [];
    const selections: Selection[] = body.selections ?? [];
    if (typeof a === 'function') return start(store, [done(a(selections, offered))]);
    const result: AddResult = { cartId, store, added: [], skipped: [], failed: [], storeCartUrl: home(store) + 'cart', verified: true };
    for (const sel of selections) {
      if (!sel.productId) { result.skipped.push({ key: sel.key, reason: 'not_selected' }); continue; }
      const p = offered.find((o) => o.id === sel.productId);
      if (!p) { result.failed.push({ key: sel.key, productId: sel.productId, name: sel.productId, reason: 'not_offered' }); continue; }
      result.added.push({
        key: sel.key, productId: p.id, name: p.name, quantity: sel.quantity ?? 1,
        ...(typeof sel.weightLb === 'number' ? { weightLb: sel.weightLb } : {}),
        ...(typeof p.unitPrice === 'number' ? { unitPrice: p.unitPrice } : {}),
        ...(typeof p.pricePerLb === 'number' ? { pricePerLb: p.pricePerLb } : {}),
        ...(p.estimated ? { estimated: true } : {}),
      });
    }
    return start(store, [done(result)]);
  }

  function answer(kind: FakeKind | 'other', path: string, body: any): Res {
    const s = fake.script;
    switch (kind) {
      case 'stores': return s.errors?.stores ? httpError(s.errors.stores) : reply({ stores: s.stores ?? [{ id: 'heb', name: 'H-E-B', via: 'device' }] });
      case 'preferences': {
        if (s.errors?.preferences) return httpError(s.errors.preferences);
        if (body?.store) s.preferences = { defaultStore: body.store, location: body.locationId ? (s.locations ?? []).find((l) => l.id === body.locationId) ?? null : prefs().location };
        return reply(prefs());
      }
      case 'locations': return s.errors?.locations ? httpError(s.errors.locations) : reply({ locations: s.locations ?? [] });
      case 'warm': {
        const store = body?.store ?? prefs().defaultStore;
        if (!store || s.warm === null) return reply({ warm: null });
        if (s.errors?.warm) return jobError(store, s.errors.warm);
        return start(store, [done({ store, signedIn: s.warm?.signedIn ?? true })]);
      }
      case 'prepare': return prepare(body);
      case 'search': return search(decodeURIComponent(path.split('/')[5]), body);
      case 'add': return add(decodeURIComponent(path.split('/')[5]), body);
      case 'step': {
        const job = decodeURIComponent(path.split('/')[5]);
        const j = jobs.get(job);
        if (!j) return reply({ error: { code: 'unknown_job', message: 'No such job' } }, 404);
        jobs.delete(job);
        const login = (body?.results ?? []).find((r: any) => r && 'outcome' in r);
        return reply({ envelope: signTestEnvelope(job, (body?.seq ?? 1) + 1, j.store, j.finish(login?.outcome)) });
      }
      default: return reply({});
    }
  }

  const kindOf = (path: string): FakeKind | 'other' => {
    if (path === '/api/v1/stores') return 'stores';
    if (path === '/api/v1/sdk/preferences') return 'preferences';
    if (path === '/api/v1/sdk/locations') return 'locations';
    if (path === '/api/v1/sdk/warm') return 'warm';
    if (path === '/api/v1/sdk/carts') return 'prepare';
    if (/^\/api\/v1\/sdk\/carts\/[^/]+\/search$/.test(path)) return 'search';
    if (/^\/api\/v1\/sdk\/carts\/[^/]+\/add$/.test(path)) return 'add';
    if (/^\/api\/v1\/sdk\/jobs\/[^/]+\/step$/.test(path)) return 'step';
    return 'other';
  };

  const fetchImpl = (async (url: string, init?: any) => {
    const path = String(url).replace(FAKE_BASE_URL, '');
    const body = typeof init?.body === 'string' ? JSON.parse(init.body) : null;
    const auth = init?.headers?.authorization as string | undefined;
    const kind = kindOf(path);
    requests.push({ kind, path, body, token: auth ? auth.replace(/^Bearer /, '') : null });
    const held = kind !== 'other' ? holds.get(kind)?.shift() : undefined;
    if (held) await held;
    return answer(kind, path, body);
  }) as unknown as typeof fetch;

  const host: Host = {
    async openPage(_store, url) { hostCalls.push(`open ${url}`); return { ok: true, finalUrl: url }; },
    async runScript() { hostCalls.push('script'); return { messages: [], timedOut: false }; },
    async showLogin(opts) {
      hostCalls.push('login');
      if (opts.cancel?.cancelled) return { outcome: 'cancelled', messages: [] };
      return { outcome: fake.script.signIn ?? 'signed_in', messages: [] };
    },
    async fetch() { hostCalls.push('fetch'); return { ok: true, status: 200, headers: {}, body: '' }; },
    async resetPage() { hostCalls.push('reset'); },
  };

  const fake: FakeMealio = {
    fetchImpl, host, keys: { ...TEST_KEYS }, baseUrl: FAKE_BASE_URL, script, requests, hostCalls,
    config(over = {}) {
      return {
        publishableKey: 'pk_test_fake',
        getSessionToken: async () => {
          const e = fake.script.errors?.session;
          if (e) throw new Error(errOf(e).message ?? errOf(e).code);
          return 'session_test';
        },
        platform: 'web-test', sdkVersion: 'test',
        ...over,
        baseUrl: FAKE_BASE_URL, fetchImpl, keys: { ...TEST_KEYS },
      };
    },
    client(over = {}) { return new MealioClient(fake.config(over), host); },
    offered(cartId) { return [...(carts.get(cartId)?.offered ?? [])]; },
    hold(kind) {
      let release!: () => void;
      const p = new Promise<void>((r) => { release = r; });
      holds.set(kind, [...(holds.get(kind) ?? []), p]);
      return () => release();
    },
  };
  return fake;
}
