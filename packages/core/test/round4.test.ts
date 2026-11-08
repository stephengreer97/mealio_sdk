// 0.6 round 4: restorePicks, the core version constant.
import { it, expect, describe, vi } from 'vitest';
import { CancelToken, EXCLUSIVE_CAP_MS, SDK_CORE_VERSION } from '../src';
import { createFakeMealio, type FakeItem } from '../src/testing';
import pkg from '../package.json';

const recipe = { id: 'r1', title: 'T', ingredients: [{ name: 'garlic' }, { name: 'milk' }] };
const tick = (ms = 5) => new Promise((r) => setTimeout(r, ms));
const garlic: FakeItem = { key: 'garlic', options: [{ id: 'g1', name: 'Garlic', unitPrice: 0.5 }], remembered: 'g1' };
const milk: FakeItem = { key: 'milk', options: [{ id: 'm1', name: 'Milk', unitPrice: 3 }], remembered: 'm1' };
const fail = (p: Promise<unknown>) => p.then(() => 'ok', (e) => e.code);
const codeOf = (p: Promise<unknown>) => p.then(() => 'ok', (e) => `${e.code}${e.reason ? `/${e.reason}` : ''}`);

describe('restorePicks', () => {
  it('re-runs the search that found the pick, not the item\'s last search', async () => {
    const fake = createFakeMealio({ items: [garlic, milk], search: { minced: [{ id: 'jar', name: 'Jar', unitPrice: 3 }], peeled: [{ id: 'pl', name: 'Peeled' }] }, add: { fail: 'store_unavailable' } });
    const c = fake.client();
    const a = await c.prepareCart({ recipe });
    await a.search('garlic', 'minced'); a.select('garlic', 'jar');
    await a.search('garlic', 'peeled'); // looked again, kept the jar
    expect(await fail(a.addToCart())).toBe('store_unavailable');
    delete fake.script.add;
    const b = await c.prepareCart({ recipe });
    await b.restorePicks(a);
    expect(b.selectedId('garlic')).toBe('jar');
    expect(fake.requests.filter((r) => r.kind === 'search').map((r) => r.body.query)).toEqual(['minced', 'peeled', 'minced']);
  });

  it('a pick from a later search is re-run with that later query', async () => {
    const fake = createFakeMealio({ items: [garlic], search: { minced: [{ id: 'jar', name: 'Jar' }], peeled: [{ id: 'pl', name: 'Peeled' }] } });
    const c = fake.client();
    const a = await c.prepareCart({ recipe });
    await a.search('garlic', 'minced'); await a.search('garlic', 'peeled'); a.select('garlic', 'pl');
    const b = await c.prepareCart({ recipe });
    await b.restorePicks(a);
    expect(b.selectedId('garlic')).toBe('pl');
    expect(fake.requests.filter((r) => r.kind === 'search').map((r) => r.body.query)).toEqual(['minced', 'peeled', 'peeled']);
  });

  it('an outside cancel mid-search: resolves, keeps what it had, and the caller\'s token says cancelled', async () => {
    const fake = createFakeMealio({ items: [garlic, milk], search: { minced: [{ id: 'jar', name: 'Jar' }] } });
    const c = fake.client();
    const a = await c.prepareCart({ recipe });
    await a.search('garlic', 'minced'); a.select('garlic', 'jar'); a.deselect('milk');
    const b = await c.prepareCart({ recipe });
    const release = fake.hold('search');
    const tok = new CancelToken();
    const r = b.restorePicks(a, { cancel: tok });
    await tick();
    c.cancelJobs();
    await expect(r).resolves.toBeUndefined();
    expect(tok.cancelled).toBe(true);
    expect(tok.reason).toBe('cancelled');
    expect(b.selectedId('garlic')).toBe('g1'); // the cart's own pick stays
    expect(b.isSelected('milk')).toBe(false); // what was done before the search stays done
    release();
  });

  it('never rejects: a failing search, another store, or an item the new cart lacks', async () => {
    const fake = createFakeMealio({ items: [garlic, milk], search: { minced: [{ id: 'jar', name: 'Jar' }] } });
    const c = fake.client();
    const a = await c.prepareCart({ recipe });
    await a.search('garlic', 'minced'); a.select('garlic', 'jar');
    fake.script.errors = { search: 'store_unavailable' };
    const b = await c.prepareCart({ recipe });
    await expect(b.restorePicks(a)).resolves.toBeUndefined();
    expect(b.selectedId('garlic')).toBe('g1');
    fake.script.items = [milk];
    const d = await c.prepareCart({ recipe });
    await expect(d.restorePicks(a)).resolves.toBeUndefined();
    const other = await c.prepareCart({ recipe, store: 'safeway' });
    await expect(other.restorePicks(a)).resolves.toBeUndefined();
  });
});

