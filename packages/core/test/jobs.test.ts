// 0.6: one job at a time, cancelling, users, bounded waits, and the cart fixes.
import { describe, it, expect, vi, afterEach } from 'vitest';
import crypto from 'node:crypto';
import vm from 'node:vm';
import vectors from '../../../protocol/test-vectors.json';
import {
  CancelToken, CartSession, GUARD_ARM_SCRIPT, HOST_GRACE_MS, MealioClient, REQUEST_TIMEOUT_MS, mutationNames,
  type Envelope, type Host,
} from '../src';

const KEYS = { [vectors.kid]: vectors.publicKey };
const pkcs8 = Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), Buffer.alloc(32, 7)]);
const priv = crypto.createPrivateKey({ key: pkcs8, format: 'der', type: 'pkcs8' });
function env(job: string, seq: number, instructions: unknown[]): Envelope {
  const payload = JSON.stringify({ v: 1, kind: 'instructions', job, seq, exp: 4102444800, store: 'heb', instructions });
  return { payload, sig: crypto.sign(null, Buffer.from(payload, 'utf8'), priv).toString('base64'), kid: vectors.kid };
}
const CART = { cartId: 'c', store: 'heb', items: [], ready: [], needsChoice: [], unavailable: [] };
const done = (result: unknown) => ({ op: 'done', id: 'd', result });
const open = (id: string) => ({ op: 'page_open', id, url: 'https://www.heb.com/robots.txt', timeoutMs: 1000 });
const login = { op: 'show_login', id: 'l', url: 'https://www.heb.com/login', title: 'Sign in', doneWhen: [], timeoutMs: 1000 };
const ok = (o: unknown) => ({ ok: true, status: 200, json: async () => o });
const recipe = { id: 'r', ingredients: [{ name: 'milk' }] };
const tick = (ms = 5) => new Promise((r) => setTimeout(r, ms));

type Answer = (path: string, body: any) => unknown;
function setup(answer: Answer, host: Partial<Host> = {}, extra: Record<string, unknown> = {}) {
  const sent: Array<{ path: string; body: any; auth: string }> = [];
  const calls: string[] = [];
  let jobs = 0;
  const fetchImpl = (async (url: string, init: any) => {
    const path = url.replace('https://mealio.test', '');
    const body = init?.body ? JSON.parse(init.body) : null;
    sent.push({ path, body, auth: init?.headers?.authorization });
    return answer(path, body);
  }) as any;
  const h: Host = {
    async openPage(_s, url) { calls.push(`open ${url}`); return { ok: true, finalUrl: url }; },
    async runScript() { calls.push('script'); return { messages: [], timedOut: false }; },
    async showLogin() { calls.push('login'); return { outcome: 'signed_in', messages: [] }; },
    async fetch() { calls.push('fetch'); return { ok: true, status: 200, body: '' }; },
    ...host,
  };
  const client = new MealioClient({
    publishableKey: 'pk', getSessionToken: async () => 'tok', platform: 'web-test', sdkVersion: '0',
    baseUrl: 'https://mealio.test', fetchImpl, keys: KEYS, ...extra,
  }, h);
  const start = (ins: unknown[]) => { const job = `job${++jobs}`; return ok({ job, envelope: env(job, 1, ins) }); };
  return { client, sent, calls, start };
}
const paths = (sent: Array<{ path: string }>) => sent.map((s) => s.path.replace('/api/v1/sdk', ''));

afterEach(() => { vi.useRealTimers(); });

