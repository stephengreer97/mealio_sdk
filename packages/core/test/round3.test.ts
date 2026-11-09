// 0.6 round 3: searched picks on a new cart, nothing hangs, cancel reasons,
// and the testing kit (which most of these run on).
import { describe, it, expect, vi, afterEach } from 'vitest';
import { CancelToken, EXCLUSIVE_CAP_MS, MealioClient, REQUEST_TIMEOUT_MS, type CartSession } from '../src';
import { createFakeMealio, TEST_KEYS, type FakeItem } from '../src/testing';

const recipe = { id: 'r1', title: 'Tacos', ingredients: [{ name: 'garlic' }] };
const codeOf = (p: Promise<unknown>) => p.then(() => 'ok', (e) => `${e.code}${e.reason ? `/${e.reason}` : ''}`);
const settle = (p: Promise<unknown>) => { const s = { v: 'pending' }; p.then(() => { s.v = 'resolved'; }, (e) => { s.v = `rejected ${e?.code}`; }); return s; };
const tick = (ms = 5) => new Promise((r) => setTimeout(r, ms));

const garlic: FakeItem = { key: 'garlic', options: [{ id: 'g1', name: 'Garlic bulb', unitPrice: 0.5 }], remembered: 'g1' };

afterEach(() => { vi.useRealTimers(); });

describe('round 3: restorePicks with a searched product (item 1)', () => {
  it('searches again on the new cart and sends only what that cart offered', async () => {
    const fake = createFakeMealio({ items: [garlic], search: { 'minced garlic': [{ id: 'jar9', name: 'Minced garlic jar', unitPrice: 3 }] }, add: { fail: 'store_unavailable' } });
    const client = fake.client();
    const a = await client.prepareCart({ recipe });
    await a.search('garlic', 'minced garlic');
    a.select('garlic', 'jar9');
    a.setQuantity('garlic', 2);
    expect(await codeOf(a.addToCart())).toBe('store_unavailable');

    fake.script.add = undefined;
    const b = await client.prepareCart({ recipe });
    await b.restorePicks(a);
    const searches = fake.requests.filter((r) => r.kind === 'search').map((r) => r.path);
    expect(searches).toEqual([`/api/v1/sdk/carts/${a.cartId}/search`, `/api/v1/sdk/carts/${b.cartId}/search`]);
    expect(b.selections()).toEqual([{ key: 'garlic', productId: 'jar9', quantity: 2, remember: true, preferenceId: null }]);
    const r = await b.addToCart();
    expect(r.failed).toEqual([]);
    expect(r.added.map((x) => [x.productId, x.quantity])).toEqual([['jar9', 2]]);
  });

  it('keeps the new cart\'s own pick when the search does not bring the product back', async () => {
    const fake = createFakeMealio({ items: [garlic], search: { 'minced garlic': [{ id: 'jar9', name: 'Minced garlic jar', unitPrice: 3 }] } });
    const client = fake.client();
    const a = await client.prepareCart({ recipe });
    await a.search('garlic', 'minced garlic');
    a.select('garlic', 'jar9');
    fake.script.search = {};
    const b = await client.prepareCart({ recipe });
    await b.restorePicks(a);
    expect(b.selectedId('garlic')).toBe('g1');
    expect(b.options('garlic').map((p) => p.id)).toEqual(['g1']);
    for (const s of b.selections()) if (s.productId) expect(fake.offered(b.cartId).some((p) => p.id === s.productId)).toBe(true);
  });
});

describe('round 3: nothing hangs (item 2)', () => {
  it('releases the queue 60 s into exclusive work that never ends, and the next job resets the page first', async () => {
    vi.useFakeTimers();
    const fake = createFakeMealio({ items: [garlic] });
    const client = fake.client();
    const ex = settle(client.runExclusive(() => new Promise(() => {})));
    const prep = settle(client.prepareCart({ recipe }));
    await vi.advanceTimersByTimeAsync(REQUEST_TIMEOUT_MS + 10);
    expect(ex.v).toBe('rejected network');
    expect(prep.v).toBe('pending');
    expect(fake.requests).toEqual([]);
    await vi.advanceTimersByTimeAsync(EXCLUSIVE_CAP_MS - REQUEST_TIMEOUT_MS);
    expect(prep.v).toBe('resolved');
    expect(fake.hostCalls[0]).toBe('reset');
    expect(fake.hostCalls.filter((c) => c === 'reset')).toHaveLength(1);
  });

  it('a job cancelled while it waits in the queue settles at once', async () => {
    const fake = createFakeMealio({ items: [garlic] });
    const client = fake.client();
    const release = fake.hold('prepare');
    const first = client.prepareCart({ recipe });
    await tick();
    const cancel = new CancelToken();
    const second = settle(client.prepareCart({ recipe }, { cancel }));
    const search = new CancelToken();
    const third = settle(client.search('cart_x', 'garlic', 'x', { cancel: search }));
    cancel.cancel();
    search.cancel();
    await tick();
    expect(second.v).toBe('rejected cancelled');
    expect(third.v).toBe('rejected cancelled');
    release();
    await first;
    expect(fake.requests.filter((r) => r.kind === 'prepare')).toHaveLength(1);
  });
});

