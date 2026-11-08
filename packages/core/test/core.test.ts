import { describe, it, expect } from 'vitest';
import vm from 'node:vm';
import vectors from '../../../protocol/test-vectors.json';
import sharedStrings from '../../../protocol/strings.json';
import {
  Allowlist, GUARD_SCRIPT, Runner, matches, bodyBlocked, parseUrl, openEnvelope, checkInstructions, EnvelopeError, MealioClient, CartSession, addedPrice, DEFAULT_STRINGS, fillText, safeListener, textTools,
  type AddResult, type Host, type Envelope, type Matcher,
} from '../src';

const KEYS = { [vectors.kid]: vectors.publicKey };

function fakeHost(over: Partial<Host> = {}): Host & { calls: string[] } {
  const calls: string[] = [];
  return {
    calls,
    async openPage(store, url) { calls.push(`open ${url}`); return { ok: true, finalUrl: url }; },
    async runScript(store, guard, script, until) {
      calls.push('script');
      return { messages: [{ type: until[0]?.type ?? 'X', loggedIn: true }], timedOut: false };
    },
    async showLogin() { calls.push('login'); return { outcome: 'signed_in', messages: [] }; },
    async fetch() { calls.push('fetch'); return { ok: true, status: 200, body: '{}' }; },
    ...over,
  };
}

describe('test vectors', () => {
  for (const c of vectors.cases) {
    it(c.name, async () => {
      const runner = new Runner(fakeHost(), new Allowlist(), KEYS);
      if (c.expect === 'ok') {
        const out = await runner.run(c.envelope as Envelope, c.job, c.lastSeq);
        if ((c as any).firstResultError) expect((out.results[0] as any).error).toBe((c as any).firstResultError);
        else expect(out.results.every((r) => r.ok) || out.terminal).toBeTruthy();
      } else {
        await expect(runner.run(c.envelope as Envelope, c.job, c.lastSeq)).rejects.toMatchObject({ why: c.expect });
      }
    });
  }

  it('allowlist cases', () => {
    const a = new Allowlist();
    for (const c of vectors.allowlist) {
      expect(a.check(c.store, c.url, c.use as any).ok, `${c.store} ${c.url} ${c.use}`).toBe(c.ok);
    }
  });

  it('matcher cases', () => {
    for (const c of vectors.matchers) expect(matches(c.msg as any, c.m as Matcher)).toBe(c.ok);
  });

  it('done carries unicode result intact', async () => {
    const c = vectors.cases.find((x) => x.name === 'valid_unicode_done')!;
    const out = await new Runner(fakeHost(), new Allowlist(), KEYS).run(c.envelope as Envelope, 'job_test', 1);
    expect(out.terminal).toEqual({ kind: 'done', result: { hello: 'café ✓' } });
  });

  it('refuses the production key for test envelopes', () => {
    const c = vectors.cases[0];
    expect(() => openEnvelope(c.envelope as Envelope)).toThrow(EnvelopeError);
  });
});

describe('runner', () => {
  it('skips the rest of an envelope after a failure', async () => {
    const c = vectors.cases.find((x) => x.name === 'blocked_url_runs_but_refuses')!;
    const host = fakeHost();
    const out = await new Runner(host, new Allowlist(), KEYS).run(c.envelope as Envelope, 'job_test', 0);
    expect(out.results).toHaveLength(1);
    expect(host.calls).toEqual([]);
  });
});

describe('allowlist widening', () => {
  it('adds only hosts on a registrable domain the store already has', () => {
    const a = new Allowlist();
    a.widen({ v: 1, kind: 'allowlist', exp: 0, stores: { heb: { hosts: ['api.heb.com', 'heb-cdn.net'] }, nope: { hosts: ['x.com'] } } });
    expect(a.hostsFor('heb')!.hosts).toContain('api.heb.com');
    expect(a.hostsFor('heb')!.hosts).not.toContain('heb-cdn.net');
    expect(a.check('heb', 'https://www.heb.com/checkout', 'page').ok).toBe(false);
  });
});