describe('one job at a time', () => {
  it('a second prepare waits for the first to end', async () => {
    let release!: () => void;
    const gate = new Promise<void>((r) => { release = r; });
    const order: string[] = [];
    const t = setup((p) => (p.endsWith('/carts') ? t.start([open('o'), done(CART)]) : ok({})), {
      async openPage(_s, url) { order.push('open'); await gate; order.push('opened'); return { ok: true, finalUrl: url }; },
    });
    const a = t.client.prepareCart({ recipe });
    const b = t.client.prepareCart({ recipe });
    await tick(20);
    expect(order).toEqual(['open']);
    expect(paths(t.sent)).toEqual(['/carts']);
    release();
    await Promise.all([a, b]);
    expect(order).toEqual(['open', 'opened', 'open', 'opened']);
  });

  it('a Host that never answers ends the step at its timeout plus the grace', async () => {
    vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] });
    const t = setup((p, b) => (p.endsWith('/carts') ? t.start([{ op: 'page_script', id: 's', script: '', until: [], timeoutMs: 100 }])
      : ok({ envelope: env(p.split('/')[5], 2, [done({ ...CART, seen: b.results })]) })), { runScript: () => new Promise(() => {}) });
    const p = t.client.prepareCart({ recipe });
    await vi.advanceTimersByTimeAsync(100 + HOST_GRACE_MS + 10);
    const cart = await p;
    expect((cart.cart as any).seen[0]).toMatchObject({ id: 's', timedOut: true, messages: [] });
  });

  it('after a hung job ends, a warm-up runs again', async () => {
    vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] });
    const t = setup((p) => (p.endsWith('/carts') ? t.start([open('o')]) : p.endsWith('/warm') ? ok({ warm: null }) : ok({ envelope: env('job1', 2, [done(CART)]) })),
      { openPage: () => new Promise(() => {}) });
    const p = t.client.prepareCart({ recipe });
    await vi.advanceTimersByTimeAsync(1000 + HOST_GRACE_MS + 10);
    await p;
    await t.client.warm();
    expect(paths(t.sent)).toContain('/warm');
  });
});

describe('bounded requests', () => {
  it('a request with no answer fails as network after 30 seconds', async () => {
    vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] });
    const t = setup(() => new Promise(() => {}));
    const p = t.client.storePreferences().catch((e) => e);
    await vi.advanceTimersByTimeAsync(REQUEST_TIMEOUT_MS + 10);
    expect(await p).toMatchObject({ code: 'network' });
  });

  it('a 200 that is not JSON is a server error, not a TypeError', async () => {
    const t = setup(() => new Response('<html>portal</html>', { status: 200 }));
    expect(await t.client.prepareCart({ recipe }).catch((e) => e)).toMatchObject({ name: 'MealioError', code: 'server' });
    expect(await t.client.stores().catch((e) => e)).toMatchObject({ code: 'server' });
  });

  it('a failed store list throws instead of reading as no stores', async () => {
    const t = setup(() => ({ ok: false, status: 503, json: async () => ({ error: { code: 'store_unavailable', message: 'down' } }) }));
    expect(await t.client.stores().catch((e) => e)).toMatchObject({ code: 'store_unavailable' });
  });
});

describe('session function', () => {
  it('a failing one raises session_failed with its message', async () => {
    const t = setup(() => ok({}), {}, { getSessionToken: async () => { throw new Error('your server is down'); } });
    expect(await t.client.storePreferences().catch((e) => e)).toMatchObject({ code: 'session_failed', message: 'your server is down' });
  });

  it('one that never answers raises session_failed', async () => {
    vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] });
    const t = setup(() => ok({}), {}, { getSessionToken: () => new Promise(() => {}) });
    const p = t.client.storePreferences().catch((e) => e);
    await vi.advanceTimersByTimeAsync(REQUEST_TIMEOUT_MS + 10);
    expect(await p).toMatchObject({ code: 'session_failed' });
  });
});