describe('round 3: cancel beats a failed session fetch (item 4) and carries a reason (item 10)', () => {
  it('cancelJobs during getSessionToken, then the fetch fails: cancelled, not session_failed', async () => {
    let fail!: (e: Error) => void;
    const fake = createFakeMealio({ items: [garlic] });
    const client = fake.client({ getSessionToken: () => new Promise<string>((_, rej) => { fail = rej; }) });
    const p = codeOf(client.prepareCart({ recipe }));
    await tick();
    client.cancelJobs();
    fail(new Error('offline'));
    expect(await p).toBe('cancelled/cancelled');
  });

  it('setUser: user_changed; your own token: cancelled or the reason you gave', async () => {
    const fake = createFakeMealio({ items: [garlic] });
    const client = fake.client({ userId: 'u1' });
    const release = fake.hold('prepare');
    const p = codeOf(client.prepareCart({ recipe }));
    await tick();
    client.setUser('u2');
    expect(await p).toBe('cancelled/user_changed');
    release();
    const mine = new CancelToken();
    const q = codeOf(client.prepareCart({ recipe }, { cancel: mine }));
    mine.cancel('closed');
    expect(await q).toBe('cancelled/closed');
    const t = new CancelToken();
    const r = codeOf(client.prepareCart({ recipe }, { cancel: t }));
    t.cancel();
    expect(await r).toBe('cancelled/cancelled');
  });

  it('resetSession while the token is on its way: user_changed, and nothing loops', async () => {
    let calls = 0;
    let client!: MealioClient;
    const fake = createFakeMealio({ items: [garlic] });
    client = fake.client({ getSessionToken: async () => { calls += 1; client.resetSession(); return 'tok'; } });
    expect(await codeOf(client.prepareCart({ recipe }))).toBe('cancelled/user_changed');
    expect(calls).toBe(1);
  });
});