describe('guard script', () => {
  function sandbox() {
    const posted: string[] = [];
    const fetched: string[] = [];
    const win: any = {
      location: { href: 'https://www.heb.com/robots.txt' },
      fetch: (u: string) => { fetched.push(String(u)); return Promise.resolve('ok'); },
      ReactNativeWebView: { postMessage: (s: string) => posted.push(s) },
      URL, Date, JSON, Promise, Error, RegExp, String,
    };
    win.window = win;
    vm.createContext(win);
    vm.runInContext(GUARD_SCRIPT, win);
    return { win, posted, fetched };
  }

  it('checks beacons too', () => {
    const beacons: string[] = [];
    const posted: string[] = [];
    const win: any = {
      location: { href: 'https://www.heb.com/' },
      navigator: { sendBeacon: (u: string) => { beacons.push(u); return true; } },
      ReactNativeWebView: { postMessage: (s: string) => posted.push(s) },
      URL, Date, JSON, Promise, Error, RegExp, String,
    };
    win.window = win;
    vm.createContext(win);
    vm.runInContext(GUARD_SCRIPT, win);
    expect(vm.runInContext(`navigator.sendBeacon('/analytics', 'x=1')`, win)).toBe(true);
    expect(vm.runInContext(`navigator.sendBeacon('/checkout/place-order', 'x')`, win)).toBe(false);
    expect(vm.runInContext(`navigator.sendBeacon('/graphql', '{"query":"mutation { confirmOrder { id } }"}')`, win)).toBe(false);
    expect(vm.runInContext(`navigator.sendBeacon('/graphql', new Blob(['x']))`, Object.assign(win, { Blob }))).toBe(false);
    expect(beacons).toEqual(['/analytics']);
  });

  it('lets a normal request through', async () => {
    const { win, fetched } = sandbox();
    await vm.runInContext(`fetch('/graphql', { method: 'POST', body: '{"operationName":"productSearchPageV2"}' })`, win);
    expect(fetched).toEqual(['/graphql']);
  });

  it('blocks checkout paths and checkout operations', async () => {
    const { win, posted, fetched } = sandbox();
    await expect(vm.runInContext(`fetch('/checkout/review')`, win)).rejects.toThrow(/blocked_path/);
    await expect(vm.runInContext(`fetch('/graphql', { body: '{"operationName":"PlaceOrder"}' })`, win)).rejects.toThrow(/blocked_operation/);
    expect(fetched).toEqual([]);
    expect(posted.length).toBe(2);
  });

  it('is idempotent', () => {
    const { win } = sandbox();
    const f = win.fetch;
    vm.runInContext(GUARD_SCRIPT, win);
    expect(win.fetch).toBe(f);
  });
});

describe('client', () => {
  it('drives a job to done through step calls', async () => {
    const c1 = vectors.cases[0].envelope;
    const c2 = vectors.cases[1].envelope;
    const seen: string[] = [];
    const fetchImpl = (async (url: string, init: any) => {
      seen.push(url.replace('https://mealio.test', ''));
      const body = (o: unknown) => ({ ok: true, status: 200, json: async () => o });
      if (url.endsWith('/carts')) {
        // Who is calling rides on the first call: no separate hello round trip.
        expect(JSON.parse(init.body).sdk.platform).toBe('web-test');
        return body({ job: 'job_test', envelope: c1 });
      }
      if (url.endsWith('/step')) {
        const b = JSON.parse(init.body);
        expect(b.seq).toBe(1);
        expect(b.results).toHaveLength(2);
        return body({ envelope: c2 });
      }
      throw new Error('unexpected ' + url);
    }) as any;
    const client = new MealioClient({
      publishableKey: 'pk_test', getSessionToken: async () => 'tok', platform: 'web-test', sdkVersion: '0',
      baseUrl: 'https://mealio.test', fetchImpl, keys: KEYS,
    }, fakeHost());
    // done result is not a PreparedCart here, the point is the loop.
    const session = await client.prepareCart({ store: 'heb', recipe: { id: 'r1', ingredients: [] } }).catch((e) => e);
    expect(seen).toEqual(['/api/v1/sdk/carts', '/api/v1/sdk/jobs/job_test/step']);
    expect(session).toBeDefined();
  });

  it('retries once with a fresh token on 401', async () => {
    let tokens = 0;
    let calls = 0;
    const fetchImpl = (async () => {
      calls += 1;
      if (calls === 1) return { ok: false, status: 401, json: async () => ({}) };
      return { ok: true, status: 200, json: async () => ({ job: 'job_test', envelope: vectors.cases[1].envelope }) };
    }) as any;
    const client = new MealioClient({
      publishableKey: 'pk', getSessionToken: async () => `t${++tokens}`, platform: 'web-test', sdkVersion: '0', fetchImpl, keys: KEYS,
    }, fakeHost());
    // seq 2 vector is the first envelope here only for the retry check; it fails the seq check after.
    await client.addToCart('c1', []).catch(() => {});
    expect(tokens).toBe(2);
  });

  describe('resetSession', () => {
    function recorded(getSessionToken: () => Promise<string>) {
      const seen: string[] = [];
      const fetchImpl = (async (_url: string, init: { headers: Record<string, string> }) => {
        seen.push(init.headers.authorization);
        return { ok: true, status: 200, json: async () => ({}) };
      }) as any;
      const client = new MealioClient({ publishableKey: 'pk', getSessionToken, platform: 'web-test', sdkVersion: '0', fetchImpl, keys: KEYS }, fakeHost());
      return { client, seen };
    }

    it('keeps one token for one user', async () => {
      const { client, seen } = recorded(async () => 'alice');
      await client.storePreferences();
      await client.storePreferences();
      expect(seen).toEqual(['Bearer alice', 'Bearer alice']);
    });

    it('gives the next user a new token', async () => {
      const users = ['alice', 'bob'];
      const { client, seen } = recorded(async () => users.shift()!);
      await client.storePreferences();
      client.resetSession();
      await client.storePreferences();
      expect(seen).toEqual(['Bearer alice', 'Bearer bob']);
    });

    it('asks once when your function returns an empty token', async () => {
      let asked = 0;
      const { client, seen } = recorded(async () => { asked += 1; return ''; });
      await client.storePreferences();
      expect(asked).toBe(1);
      expect(seen).toEqual(['Bearer ']);
    });

    it('drops a token that arrives after the reset', async () => {
      let finishAlice!: (t: string) => void;
      const answers = [new Promise<string>((r) => { finishAlice = r; }), Promise.resolve('bob')];
      const { client, seen } = recorded(() => answers.shift()!);
      const asked = client.storePreferences();
      client.resetSession();
      finishAlice('alice');
      await asked;
      await client.storePreferences();
      expect(seen).toEqual(['Bearer bob', 'Bearer bob']);
    });
  });
});

