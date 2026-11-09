// 0.6 round 6, item 2: the guard's cheap fixes, in real Chrome. The guard
// decides with built-ins it captured at install, reads any other body object
// as its text, judges form submissions, arms frames in open shadow roots, and
// arms a same-origin popup of an armed page. Skipped without Playwright, as
// guard.browser.test.ts. Nothing here reaches the network: every host fails
// to resolve, and www.heb.com is served by the route below.
import { describe, it, expect, afterAll } from 'vitest';
import { createRequire } from 'node:module';
import path from 'node:path';
import { GUARD_ARM_SCRIPT, GUARD_SCRIPT } from '../src';

function loadPlaywright(): any {
  const from = process.env.MEALIO_PLAYWRIGHT;
  try {
    return createRequire(from ? path.join(path.resolve(from), 'x.js') : import.meta.url)('playwright');
  } catch { return null; }
}

async function launch(pw: any): Promise<any> {
  if (!pw) return null;
  const args = ['--host-resolver-rules=MAP * ~NOTFOUND , EXCLUDE localhost'];
  for (const opts of [{ channel: 'chrome', args }, { args }]) {
    try { return await pw.chromium.launch(opts); } catch { /* try the next */ }
  }
  return null;
}

const browser = await launch(loadPlaywright());
if (!browser) console.warn('[round6.browser] skipped: no Playwright or Chrome (set MEALIO_PLAYWRIGHT)');

const PO = JSON.stringify({ operationName: 'PlaceOrder', query: 'mutation PlaceOrder { placeOrder { id } }' });
const T = `const t = async (f) => { try { const r = await f(); return r === false ? 'false' : 'sent'; } catch (e) { return String(e && e.message || e).replace('mealio guard: ', ''); } };`;

/** https://www.heb.com/ with GUARD_SCRIPT at document start in every frame and window, then armed. */
async function armedPage(pages: Record<string, string> = {}) {
  const ctx = await browser.newContext();
  const reached: string[] = [];
  await ctx.addInitScript(GUARD_SCRIPT);
  await ctx.route('https://www.heb.com/**', async (r: any) => {
    const u = new URL(r.request().url());
    const html = pages[u.pathname] ?? (u.pathname === '/' || u.pathname === '/frame' || u.pathname === '/popup' ? '<html><body></body></html>' : undefined);
    if (html !== undefined && r.request().method() === 'GET') return r.fulfill({ status: 200, contentType: 'text/html', body: html });
    reached.push(`${r.request().method()} ${u.pathname}`);
    return r.fulfill({ status: 200, contentType: 'text/html', body: '<html><body>posted</body></html>' });
  });
  const page = await ctx.newPage();
  await page.goto('https://www.heb.com/');
  await page.evaluate(GUARD_ARM_SCRIPT);
  const run = (body: string) => page.evaluate(`(async () => { ${T} const PO = ${JSON.stringify(PO)}; ${body} })()`);
  return { ctx, page, reached, run };
}