describe('testing kit (item 9)', () => {
  const items: FakeItem[] = [
    { key: 'salmon', options: [{ id: 'f1', name: 'Salmon', soldByWeight: true, pricePerLb: 10, estimated: true, weightOptions: [0.5, 1, 1.5] }], remembered: 'f1', weightLb: 1 },
    { key: 'garlic', options: [{ id: 'g1', name: 'Garlic', unitPrice: 0.5 }, { id: 'g2', name: 'Garlic 3 pack', unitPrice: 1.5 }] },
    { key: 'ham', options: [{ id: 'h1', name: 'Deli ham', unitPrice: 6, preferences: [{ id: 'sliced', label: 'Sliced' }] }], remembered: 'h1', rememberedPreferenceId: 'sliced' },
    { key: 'salt', options: [{ id: 's1', name: 'Salt', unitPrice: 2 }], remembered: 's1', startUnchecked: true },
    { key: 'herbs', options: [{ id: 'x1', name: 'Herbs' }] },
    { key: 'saffron', unavailable: 'not_found' },
  ];

  it('loads with the test key only when asked: a default client refuses the fake\'s envelopes', async () => {
    const fake = createFakeMealio({ items });
    expect(Object.keys(TEST_KEYS)).toEqual(['ktest']);
    const prod = new MealioClient({ ...fake.config(), keys: undefined }, fake.host);
    expect(await codeOf(prod.prepareCart({ recipe }))).toBe('bad_envelope');
  });

  it('remembered picks, startUnchecked, preferences, weight, unavailable, warnings', async () => {
    const fake = createFakeMealio({ items, warnings: [{ code: 'servings_ignored', message: 'x' }] });
    const cart = await fake.client().prepareCart({ recipe });
    expect(cart.items.map((i) => [i.key, i.status, i.selectedId])).toEqual([
      ['salmon', 'remembered', 'f1'], ['garlic', 'choose', null], ['ham', 'remembered', 'h1'],
      ['salt', 'remembered', 's1'], ['herbs', 'choose', null], ['saffron', 'unavailable', null],
    ]);
    expect(cart.selectedId('salmon')).toBe('f1');
    expect(cart.preferenceId('ham')).toBe('sliced');
    expect(cart.isSelected('salt')).toBe(false);
    expect(cart.weight('salmon')).toBe(1);
    expect(cart.warnings.map((w) => w.code)).toEqual(['servings_ignored']);
    expect(cart.estimate()).toEqual({ total: 16, count: 2, estimated: true, unpriced: 0 });
  });

  it('a startUnchecked item with nothing remembered has selectedId null', async () => {
    const fake = createFakeMealio({ items: [{ key: 'oil', options: [{ id: 'o1', name: 'Oil', unitPrice: 4 }], startUnchecked: true }] });
    const cart = await fake.client().prepareCart({ recipe });
    expect(cart.items[0]).toMatchObject({ startUnchecked: true, selectedId: null, status: 'choose' });
    expect(cart.selectedId('oil')).toBeNull();
  });

  it('total is null while any ticked item has no price, and the add reports what the store took', async () => {
    const fake = createFakeMealio({ items });
    const cart = await fake.client().prepareCart({ recipe });
    cart.select('herbs', 'x1');
    expect(cart.estimate()).toMatchObject({ total: null, unpriced: 1 });
    cart.deselect('herbs');
    const r = await cart.addToCart();
    expect(r.added.map((a) => a.key)).toEqual(['salmon', 'ham']);
    expect(cart.addedTotal(r).total).toBe(16);
  });

  it('cancel on unmount: a held prepare fails as cancelled/closed and sends nothing more', async () => {
    const fake = createFakeMealio({ items });
    const release = fake.hold('prepare');
    const unmount = new CancelToken();
    const p = codeOf(fake.client().prepareCart({ recipe }, { cancel: unmount }));
    await tick();
    unmount.cancel('closed');
    release();
    expect(await p).toBe('cancelled/closed');
    expect(fake.requests.filter((r) => r.kind === 'step')).toEqual([]);
    expect(fake.hostCalls).toEqual([]);
  });

  it('user switch: the old prepare ends user_changed, the next one uses the new session', async () => {
    let user = 'u1';
    const fake = createFakeMealio({ items });
    const client = fake.client({ userId: 'u1', getSessionToken: async () => `tok_${user}` });
    const release = fake.hold('prepare');
    const p = codeOf(client.prepareCart({ recipe }));
    await tick();
    user = 'u2';
    client.setUser('u2');
    release();
    expect(await p).toBe('cancelled/user_changed');
    await client.prepareCart({ recipe });
    expect(fake.requests.filter((r) => r.kind === 'prepare').map((r) => r.token)).toEqual(['tok_u1', 'tok_u2']);
  });

  it('sign-in required, errors by code, store preferences', async () => {
    const fake = createFakeMealio({ items, signIn: 'signed_in' });
    const client = fake.client();
    await client.prepareCart({ recipe });
    expect(fake.hostCalls).toContain('login');
    fake.script.signIn = 'cancelled';
    expect(await codeOf(client.prepareCart({ recipe }))).toBe('login_cancelled');
    fake.script.signIn = null;
    fake.script.errors = { prepare: { code: 'location_required', status: 400 } };
    expect(await codeOf(client.prepareCart({ recipe, store: 'kroger' }))).toBe('location_required');
    fake.script.errors = {};
    expect((await client.setStore('safeway')).defaultStore).toBe('safeway');
    expect((await client.storePreferences()).defaultStore).toBe('safeway');
    fake.script.errors = { session: 'boom' };
    expect(await codeOf(fake.client().prepareCart({ recipe }))).toBe('session_failed');
  });

  it('a Kroger family cart signs in through Kroger with no page of its own', async () => {
    const fake = createFakeMealio({ items, store: 'kroger', signIn: 'signed_in' });
    const cart: CartSession = await fake.client().prepareCart({ recipe });
    expect(cart.store).toBe('kroger');
    expect(fake.hostCalls).toEqual(['login']);
  });
});