describe('cart session', () => {
  const prepared = {
    cartId: 'c1', store: 'heb',
    items: [
      { key: 'onion', ingredient: 'onion', quantity: 1, status: 'remembered', selectedId: 'o1', remembered: { id: 'o1', name: 'Onion' },
        options: [{ id: 'o1', name: 'Onion' }, { id: 'o2', name: 'Red Onion' }] },
      { key: 'garlic', ingredient: 'garlic', quantity: 1, status: 'choose', selectedId: null, remembered: null,
        options: [{ id: 'g1', name: 'Garlic' }] },
      { key: 'saffron', ingredient: 'saffron', quantity: 1, status: 'unavailable', selectedId: null, remembered: null, options: [], reason: 'no_results' },
    ],
    ready: [], needsChoice: [], unavailable: [],
  } as any;

  it('starts with remembered items selected, and deselecting leaves them out without forgetting', () => {
    const cs = new CartSession({} as any, prepared);
    expect(cs.isSelected('onion')).toBe(true);
    expect(cs.isSelected('garlic')).toBe(false);
    cs.select('garlic', 'g1');
    cs.deselect('onion');
    expect(cs.selections()).toEqual([
      { key: 'onion', productId: null, remember: false },
      { key: 'garlic', productId: 'g1', quantity: 1, remember: true, preferenceId: null },
      { key: 'saffron', productId: null, remember: false },
    ]);
  });

  it('keeps a quantity per item, clamped to 1 and the store cap, in selections and the total', () => {
    const p2 = JSON.parse(JSON.stringify(prepared));
    p2.items[0].options[0] = { id: 'o1', name: 'Onion', unitPrice: 1.5, maxQuantity: 3 };
    p2.items[0].remembered = p2.items[0].options[0];
    p2.items[0].quantity = 2;
    const cs = new CartSession({} as any, p2);
    expect(cs.quantity('onion')).toBe(2);
    expect(cs.setQuantity('onion', 9)).toBe(3);
    expect(cs.setQuantity('onion', 0)).toBe(1);
    cs.setQuantity('onion', 3);
    expect(cs.selections()[0]).toMatchObject({ key: 'onion', productId: 'o1', quantity: 3 });
    expect(cs.estimate().total).toBeCloseTo(4.5);
    cs.select('onion', 'o2');
    expect(cs.maxQuantity('onion')).toBe(99);
    expect(cs.quantity('onion')).toBe(3);
    const p3 = JSON.parse(JSON.stringify(prepared));
    p3.items[0].quantity = 0;
    expect(new CartSession({} as any, p3).quantity('onion')).toBe(1);
  });

  describe('sold by weight', () => {
    const turkey = { id: 't1', name: 'Deli Turkey', soldByWeight: true, estimated: true, pricePerLb: 10, unitPrice: 10, weightOptions: [0.25, 0.5, 0.75, 1, 1.25] };
    const salmon = { id: 's1', name: 'Salmon', soldByWeight: true, estimated: true, pricePerLb: 12, unitPrice: 12 };
    const brisket = { id: 'b1', name: 'Brisket, Avg. 4 lbs', soldByWeight: true, estimated: true, pricePerLb: null, unitPrice: 32 };
    const cart = (over: Record<string, unknown> = {}) => ({
      cartId: 'c1', store: 'heb', ready: [], needsChoice: [], unavailable: [],
      items: [
        { key: 'turkey', ingredient: 'deli turkey', quantity: 1, status: 'remembered', selectedId: 't1', remembered: turkey, options: [turkey, salmon, brisket], ...over },
        { key: 'onion', ingredient: 'onion', quantity: 2, status: 'remembered', selectedId: 'o1', remembered: null, options: [{ id: 'o1', name: 'Onion', unitPrice: 1 }] },
      ],
    }) as any;

    it('starts at the recipe weight, else the first option, else 0.25', () => {
      expect(new CartSession({} as any, cart({ weightLb: 0.75 })).weight('turkey')).toBe(0.75);
      // A recipe weight the store does not sell becomes the nearest one it does.
      expect(new CartSession({} as any, cart({ weightLb: 0.6 })).weight('turkey')).toBe(0.5);
      expect(new CartSession({} as any, cart()).weight('turkey')).toBe(0.25);
      const cs = new CartSession({} as any, cart());
      cs.select('turkey', 's1');
      expect(cs.weight('turkey')).toBe(0.25);
      expect(cs.weight('onion')).toBe(0);
      expect(cs.isWeight('turkey')).toBe(true);
      expect(cs.isWeight('onion')).toBe(false);
    });

    it('setWeight snaps to the options and clamps to their range', () => {
      const cs = new CartSession({} as any, cart());
      expect(cs.setWeight('turkey', 0.8)).toBe(0.75);
      expect(cs.setWeight('turkey', 9)).toBe(1.25);
      expect(cs.setWeight('turkey', 0)).toBe(0.25);
      expect(cs.weightRange('turkey')).toEqual({ min: 0.25, max: 1.25 });
      expect(cs.weight('turkey')).toBe(0.25);
    });

    it('with no options, 0.25 lb steps from 0.25 to 20', () => {
      const cs = new CartSession({} as any, cart());
      cs.select('turkey', 's1');
      expect(cs.setWeight('turkey', 1.1)).toBe(1);
      expect(cs.setWeight('turkey', 1.13)).toBe(1.25);
      expect(cs.setWeight('turkey', 0.01)).toBe(0.25);
      expect(cs.setWeight('turkey', 99)).toBe(20);
      expect(cs.weightRange('turkey')).toEqual({ min: 0.25, max: 20 });
      cs.setWeight('turkey', 1);
      expect(cs.stepWeight('turkey', 1)).toBe(1.25);
      expect(cs.stepWeight('turkey', -1)).toBe(1);
    });

    it('stepWeight walks the options and stops at the ends', () => {
      const cs = new CartSession({} as any, cart());
      expect(cs.stepWeight('turkey', -1)).toBe(0.25);
      expect(cs.stepWeight('turkey', 1)).toBe(0.5);
      cs.setWeight('turkey', 1.25);
      expect(cs.stepWeight('turkey', 1)).toBe(1.25);
      expect(cs.stepWeight('turkey', -1)).toBe(1);
    });

    it('switching product re-snaps the weight to the new product', () => {
      const cs = new CartSession({} as any, cart());
      cs.select('turkey', 's1');
      cs.setWeight('turkey', 3);
      cs.select('turkey', 't1');
      expect(cs.weight('turkey')).toBe(1.25);
    });

    it('selections send weightLb for weight items only', () => {
      const cs = new CartSession({} as any, cart({ weightLb: 1 }));
      expect(cs.selections()).toEqual([
        { key: 'turkey', productId: 't1', quantity: 1, weightLb: 1, remember: true, preferenceId: null },
        { key: 'onion', productId: 'o1', quantity: 2, remember: true, preferenceId: null },
      ]);
    });

    it('estimate is price per lb times the weight, and marked estimated', () => {
      const cs = new CartSession({} as any, cart());
      cs.setWeight('turkey', 1.25);
      expect(cs.estimate()).toMatchObject({ total: 14.5, estimated: true, count: 2 });
      // A package-priced weight item counts its price once, whatever the weight.
      cs.select('turkey', 'b1');
      cs.setWeight('turkey', 3);
      expect(cs.estimate()).toMatchObject({ total: 34, estimated: true });
    });
  });

  describe('no partial totals', () => {
    const priced = (over: Record<string, unknown>[] = []) => ({
      cartId: 'c1', store: 'heb', ready: [], needsChoice: [], unavailable: [],
      items: [
        { key: 'onion', ingredient: 'onion', quantity: 2, status: 'remembered', selectedId: 'o1', remembered: null, options: [{ id: 'o1', name: 'Onion', unitPrice: 1, ...over[0] }] },
        { key: 'turkey', ingredient: 'deli turkey', quantity: 1, weightLb: 0.5, status: 'remembered', selectedId: 't1', remembered: null,
          options: [{ id: 't1', name: 'Deli Turkey', soldByWeight: true, estimated: true, pricePerLb: 12, unitPrice: 12, ...over[1] }] },
        { key: 'chipotle', ingredient: 'chipotle in adobo', quantity: 1, status: 'choose', selectedId: null, remembered: null,
          options: [{ id: 'c1', name: 'Chipotle Peppers', unitPrice: null }] },
      ],
    }) as any;

    it('totals when every selected item has a price; a weight item priced per lb counts as priced', () => {
      expect(new CartSession({} as any, priced()).estimate()).toEqual({ total: 8, count: 2, estimated: true, unpriced: 0 });
    });

    it('total is null when even one selected item has no price', () => {
      const cs = new CartSession({} as any, priced());
      cs.select('chipotle', 'c1');
      expect(cs.estimate()).toEqual({ total: null, count: 3, estimated: true, unpriced: 1 });
      // A weight item with neither a per-lb nor a package price is unpriced too.
      const w = new CartSession({} as any, priced([{}, { pricePerLb: null, unitPrice: null }]));
      expect(w.estimate()).toMatchObject({ total: null, unpriced: 1 });
      // Deselecting the unpriced item brings the number back.
      cs.deselect('chipotle');
      expect(cs.estimate().total).toBe(8);
    });

    const result = (added: AddResult['added']): AddResult => ({ cartId: 'c1', store: 'heb', added, skipped: [], failed: [], storeCartUrl: null, verified: true });

    it('prices added items from their own fields: unit times quantity, per lb times pounds, a package once', () => {
      expect(addedPrice({ key: 'a', productId: '1', name: 'Onion', quantity: 2, unitPrice: 0.37 })).toEqual({ amount: 0.74, estimated: false });
      expect(addedPrice({ key: 'b', productId: '2', name: 'Salmon', quantity: 1, weightLb: 1.25, pricePerLb: 10.9, unitPrice: 10.9, estimated: true })).toEqual({ amount: 13.63, estimated: true });
      expect(addedPrice({ key: 'c', productId: '3', name: 'Brisket', quantity: 1, weightLb: 4, unitPrice: 32, estimated: true })).toEqual({ amount: 32, estimated: true });
      expect(addedPrice({ key: 'd', productId: '4', name: 'Chipotle', quantity: 1 })).toBeNull();
    });

    it('addedTotal reads the added entries, falls back to the session product, and is null when any is unpriced', () => {
      const cs = new CartSession({} as any, priced());
      const full = result([
        { key: 'onion', productId: 'o1', name: 'Onion', quantity: 2, imageUrl: 'https://img/o.jpg', ingredient: '2 onions', unitPrice: 1.25 },
        { key: 'turkey', productId: 't1', name: 'Deli Turkey', quantity: 1, weightLb: 0.5, pricePerLb: 12, estimated: true },
      ]);
      expect(cs.addedTotal(full)).toEqual({ total: 8.5, count: 2, estimated: true, unpriced: 0 });
      // An older server: no prices on the entries, the selected products stand in.
      const old = result([{ key: 'onion', productId: 'o1', name: 'Onion', quantity: 2 }, { key: 'turkey', productId: 't1', name: 'Deli Turkey', quantity: 1, weightLb: 0.5 }]);
      expect(cs.addedTotal(old)).toEqual({ total: 8, count: 2, estimated: true, unpriced: 0 });
      cs.select('chipotle', 'c1');
      expect(cs.addedTotal(result([...full.added, { key: 'chipotle', productId: 'c1', name: 'Chipotle Peppers', quantity: 1 }])))
        .toEqual({ total: null, count: 3, estimated: true, unpriced: 1 });
      expect(cs.addedPrice(full.added[0])).toEqual({ amount: 2.5, estimated: false });
    });
  });

  it('holds an item back from the add and the total until its preference is chosen', () => {
    const p4 = JSON.parse(JSON.stringify(prepared));
    p4.items[1].options = [{ id: 'g1', name: 'Deli Turkey', unitPrice: 6, preferences: [{ id: 'thin', label: 'Thin' }, { id: 'none', label: 'No preference' }] }];
    const cs = new CartSession({} as any, p4);
    cs.select('garlic', 'g1');
    expect(cs.needsPreference('garlic')).toBe(true);
    expect(cs.pendingPreferences()).toEqual(['garlic']);
    expect(cs.selections()[1]).toEqual({ key: 'garlic', productId: null, remember: false });
    expect(cs.estimate().count).toBe(1);
    cs.select('garlic', 'g1', { preferenceId: 'thin' });
    expect(cs.needsPreference('garlic')).toBe(false);
    expect(cs.preferenceId('garlic')).toBe('thin');
    expect(cs.selections()[1]).toMatchObject({ key: 'garlic', productId: 'g1', preferenceId: 'thin' });
    expect(cs.estimate().count).toBe(2);
  });

  it('adds searched products to an item and lets the user pick one', async () => {
    const client = { search: async () => ({ key: 'garlic', query: 'jar', options: [{ id: 'g9', name: 'Minced Garlic Jar' }] }) } as any;
    const cs = new CartSession(client, prepared);
    await cs.search('garlic', 'jar');
    expect(cs.options('garlic').map((p) => p.id)).toEqual(['g1', 'g9']);
    cs.select('garlic', 'g9');
    expect(cs.selectedId('garlic')).toBe('g9');
    expect(() => cs.select('garlic', 'nope')).toThrow();
  });
});