describe('cancelling', () => {
  it('stops after the current step: no sign-in, nothing more sent', async () => {
    const cancel = new CancelToken();
    const t = setup((p) => (p.endsWith('/carts') ? t.start([open('o'), login]) : ok({})), {
      async openPage(_s, url) { cancel.cancel(); return { ok: true, finalUrl: url }; },
    });
    const e = await t.client.prepareCart({ recipe }, { cancel }).catch((x) => x);
    expect(e).toMatchObject({ code: 'cancelled' });
    expect(paths(t.sent)).toEqual(['/carts']);
    // The queue is free again.
    await t.client.warm();
  });

  it('a cancelled job waiting in the queue never starts', async () => {
    let release!: () => void;
    const gate = new Promise<void>((r) => { release = r; });
    const t = setup((p) => (p.endsWith('/carts') ? t.start([open('o'), done(CART)]) : ok({})), {
      async openPage(_s, url) { await gate; return { ok: true, finalUrl: url }; },
    });
    const a = t.client.prepareCart({ recipe });
    const cancel = new CancelToken();
    const b = t.client.prepareCart({ recipe }, { cancel }).catch((x) => x);
    cancel.cancel();
    release();
    await a;
    expect(await b).toMatchObject({ code: 'cancelled' });
    expect(paths(t.sent)).toEqual(['/carts']);
  });

  it('a sign-in open when it is cancelled is told to close', async () => {
    const cancel = new CancelToken();
    const t = setup((p) => (p.endsWith('/carts') ? t.start([login]) : ok({})), {
      showLogin: (o) => new Promise((resolve) => { o.cancel?.onCancel(() => resolve({ outcome: 'cancelled', messages: [] })); }),
    });
    const p = t.client.prepareCart({ recipe }, { cancel }).catch((x) => x);
    await tick();
    cancel.cancel();
    expect(await p).toMatchObject({ code: 'cancelled' });
  });
});

describe('users', () => {
  it('while nobody is signed in, no session is asked for and warm does nothing', async () => {
    let asked = 0;
    const t = setup(() => ok({ warm: null }), {}, { userId: null, getSessionToken: async () => { asked += 1; return 't'; } });
    await t.client.warm();
    expect(await t.client.prepareCart({ recipe }).catch((e) => e)).toMatchObject({ code: 'not_signed_in' });
    expect(asked).toBe(0);
    expect(t.sent).toEqual([]);
  });

  it('a new user cancels a prepare, resets the session, and says to sign out of stores', async () => {
    const tokens = ['alice', 'bob'];
    const t = setup((p) => (p.endsWith('/carts') ? t.start([open('o'), done(CART)]) : ok({})),
      { async openPage(_s, url) { await tick(20); return { ok: true, finalUrl: url }; } },
      { userId: 'a', getSessionToken: async () => tokens.shift()! });
    const p = t.client.prepareCart({ recipe }).catch((e) => e);
    await tick();
    expect(t.client.setUser('b')).toBe(true);
    expect(await p).toMatchObject({ code: 'cancelled' });
    await t.client.storePreferences();
    expect(t.sent.map((s) => s.auth)).toEqual(['Bearer alice', 'Bearer bob']);
    expect(t.client.setUser('b')).toBe(false);
    expect(t.client.setUser(null)).toBe(true);
    expect(t.client.setUser('c')).toBe(false);
  });

  it('an add runs on under the session it started with', async () => {
    const tokens = ['alice', 'bob'];
    let release!: () => void;
    const gate = new Promise<void>((r) => { release = r; });
    const t = setup((p) => (p.endsWith('/add') ? t.start([open('o')]) : ok({ envelope: env('job1', 2, [done({ added: [] })]) })),
      { async openPage(_s, url) { await gate; return { ok: true, finalUrl: url }; } },
      { userId: 'a', getSessionToken: async () => tokens.shift()! });
    const p = t.client.addToCart('c', []);
    await tick();
    t.client.setUser('b');
    release();
    await p;
    expect(t.sent.map((s) => s.auth)).toEqual(['Bearer alice', 'Bearer alice']);
  });

  it('a warm-up that ends after a reset is not offered to the next prepare', async () => {
    let release!: () => void;
    const gate = new Promise<void>((r) => { release = r; });
    const t = setup(async (p) => {
      if (p.endsWith('/warm')) { await gate; return ok({ job: 'w', envelope: env('w', 1, [done({ store: 'heb', signedIn: true })]) }); }
      return t.start([done(CART)]);
    });
    const w = t.client.warm();
    await tick();
    t.client.resetSession();
    release();
    await w;
    await t.client.prepareCart({ store: 'heb', recipe });
    expect(t.sent.find((s) => s.path.endsWith('/carts'))!.body.warm).toBeUndefined();
  });
});

