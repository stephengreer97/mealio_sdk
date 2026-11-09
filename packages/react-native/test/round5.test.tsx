// 0.6 round 5: which guard copy goes where (item 1), and the sign-in sheet's
// insets without react-native-safe-area-context (item 5). The Jest kit in
// beforeAll is in jestkit.test.ts.
import React from 'react';
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import TR, { act } from 'react-test-renderer';
import crypto from 'node:crypto';
import { GUARD_ARM_SCRIPT, GUARD_SCRIPT, KEYS } from '@mealio/sdk-core';
import { Inset, MealioProvider, fallbackInsets } from '../src/MealioProvider';
import { MealioCartFlow } from '../src/MealioCartFlow';
import { Platform } from './stubs/rn';
import { views } from './stubs/webview';

(globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
const g = globalThis as any;

const priv = crypto.generateKeyPairSync('ed25519').privateKey;
(KEYS as any).ktest_r5 = crypto.createPublicKey(priv).export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64');
function env(job: string, seq: number, instructions: any[]) {
  const payload = JSON.stringify({ v: 1, kind: 'instructions', job, seq, exp: Math.floor(Date.now() / 1000) + 600, store: 'heb', instructions });
  return { payload, sig: crypto.sign(null, Buffer.from(payload), priv).toString('base64'), kid: 'ktest_r5' };
}
const json = (o: any) => new Response(JSON.stringify(o), { status: 200 });
const wait = (ms = 10) => act(async () => { await new Promise((r) => setTimeout(r, ms)); });

afterEach(() => { g.__noSafeArea = false; g.__dims = undefined; Platform.OS = 'android'; delete Platform.isPad; });

describe('round 5: the guard copies the provider injects', () => {
  beforeEach(() => { views.hidden = null; views.login = null; views.injected.length = 0; });

  it('document start gets GUARD_SCRIPT; right before each server script, GUARD_ARM_SCRIPT', async () => {
    let step = 0;
    g.fetch = async (u: string) => {
      if (u.endsWith('/warm')) return json({ warm: null });
      if (u.endsWith('/carts')) return json({ job: 'j1', envelope: env('j1', 1, [{ op: 'page_script', id: 's1', script: '/*s1*/', until: [{ type: 'S' }], timeoutMs: 200 }]) });
      if (/jobs\/j1\/step/.test(u) && step++ === 0) {
        return json({ envelope: env('j1', 2, [{ op: 'show_login', id: 'l1', url: 'https://www.heb.com/login', title: 'Sign in', check: { script: '/*check*/', intervalMs: 60000 }, doneWhen: [{ type: 'IN' }], timeoutMs: 3000 }]) });
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
    expect(views.hidden.injectedJavaScriptBeforeContentLoaded).toBe(GUARD_SCRIPT);
    const before = (s: string) => views.injected[views.injected.indexOf(s) - 1];
    expect(before('/*s1*/')).toBe(GUARD_ARM_SCRIPT);
    expect(views.login).not.toBeNull();
    expect(views.login.injectedJavaScriptBeforeContentLoaded).toBe(GUARD_SCRIPT);
    await act(async () => { views.login.onLoadEnd({ nativeEvent: { url: 'https://www.heb.com/login' } }); });
    expect(before('/*check*/')).toBe(GUARD_ARM_SCRIPT);
    await act(async () => { r.unmount(); });
  });
});

describe('round 5: sign-in sheet insets without react-native-safe-area-context', () => {
  const render = async () => {
    g.__noSafeArea = true;
    let r!: TR.ReactTestRenderer;
    await act(async () => { r = TR.create(<Inset style={{ flex: 1 }}><React.Fragment /></Inset>); });
    const v = r.root.findAll((n: any) => n.type === 'View')[0];
    const [, pad] = v.props.style;
    return { top: pad.paddingTop, right: pad.paddingRight, bottom: pad.paddingBottom, left: pad.paddingLeft };
  };
  const size = (width: number, height: number) => ({ width, height, scale: 3, fontScale: 1 });

  it('iOS: the home indicator in portrait, and the notch on both sides in landscape', async () => {
    Platform.OS = 'ios';
    g.__dims = { window: size(390, 844), screen: size(390, 844) };
    expect(await render()).toEqual({ top: 0, right: 0, bottom: 34, left: 0 });
    g.__dims = { window: size(844, 390), screen: size(844, 390) };
    expect(await render()).toEqual({ top: 0, right: 44, bottom: 21, left: 44 });
    g.__dims = { window: size(375, 667), screen: size(375, 667) }; // a home button, no notch
    expect(await render()).toEqual({ top: 0, right: 0, bottom: 0, left: 0 });
    Platform.isPad = true;
    g.__dims = { window: size(820, 1180), screen: size(820, 1180) };
    expect(await render()).toEqual({ top: 0, right: 0, bottom: 20, left: 0 });
  });

  it('Android: the status bar on top and the navigation bar below, or beside in landscape', async () => {
    g.__dims = { window: size(400, 800), screen: size(400, 872) }; // 24 status + 48 bar
    expect(await render()).toEqual({ top: 24, right: 0, bottom: 48, left: 0 });
    g.__dims = { window: size(800, 376), screen: size(848, 400) }; // three-button bar on a side
    expect(await render()).toEqual({ top: 24, right: 48, bottom: 0, left: 48 });
    g.__dims = { window: size(400, 800), screen: size(400, 800) }; // edge to edge: nothing to measure
    expect(await render()).toEqual({ top: 24, right: 0, bottom: 48, left: 0 });
  });

  it('fallbackInsets measures a gesture bar, and pads nothing on other platforms', () => {
    expect(fallbackInsets('android', false, size(400, 836), size(400, 876), 24)).toEqual({ top: 24, right: 0, bottom: 16, left: 0 });
    expect(fallbackInsets('android', false, size(800, 400), size(800, 400), 0)).toEqual({ top: 0, right: 48, bottom: 24, left: 48 });
    expect(fallbackInsets('web', false, size(800, 400), size(800, 400), 0)).toEqual({ top: 0, right: 0, bottom: 0, left: 0 });
  });
});