describe('several recipes', () => {
  function capture() {
    const bodies: any[] = [];
    const fetchImpl = (async (url: string, init: any) => {
      bodies.push(JSON.parse(init.body));
      return { ok: false, status: 400, json: async () => ({ code: 'stop', message: 'stop' }) };
    }) as any;
    const client = new MealioClient({
      publishableKey: 'pk_test', getSessionToken: async () => 'tok', platform: 'web-test', sdkVersion: '0',
      baseUrl: 'https://mealio.test', fetchImpl, keys: KEYS,
    }, fakeHost());
    return { client, bodies };
  }
  const r = (id: string) => ({ id, title: id.toUpperCase(), ingredients: [{ name: 'onion' }] });

  it('sends one recipe as `recipe`, so older servers still understand it', async () => {
    const { client, bodies } = capture();
    await client.prepareCart({ store: 'heb', recipes: [r('a')] }).catch(() => null);
    expect(bodies[0].recipe.id).toBe('a');
    expect(bodies[0].recipes).toBeUndefined();
  });

  it('sends several as `recipes`', async () => {
    const { client, bodies } = capture();
    await client.prepareCart({ store: 'heb', recipes: [r('a'), r('b')] }).catch(() => null);
    expect(bodies[0].recipes.map((x: any) => x.id)).toEqual(['a', 'b']);
    expect(bodies[0].recipe).toBeUndefined();
  });

  it('refuses none or more than 10 before calling the server', async () => {
    const { client, bodies } = capture();
    await expect(client.prepareCart({ store: 'heb', recipes: [] })).rejects.toMatchObject({ code: 'bad_recipe' });
    await expect(client.prepareCart({ store: 'heb', recipes: Array.from({ length: 11 }, (_, i) => r('r' + i)) })).rejects.toMatchObject({ code: 'too_many_recipes' });
    expect(bodies).toHaveLength(0);
  });

  it('a session says which recipes each item is for', () => {
    const item = { key: 'onion', ingredient: 'onion', quantity: 3, status: 'choose', options: [], selectedId: null, remembered: null,
      recipes: [{ id: 'a', title: 'Tacos', quantity: 1 }, { id: 'b', title: 'Pasta', quantity: 2 }] };
    const cs = new CartSession({} as any, { cartId: 'c', store: 'heb', recipes: [{ id: 'a', title: 'Tacos' }, { id: 'b', title: 'Pasta' }], items: [item], ready: [], needsChoice: [item], unavailable: [] } as any);
    expect(cs.recipes.map((x) => x.id)).toEqual(['a', 'b']);
    expect(cs.recipesFor('onion').map((x) => x.quantity)).toEqual([1, 2]);
    // An older server sends neither.
    const old = new CartSession({} as any, { cartId: 'c', store: 'heb', items: [{ ...item, recipes: undefined }], ready: [], needsChoice: [], unavailable: [] } as any);
    expect(old.recipes).toEqual([]);
    expect(old.recipesFor('onion')).toEqual([]);
  });
});