describe('cart session', () => {
  const prod = (o: any) => ({ id: 'p', name: 'P', ...o });
  const item = (o: any) => ({ key: 'k', ingredient: 'x', quantity: 1, status: 'remembered', options: [], selectedId: 'p', remembered: null, ...o });
  const session = (items: any[], client: any = {}, store = 'heb') => new CartSession(client, { cartId: 'c', store, items, ready: [], needsChoice: [], unavailable: [] } as any);

  it('shows the quantity it sends, under the cap, also after switching product', () => {
    const c = session([item({ quantity: 8, options: [prod({ unitPrice: 2, maxQuantity: 5 })] })]);
    expect(c.quantity('k')).toBe(5);
    expect(c.selections()[0].quantity).toBe(5);
    const d = session([item({ selectedId: 'a', options: [prod({ id: 'a', unitPrice: 2 }), prod({ id: 'b', unitPrice: 2, maxQuantity: 3 })] })]);
    d.setQuantity('k', 10);
    d.select('k', 'b');
    expect(d.quantity('k')).toBe(3);
    expect(d.selections()[0].quantity).toBe(3);
    expect(d.setQuantity('k', d.quantity('k') - 1)).toBe(2);
  });

  it('the list total and the done total agree to the cent', () => {
    const lb = (key: string) => item({ key, weightLb: 0.25, options: [prod({ soldByWeight: true, pricePerLb: 3.33 })] });
    const c = session([lb('a'), lb('b')]);
    const added = ['a', 'b'].map((key) => ({ key, productId: 'p', name: 'P', quantity: 1, weightLb: 0.25, pricePerLb: 3.33 }));
    expect(c.estimate().total).toBe(1.66);
    expect(c.addedTotal({ added, failed: [], skipped: [] } as any).total).toBe(1.66);
  });

  it('a second add while one runs returns the same promise', async () => {
    let calls = 0;
    const c = session([], { addToCart: async () => { calls += 1; await tick(); return { added: [] }; } });
    const a = c.addToCart();
    expect(c.addToCart()).toBe(a);
    await a;
    expect(calls).toBe(1);
  });

  it('knows when a search runs, and cancels it', async () => {
    let seen: CancelToken | undefined;
    const c = session([item({})], { search: (_c: string, _k: string, _q: string, o: any) => { seen = o.cancel; return new Promise((_, rej) => o.cancel.onCancel(() => rej(new Error('cancelled')))); } });
    const p = c.search('k', 'milk').catch(() => 'stopped');
    expect(c.searching).toBe(true);
    c.cancelSearches();
    expect(await p).toBe('stopped');
    expect(seen!.cancelled).toBe(true);
    expect(c.searching).toBe(false);
  });

  it('restores picks from a failed add where the product is still offered', () => {
    const opts = [prod({ id: 'p1', maxQuantity: 9, preferences: [{ id: 'sl', label: 'Sliced' }] }), prod({ id: 'p2' })];
    const old = session([item({ key: 'a', options: opts, selectedId: 'p1' }), item({ key: 'b', options: opts, selectedId: 'p1' }), item({ key: 'c', options: [prod({ id: 'gone' })], selectedId: 'gone' })]);
    old.select('a', 'p2');
    old.setQuantity('a', 4);
    old.deselect('b');
    old.select('c', 'gone');
    const fresh = session([item({ key: 'a', options: opts, selectedId: 'p1' }), item({ key: 'b', options: opts, selectedId: 'p1' }), item({ key: 'c', options: [prod({ id: 'new' })], selectedId: 'new' })]);
    fresh.restorePicks(old);
    expect([fresh.selectedId('a'), fresh.quantity('a'), fresh.isSelected('b'), fresh.selectedId('c')]).toEqual(['p2', 4, false, 'new']);
    const elsewhere = session([item({ key: 'a', options: opts, selectedId: 'p1' })], {}, 'walmart');
    elsewhere.restorePicks(old);
    expect(elsewhere.selectedId('a')).toBe('p1');
  });

  it('exposes server warnings, and none from older servers', () => {
    const c = new CartSession({} as any, { ...CART, warnings: [{ code: 'lines_dropped', message: 'Two lines were empty.' }] } as any);
    expect(c.warnings).toEqual([{ code: 'lines_dropped', message: 'Two lines were empty.' }]);
    expect(session([]).warnings).toEqual([]);
  });
});