describe.skipIf(!browser)('round 6: the guard in Chromium', () => {
  afterAll(async () => { await browser?.close(); });

  it('decides with the built-ins it captured, whatever the page replaces later', async () => {
    const s = await armedPage();
    const poisons: Record<string, string> = {
      'RegExp.prototype.test': 'RegExp.prototype.test = function () { return false; }',
      'RegExp.prototype.exec': 'RegExp.prototype.exec = function () { return null; }',
      'window.URL': 'window.URL = function () { return { pathname: "/ok", search: "" }; }',
      'URL.prototype.pathname': 'Object.defineProperty(URL.prototype, "pathname", { get: function () { return "/ok"; }, configurable: true })',
      'Blob.prototype.text': 'Blob.prototype.text = function () { return Promise.resolve(""); }',
      'String': 'window.String = function () { return ""; }',
      'JSON.parse': 'JSON.parse = function () { return {}; }',
      'Array.prototype.push': 'Array.prototype.push = function () { return 0; }',
      'Promise.prototype.then': 'Promise.prototype.then = function (ok) { ok(""); }',
    };
    const all: Record<string, unknown> = {};
    const want: Record<string, unknown> = {};
    for (const [name, poison] of Object.entries(poisons)) {
      // Each call runs, and the original is put back, inside one evaluation.
      const got = await s.run(`
        const saved = { t: RegExp.prototype.test, x: RegExp.prototype.exec, U: window.URL, p: Object.getOwnPropertyDescriptor(URL.prototype, 'pathname'),
          b: Blob.prototype.text, S: window.String, j: JSON.parse, i: String.prototype.indexOf, a: Array.prototype.push, th: Promise.prototype.then,
          c: Function.prototype.call, ap: Function.prototype.apply };
        const go = (f) => { try { return f(); } catch (e) { return Promise.reject(e); } };
        const doc = 'query=' + encodeURIComponent('mutation { placeOrder { id } }'), blob = new Blob([PO]);
        ${poison};
        const out = {};
        const done = [];
        // Started while poisoned; settled after the originals are back.
        done[0] = go(() => fetch('/checkout/a', { method: 'POST' }));
        done[1] = go(() => fetch('/graphql', { method: 'POST', body: PO }));
        done[2] = go(() => fetch('/graphql', { method: 'POST', body: blob }));
        done[3] = go(() => fetch('/graphql', { method: 'POST', body: doc }));
        RegExp.prototype.test = saved.t; RegExp.prototype.exec = saved.x; window.URL = saved.U; Object.defineProperty(URL.prototype, 'pathname', saved.p);
        Blob.prototype.text = saved.b; window.String = saved.S; JSON.parse = saved.j; String.prototype.indexOf = saved.i; Array.prototype.push = saved.a;
        Promise.prototype.then = saved.th; Function.prototype.call = saved.c; Function.prototype.apply = saved.ap;
        out.path = await t(() => done[0]);
        out.json = await t(() => done[1]);
        out.blob = await t(() => done[2]);
        out.doc = await t(() => done[3]);
        return out;`);
      all[name] = got;
      want[name] = { path: 'blocked_path', json: 'blocked_operation', blob: 'blocked_operation', doc: 'blocked_operation' };
    }
    expect(all).toEqual(want);
    expect(s.reached).toEqual([]);
    await s.ctx.close();
  });

  it('never hands the page an original through Function.prototype.call or apply', async () => {
    const s = await armedPage();
    // Page code replaces call and apply to collect every function they are used on,
    // then makes allowed calls, so the guard passes them on to the originals.
    const leaked = await s.run(`
      const seen = [], C = Function.prototype.call, A = Function.prototype.apply, R = Reflect.apply;
      Function.prototype.call = function (self, ...args) { seen.push(this); return R(this, self, args); };
      Function.prototype.apply = function (self, args) { seen.push(this); return R(this, self, args || []); };
      const frame = document.createElement('iframe');
      let pending;
      try {
        pending = fetch('/graphql/ok', { method: 'POST', body: '{"operationName":"Search"}' });
        navigator.sendBeacon('/graphql/ok2', 'x=1');
        const x = new XMLHttpRequest(); x.open('POST', '/graphql/ok3'); x.send('x=1');
        document.body.appendChild(frame); void frame.contentWindow;
      } finally { Function.prototype.call = C; Function.prototype.apply = A; }
      await pending;
      const originals = [];
      for (const f of seen) {
        if (typeof f !== 'function' || !/\[native code\]/.test(Function.prototype.toString.call(f))) continue;
        if (f === window.fetch || f === navigator.sendBeacon || f === XMLHttpRequest.prototype.send || f === XMLHttpRequest.prototype.open) continue;
        if (/^(fetch|sendBeacon|send|open|get contentWindow|appendChild)$/.test(f.name)) originals.push(f.name);
      }
      return originals;`);
    expect(leaked).toEqual([]);
    await s.ctx.close();
  });

  it('reads a String object or an object with toString as its text, in fetch, XHR and beacons', async () => {
    const s = await armedPage();
    const got = await s.run(`
      const H = { 'content-type': 'application/json' };
      return {
        fetchString: await t(() => fetch('/graphql/1', { method: 'POST', headers: H, body: new String(PO) })),
        fetchObject: await t(() => fetch('/graphql/2', { method: 'POST', headers: H, body: { toString: () => PO } })),
        xhr: await t(() => new Promise((ok, no) => { const x = new XMLHttpRequest(); x.open('POST', '/graphql/3'); x.onload = ok; x.onerror = no; x.send(new String(PO)); })),
        beacon: await t(() => navigator.sendBeacon('/graphql/4', new String(PO))),
        innocent: await t(() => fetch('/graphql/5', { method: 'POST', headers: H, body: new String('{"operationName":"Search"}') })),
      };`);
    expect(got).toEqual({ fetchString: 'blocked_operation', fetchObject: 'blocked_operation', xhr: 'blocked_operation', beacon: 'false', innocent: 'sent' });
    expect(s.reached).toEqual(['POST /graphql/5']);
    await s.ctx.close();
  });

  it('judges form submissions: submit(), requestSubmit() and a button click', async () => {
    const s = await armedPage();
    const got = await s.run(`
      const frame = document.createElement('iframe'); frame.name = 'tgt'; document.body.appendChild(frame);
      const form = (action, field) => {
        const f = document.createElement('form'); f.method = 'POST'; f.action = action; f.target = 'tgt';
        const i = document.createElement('input'); i.name = field[0]; i.value = field[1]; f.appendChild(i);
        const b = document.createElement('button'); b.type = 'submit'; f.appendChild(b);
        document.body.appendChild(f); return f;
      };
      const out = {};
      out.submitPath = await t(() => form('/checkout/f1', ['x', '1']).submit());
      out.submitBody = await t(() => form('/graphql/f2', ['operationName', 'PlaceOrder']).submit());
      out.requestSubmit = await t(() => form('/checkout/f3', ['x', '1']).requestSubmit());
      const f4 = form('/graphql/f4', ['query', 'mutation { submitOrder { id } }']);
      let seen = 'no event'; f4.addEventListener('submit', (e) => { seen = e.defaultPrevented ? 'prevented' : 'went'; });
      f4.querySelector('button').click();
      out.click = seen;
      const f5 = form('/graphql/f5', ['x', '1']);
      f5.querySelector('button').setAttribute('formaction', '/checkout/f5');
      out.formaction = await t(() => f5.requestSubmit(f5.querySelector('button')));
      out.innocent = await t(() => form('/search', ['q', 'milk']).submit());
      return out;`);
    // The click's event never reached the page's own listener: the guard stopped it first.
    expect(got).toEqual({
      submitPath: 'blocked_path', submitBody: 'blocked_operation', requestSubmit: 'blocked_path', click: 'no event',
      formaction: 'blocked_path', innocent: 'sent',
    });
    await s.page.waitForTimeout(500);
    expect(s.reached).toEqual(['POST /search']);
    await s.ctx.close();
  });

  it('arming arms a frame that sits in an open shadow root', async () => {
    const ctx = await browser.newContext();
    const reached: string[] = [];
    await ctx.addInitScript(GUARD_SCRIPT);
    await ctx.route('https://www.heb.com/**', async (r: any) => {
      const u = new URL(r.request().url());
      if (u.pathname === '/' || u.pathname === '/frame') return r.fulfill({ status: 200, contentType: 'text/html', body: '<html><body></body></html>' });
      reached.push(u.pathname);
      return r.fulfill({ status: 200, body: '{}' });
    });
    const page = await ctx.newPage();
    await page.goto('https://www.heb.com/');
    // The store, before arming: a widget whose frames live in nested open shadow roots.
    await page.evaluate(() => new Promise<void>((done) => {
      const host = document.createElement('div'); document.body.appendChild(host);
      const outer = host.attachShadow({ mode: 'open' });
      const inner = document.createElement('div'); outer.appendChild(inner);
      const deep = inner.attachShadow({ mode: 'open' });
      const a = document.createElement('iframe'); a.src = '/frame'; a.onload = () => done(); outer.appendChild(a);
      const b = document.createElement('iframe'); deep.appendChild(b);
      (window as any).__w = [a.contentWindow, b.contentWindow];
    }));
    await page.evaluate(GUARD_ARM_SCRIPT);
    const got = await page.evaluate(`(async () => {
      const out = [];
      for (const w of window.__w) {
        let r; try { await w.fetch('/checkout/s', { method: 'POST' }); r = 'sent'; } catch (e) { r = e.message; }
        out.push(w.__mealioArmed() + ' ' + r);
      }
      return out;
    })()`);
    expect(got).toEqual(['true mealio guard: blocked_path', 'true mealio guard: blocked_path']);
    expect(reached).toEqual([]);
    await ctx.close();
  });

  it('a same-origin popup of an armed page starts armed, by link or by window.open', async () => {
    const s = await armedPage({ '/': '<html><body><a id="go" target="pop" href="/popup">open</a></body></html>' });
    await s.page.reload();
    await s.page.evaluate(GUARD_ARM_SCRIPT);
    // A link with a target name keeps window.opener, so only the popup's own document-start copy can arm it.
    const [byLink] = await Promise.all([s.ctx.waitForEvent('page'), s.page.click('#go')]);
    await byLink.waitForLoadState();
    const linkGot = await byLink.evaluate(`(async () => {
      let r; try { await fetch('/checkout/p1', { method: 'POST' }); r = 'sent'; } catch (e) { r = e.message; }
      return window.__mealioArmed() + ' ' + r;
    })()`);
    expect(linkGot).toBe('true mealio guard: blocked_path');
    const openGot = await s.run(`
      const w = window.open('', 'blank');
      return w.__mealioArmed() + ' ' + await t(() => w.fetch('/checkout/p2', { method: 'POST' }));`);
    expect(openGot).toBe('true blocked_path');
    expect(s.reached).toEqual([]);
    await s.ctx.close();
    // Where no document-start copy runs (only the per-script copy), window.open itself arms the window it returns.
    const ctx = await browser.newContext();
    const reached: string[] = [];
    await ctx.route('https://www.heb.com/**', async (r: any) => {
      const u = new URL(r.request().url());
      if (u.pathname === '/') return r.fulfill({ status: 200, contentType: 'text/html', body: '<html><body></body></html>' });
      reached.push(u.pathname);
      return r.fulfill({ status: 200, body: '{}' });
    });
    const page = await ctx.newPage();
    await page.goto('https://www.heb.com/');
    await page.evaluate(GUARD_ARM_SCRIPT);
    expect(await page.evaluate(`(async () => {
      const w = window.open('', 'bare');
      let r; try { await w.fetch('/checkout/p3', { method: 'POST' }); r = 'sent'; } catch (e) { r = e.message; }
      return w.__mealioArmed() + ' ' + r;
    })()`)).toBe('true mealio guard: blocked_path');
    expect(reached).toEqual([]);
    await ctx.close();
  });
});
