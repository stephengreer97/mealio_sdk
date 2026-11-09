// 0.6 round 3: capped restarts, bounded store sign-out, cancel reasons, and
// custom screens on the testing kit (<MealioProvider testing={fake}>).
import React, { useEffect, useState } from 'react';
import { describe, it, expect, vi, afterEach } from 'vitest';
import TR, { act } from 'react-test-renderer';
import { CancelToken, type CartSession } from '@mealio/sdk-core';
import { createFakeMealio, type FakeItem } from '@mealio/sdk-core/testing';
import { MealioProvider, boundedStep, useMealio, type MealioApi } from '../src/MealioProvider';
import { MealioCartFlow, MAX_RESTARTS } from '../src/MealioCartFlow';
import { Text } from 'react-native';

(globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;

const RECIPE = { id: 'r', title: 'Tacos', ingredients: [{ name: 'onion' }] };
const ONION: FakeItem = { key: 'onion', options: [{ id: 'p1', name: 'Onion', unitPrice: 1 }], remembered: 'p1' };
const wait = (ms = 10) => act(async () => { await new Promise((r) => setTimeout(r, ms)); });
const texts = (r: TR.ReactTestRenderer) => r.root.findAll((n: any) => n.type === 'Text').flatMap((n: any) => n.children).filter((c: any) => typeof c === 'string') as string[];
const press = (r: TR.ReactTestRenderer, label: string) => act(async () => {
  const t = r.root.findAll((n: any) => n.type === 'Text' && n.children.includes(label))[0];
  let n: any = t;
  while (n && !n.props.onPress) n = n.parent;
  n.props.onPress();
  await new Promise((x) => setTimeout(x, 5));
});

afterEach(() => { vi.useRealTimers(); });

describe('restarts after an outside cancel are capped (item 3)', () => {
  it('resetSession in every token fetch: 3 restarts, then the error screen with Try again, which starts the count over', async () => {
    const fake = createFakeMealio({ items: [ONION] });
    let calls = 0; let api!: MealioApi; const closes: unknown[] = []; const errors: string[] = [];
    let resets = Infinity;
    const Grab = () => { api = useMealio(); return null; };
    let r!: TR.ReactTestRenderer;
    await act(async () => {
      r = TR.create(
        <MealioProvider publishableKey="pk" testing={fake} getSessionToken={async () => { calls += 1; if (resets > 0) { resets -= 1; api.resetSession(); } return 'tok'; }}>
          <Grab />
          <MealioCartFlow visible recipe={RECIPE} onClose={(x) => closes.push(x)} onError={(e: any) => errors.push(`${e.code}/${e.reason}`)} />
        </MealioProvider>);
      await new Promise((x) => setTimeout(x, 5));
    });
    await wait(100);
    expect(calls).toBe(MAX_RESTARTS + 1);
    expect(errors).toEqual(['cancelled/user_changed']);
    expect(closes).toEqual([]);
    expect(texts(r)).toContain('Try again');
    // Try again starts the count over: one more outside cancel restarts, not an error.
    resets = 1;
    await press(r, 'Try again');
    await wait(50);
    expect(texts(r).some((t) => /Onion/.test(t))).toBe(true);
    expect(errors).toHaveLength(1);
    await act(async () => { r.unmount(); });
  });
});

describe('store sign-out is bounded (item 2)', () => {
  it('an epoch storage that never answers cannot hold sign-out, or the queue, past 10 s a step', async () => {
    const fake = createFakeMealio({ items: [ONION] });
    let api!: MealioApi;
    const Grab = () => { api = useMealio(); return null; };
    const never = { get: () => new Promise<number>(() => {}), set: () => new Promise<void>(() => {}) };
    let r!: TR.ReactTestRenderer;
    await act(async () => {
      r = TR.create(<MealioProvider publishableKey="pk" testing={fake} epochStorage={{ get: async () => 0, set: never.set }} getSessionToken={async () => 'tok'}><Grab /></MealioProvider>);
    });
    vi.useFakeTimers();
    let out = 'pending';
    api.signOutOfAllStores().then(() => { out = 'done'; }, (e) => { out = e.code; });
    await act(async () => { await vi.advanceTimersByTimeAsync(9_000); });
    expect(out).toBe('pending');
    await act(async () => { await vi.advanceTimersByTimeAsync(2_000); });
    expect(out).toBe('network');
    vi.useRealTimers();
    // The queue moved on: a cart runs.
    const cart = await act(async () => api.prepareCart({ recipe: RECIPE }));
    expect((cart as unknown as CartSession).items.map((i) => i.key)).toEqual(['onion']);
    await act(async () => { r.unmount(); });
    void never;
  });

  it('each step stops at once on the cancel token', async () => {
    const cancel = new CancelToken();
    const p = boundedStep(() => new Promise(() => {}), cancel).catch((e) => `${e.code}/${e.reason}`);
    cancel.cancel('user_changed');
    expect(await p).toBe('cancelled/user_changed');
  });
});

/** A custom screen on useMealio(), the way a partner writes one. */
function MyScreen({ onCart, onError }: { onCart: (c: CartSession) => void; onError: (e: any) => void }) {
  const mealio = useMealio();
  const [cart, setCart] = useState<CartSession | null>(null);
  useEffect(() => {
    const cancel = new CancelToken();
    mealio.prepareCart({ recipe: RECIPE }, { cancel }).then((c) => { setCart(c); onCart(c); }, onError);
    return () => cancel.cancel('closed');
  }, [mealio.userId]); // eslint-disable-line react-hooks/exhaustive-deps
  return <Text>{cart ? cart.items.map((i) => i.ingredient).join(',') : 'loading'}</Text>;
}

describe('custom screens on the testing kit (items 9 and 10)', () => {
  it('runs the real client on the fake: remembered pick, cancel on unmount reports closed', async () => {
    const fake = createFakeMealio({ items: [ONION, { key: 'salt', options: [{ id: 's1', name: 'Salt' }], startUnchecked: true }] });
    const carts: CartSession[] = []; const errors: string[] = [];
    let r!: TR.ReactTestRenderer;
    await act(async () => {
      r = TR.create(<MealioProvider publishableKey="pk" testing={fake} getSessionToken={async () => 'tok'}>
        <MyScreen onCart={(c) => carts.push(c)} onError={(e) => errors.push(`${e.code}/${e.reason}`)} />
      </MealioProvider>);
    });
    await wait(20);
    expect(texts(r)).toEqual(['onion,salt']);
    expect(carts[0].selectedId('onion')).toBe('p1');
    expect(carts[0].selectedId('salt')).toBeNull();
    expect(carts[0].items[1].selectedId).toBeNull();

    const release = fake.hold('prepare');
    await act(async () => {
      r.update(<MealioProvider publishableKey="pk" testing={fake} getSessionToken={async () => 'tok'}>
        <MyScreen key="again" onCart={(c) => carts.push(c)} onError={(e) => errors.push(`${e.code}/${e.reason}`)} />
      </MealioProvider>);
    });
    await act(async () => { r.unmount(); });
    release();
    await wait(10);
    expect(errors).toEqual(['cancelled/closed']);
  });

  it('a user change ends the old prepare as user_changed, and the screen prepares again for the new user', async () => {
    const fake = createFakeMealio({ items: [ONION] });
    const errors: string[] = []; const carts: CartSession[] = [];
    let user = 'u1';
    const tree = (id: string) => (
      <MealioProvider publishableKey="pk" testing={fake} userId={id} getSessionToken={async () => `tok_${user}`}>
        <MyScreen onCart={(c) => carts.push(c)} onError={(e) => errors.push(`${e.code}/${e.reason}`)} />
      </MealioProvider>);
    const release = fake.hold('prepare');
    let r!: TR.ReactTestRenderer;
    await act(async () => { r = TR.create(tree('u1')); });
    await wait(10);
    user = 'u2';
    await act(async () => { r.update(tree('u2')); });
    release();
    await wait(30);
    expect(errors).toContain('cancelled/user_changed');
    expect(carts).toHaveLength(1);
    expect(fake.requests.filter((q) => q.kind === 'prepare').map((q) => q.token)).toEqual(['tok_u1', 'tok_u2']);
    await act(async () => { r.unmount(); });
  });
});