describe('blocked mutations', () => {
  it("names a mutation and its root fields, and nothing of a query", () => {
    expect(mutationNames('mutation Go($a: ID!) { x: placeOrder(id: $a, note: "checkout") { ... on Err { message } } } # payment'))
      .toEqual(['Go', 'placeOrder']);
    expect(mutationNames('query Q { paymentMethods { id } }')).toEqual([]);
  });

  function guard() {
    const sent: string[] = [];
    const win: any = { location: { href: 'https://www.heb.com/' }, Blob, ArrayBuffer, URLSearchParams, encodeURIComponent };
    win.fetch = (u: any) => { sent.push(String(u?.url ?? u)); return Promise.resolve('ok'); };
    win.XMLHttpRequest = function () {};
    win.XMLHttpRequest.prototype.open = function () {};
    win.XMLHttpRequest.prototype.send = function () { sent.push('xhr'); };
    win.window = win;
    vm.createContext(win);
    vm.runInContext(GUARD_ARM_SCRIPT, win);
    return { win, sent };
  }
  const outcome = (p: Promise<unknown>) => p.then(() => 'sent', () => 'refused');

  it('the guard refuses every shared blocked body, and passes the rest', async () => {
    const { win } = guard();
    for (const v of [...(vectors as any).blockedBodies, ...(vectors as any).jsonBodies]) {
      if (!v.body) continue;
      expect(await outcome(win.fetch('/graphql', { method: 'POST', body: v.body })), v.body).toBe(v.blocked ? 'refused' : 'sent');
    }
  });

  it('the guard reads Request objects, Blob and form bodies', async () => {
    const { win, sent } = guard();
    const body = '{"operationName":"PlaceOrder"}';
    expect(await outcome(win.fetch(new Request('https://www.heb.com/graphql', { method: 'POST', body })))).toBe('refused');
    expect(await outcome(win.fetch('/graphql', { method: 'POST', body: new Blob([body]) }))).toBe('refused');
    expect(await outcome(win.fetch('/graphql', { method: 'POST', body: new URLSearchParams({ operationName: 'place_order' }) }))).toBe('refused');
    expect(await outcome(win.fetch('/graphql', { method: 'POST', body: new TextEncoder().encode(body) }))).toBe('refused');
    expect(await outcome(win.fetch(new Request('https://www.heb.com/graphql', { method: 'POST', body: '{"operationName":"Search"}' })))).toBe('sent');
    expect(sent).toEqual(['https://www.heb.com/graphql']);
  });

  it('the guard holds a Blob sent by XMLHttpRequest until it is read', async () => {
    const { win, sent } = guard();
    const x = new win.XMLHttpRequest();
    x.abort = () => sent.push('aborted');
    x.open('POST', '/graphql');
    x.send(new Blob(['{"operationName":"submit_order"}']));
    await tick();
    expect(sent).toEqual(['aborted']);
  });
});