it('SDK_CORE_VERSION is the package version', () => {
  expect(SDK_CORE_VERSION).toBe(pkg.version);
});

// The audit's queue and cancel probes, kept as the reference the native
// ports' parity work (round 4 item 5) is checked against.
describe('queue and cancel reference', () => {
  it('a cancelled waiter frees its place; the others keep their order', async () => {
    const fake = createFakeMealio({ items: [garlic, milk] });
    const c = fake.client();
    const rel = fake.hold('prepare');
    const p1 = c.prepareCart({ recipe });
    const t2 = new CancelToken();
    const p2 = codeOf(c.prepareCart({ recipe }, { cancel: t2 }));
    const p3 = c.prepareCart({ recipe });
    await tick(); t2.cancel();
    expect(await p2).toBe('cancelled/cancelled');
    rel();
    await p1; await p3;
    expect(fake.requests.filter((r) => r.kind === 'prepare')).toHaveLength(2);
  });

  it('runExclusive: network at 30 s, the queue held to the cap, then one page reset whose failure is not the job\'s', async () => {
    vi.useFakeTimers();
    try {
      const fake = createFakeMealio({ items: [garlic] });
      let resets = 0;
      fake.host.resetPage = async () => { resets += 1; throw new Error('boom'); };
      const c = fake.client();
      const ex = codeOf(c.runExclusive(() => new Promise(() => {})));
      const t = new CancelToken();
      const waiting = codeOf(c.prepareCart({ recipe }, { cancel: t }));
      const later = c.prepareCart({ recipe });
      await vi.advanceTimersByTimeAsync(31_000);
      expect(await ex).toBe('network');
      t.cancel('closed');
      expect(await waiting).toBe('cancelled/closed');
      await vi.advanceTimersByTimeAsync(EXCLUSIVE_CAP_MS);
      expect(await later).toBeTruthy();
      expect(resets).toBe(1);
      await c.prepareCart({ recipe });
      expect(resets).toBe(1);
    } finally {
      vi.useRealTimers();
    }
  });

  it('cancelJobs during a token fetch that then fails: cancelled, with or without the caller\'s own token', async () => {
    const fake = createFakeMealio({ items: [garlic] });
    let failToken!: (e: unknown) => void;
    const c = fake.client({ getSessionToken: () => new Promise((_, rj) => { failToken = rj; }) });
    const p = codeOf(c.prepareCart({ recipe }, { cancel: new CancelToken() }));
    await tick();
    c.cancelJobs(); failToken(new Error('x'));
    expect(await p).toBe('cancelled/cancelled');
    const q = codeOf(c.prepareCart({ recipe }));
    await tick();
    c.cancelJobs(); failToken(new Error('x'));
    expect(await q).toBe('cancelled/cancelled');
  });

  it('setUser while one runs and one waits: both end user_changed, a later close does not change that', async () => {
    const fake = createFakeMealio({ items: [garlic] });
    const c = fake.client({ userId: 'u1' });
    const rel = fake.hold('prepare');
    const p1 = codeOf(c.prepareCart({ recipe }));
    const t = new CancelToken();
    const p2 = codeOf(c.prepareCart({ recipe }, { cancel: t }));
    await tick();
    c.setUser('u2'); t.cancel('closed');
    rel();
    expect([await p1, await p2]).toEqual(['cancelled/user_changed', 'cancelled/user_changed']);
  });
});