describe('warm-up', () => {
  // Signs with the same deterministic TEST key as protocol/make-vectors.mjs.
  const crypto = require('node:crypto') as typeof import('node:crypto');
  const pkcs8 = Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), Buffer.alloc(32, 7)]);
  const priv = crypto.createPrivateKey({ key: pkcs8, format: 'der', type: 'pkcs8' });
  const env = (job: string, seq: number, instructions: unknown[]): Envelope => {
    const payload = JSON.stringify({ v: 1, kind: 'instructions', job, seq, exp: 4102444800, store: 'heb', instructions });
    return { payload, sig: crypto.sign(null, Buffer.from(payload, 'utf8'), priv).toString('base64'), kid: vectors.kid } as Envelope;
  };
  const cartDone = (job: string) => env(job, 1, [{ op: 'done', id: 'd', result: { cartId: 'c', store: 'heb', items: [], ready: [], needsChoice: [], unavailable: [] } }]);
  const warmDone = (signedIn: boolean | null) => env('job_warm', 1, [{ op: 'done', id: 'd', result: { store: 'heb', signedIn } }]);

  function setup(warmAnswer: () => unknown) {
    const sent: Array<{ path: string; body: any }> = [];
    const fetchImpl = (async (url: string, init: any) => {
      const path = url.replace('https://mealio.test', '');
      const body = JSON.parse(init.body);
      sent.push({ path, body });
      const ok = (o: unknown) => ({ ok: true, status: 200, json: async () => o });
      if (path === '/api/v1/sdk/warm') return ok(warmAnswer());
      if (path === '/api/v1/sdk/carts') return ok({ job: 'job_cart', envelope: cartDone('job_cart') });
      throw new Error('unexpected ' + path);
    }) as any;
    const host = fakeHost();
    const client = new MealioClient({
      publishableKey: 'pk', getSessionToken: async () => 'tok', platform: 'web-test', sdkVersion: '0',
      baseUrl: 'https://mealio.test', fetchImpl, keys: KEYS,
    }, host);
    const cartBody = () => sent.find((s) => s.path === '/api/v1/sdk/carts')?.body;
    return { client, sent, cartBody, host };
  }
  const recipe = { id: 'r1', ingredients: [{ name: 'milk' }] };

  it('hands a signed-in warm-up to the next prepare, once', async () => {
    const { client, cartBody, sent } = setup(() => ({ job: 'job_warm', envelope: warmDone(true) }));
    await client.warm();
    await client.prepareCart({ recipe });
    expect(cartBody().warm).toBe('job_warm');
    sent.length = 0;
    await client.prepareCart({ recipe });
    expect(cartBody().warm).toBeUndefined();
  });

  it('sends no hint when the warm-up found the user signed out, or nothing to warm', async () => {
    for (const answer of [() => ({ job: 'job_warm', envelope: warmDone(false) }), () => ({ warm: null })]) {
      const { client, cartBody } = setup(answer);
      await client.warm();
      await client.prepareCart({ recipe });
      expect(cartBody().warm).toBeUndefined();
    }
  });

  it('sends no hint for another store, or once the hidden page has loaded something else', async () => {
    const a = setup(() => ({ job: 'job_warm', envelope: warmDone(true) }));
    await a.client.warm();
    await a.client.prepareCart({ store: 'walmart', recipe });
    expect(a.cartBody().warm).toBeUndefined();

    const b = setup(() => ({ job: 'job_warm', envelope: warmDone(true) }));
    await b.client.warm();
    (b.client as any).runner.pageOpens += 1;
    await b.client.prepareCart({ recipe });
    expect(b.cartBody().warm).toBeUndefined();
  });

  it('a prepare waits for a warm-up in flight rather than sharing the page with it', async () => {
    let release!: () => void;
    const gate = new Promise<void>((r) => { release = r; });
    const order: string[] = [];
    const { client } = setup(() => ({ job: 'job_warm', envelope: warmDone(true) }));
    const f = (client as any).f;
    (client as any).f = async (url: string, init: any) => {
      if (url.endsWith('/warm')) { await gate; order.push('warm'); }
      if (url.endsWith('/carts')) order.push('cart');
      return f(url, init);
    };
    const w = client.warm();
    const p = client.prepareCart({ recipe });
    await new Promise((r) => setTimeout(r, 10));
    release();
    await Promise.all([w, p]);
    expect(order).toEqual(['warm', 'cart']);
  });

  it('runs at most once every few minutes, and never throws', async () => {
    let calls = 0;
    const { client } = setup(() => { calls += 1; throw new Error('boom'); });
    await client.warm();
    await client.warm();
    expect(calls).toBe(1);
    client.clearWarm();
    await expect(client.warm()).resolves.toBeUndefined();
    expect(calls).toBe(2);
  });
});