describe('round 2: sessions and users', () => {
  it('a user change while a prepare waits for its token sends nothing and is cancelled', async () => {
    let asked = 0;
    let give!: (s: string) => void;
    const t = setup((p) => (p.endsWith('/carts') ? t.start([done(CART)]) : ok({})), {}, {
      userId: 'A', getSessionToken: () => { asked += 1; return asked === 1 ? new Promise<string>((r) => { give = r; }) : Promise.resolve('tokB'); },
    });
    const p = t.client.prepareCart({ recipe }).catch((e) => e);
    await tick();
    t.client.setUser('B');
    give('tokA');
    expect(await p).toMatchObject({ code: 'cancelled' });
    expect(t.sent).toEqual([]);
    expect(asked).toBe(1);
  });

  it('to nobody: cancelled, not not_signed_in', async () => {
    let give!: (s: string) => void;
    const t = setup((p) => (p.endsWith('/carts') ? t.start([done(CART)]) : ok({})), {}, {
      userId: 'A', getSessionToken: () => new Promise<string>((r) => { give = r; }),
    });
    const p = t.client.prepareCart({ recipe }).catch((e) => e);
    await tick();
    t.client.setUser(null);
    give('tokA');
    expect(await p).toMatchObject({ code: 'cancelled' });
    expect(t.sent).toEqual([]);
  });

  it("an add's 401 after a user change fails as session_expired, never with the new user's token", async () => {
    const tokens = ['tokA', 'tokB'];
    let steps = 0;
    let release!: () => void;
    const gate = new Promise<void>((r) => { release = r; });
    const t = setup((p) => {
      if (p.endsWith('/add')) return t.start([open('o')]);
      if (p.includes('/step')) { steps += 1; return steps === 1 ? { ok: false, status: 401, json: async () => ({}) } : ok({ envelope: env('job1', 2, [done({ added: [] })]) }); }
      return ok({});
    }, { async openPage(_s, url) { await gate; return { ok: true, finalUrl: url }; } }, { userId: 'A', getSessionToken: async () => tokens.shift()! });
    const a = t.client.addToCart('c', []).catch((e) => e);
    await tick();
    t.client.setUser('B');
    release();
    expect(await a).toMatchObject({ code: 'session_expired' });
    expect(t.sent.map((s) => s.auth)).toEqual(['Bearer tokA', 'Bearer tokA']);
  });

  it('an add keeps the token of the moment it was asked for, even after a queue wait', async () => {
    const tokens = ['tokA', 'tokB'];
    let release!: () => void;
    const gate = new Promise<void>((r) => { release = r; });
    const t = setup((p) => (p.endsWith('/carts') ? t.start([open('o'), done(CART)]) : p.endsWith('/add') ? t.start([done({ added: [] })]) : ok({})),
      { async openPage(_s, url) { await gate; return { ok: true, finalUrl: url }; } },
      { userId: 'A', getSessionToken: async () => tokens.shift()! });
    const prep = t.client.prepareCart({ recipe }).catch((e) => e);
    await tick();
    const add = t.client.addToCart('c', []);
    await tick();
    t.client.setUser('B');
    release();
    await prep;
    await add;
    expect(t.sent.filter((s) => s.path.endsWith('/add')).map((s) => s.auth)).toEqual(['Bearer tokA']);
  });

  it("an add's 401 with the same user renews the token once", async () => {
    const tokens = ['t1', 't2'];
    let steps = 0;
    const t = setup((p) => {
      if (p.endsWith('/add')) return t.start([open('o')]);
      steps += 1;
      return steps === 1 ? { ok: false, status: 401, json: async () => ({}) } : ok({ envelope: env('job1', 2, [done({ added: [] })]) });
    }, {}, { userId: 'A', getSessionToken: async () => tokens.shift()! });
    await t.client.addToCart('c', []);
    expect(t.sent.map((s) => s.auth)).toEqual(['Bearer t1', 'Bearer t1', 'Bearer t2']);
  });
});

describe('round 2: runExclusive', () => {
  it('a late function gets network, but the queue stays held until it really ends', async () => {
    vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] });
    let finish!: () => void;
    let seen: CancelToken | undefined;
    const t = setup((p) => (p.endsWith('/carts') ? t.start([done(CART)]) : ok({})));
    const ex = t.client.runExclusive((cancel) => { seen = cancel; return new Promise<void>((r) => { finish = r; }); }).catch((e) => e);
    const prep = t.client.prepareCart({ recipe });
    await vi.advanceTimersByTimeAsync(REQUEST_TIMEOUT_MS + 10);
    expect(await ex).toMatchObject({ code: 'network' });
    expect(seen!.cancelled).toBe(true);
    expect(t.sent).toEqual([]);
    finish();
    await prep;
    expect(paths(t.sent)).toEqual(['/carts']);
  });
});

