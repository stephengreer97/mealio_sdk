// protocol/fake-script.json: the testing-kit script every platform's kit runs.
// This is the reference interpreter; the Swift, Kotlin and Dart kit tests do the same.
import { describe, it, expect } from 'vitest';
import fs from 'node:fs';
import { createFakeMealio } from '../src/testing';
import type { CartSession } from '../src';

const fixture = JSON.parse(fs.readFileSync(new URL('../../../protocol/fake-script.json', import.meta.url), 'utf8'));

const cents = (n: number | null) => (n == null ? null : Math.round(n * 100));

describe('protocol/fake-script.json', () => {
  for (const c of fixture.cases) {
    it(c.name, async () => {
      const fake = createFakeMealio(JSON.parse(JSON.stringify(c.script)));
      const client = fake.client();
      const carts: Record<string, CartSession> = {};
      for (const [i, step] of (c.steps as any[]).entries()) {
        const at = `${c.name} step ${i} (${step.do})`;
        const want = step.expect ?? {};
        const cart = carts[step.cart ?? 'a'];
        let out: any;
        let error: string | null = null;
        try {
          switch (step.do) {
            case 'prepare': out = carts[step.cart ?? 'a'] = await client.prepareCart({ recipe: fixture.recipe }); break;
            case 'search': out = await cart.search(step.key, step.query); break;
            case 'select': cart.select(step.key, step.productId); break;
            case 'add': out = await cart.addToCart(); break;
            case 'restorePicks': await cart.restorePicks(carts[step.from]); break;
            case 'setScript':
              for (const [k, v] of Object.entries(step.set)) {
                if (v === null) delete (fake.script as any)[k]; else (fake.script as any)[k] = v;
              }
              break;
            case 'requests': expect(fake.requests.map((r) => r.kind), at).toEqual(want); continue;
            case 'searches': expect(fake.requests.filter((r) => r.kind === 'search').map((r) => r.body.query), at).toEqual(want); continue;
            default: throw new Error(`unknown step ${step.do}`);
          }
        } catch (e: any) {
          if (!e?.code) throw e;
          error = e.code;
        }
        expect(error, at).toBe(want.error ?? null);
        if (error) continue;
        const s = carts[step.cart ?? 'a'];
        if (want.store) expect(s.store, at).toBe(want.store);
        if (want.storeName) expect(s.cart.storeName, at).toBe(want.storeName);
        if (want.recipes) expect(s.recipes, at).toEqual(want.recipes);
        for (const [key, w] of Object.entries<any>(want.items ?? {})) {
          if ('status' in w) expect(s.items.find((it) => it.key === key)?.status, `${at} ${key}`).toBe(w.status);
          if ('selectedId' in w) expect(s.selectedId(key), `${at} ${key}`).toBe(w.selectedId);
          if ('quantity' in w) expect(s.quantity(key), `${at} ${key}`).toBe(w.quantity);
        }
        if (want.options) expect(out.map((p: any) => p.id), at).toEqual(want.options);
        if ('selectedId' in want) expect(s.selectedId(step.key), at).toBe(want.selectedId);
        if (want.added) {
          expect(out.added.map((a: any) => a.key), at).toEqual(want.added);
          expect(out.skipped.map((a: any) => a.key), at).toEqual(want.skipped);
          expect(out.failed.map((a: any) => a.key), at).toEqual(want.failed);
          expect(cents(s.addedTotal(out).total), at).toBe(cents(want.addedTotal));
        }
      }
    });
  }

  it('covers every step kind the other platforms must interpret', () => {
    const kinds = new Set(fixture.cases.flatMap((c: any) => c.steps.map((s: any) => s.do)));
    expect([...kinds].sort()).toEqual(['add', 'prepare', 'requests', 'restorePicks', 'search', 'searches', 'select', 'setScript']);
  });
});
