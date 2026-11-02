import { describe, it, expect } from 'vitest';
import vm from 'node:vm';
import vectors from '../../../protocol/test-vectors.json';
import {
  Allowlist, GUARD_SCRIPT, Runner, matches, openEnvelope, checkInstructions, EnvelopeError, MealioClient, CartSession,
  type Host, type Envelope, type Matcher,
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