describe('round 2: restorePicks', () => {
  it('keeps a product the user found with search, with its quantity', async () => {
    const mk = () => ({ cartId: 'c', store: 'heb', ready: [], needsChoice: [], unavailable: [], items: [
      { key: 'g', ingredient: 'garlic', quantity: 1, status: 'remembered', selectedId: 'p1', options: [{ id: 'p1', name: 'Garlic bulb', unitPrice: 1 }] }] } as any);
    // 0.6 round 3: by searching again on the new cart, never by carrying the product over.
    const searched: string[] = [];
    const client = { search: async (cartId: string) => { searched.push(cartId); return { options: [{ id: 'p9', name: 'Minced garlic jar', unitPrice: 4 }] }; } } as any;
    const a = new CartSession(client, mk());
    await a.search('g', 'minced garlic jar');
    a.select('g', 'p9');
    a.setQuantity('g', 2);
    const b = new CartSession(client, { ...mk(), cartId: 'c2' });
    await b.restorePicks(a);
    expect(searched).toEqual(['c', 'c2']);
    expect(b.selections()).toEqual([{ key: 'g', productId: 'p9', quantity: 2, remember: true, preferenceId: null }]);
    expect(b.options('g').map((p) => p.id)).toEqual(['p1', 'p9']);
  });
});

describe('round 2: guard', () => {
  function guard() {
    const sent: string[] = [];
    const win: any = { location: { href: 'https://www.heb.com/' }, Blob, ArrayBuffer, URLSearchParams, FormData, ReadableStream, Request, encodeURIComponent };
    win.fetch = (u: any) => { sent.push(String(u?.url ?? u)); return Promise.resolve('ok'); };
    win.window = win;
    vm.createContext(win);
    vm.runInContext(GUARD_ARM_SCRIPT, win);
    return { win, sent };
  }
  const outcome = (p: Promise<unknown>) => p.then(() => 'sent', () => 'refused');
  const stream = () => new ReadableStream({ start(c) { c.enqueue(new TextEncoder().encode('{"operationName":"PlaceOrder"}')); c.close(); } });

  it('reads a multipart FormData upload by its operations field', async () => {
    const { win, sent } = guard();
    const fd = new FormData();
    fd.append('operations', JSON.stringify({ query: 'mutation { placeOrder(id: 1) { id } }', variables: {} }));
    fd.append('map', '{}');
    expect(await outcome(win.fetch('https://www.heb.com/graphql', { method: 'POST', body: fd }))).toBe('refused');
    const ok2 = new FormData();
    ok2.append('operations', JSON.stringify([{ operationName: 'Upload', query: 'mutation Upload { uploadPhoto { id } }' }]));
    expect(await outcome(win.fetch('https://www.heb.com/graphql', { method: 'POST', body: ok2 }))).toBe('sent');
    expect(sent).toEqual(['https://www.heb.com/graphql']);
  });

  it('lets a body it cannot read through, but never past a blocked path', async () => {
    const { win, sent } = guard();
    expect(await outcome(win.fetch('https://www.heb.com/graphql', { method: 'POST', body: stream(), duplex: 'half' }))).toBe('sent');
    expect(await outcome(win.fetch('https://www.heb.com/checkout/submit', { method: 'POST', body: stream(), duplex: 'half' }))).toBe('refused');
    const used = new Request('https://www.heb.com/graphql', { method: 'POST', body: 'x' });
    await used.text();
    expect(await outcome(win.fetch(used))).toBe('sent');
    expect(sent).toEqual(['https://www.heb.com/graphql', 'https://www.heb.com/graphql']);
  });

  it('judges only a mutation root: nested fields and aliases pass, root fields block', () => {
    expect(mutationNames('mutation AddToCart { addItemsToCart { cart { items { maxPurchaseQuantity } } } }')).toEqual(['AddToCart', 'addItemsToCart']);
    expect(mutationNames('mutation { a: placeOrder { id } ... on Mutation { ...F } } fragment F on Mutation { checkout { id } }')).toEqual(['placeOrder', 'checkout']);
  });
});
