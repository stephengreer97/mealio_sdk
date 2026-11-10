// 0.6.1: "Choose a different store" on the sign-in step. A user signed out of
// their saved store can pick another without signing in to the old one first.
import React from 'react';
import { describe, it, expect, beforeEach } from 'vitest';
import TR, { act } from 'react-test-renderer';
import crypto from 'node:crypto';
import { KEYS } from '@mealio/sdk-core';
import { MealioProvider } from '../src/MealioProvider';
import { MealioCartFlow } from '../src/MealioCartFlow';
import { views } from './stubs/webview';

(globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
const g = globalThis as any;

const priv = crypto.generateKeyPairSync('ed25519').privateKey;
(KEYS as any).ktest_r7 = crypto.createPublicKey(priv).export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64');
function env(job: string, seq: number, store: string, instructions: any[]) {
  const payload = JSON.stringify({ v: 1, kind: 'instructions', job, seq, exp: Math.floor(Date.now() / 1000) + 600, store, instructions });
  return { payload, sig: crypto.sign(null, Buffer.from(payload), priv).toString('base64'), kid: 'ktest_r7' };
}
const json = (o: any) => new Response(JSON.stringify(o), { status: 200 });
const wait = (ms = 10) => act(async () => { await new Promise((r) => setTimeout(r, ms)); });
const login = (job: string, store: string) => env(job, 2, store, [{ op: 'show_login', id: 'l1', url: `https://www.${store}.com/login`, title: 'Sign in', check: { script: '/*check*/', intervalMs: 60000 }, doneWhen: [{ type: 'IN' }], timeoutMs: 30000 }]);

describe('0.6.1: a different store from the sign-in step', () => {
  beforeEach(() => { views.hidden = null; views.login = null; views.injected.length = 0; });

  it('stops the sign-in, shows the stores, and starts the picked one', async () => {
    const carts: any[] = [];
    const steps: Record<string, number> = {};
    g.fetch = async (u: string, init?: any) => {
      if (u.endsWith('/warm')) return json({ warm: null });
      if (u.endsWith('/api/v1/stores')) return json({ stores: [{ id: 'heb', name: 'H-E-B' }, { id: 'aldi', name: 'ALDI' }] });
      if (u.endsWith('/carts')) {
        const body = JSON.parse(init.body);
        carts.push(body.store ?? null);
        const job = `j${carts.length}`;
        return json({ job, envelope: env(job, 1, body.store ?? 'heb', [{ op: 'page_script', id: 's1', script: '/*s1*/', until: [{ type: 'S' }], timeoutMs: 200 }]) });
      }
      const m = /jobs\/(j\d)\/step/.exec(u);
      if (m) {
        steps[m[1]] = (steps[m[1]] ?? 0) + 1;
        if (m[1] === 'j1' && steps.j1 === 1) return json({ envelope: login('j1', 'heb') });
        return json({});
      }
      return json({});
    };
    let r!: TR.ReactTestRenderer;
    await act(async () => {
      r = TR.create(<MealioProvider publishableKey="pk" getSessionToken={async () => 'tok'}>
        <MealioCartFlow visible recipe={{ id: 'r', title: 'Tacos', ingredients: [{ name: 'onion' }] }} onClose={() => {}} />
      </MealioProvider>);
    });
    await wait(400);
    const loginPages = () => r.root.findAll((n) => (n.type as any) === 'WebView' && /login/.test(n.props.uri ?? ''));
    expect(loginPages()).toHaveLength(1);
    const link = r.root.findByProps({ testID: 'mealio-signin-different-store' });
    await act(async () => { link.props.onPress(); });
    await wait(100);
    // The store's sign-in page is gone from the sheet.
    expect(loginPages()).toHaveLength(0);
    expect(r.root.findAll((n) => n.props.testID === 'mealio-signin-different-store')).toHaveLength(0);
    // The store list is up: pick ALDI.
    const aldi = r.root.findAll((n) => n.props.accessibilityRole === 'radio' && typeof n.props.onPress === 'function')
      .find((n) => JSON.stringify(n.findAllByType('Text' as any).map((t: any) => t.props.children)).includes('ALDI'));
    expect(aldi).toBeTruthy();
    await act(async () => { aldi!.props.onPress(); });
    await wait(400);
    expect(carts).toEqual([null, 'aldi']);
    await act(async () => { r.unmount(); });
  });
});