describe('security: request bodies and the runner fetch op', () => {
  it('flags every blocked body in the shared vectors', () => {
    for (const v of (vectors as any).blockedBodies) expect(bodyBlocked(v.body)).toBe(v.blocked);
  });

  it('judges the JSON strictness vectors as JSON.parse reads them', () => {
    const list = (vectors as any).jsonBodies as { rule: string; body: string; blocked: boolean }[];
    expect(new Set(list.map((v) => v.rule))).toEqual(new Set(['depth', 'hex', 'surrogate']));
    for (const v of list) expect(bodyBlocked(v.body), `${v.rule}: ${v.body.slice(0, 60)}`).toBe(v.blocked);
  });

  it('reads a multipart part whatever quotes its name has (round 4)', () => {
    const part = (name: string, value: string) => `--b\r\nContent-Disposition: form-data; name=${name}\r\n\r\n${value}\r\n--b--`;
    const m = JSON.stringify({ query: 'mutation { placeOrder { id } }' });
    for (const q of ['"', "'", '']) {
      expect(bodyBlocked(part(`${q}operations${q}`, m))).toBe(true);
      expect(bodyBlocked(part(`${q}query${q}`, 'mutation { placeOrder { id } }'))).toBe(true);
      expect(bodyBlocked(part(`${q}operationName${q}`, 'PlaceOrder'))).toBe(true);
      expect(bodyBlocked(part(`${q}operationsX${q}`, m))).toBe(false);
    }
  });

  it('refuses a signed fetch whose body names an order, before it leaves the device', async () => {
    const host = fakeHost();
    const runner = new Runner(host, new Allowlist(), KEYS);
    const r = await (runner as any).one('heb', { op: 'fetch', id: 'f1', request: { method: 'POST', url: 'https://www.heb.com/graphql', body: '{"operationName":"place\\u004frder"}' }, timeoutMs: 1000, maxBytes: 1000 });
    expect(r).toMatchObject({ ok: false, error: 'blocked' });
    expect(host.calls).not.toContain('fetch');
    const ok = await (runner as any).one('heb', { op: 'fetch', id: 'f2', request: { method: 'POST', url: 'https://www.heb.com/graphql', body: '{"operationName":"cartItemsV2"}' }, timeoutMs: 1000, maxBytes: 1000 });
    expect(ok.ok).toBe(true);
  });

  it('refuses show_login when the run may not sign in (a warm-up)', async () => {
    const host = fakeHost();
    const runner = new Runner(host, new Allowlist(), KEYS);
    const ins = { op: 'show_login', id: 'l1', url: 'https://www.heb.com/login', title: 'Sign in', doneWhen: [], timeoutMs: 1000 };
    expect(await (runner as any).one('heb', ins, false)).toMatchObject({ ok: false, outcome: 'cancelled', error: 'not_allowed' });
    expect(host.calls).not.toContain('login');
    expect((await (runner as any).one('heb', ins, true)).outcome).toBe('signed_in');
  });

  it('parses only plain host names: no userinfo, backslash or spaces', () => {
    expect(parseUrl('https://www.heb.com:x@evil.com/')).toBeNull();
    expect(parseUrl('https://evil.com\\.heb.com/')).toBeNull();
    expect(parseUrl('https://www.heb.com:443/a?b=1#c')).toEqual({ scheme: 'https', host: 'www.heb.com', rest: '/a?b=1' });
    expect(parseUrl('https://www.heb.com')).toEqual({ scheme: 'https', host: 'www.heb.com', rest: '/' });
  });
});

