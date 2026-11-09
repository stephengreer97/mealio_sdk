// 0.6 round 7: the in-page guard, in real Chrome. A form submission is judged
// after the page's own handlers and only when it will really go; forms in
// shadow roots are covered; Worker subclasses still work; a synchronous XHR
// with a Blob or buffer body is sent at once; the page's formdata listener
// fires once per submission. Skipped without Playwright, as the other browser
// tests. Nothing here reaches the network: every host fails to resolve, and
// www.heb.com is served by the route below.
import { describe, it, expect, afterAll } from 'vitest';
import { createRequire } from 'node:module';
import path from 'node:path';
import * as guardModule from '../src/guard';

// MEALIO_GUARD_MODULE lets a check run these same tests against another copy
// of guard.ts (an older one, to see each test fail without its fix).
const alt = process.env.MEALIO_GUARD_MODULE;
const { GUARD_ARM_SCRIPT, GUARD_SCRIPT } = (alt ? await import(path.resolve(alt)) : guardModule) as typeof guardModule;

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
if (!browser) console.warn('[round7.browser] skipped: no Playwright or Chrome (set MEALIO_PLAYWRIGHT)');

const PAGE = '<html><body><iframe name="sink"></iframe></body></html>';

/** The store page at `start`, GUARD_SCRIPT at document start, armed. `reached` lists every request the server saw but the pages. */
async function armedPage(start = '/') {
  const ctx = await browser.newContext();
  const reached: string[] = [];
  await ctx.addInitScript(GUARD_SCRIPT);
  await ctx.route('https://www.heb.com/**', async (r: any) => {
    const req = r.request();
    const u = new URL(req.url());
    if (req.method() === 'GET' && (u.pathname === '/' || u.pathname === '/store')) return r.fulfill({ status: 200, contentType: 'text/html', body: PAGE });
    if (u.pathname === '/w.js') return r.fulfill({ status: 200, contentType: 'text/javascript', body: 'onmessage = (e) => postMessage(e.data);' });
    reached.push(`${req.method()} ${u.pathname}${u.search}`);
    return r.fulfill({ status: 200, contentType: 'text/plain', headers: { 'access-control-allow-origin': '*' }, body: `ok ${req.postData() ?? ''}` });
  });
  const page = await ctx.newPage();
  await page.goto('https://www.heb.com' + start);
  await page.evaluate(GUARD_ARM_SCRIPT);
  const run = (body: string) => page.evaluate(`(async () => {
    const t = async (f) => { try { const r = await f(); return r === false ? 'false' : 'sent'; } catch (e) { return String(e && e.message || e).replace('mealio guard: ', ''); } };
    const wait = (ms) => new Promise((r) => setTimeout(r, ms));
    ${body} })()`);
  return { ctx, page, reached, run };
}

