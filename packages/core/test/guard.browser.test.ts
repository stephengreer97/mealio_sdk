// The guard in a real Chromium: same-origin frames and workers cannot be
// faked in a vm. Needs Playwright and Chrome; skipped when either is missing.
//   MEALIO_PLAYWRIGHT=/path/with/node_modules/playwright npx vitest run test/guard.browser.test.ts
// Without MEALIO_PLAYWRIGHT it tries the repo's own `playwright`, if installed.
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { createRequire } from 'node:module';
import path from 'node:path';
import { GUARD_SCRIPT } from '../src';

function loadPlaywright(): any {
  const from = process.env.MEALIO_PLAYWRIGHT;
  try {
    return createRequire(from ? path.join(path.resolve(from), 'x.js') : import.meta.url)('playwright');
  } catch { return null; }
}

async function launch(pw: any): Promise<any> {
  if (!pw) return null;
  for (const opts of [{ channel: 'chrome' }, {}]) {
    try { return await pw.chromium.launch(opts); } catch { /* try the next */ }
  }
  return null;
}

const pw = loadPlaywright();
const browser = await launch(pw);
if (!browser) console.warn('[guard.browser] skipped: no Playwright or Chrome (set MEALIO_PLAYWRIGHT)');

const M = JSON.stringify({ query: 'mutation { placeOrder { id } }' });

describe.skipIf(!browser)('guard in Chromium', () => {
  let page: any;
  const reached: string[] = [];

  beforeAll(async () => {
    const ctx = await browser.newContext();
    await ctx.route('https://www.heb.com/**', async (r: any) => {
      const u = new URL(r.request().url());
      if (u.pathname === '/' || u.pathname === '/frame') return r.fulfill({ status: 200, contentType: 'text/html', body: '<html><body>page</body></html>' });
      if (u.pathname === '/w.js') return r.fulfill({ status: 200, contentType: 'text/javascript', body: 'postMessage("store worker");' });
      reached.push(u.pathname);
      return r.fulfill({ status: 200, contentType: 'application/json', body: '{}' });
    });
    page = await ctx.newPage();
    await page.goto('https://www.heb.com/');
    await page.evaluate(GUARD_SCRIPT);
  });
  afterAll(async () => { await browser?.close(); });

  /** What each named call did in the page: 'sent' or the guard's reason. */
  const run = (body: string) => page.evaluate(`(async () => {
    const t = async (f) => { try { await f(); return 'sent'; } catch (e) { return String(e && e.message || e).replace('mealio guard: ', ''); } };
    const M = ${JSON.stringify(M)};
    ${body}
  })()`);

  it('checks fetch and XHR in a same-origin iframe, however it is reached', async () => {
    const out = await run(`
      const a = document.createElement('iframe'); document.body.appendChild(a);
      const b = document.createElement('iframe'); b.src = '/frame'; document.body.appendChild(b);
      await new Promise((r) => b.addEventListener('load', r));
      const c = document.createElement('div'); c.innerHTML = '<iframe></iframe>'; document.body.appendChild(c);
      await new Promise((r) => setTimeout(r, 0));
      const xhr = (w) => t(() => { const x = new w.XMLHttpRequest(); x.open('POST', '/graphql'); x.send(M); });
      return {
        appendedBody: await t(() => a.contentWindow.fetch('/graphql', { method: 'POST', body: M })),
        appendedPath: await t(() => a.contentWindow.fetch('/checkout/submit', { method: 'POST' })),
        viaDocument: await t(() => a.contentDocument.defaultView.fetch('/graphql', { method: 'POST', body: M })),
        navigated: await t(() => window.frames[1].fetch('/graphql', { method: 'POST', body: M })),
        innerHtml: await t(() => window.frames[2].fetch('/graphql', { method: 'POST', body: M })),
        xhr: await xhr(a.contentWindow),
        blobFromTop: await t(() => a.contentWindow.fetch('/graphql', { method: 'POST', body: new Blob([M]) })),
        allowed: await t(() => a.contentWindow.fetch('/graphql', { method: 'POST', body: '{"operationName":"cartItemsV2"}' })),
      };
    `);
    expect(out).toEqual({
      appendedBody: 'blocked_operation', appendedPath: 'blocked_path', viaDocument: 'blocked_operation',
      navigated: 'blocked_operation', innerHtml: 'blocked_operation', xhr: 'blocked_operation',
      blobFromTop: 'blocked_operation', allowed: 'sent',
    });
  });

  it('refuses blob: and data: workers, in the page and in a frame, and allows the store\'s own', async () => {
    const out = await run(`
      const src = 'fetch("https://www.heb.com/checkout/w", { method: "POST" })';
      const a = document.createElement('iframe'); document.body.appendChild(a);
      const own = await new Promise((res) => { const w = new Worker('/w.js'); w.onmessage = (e) => res(e.data); w.onerror = () => res('error'); });
      return {
        blob: await t(() => new Worker(URL.createObjectURL(new Blob([src], { type: 'text/javascript' })))),
        data: await t(() => new Worker('data:text/javascript,' + encodeURIComponent(src))),
        shared: await t(() => new SharedWorker(URL.createObjectURL(new Blob([src], { type: 'text/javascript' })))),
        frame: await t(() => new a.contentWindow.Worker(URL.createObjectURL(new Blob([src], { type: 'text/javascript' })))),
        own,
        isWorker: new Worker('/w.js') instanceof Worker,
      };
    `);
    expect(out).toEqual({ blob: 'blocked_worker', data: 'blocked_worker', shared: 'blocked_worker', frame: 'blocked_worker', own: 'store worker', isWorker: true });
  });

  it('reads BOM JSON and raw multipart text', async () => {
    const out = await run(`
      const mp = '--b\\r\\nContent-Disposition: form-data; name="operations"\\r\\n\\r\\n' + M + '\\r\\n--b--';
      return {
        bom: await t(() => fetch('/graphql', { method: 'POST', body: '\\ufeff' + M })),
        multipart: await t(() => fetch('/graphql', { method: 'POST', headers: { 'content-type': 'multipart/form-data; boundary=b' }, body: mp })),
      };
    `);
    expect(out).toEqual({ bom: 'blocked_operation', multipart: 'blocked_operation' });
    expect(reached.filter((p) => /checkout/.test(p))).toEqual([]);
  });
});