describe('warm-up never shares the page with a cart', () => {
  it('does not start while a cart call is waiting on its first request', async () => {
    const paths: string[] = [];
    let release!: () => void;
    const gate = new Promise<void>((r) => { release = r; });
    const fetchImpl = (async (url: string) => {
      const path = url.replace('https://mealio.test', '');
      paths.push(path);
      if (path === '/api/v1/sdk/carts') { await gate; return { ok: false, status: 503, json: async () => ({ error: { code: 'store_unavailable', message: 'down' } }) }; }
      return { ok: true, status: 200, json: async () => ({ warm: null }) };
    }) as any;
    const client = new MealioClient({ publishableKey: 'pk', getSessionToken: async () => 't', platform: 'web-test', sdkVersion: '0', baseUrl: 'https://mealio.test', fetchImpl, keys: KEYS }, fakeHost());
    const p = client.prepareCart({ recipe: { id: 'r', ingredients: [] } }).catch(() => null);
    await new Promise((r) => setTimeout(r, 5));
    await client.warm();
    release();
    await p;
    expect(paths).toEqual(['/api/v1/sdk/carts']);
  });
});

describe('store locations', () => {
  function client(reply: (path: string, body: any) => { status?: number; json: unknown }) {
    const calls: Array<{ path: string; body: any }> = [];
    const fetchImpl = (async (url: string, init: any) => {
      const path = String(url).replace('https://mealio.test', '');
      const body = JSON.parse(init.body);
      calls.push({ path, body });
      const r = reply(path, body);
      return new Response(JSON.stringify(r.json), { status: r.status ?? 200 });
    }) as unknown as typeof fetch;
    const c = new MealioClient({ publishableKey: 'pk', getSessionToken: async () => 'mst_x', platform: 'web-test', sdkVersion: '0', baseUrl: 'https://mealio.test', fetchImpl, keys: KEYS }, fakeHost());
    return { c, calls };
  }
  const OAK = { id: 'k2', name: 'Kroger Oak', address: '3 Oak St, Dallas, TX 75202', zip: '75202' };

  it('lists stores near a zip', async () => {
    const { c, calls } = client(() => ({ json: { locations: [OAK] } }));
    expect(await c.storeLocations('kroger', '75202')).toEqual([OAK]);
    expect(calls[0]).toEqual({ path: '/api/v1/sdk/locations', body: { store: 'kroger', zip: '75202' } });
  });

  it('reads and sets the store', async () => {
    const { c, calls } = client(() => ({ json: { defaultStore: 'kroger', location: OAK } }));
    await c.storePreferences();
    await c.setStore('kroger', 'k2');
    await c.setStore('heb');
    expect(calls.map((x) => x.body)).toEqual([{}, { store: 'kroger', locationId: 'k2' }, { store: 'heb' }]);
  });

  it('a cart with no store chosen fails with location_required', async () => {
    const { c } = client(() => ({ status: 409, json: { error: { code: 'location_required', message: 'Choose' } } }));
    await expect(c.prepareCart({ store: 'kroger', recipe: { id: 'r', ingredients: [{ name: 'garlic' }] } })).rejects.toMatchObject({ code: 'location_required' });
  });
});