describe.skipIf(!browser)('round 7: the guard judges what really leaves', () => {
  afterAll(async () => { await browser?.close(); });

  it('never touches a form the page sends itself in JS, even with no action on a checkout-looking URL', async () => {
    // A React-style form: no action, onSubmit at the root calls preventDefault
    // and sends the fields with fetch. The page URL names checkout.
    const s = await armedPage('/store?redirect=/checkout');
    const got = await s.run(`
      let fd = 0, handled = 0, result = null;
      document.addEventListener('formdata', () => fd++, true);
      const root = document.createElement('div'); document.body.appendChild(root);
      root.addEventListener('submit', (e) => {
        e.preventDefault(); handled++;
        fetch('/api/login', { method: 'POST', body: new URLSearchParams(new FormData(e.target)) }).then((r) => r.text()).then((x) => { result = x; });
      });
      root.innerHTML = '<form id="login"><input name="email" value="a@b.c"><button id="go">Sign in</button></form>';
      document.getElementById('go').click();
      await wait(300);
      return { handled, result, fd };`);
    expect(got).toEqual({ handled: 1, result: 'ok email=a%40b.c', fd: 1 });
    expect(s.reached).toEqual(['POST /api/login']);
    await s.ctx.close();
  });

  it('judges a form with no action by the page URL, when it really submits', async () => {
    const s = await armedPage('/store?redirect=/checkout');
    await s.run(`
      const f = document.createElement('form'); f.method = 'POST'; f.target = 'sink';
      f.innerHTML = '<input name="x" value="1"><button>go</button>'; document.body.appendChild(f);
      f.querySelector('button').click(); await wait(300);`);
    expect(s.reached).toEqual([]);
    await s.ctx.close();
    const ok = await armedPage('/store?q=milk');
    await ok.run(`
      const f = document.createElement('form'); f.method = 'POST'; f.target = 'sink';
      f.innerHTML = '<input name="x" value="1"><button>go</button>'; document.body.appendChild(f);
      f.querySelector('button').click(); await wait(300);`);
    expect(ok.reached).toEqual(['POST /store?q=milk']);
    await ok.ctx.close();
  });

  it('judges forms in shadow roots: open ones from before arming, and open or closed ones attached after', async () => {
    const ctx = await browser.newContext();
    const reached: string[] = [];
    await ctx.addInitScript(GUARD_SCRIPT);
    await ctx.route('https://www.heb.com/**', async (r: any) => {
      const u = new URL(r.request().url());
      if (r.request().method() === 'GET' && u.pathname === '/') return r.fulfill({ status: 200, contentType: 'text/html', body: PAGE });
      reached.push(u.pathname);
      return r.fulfill({ status: 200, contentType: 'text/html', body: 'posted' });
    });
    const page = await ctx.newPage();
    await page.goto('https://www.heb.com/');
    const form = (path: string) => `<form action="${path}" method="post" target="sink"><input name="x" value="1"><button>Pay</button></form>`;
    // Before arming: a widget with a form in a nested open shadow root.
    await page.evaluate((html: string) => {
      const host = document.createElement('div'); document.body.appendChild(host);
      const outer = host.attachShadow({ mode: 'open' });
      const inner = document.createElement('div'); outer.appendChild(inner);
      inner.attachShadow({ mode: 'open' }).innerHTML = html;
      (window as any).__early = inner.shadowRoot;
    }, form('/checkout/early'));
    await page.evaluate(GUARD_ARM_SCRIPT);
    await page.evaluate(({ a, b, c }: any) => {
      (window as any).__early.querySelector('button').click();
      const h1 = document.createElement('div'); document.body.appendChild(h1);
      const open = h1.attachShadow({ mode: 'open' }); open.innerHTML = a;
      open.querySelector('button')!.click();
      const h2 = document.createElement('div'); document.body.appendChild(h2);
      const closed = h2.attachShadow({ mode: 'closed' }); closed.innerHTML = b;
      (closed.querySelector('form') as HTMLFormElement).requestSubmit();
      const h3 = document.createElement('div'); document.body.appendChild(h3);
      const fine = h3.attachShadow({ mode: 'open' }); fine.innerHTML = c;
      fine.querySelector('button')!.click();
    }, { a: form('/checkout/open'), b: form('/payment/closed'), c: form('/search') });
    await page.waitForTimeout(500);
    expect(reached).toEqual(['/search']);
    await ctx.close();
  });

  it('keeps Worker and SharedWorker subclasses working, armed or not', async () => {
    const s = await armedPage();
    const got = await s.run(`
      class W2 extends Worker { hi() { return 'hi'; } }
      const w = new W2('/w.js');
      const echo = await new Promise((r) => { w.onmessage = (e) => r(e.data); w.postMessage('echo'); });
      w.terminate();
      class S2 extends SharedWorker { hi() { return 'hi'; } }
      const sw = new S2('/w.js');
      class B2 extends Worker {}
      return { hi: w.hi(), sub: w instanceof W2, base: w instanceof Worker, echo, shared: sw.hi() + (sw instanceof S2) + (sw.port ? ' port' : ''),
        blob: await t(() => new B2(URL.createObjectURL(new Blob(['1'], { type: 'text/javascript' })))),
        plain: Object.getPrototypeOf(new Worker('/w.js')) === Worker.prototype };`);
    expect(got).toEqual({ hi: 'hi', sub: true, base: true, echo: 'echo', shared: 'hitrue port', blob: 'blocked_worker', plain: true });
    await s.ctx.close();
  });

  it('sends a synchronous XHR with a Blob or buffer body at once, and still judges its path', async () => {
    const s = await armedPage();
    const got = await s.run(`
      const sync = (path, body) => { const x = new XMLHttpRequest(); x.open('POST', path, false); x.send(body); return x.status + ' ' + x.responseText; };
      return {
        u8: sync('/api/sync', new Uint8Array([104, 105])),
        blob: sync('/api/sync2', new Blob(['yo'])),
        blocked: await t(() => sync('/checkout/sync', new Blob(['x']))),
        asyncBlob: await t(() => new Promise((ok, no) => { const x = new XMLHttpRequest(); x.open('POST', '/api/async'); x.onload = () => ok(x.responseText); x.onerror = no; x.send(new Blob(['{"operationName":"PlaceOrder"}'])); setTimeout(() => ok('never sent'), 500); })),
      };`);
    expect(got).toEqual({ u8: '200 ok hi', blob: '200 ok yo', blocked: 'blocked_path', asyncBlob: 'sent' });
    // The async Blob naming PlaceOrder was read, then refused: it never went.
    expect(s.reached).toEqual(['POST /api/sync', 'POST /api/sync2']);
    await s.ctx.close();
  });

  it("fires the page's formdata listener once per submission", async () => {
    const s = await armedPage();
    const got = await s.run(`
      // Each form posts into its own frame: Chrome itself builds the entry list
      // again when a second submission lands on a frame still navigating.
      const make = () => { const f = document.createElement('form'); f.method = 'POST'; f.action = '/search';
        const fr = document.createElement('iframe'); fr.name = 'sink' + Math.random(); document.body.appendChild(fr); f.target = fr.name;
        f.innerHTML = '<input name="q" value="milk"><button>go</button>'; document.body.appendChild(f);
        let n = 0; f.addEventListener('formdata', (e) => { n++; e.formData.append('nonce', String(n)); }); return { f, n: () => n }; };
      const a = make(); a.f.querySelector('button').click(); await wait(200);
      const b = make(); b.f.submit(); await wait(200);
      const c = make(); let sent = null;
      c.f.addEventListener('submit', (e) => { e.preventDefault(); sent = new FormData(c.f).getAll('nonce').join(','); });
      c.f.requestSubmit();
      return { click: a.n(), submit: b.n(), handled: c.n(), sent };`);
    expect(got).toEqual({ click: 1, submit: 1, handled: 1, sent: '1' });
    await s.page.waitForTimeout(200);
    expect(s.reached).toEqual(['POST /search', 'POST /search']);
    await s.ctx.close();
  });

  it('still refuses a checkout form the page lets go, and a GraphQL mutation in its fields', async () => {
    const s = await armedPage();
    await s.run(`
      const f = document.createElement('form'); f.method = 'POST'; f.action = '/graphql'; f.target = 'sink';
      f.innerHTML = '<textarea name="query">mutation { placeOrder { id } }</textarea><button>go</button>';
      f.addEventListener('submit', () => {}); document.body.appendChild(f);
      f.querySelector('button').click();
      const g = document.createElement('form'); g.method = 'POST'; g.action = '/graphql'; g.target = 'sink';
      g.innerHTML = '<input name="x" value="1"><button name="operationName" value="PlaceOrder">go</button>'; document.body.appendChild(g);
      g.querySelector('button').click();
      await wait(300);`);
    expect(s.reached).toEqual([]);
    await s.ctx.close();
  });
});
