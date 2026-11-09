// The drop-in against stub React Native: a fake Mealio server, a hidden page the
// test drives by hand, and the sheet as the user sees it.
import React, { useState } from 'react';
import { describe, it, expect, beforeEach } from 'vitest';
import TR, { act } from 'react-test-renderer';
import crypto from 'node:crypto';
import { KEYS } from '@mealio/sdk-core';
import { MealioProvider, useMealio } from '../src/MealioProvider';
import { MealioCartFlow } from '../src/MealioCartFlow';
import { MealioCartButton } from '../src/MealioCartButton';
import { MealioStoreSettings } from '../src/MealioStoreSettings';
import { views } from './stubs/webview';

(globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;

// Envelopes signed with a test key the core is told to trust.
const priv = crypto.generateKeyPairSync('ed25519').privateKey;
(KEYS as any).ktest_rn = crypto.createPublicKey(priv).export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64');
function env(job: string, seq: number, instructions: any[], store = 'heb') {
  const payload = JSON.stringify({ v: 1, kind: 'instructions', job, seq, exp: Math.floor(Date.now() / 1000) + 600, store, instructions });
  return { payload, sig: crypto.sign(null, Buffer.from(payload), priv).toString('base64'), kid: 'ktest_rn' };
}

const json = (o: any, status = 200) => new Response(JSON.stringify(o), { status });
const open = (id: string, ms = 300) => ({ op: 'page_open', id, url: 'https://www.heb.com/robots.txt', timeoutMs: ms });
const script = (id: string, type: string, ms = 150) => ({ op: 'page_script', id, script: `/*${id}*/`, until: [{ type }], timeoutMs: ms });
const login = { op: 'show_login', id: 'l1', url: 'https://www.heb.com/login', title: 'Sign in', doneWhen: [{ type: 'IN' }], timeoutMs: 5000 };
const done = (result: any) => ({ op: 'done', id: 'd', result });
const CART = (id = 'c1') => ({ cartId: id, store: 'heb', storeName: 'H-E-B', ready: [], needsChoice: [], unavailable: [], items: [
  { key: 'a', ingredient: 'onion', quantity: 1, status: 'remembered', selectedId: 'p1', remembered: { id: 'p1', name: 'Onion' }, options: [{ id: 'p1', name: 'Onion', unitPrice: 1 }] },
  { key: 'b', ingredient: 'garlic', quantity: 1, status: 'choose', selectedId: null, remembered: null, options: [{ id: 'p2', name: 'Garlic', unitPrice: 2 }] },
] });
const ADDED = { cartId: 'c1', store: 'heb', added: [{ key: 'a', productId: 'p1', name: 'Onion', quantity: 1 }], skipped: [], failed: [], storeCartUrl: null };
const RECIPE = { id: 'r', title: 'Tacos', ingredients: [{ name: 'onion' }] };

type On = (path: string, body: any) => any;
let srv: { posts: Array<{ path: string; body: any; auth?: string }>; on: On; warms: number };
let jobN = 0;
beforeEach(() => {
  views.hidden = null; views.login = null; views.injected.length = 0; jobN = 0;
  srv = { posts: [], on: () => json({}), warms: 0 };
  (globalThis as any).fetch = async (u: string, o: any) => {
    const path = u.replace('https://mealio.co', '');
    const body = o?.body ? JSON.parse(o.body) : null;
    if (path.endsWith('/warm')) { srv.warms += 1; return json({ warm: null }); }
    srv.posts.push({ path, body, auth: o?.headers?.authorization });
    return srv.on(path, body);
  };
});
const startJob = (ins: any[]) => { const job = `job${++jobN}`; return json({ job, envelope: env(job, 1, ins) }); };
const jobOf = (p: string) => /jobs\/([^/]+)\/step/.exec(p)?.[1];
const nextEnv = (job: string, ins: any[]) => json({ envelope: env(job, 2, ins) });
const steps = () => srv.posts.filter((x) => jobOf(x.path));
const posts = (end: string) => srv.posts.filter((x) => x.path.endsWith(end));
const wait = (ms = 10) => act(async () => { await new Promise((r) => setTimeout(r, ms)); });
const loaded = () => act(async () => { views.hidden.onLoadEnd({ nativeEvent: { url: 'https://www.heb.com/robots.txt' } }); await new Promise((r) => setTimeout(r, 5)); });
const page = (m: any) => act(async () => { views.hidden.onMessage({ nativeEvent: { data: JSON.stringify(m) } }); await new Promise((r) => setTimeout(r, 5)); });

let set: (f: (x: any) => any) => void;
const events: any[] = []; const closes: any[] = []; const addeds: any[] = []; const errors: any[] = [];
const TOKEN = async () => 'tok';
function App(init: any) {
  const [st, s] = useState<any>({ visible: true, show: true, ...init }); set = s;
  return (
    <MealioProvider publishableKey="pk" getSessionToken={TOKEN} onEvent={(e) => events.push(e)}>
      {st.show ? <MealioCartFlow visible={st.visible} recipe={RECIPE} store={st.store}
        onClose={(r) => { closes.push(r); s((x: any) => ({ ...x, visible: false })); }}
        onAdded={st.onAdded ?? ((r) => addeds.push(r))} onError={(e) => errors.push((e as any)?.code)} /> : null}
    </MealioProvider>
  );
}
async function mount(el: React.ReactElement) {
  events.length = 0; closes.length = 0; addeds.length = 0; errors.length = 0;
  let r!: TR.ReactTestRenderer;
  await act(async () => { r = TR.create(el); await new Promise((x) => setTimeout(x, 5)); });
  return r;
}
const texts = (r: TR.ReactTestRenderer) => r.root.findAll((n: any) => n.type === 'Text').flatMap((n: any) => n.children).filter((c: any) => typeof c === 'string') as string[];
const hasText = (t: string) => (n: any) => n.findAll((c: any) => c.type === 'Text').some((c: any) => c.children.some((x: any) => typeof x === 'string' && x.includes(t)));
const pressables = (r: TR.ReactTestRenderer, pred: (n: any) => boolean) => r.root.findAll((n: any) => n.type === 'Pressable' && pred(n));
const press = (r: TR.ReactTestRenderer, pred: (n: any) => boolean) => act(async () => { pressables(r, pred)[0].props.onPress(); await new Promise((x) => setTimeout(x, 5)); });
const closeBtn = (n: any) => n.props.accessibilityLabel === 'Close';
const addBtn = (r: TR.ReactTestRenderer) => pressables(r, hasText('Add ')).slice(-1)[0];
const pickGarlic = (r: TR.ReactTestRenderer) => act(async () => { const c = pressables(r, (n) => n.props.accessibilityRole === 'radio'); c[c.length - 1].props.onPress(); await new Promise((x) => setTimeout(x, 5)); });
async function toList(init: any = {}, on?: On) {
  srv.on = on ?? ((p) => (p.endsWith('/carts') ? startJob([done(CART())]) : json({})));
  const r = await mount(<App {...init} />); await wait(); return r;
}

describe('closing while a cart loads', () => {
  it('stops the job: nothing more is sent and sign-in never shows', async () => {
    srv.on = (p) => p.endsWith('/carts') ? startJob([open('o', 2000), script('session', 'S', 2000)]) : jobOf(p) ? nextEnv(jobOf(p)!, [login]) : json({});
    const r = await mount(<App />); await wait(); await loaded();
    await press(r, closeBtn);
    await page({ type: 'S' }); await wait();
    expect(steps()).toEqual([]);
    expect(views.login).toBeNull();
    expect(r.root.findAll((n: any) => n.type === 'Modal')).toHaveLength(0);
  });

  it('a reopened sheet waits for the old job, then runs its own', async () => {
    srv.on = (p) => p.endsWith('/carts') ? startJob([open('o' + (jobN + 1), 150), script('s' + (jobN + 1), 'S', 100)]) : jobOf(p) ? nextEnv(jobOf(p)!, [done(CART())]) : json({});
    const r = await mount(<App />); await wait(40);
    await press(r, closeBtn);
    await act(async () => { set((x) => ({ ...x, visible: true })); await new Promise((x) => setTimeout(x, 40)); });
    await wait(600);
    expect(steps().map((s) => jobOf(s.path))).toEqual(['job2']);
    expect(texts(r)).toContain('Your H-E-B list');
  });

  it("an old job's late page load never runs its script over the new job's", async () => {
    srv.on = (p) => p.endsWith('/carts') ? startJob(jobN === 0 ? [open('oA', 2000), script('sA', 'S', 2000)] : [script('sB', 'B', 100)]) : jobOf(p) ? nextEnv(jobOf(p)!, [done(CART())]) : json({});
    const r = await mount(<App />); await wait();
    await press(r, closeBtn);
    await act(async () => { set((x) => ({ ...x, visible: true })); await new Promise((x) => setTimeout(x, 10)); });
    await loaded();
    await wait(400);
    expect(views.injected.filter((s: string) => s.startsWith('/*'))).toEqual(['/*sB*/']);
    expect(steps().map((s) => jobOf(s.path))).toEqual(['job2']);
  });

  it('unmounting mid-load reports nothing', async () => {
    srv.on = (p) => p.endsWith('/carts') ? startJob([open('o', 2000), script('s', 'S', 2000)]) : jobOf(p) ? nextEnv(jobOf(p)!, [{ op: 'fail', id: 'f', code: 'store_unavailable', message: 'x' }]) : json({});
    await mount(<App />); await wait(); await loaded();
    await act(async () => { set((x) => ({ ...x, show: false })); });
    await page({ type: 'S' }); await wait();
    expect(events.filter((e) => e.type === 'error')).toEqual([]);
    expect(errors).toEqual([]);
  });
});

describe('adding', () => {
  const adding: On = (p) => p.endsWith('/carts') ? startJob([done(CART())]) : p.endsWith('/add') ? startJob([script('add', 'NET_ADD_DONE', 2000)])
    : jobOf(p) ? nextEnv(jobOf(p)!, [done(ADDED)]) : json({});

  it('cannot be closed once tapped, and reports the add when it ends', async () => {
    const r = await toList({}, adding);
    await press(r, hasText('Add 1')); await wait();
    expect(pressables(r, closeBtn)[0].props.disabled).toBe(true);
    await press(r, closeBtn);
    await act(async () => { r.root.findByType('Modal' as any).props.onRequestClose(); });
    expect(closes).toEqual([]);
    await page({ type: 'NET_ADD_DONE' }); await wait();
    expect(addeds).toHaveLength(1);
    expect(events.some((e) => e.type === 'cart_added')).toBe(true);
    expect(texts(r)).toContain('1 item added');
  });

  it('two taps before a render add once', async () => {
    const r = await toList({}, adding);
    const b = addBtn(r);
    await act(async () => { b.props.onPress(); b.props.onPress(); await new Promise((x) => setTimeout(x, 10)); });
    expect(posts('/add')).toHaveLength(1);
    expect(events.filter((e) => e.type === 'add_started')).toHaveLength(1);
  });

  it('calls the latest onAdded', async () => {
    const seen: string[] = [];
    const r = await toList({ onAdded: () => seen.push('v1') }, (p) => p.endsWith('/carts') ? startJob([done(CART())]) : p.endsWith('/add') ? startJob([done(ADDED)]) : json({}));
    await act(async () => { set((x) => ({ ...x, onAdded: () => seen.push('v2') })); });
    await press(r, hasText('Add 1')); await wait();
    expect(seen).toEqual(['v2']);
  });

  it('a failed add says to check the cart, and Try again keeps the picks', async () => {
    let carts = 0;
    const r = await toList({}, (p) => {
      if (p.endsWith('/carts')) return startJob([done(CART('c' + ++carts))]);
      if (p.endsWith('/add')) return startJob([script('add', 'NET_ADD_DONE', 100)]);
      if (jobOf(p)) throw new Error('offline');
      return json({});
    });
    await pickGarlic(r);
    expect(texts(r)).toContain('2 of 2 selected');
    await press(r, hasText('Add 2')); await wait();
    await page({ type: 'NET_ADD_DONE' }); await wait();
    expect(texts(r)).toContain('Some items may already be in your cart. Check it before adding again.');
    await press(r, hasText('Try again')); await wait();
    expect(posts('/carts')).toHaveLength(2);
    expect(texts(r)).toContain('2 of 2 selected');
  });
});

describe('the list', () => {
  it('Add is off while a search runs', async () => {
    const r = await toList({}, (p) => p.endsWith('/carts') ? startJob([done(CART())]) : p.endsWith('/search') ? startJob([script('search', 'SEARCH_DONE', 2000)])
      : jobOf(p) ? nextEnv(jobOf(p)!, [done({ key: 'a', query: 'red onion', options: [] })]) : json({}));
    await act(async () => { r.root.findAll((n: any) => n.type === 'TextInput' && n.props.onSubmitEditing)[0].props.onChangeText('red onion'); });
    await press(r, (n) => hasText('Search')(n) && n.props.style !== undefined && !n.props.accessibilityLabel);
    expect(addBtn(r).props.disabled).toBe(true);
    await page({ type: 'SEARCH_DONE' }); await wait();
    expect(addBtn(r).props.disabled).toBe(false);
  });

  it('ticking an item by tapping an option sends item_checked', async () => {
    const r = await toList();
    await pickGarlic(r);
    expect(events.filter((e) => e.type === 'item_checked')).toEqual([{ type: 'item_checked', key: 'b' }]);
  });

  it('a store list that failed to load is asked for again', async () => {
    let calls = 0, up = false;
    const r = await toList({}, (p) => {
      if (p.endsWith('/stores')) { calls += 1; return up ? json({ stores: [{ id: 'heb', name: 'H-E-B', via: 'device' }] }) : json({}, 503); }
      return p.endsWith('/carts') ? startJob([done(CART())]) : json({});
    });
    const chip = (n: any) => (n.props.accessibilityLabel || '').startsWith('Store:');
    await press(r, chip); await wait();
    expect(texts(r)).toContain('Could not load stores. Close and try again.');
    up = true;
    await act(async () => { set((x) => ({ ...x, visible: false })); });
    await act(async () => { set((x) => ({ ...x, visible: true })); }); await wait();
    await press(r, chip); await wait();
    expect(calls).toBe(2);
    expect(texts(r)).toContain('H-E-B');
  });
});

describe('the store prop', () => {
  it('Try again uses the store the partner passes now', async () => {
    let fail = false;
    const r = await toList({ store: 'heb' }, (p, b) => !p.endsWith('/carts') ? json({})
      : fail && b.store === 'aldi' ? json({ error: { code: 'store_unavailable', message: 'ALDI is down' } }, 503) : startJob([done(CART())]));
    await press(r, closeBtn);
    fail = true;
    await act(async () => { set((x) => ({ ...x, store: 'aldi', visible: true })); }); await wait();
    expect(texts(r)).toContain('ALDI is down');
    await press(r, hasText('Try again')); await wait();
    expect(posts('/carts').map((x) => x.body.store)).toEqual(['heb', 'aldi', 'aldi']);
  });
});

describe('store settings', () => {
  it('an inline theme on the provider keeps the zip step', async () => {
    let bump!: (f: (n: number) => number) => void;
    function Host() {
      const [, b] = useState(0); bump = b;
      return <MealioProvider publishableKey="pk" getSessionToken={TOKEN} theme={{ accent: '#f00' }}><MealioStoreSettings visible onClose={() => {}} /></MealioProvider>;
    }
    srv.on = (p) => p.endsWith('/stores') ? json({ stores: [{ id: 'kroger', name: 'Kroger', via: 'kroger_api' }] }) : p.endsWith('/preferences') ? json({ defaultStore: null, location: null }) : json({});
    const r = await mount(<Host />); await wait();
    await press(r, hasText('Kroger'));
    const zip = () => r.root.findAll((n: any) => n.props.testID === 'mealio-zip' && n.type === 'TextInput').length;
    expect(zip()).toBe(1);
    await act(async () => { bump((n) => n + 1); await new Promise((x) => setTimeout(x, 10)); });
    expect(zip()).toBe(1);
  });
});

describe('users', () => {
  function Users(props: { userId?: string | null; onSignInRequired?: () => void; disabled?: boolean; token?: () => Promise<string>; grab?: (api: any) => void }) {
    const Grab = () => { props.grab?.(useMealio()); return null; };
    return (
      <MealioProvider publishableKey="pk" getSessionToken={props.token ?? (async () => 'tok')} userId={props.userId}>
        <Grab />
        <MealioCartButton recipe={RECIPE} store="heb" disabled={props.disabled} onSignInRequired={props.onSignInRequired} />
      </MealioProvider>
    );
  }
  const button = (r: TR.ReactTestRenderer) => pressables(r, (n) => n.props.accessibilityLabel === 'Add to my grocery cart')[0];

  it('with nobody signed in, the button asks for sign-in, or is off without a callback', async () => {
    const asked: number[] = [];
    const r = await mount(<Users userId={null} onSignInRequired={() => asked.push(1)} />); await wait();
    await act(async () => { button(r).props.onPress(); });
    expect(asked).toEqual([1]);
    expect(r.root.findAll((n: any) => n.type === 'Modal')).toHaveLength(0);
    const r2 = await mount(<Users userId={null} />); await wait();
    expect(button(r2).props.disabled).toBe(true);
    expect(srv.warms).toBe(0);
    expect(srv.posts).toEqual([]);
  });

  it('keeps one client for an inline getSessionToken once userId is passed', async () => {
    const apis: any[] = [];
    let rerender!: (u: any) => void;
    function Outer() { const [n, s] = useState(0); rerender = s; return <Users userId="a" token={async () => `t${n}`} grab={(a) => apis.push(a)} />; }
    await mount(<Outer />); await wait();
    await act(async () => { rerender(1); });
    expect(apis.length).toBeGreaterThan(1);
    expect(apis[apis.length - 1].prepareCart).toBe(apis[0].prepareCart);
  });

  it('a new user stops the open cart and gets a new session', async () => {
    let api: any;
    let user!: (u: string | null) => void;
    const tokens = ['alice', 'bob'];
    srv.on = (p) => p.endsWith('/carts') ? startJob([open('o', 2000), script('s', 'S', 2000)]) : jobOf(p) ? nextEnv(jobOf(p)!, [login]) : json({});
    function Outer() {
      const [u, s] = useState<string | null>('a'); user = s;
      const Grab = () => { api = useMealio(); return null; };
      return (
        <MealioProvider publishableKey="pk" getSessionToken={async () => tokens.shift()!} userId={u}>
          <Grab />
          <MealioCartFlow visible recipe={RECIPE} onClose={(x) => closes.push(x)} />
        </MealioProvider>
      );
    }
    await mount(<Outer />); await wait(); await loaded();
    await act(async () => { user('b'); await new Promise((x) => setTimeout(x, 5)); });
    expect(closes).toEqual([null]);
    await page({ type: 'S' }); await wait();
    expect(steps()).toEqual([]);
    expect(views.login).toBeNull();
    await act(async () => { await api.storePreferences(); });
    expect(srv.posts.map((x) => x.auth)).toEqual(['Bearer alice', 'Bearer bob']);
  });

  it('warms when the button becomes enabled', async () => {
    let enable!: () => void;
    function Outer() { const [d, s] = useState(true); enable = () => s(false); return <Users userId="a" disabled={d} />; }
    await mount(<Outer />); await wait();
    expect(srv.warms).toBe(0);
    await act(async () => { enable(); await new Promise((x) => setTimeout(x, 10)); });
    expect(srv.warms).toBe(1);
  });
});

describe('a hung job', () => {
  it('does not lock out the warm-up once it ends', async () => {
    let api: any;
    srv.on = (p) => p.endsWith('/carts') ? startJob(jobN === 0 ? [open('oA', 2000), script('sA', 'S', 2000)] : [script('sB', 'B', 100)]) : json({});
    function H() {
      const [st, s] = useState(true); set = s as any;
      const Grab = () => { api = useMealio(); return null; };
      return <MealioProvider publishableKey="pk" getSessionToken={TOKEN}><Grab /><MealioCartFlow visible={st} recipe={RECIPE} onClose={() => s(false)} /></MealioProvider>;
    }
    const r = await mount(<H />); await wait();
    await press(r, closeBtn);
    await act(async () => { (set as any)(true); await new Promise((x) => setTimeout(x, 10)); });
    await loaded(); await wait(400);
    await press(r, closeBtn);
    await act(async () => { await api.warm({ store: 'heb' }); });
    expect(srv.warms).toBe(1);
  });
});

describe('the Jest kit', () => {
  it('stands in for the package', async () => {
    const kit = require('../jest.js');
    expect(Object.keys(kit)).toEqual(expect.arrayContaining(['MealioProvider', 'useMealio', 'MealioCartButton', 'MealioCartFlow', 'MealioStoreSettings', 'CancelToken', 'MealioError', 'mockCart']));
    const cart = await kit.useMealio().prepareCart({ recipe: RECIPE });
    expect(cart.warnings).toEqual([]);
    const got: any[] = [];
    const el = kit.MealioCartButton({ recipe: RECIPE, onAdded: (x: any) => got.push(x), renderButton: (b: any) => b });
    el.onPress();
    expect(got[0]).toMatchObject({ added: [] });
    expect(kit.useMealio().ui.tr('addFailedNote')).toBe('Some items may already be in your cart. Check it before adding again.');
  });
});