describe('strings', () => {
  it('matches the shared table', () => { expect(DEFAULT_STRINGS).toEqual(sharedStrings); });
  it('fills placeholders and leaves unknown ones showing', () => {
    expect(fillText('Your {store} list', { store: 'H-E-B' })).toBe('Your H-E-B list');
    expect(fillText('Your {stroe} list', { store: 'H-E-B' })).toBe('Your {stroe} list');
  });
  it('picks singular or plural', () => {
    const { plural } = textTools();
    expect(plural('addItems', 1, { store: 'ALDI' })).toBe('Add 1 item to ALDI');
    expect(plural('addItems', 3, { store: 'ALDI' })).toBe('Add 3 items to ALDI');
  });
  it('a partner override wins, and the rest stay', () => {
    const { tr } = textTools({ done: 'Listo' });
    expect(tr('done')).toBe('Listo');
    expect(tr('total')).toBe('Total');
  });
  it('every plural has both forms', () => {
    for (const k of Object.keys(DEFAULT_STRINGS)) {
      if (k.endsWith('_one')) expect(DEFAULT_STRINGS).toHaveProperty(k.replace(/_one$/, '_other'));
    }
  });
});

describe('pantry and optional items', () => {
  const salt = { key: 'salt', ingredient: 'salt', quantity: 1, status: 'remembered', options: [{ id: '9', productId: '9', name: 'Salt', unitPrice: 1 }], selectedId: '9', remembered: { id: '9', productId: '9', name: 'Salt' }, startUnchecked: true };
  const onion = { ...salt, key: 'onion', ingredient: 'onion', startUnchecked: undefined };
  const session = () => new CartSession({} as MealioClient, { cartId: 'c', store: 'heb', items: [salt, onion], ready: [], needsChoice: [], unavailable: [] } as any);

  it('a remembered product stays unchecked until the user checks it', () => {
    const c = session();
    expect(c.isSelected('salt')).toBe(false);
    expect(c.isSelected('onion')).toBe(true);
    c.select('salt', '9');
    expect(c.isSelected('salt')).toBe(true);
  });

  it('is left out of the estimate until then', () => {
    expect(session().estimate().count).toBe(1);
  });
});

describe('events', () => {
  it('passes events on', () => {
    const got: string[] = [];
    safeListener((e) => got.push(e.type))({ type: 'sheet_opened', recipes: 1 });
    expect(got).toEqual(['sheet_opened']);
  });
  it('survives a listener that throws, or none at all', () => {
    expect(() => safeListener(() => { throw new Error('boom'); })({ type: 'sheet_opened', recipes: 1 })).not.toThrow();
    expect(() => safeListener()({ type: 'sheet_opened', recipes: 1 })).not.toThrow();
  });
});

describe('store limits', () => {
  it('asks for the stores this app offers', async () => {
    let headers: any = null;
    const fetchImpl = (async (_url: string, init: any) => { headers = init?.headers; return new Response(JSON.stringify({ stores: [] })); }) as unknown as typeof fetch;
    const c = new MealioClient({ publishableKey: 'pk_x', getSessionToken: async () => 't', platform: 'web-test', sdkVersion: '0', baseUrl: 'https://mealio.test', fetchImpl, keys: KEYS }, fakeHost());
    await c.stores();
    expect(headers['x-mealio-publishable-key']).toBe('pk_x');
  });
});
