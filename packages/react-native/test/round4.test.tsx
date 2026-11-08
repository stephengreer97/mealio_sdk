// 0.6 round 4: restorePicks under an outside cancel, the provider without
// react-native-webview under `testing`, the guard at document start, insets.
import React from 'react';
import { describe, it, expect, afterEach } from 'vitest';
import TR, { act } from 'react-test-renderer';
import fs from 'node:fs';
import { GUARD_SCRIPT } from '@mealio/sdk-core';
import { createFakeMealio, type FakeItem } from '@mealio/sdk-core/testing';
import { Inset, MealioProvider, useMealio, type MealioApi } from '../src/MealioProvider';
import { MealioCartFlow } from '../src/MealioCartFlow';
import { views } from './stubs/webview';

(globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
const g = globalThis as any;

const RECIPE = { id: 'r', title: 'Tacos', ingredients: [{ name: 'garlic' }] };
const GARLIC: FakeItem = { key: 'garlic', options: [{ id: 'g1', name: 'Garlic bulb', unitPrice: 0.5 }], remembered: 'g1' };
const wait = (ms = 10) => act(async () => { await new Promise((r) => setTimeout(r, ms)); });
const texts = (r: TR.ReactTestRenderer) => r.root.findAll((n: any) => n.type === 'Text').flatMap((n: any) => n.children).filter((c: any) => typeof c === 'string') as string[];
const hasText = (t: string) => (n: any) => n.findAll((c: any) => c.type === 'Text').some((c: any) => c.children.some((x: any) => typeof x === 'string' && x.includes(t)));
const pressables = (r: TR.ReactTestRenderer, pred: (n: any) => boolean) => r.root.findAll((n: any) => n.type === 'Pressable' && pred(n));
const press = (r: TR.ReactTestRenderer, pred: (n: any) => boolean) => act(async () => { pressables(r, pred)[0].props.onPress(); await new Promise((x) => setTimeout(x, 5)); });

afterEach(() => { g.__noSafeArea = false; });

describe('Try again after a failed add', () => {
  it('an outside cancel while restorePicks searches restarts the load, and the pick still comes back', async () => {
    const fake = createFakeMealio({ items: [GARLIC], search: { minced: [{ id: 'jar', name: 'Minced garlic jar', unitPrice: 2.99 }] }, add: { fail: 'store_unavailable' } });
    let api!: MealioApi;
    const Grab = () => { api = useMealio(); return null; };
    const errors: string[] = [];
    let r!: TR.ReactTestRenderer;
    await act(async () => {
      r = TR.create(
        <MealioProvider publishableKey="pk" testing={fake} getSessionToken={async () => 'tok'}>
          <Grab />
          <MealioCartFlow visible recipe={RECIPE} onClose={() => {}} onError={(e: any) => errors.push(e.code)} />
        </MealioProvider>);
    });
    await wait(30);
    await press(r, (n) => n.props.accessibilityState?.expanded === false); // Change
    await act(async () => { r.root.findAll((n: any) => n.type === 'TextInput' && n.props.onSubmitEditing)[0].props.onChangeText('minced'); });
    await press(r, (n) => hasText('Search')(n) && n.props.style !== undefined && !n.props.accessibilityLabel);
    await wait(30);
    await press(r, (n) => n.props.accessibilityRole === 'radio' && hasText('Minced garlic jar')(n));
    await press(r, hasText('Add 1')); await wait(30);
    expect(errors).toEqual(['store_unavailable']);

    delete fake.script.add;
    const release = fake.hold('search');
    await press(r, hasText('Try again')); await wait(30);
    expect(fake.requests.filter((x) => x.kind === 'search')).toHaveLength(2); // the restore's search, held
    await act(async () => { await api.signOutOfAllStores(); }); // cancels every prepare and search
    release();
    await wait(50);
    // Restarted: a third prepare, whose restore found the jar again.
    expect(fake.requests.filter((x) => x.kind === 'prepare')).toHaveLength(3);
    expect(fake.requests.filter((x) => x.kind === 'search').map((x) => x.body.query)).toEqual(['minced', 'minced', 'minced']);
    expect(errors).toEqual(['store_unavailable']);
    expect(texts(r)).toContain('Minced garlic jar');
    expect(texts(r)).not.toContain('Garlic bulb');
    await act(async () => { r.unmount(); });
  });
});

describe('react-native-webview is loaded only to render a WebView', () => {
  it('under `testing` it is never required, and no WebView renders', async () => {
    g.__mealioRequire.length = 0;
    const fake = createFakeMealio({ items: [GARLIC] });
    let r!: TR.ReactTestRenderer;
    await act(async () => {
      r = TR.create(<MealioProvider publishableKey="pk" testing={fake} getSessionToken={async () => 'tok'}><MealioCartFlow visible recipe={RECIPE} onClose={() => {}} /></MealioProvider>);
    });
    await wait(30);
    expect(texts(r).some((t) => /Garlic bulb/.test(t))).toBe(true);
    expect(g.__mealioRequire).not.toContain('react-native-webview');
    expect(r.root.findAll((n: any) => n.type === 'WebView')).toHaveLength(0);
    await act(async () => { r.unmount(); });
  });

  it('nothing in the package imports it at module load', () => {
    for (const f of fs.readdirSync(new URL('../src/', import.meta.url))) {
      const src = fs.readFileSync(new URL(`../src/${f}`, import.meta.url), 'utf8');
      for (const m of src.matchAll(/^import\s+(type\s+)?[^;]*?from\s+'react-native-webview';/gm)) expect(m[1], f).toBe('type ');
    }
  });
});

describe('the guard at document start in every frame', () => {
  it('the hidden page and the sign-in page carry it, for all frames', async () => {
    views.hidden = null; views.login = null;
    let api!: MealioApi;
    const Grab = () => { api = useMealio(); return null; };
    let r!: TR.ReactTestRenderer;
    await act(async () => { r = TR.create(<MealioProvider publishableKey="pk" getSessionToken={async () => 'tok'}><Grab /></MealioProvider>); });
    expect(g.__mealioRequire).toContain('react-native-webview');
    expect(views.hidden.injectedJavaScriptBeforeContentLoaded).toBe(GUARD_SCRIPT);
    expect(views.hidden.injectedJavaScriptBeforeContentLoadedForMainFrameOnly).toBe(false);
    void api;
    await act(async () => { r.unmount(); });
  });
});

describe('the sign-in sheet\'s insets (no deprecated SafeAreaView)', () => {
  it('uses react-native-safe-area-context when the app has it, on every edge', async () => {
    let r!: TR.ReactTestRenderer;
    await act(async () => { r = TR.create(<Inset style={{ flex: 1 }}><React.Fragment /></Inset>); });
    const v = r.root.findAll((n: any) => n.type === 'SafeAreaContextView');
    expect(v).toHaveLength(1);
    expect(v[0].props.edges).toEqual(['top', 'right', 'bottom', 'left']);
  });

  it('without it, clears the Android status bar itself', async () => {
    g.__noSafeArea = true;
    let r!: TR.ReactTestRenderer;
    await act(async () => { r = TR.create(<Inset style={{ flex: 1 }}><React.Fragment /></Inset>); });
    expect(r.root.findAll((n: any) => n.type === 'SafeAreaContextView')).toHaveLength(0);
    const v = r.root.findAll((n: any) => n.type === 'View')[0];
    expect(v.props.style).toEqual([{ flex: 1 }, { paddingTop: 24 }]);
  });

  it('the login Modal draws edge to edge on Android, and nothing imports SafeAreaView from react-native', () => {
    const src = fs.readFileSync(new URL('../src/MealioProvider.tsx', import.meta.url), 'utf8');
    expect(src).toMatch(/presentationStyle="pageSheet" \{\.\.\.EDGE_TO_EDGE\}/);
    expect(src).toMatch(/EDGE_TO_EDGE: object = \{ statusBarTranslucent: true, navigationBarTranslucent: true \}/);
    for (const f of fs.readdirSync(new URL('../src/', import.meta.url))) {
      const text = fs.readFileSync(new URL(`../src/${f}`, import.meta.url), 'utf8');
      for (const m of text.matchAll(/import\s*\{([^}]*)\}\s*from\s*'react-native';/g)) expect(m[1], f).not.toMatch(/\bSafeAreaView\b/);
    }
  });
});
