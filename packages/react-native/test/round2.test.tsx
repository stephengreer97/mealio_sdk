// 0.6 round 2: a prepare cancelled from outside the sheet, an add the partner
// hid, and the Jest kit kept in step with the real package.
import React, { useState } from 'react';
import { describe, it, expect, beforeEach } from 'vitest';
import TR, { act } from 'react-test-renderer';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import ts from 'typescript';
import { KEYS } from '@mealio/sdk-core';
import { MealioProvider, useMealio } from '../src/MealioProvider';
import { MealioCartFlow } from '../src/MealioCartFlow';
import * as real from '../src/index';
import { views } from './stubs/webview';

(globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;

const priv = crypto.generateKeyPairSync('ed25519').privateKey;
(KEYS as any).ktest_r2 = crypto.createPublicKey(priv).export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64');
function env(job: string, seq: number, instructions: any[]) {
  const payload = JSON.stringify({ v: 1, kind: 'instructions', job, seq, exp: Math.floor(Date.now() / 1000) + 600, store: 'heb', instructions });
  return { payload, sig: crypto.sign(null, Buffer.from(payload), priv).toString('base64'), kid: 'ktest_r2' };
}
const json = (o: any, status = 200) => new Response(JSON.stringify(o), { status });
const open = (id: string, ms = 300) => ({ op: 'page_open', id, url: 'https://www.heb.com/robots.txt', timeoutMs: ms });
const script = (id: string, type: string, ms = 150) => ({ op: 'page_script', id, script: `/*${id}*/`, until: [{ type }], timeoutMs: ms });
const login = { op: 'show_login', id: 'l1', url: 'https://www.heb.com/login', title: 'Sign in', doneWhen: [{ type: 'IN' }], timeoutMs: 5000 };
const done = (result: any) => ({ op: 'done', id: 'd', result });
const CART = { cartId: 'c1', store: 'heb', storeName: 'H-E-B', ready: [], needsChoice: [], unavailable: [], items: [
  { key: 'a', ingredient: 'onion', quantity: 1, status: 'remembered', selectedId: 'p1', remembered: { id: 'p1', name: 'Onion' }, options: [{ id: 'p1', name: 'Onion', unitPrice: 1 }] }] };
const ADDED = { cartId: 'c1', store: 'heb', added: [{ key: 'a', productId: 'p1', name: 'Onion', quantity: 1 }], skipped: [], failed: [], storeCartUrl: null };
const RECIPE = { id: 'r', title: 'Tacos', ingredients: [{ name: 'onion' }] };

let posts: string[] = [];
let on: (p: string) => any = () => json({});
let jobN = 0;
beforeEach(() => {
  views.hidden = null; views.login = null; views.injected.length = 0; jobN = 0; posts = [];
  (globalThis as any).fetch = async (u: string) => {
    const p = u.replace('https://mealio.co', '');
    if (p.endsWith('/warm')) return json({ warm: null });
    posts.push(p);
    return on(p);
  };
});
const startJob = (ins: any[]) => { const job = `job${++jobN}`; return json({ job, envelope: env(job, 1, ins) }); };
const jobOf = (p: string) => /jobs\/([^/]+)\/step/.exec(p)?.[1];
const wait = (ms = 10) => act(async () => { await new Promise((r) => setTimeout(r, ms)); });
const page = (m: any) => act(async () => { views.hidden.onMessage({ nativeEvent: { data: JSON.stringify(m) } }); await new Promise((r) => setTimeout(r, 5)); });
const texts = (r: TR.ReactTestRenderer) => r.root.findAll((n: any) => n.type === 'Text').flatMap((n: any) => n.children).filter((c: any) => typeof c === 'string') as string[];

let api: any;
let set: (f: (x: any) => any) => void;
const closes: any[] = []; const addeds: any[] = []; const errors: any[] = []; const events: any[] = [];
function App() {
  const [st, s] = useState({ visible: true }); set = s;
  const Grab = () => { api = useMealio(); return null; };
  return (
    <MealioProvider publishableKey="pk" getSessionToken={async () => 'tok'} onEvent={(e) => events.push(e)}>
      <Grab />
      <MealioCartFlow visible={st.visible} recipe={RECIPE}
        onClose={(r) => { closes.push(r); s({ visible: false }); }}
        onAdded={(r) => addeds.push(r)} onError={(e) => errors.push((e as any)?.code)} />
    </MealioProvider>
  );
}
async function mount() {
  closes.length = 0; addeds.length = 0; errors.length = 0; events.length = 0;
  let r!: TR.ReactTestRenderer;
  await act(async () => { r = TR.create(<App />); await new Promise((x) => setTimeout(x, 5)); });
  return r;
}

describe('a prepare cancelled from outside the sheet', () => {
  it('loads again while the sheet is open, and reports no error', async () => {
    on = (p) => p.endsWith('/carts') ? startJob(jobN === 0 ? [open('o', 300), script('s', 'S', 2000)] : [done(CART)]) : json({});
    const r = await mount(); await wait();
    // Signing out of the stores cancels every prepare. With no cookie manager installed it then fails, which is its own business.
    await act(async () => { await api.signOutOfAllStores().catch(() => {}); });
    await wait(400);
    expect(posts.filter((p) => p.endsWith('/carts'))).toHaveLength(2);
    expect(errors).toEqual([]);
    expect(events.filter((e) => e.type === 'error')).toEqual([]);
    expect(texts(r)).toContain('Your H-E-B list');
  });
});

describe('an add the partner hid', () => {
  it('runs on and reports through onAdded and onClose', async () => {
    on = (p) => p.endsWith('/carts') ? startJob([done(CART)]) : p.endsWith('/add') ? startJob([script('add', 'ADD_DONE', 2000)])
      : jobOf(p) ? json({ envelope: env(jobOf(p)!, 2, [done(ADDED)]) }) : json({});
    const r = await mount(); await wait();
    const add = r.root.findAll((n: any) => n.type === 'Pressable' && n.findAll((c: any) => c.type === 'Text').some((c: any) => String(c.children).includes('Add 1')));
    await act(async () => { add[add.length - 1].props.onPress(); await new Promise((x) => setTimeout(x, 5)); });
    await act(async () => { set(() => ({ visible: false })); });
    expect(r.root.findAll((n: any) => n.type === 'Modal')).toHaveLength(1);
    await page({ type: 'ADD_DONE' }); await wait();
    expect(addeds).toHaveLength(1);
    expect(closes).toEqual([expect.objectContaining({ cartId: 'c1' })]);
    expect(r.root.findAll((n: any) => n.type === 'Modal')).toHaveLength(0);
  });

  it("shows the add's sign-in once, not in two sheets", async () => {
    on = (p) => p.endsWith('/carts') ? startJob([done(CART)]) : p.endsWith('/add') ? startJob([login]) : json({});
    const r = await mount(); await wait();
    const add = r.root.findAll((n: any) => n.type === 'Pressable' && n.findAll((c: any) => c.type === 'Text').some((c: any) => String(c.children).includes('Add 1')));
    await act(async () => { add[add.length - 1].props.onPress(); await new Promise((x) => setTimeout(x, 5)); });
    await act(async () => { set(() => ({ visible: false })); });
    await wait();
    expect(r.root.findAll((n: any) => n.type === 'WebView' && n.props.uri === 'https://www.heb.com/login')).toHaveLength(1);
  });
});

/** Public members of the real CartSession, read from its source. */
function cartSessionMembers(): string[] {
  const file = path.join(__dirname, '../../core/src/client.ts');
  const src = ts.createSourceFile(file, fs.readFileSync(file, 'utf8'), ts.ScriptTarget.Latest, true);
  const out: string[] = [];
  const hidden = (m: ts.Node) => (ts.getCombinedModifierFlags(m as ts.Declaration) & (ts.ModifierFlags.Private | ts.ModifierFlags.Protected)) !== 0;
  src.forEachChild((n) => {
    if (!ts.isClassDeclaration(n) || n.name?.text !== 'CartSession') return;
    for (const m of n.members) {
      if (ts.isConstructorDeclaration(m)) {
        for (const p of m.parameters) if (p.modifiers?.some((x) => x.kind === ts.SyntaxKind.PublicKeyword)) out.push((p.name as ts.Identifier).text);
        continue;
      }
      if (!m.name || hidden(m)) continue;
      out.push((m.name as ts.Identifier).text);
    }
  });
  return [...new Set(out)];
}

describe('the Jest kit stays in step with the package', () => {
  const kit = require('../jest.js');

  it('exports every name the package does, and only its own helpers besides', () => {
    const mine = ['mockCart', 'setMockUser', 'resetMealioMock'];
    expect(Object.keys(kit).filter((k) => !mine.includes(k)).sort()).toEqual(Object.keys(real).sort());
  });

  it('has every public CartSession member, the deprecated ones too', () => {
    const members = cartSessionMembers();
    expect(members).toEqual(expect.arrayContaining(['addToCart', 'restorePicks', 'choose', 'skip', 'pending', 'ready', 'cart']));
    const c = kit.mockCart();
    expect(members.filter((k) => !(k in c))).toEqual([]);
    expect(new kit.CartSession(null, { cartId: 'x' })).toBeInstanceOf(kit.CartSession);
  });

  it('words and plurals read like the real ones', () => {
    const { ui } = kit.useMealio();
    const realUi = (require('@mealio/sdk-core') as any).textTools();
    expect(ui.plural('addItems', 3, { store: 'H-E-B' })).toBe(realUi.plural('addItems', 3, { store: 'H-E-B' }));
    expect(ui.plural('addItems', 3, { store: 'H-E-B' })).toBe('Add 3 items to H-E-B');
    expect(ui.tr('titleInCart', { store: 'H-E-B' })).toBe('In your H-E-B cart');
  });

  it('a late cancel listener runs at once', () => {
    const t = new kit.CancelToken();
    let early = 0, late = 0;
    t.onCancel(() => { early += 1; });
    t.cancel();
    t.onCancel(() => { late += 1; });
    expect([early, late]).toEqual([1, 1]);
  });

  it('setMockUser(null) makes a guest: the button asks for sign-in, or is off', () => {
    const asked: number[] = [];
    try {
      kit.setMockUser(null);
      expect(kit.useMealio().hasUser).toBe(false);
      const added: any[] = [];
      const el = kit.MealioCartButton({ recipe: RECIPE, onSignInRequired: () => asked.push(1), onAdded: (x: any) => added.push(x), renderButton: (b: any) => b });
      el.onPress();
      expect(asked).toEqual([1]);
      expect(added).toEqual([]);
      expect(kit.MealioCartButton({ recipe: RECIPE, renderButton: (b: any) => b }).disabled).toBe(true);
      kit.setMockUser('u1');
      expect(kit.useMealio().hasUser).toBe(true);
    } finally {
      kit.setMockUser(undefined);
    }
  });
});
