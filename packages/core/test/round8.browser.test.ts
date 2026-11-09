// 0.6 round 8: forms in the in-page guard, in real Chrome. A submit event is
// judged in the capture phase and refused with preventDefault only, so a page
// handler that stops propagation cannot hide a blocked form, and the page's
// own handlers always run. A form with no action posts back to its page and
// is judged by its fields only. submit() and requestSubmit() throw for a
// blocked explicit target or blocked fields. Skipped without Playwright, as
// the other browser tests. Nothing here reaches the network.
import { describe, it, expect, afterAll } from 'vitest';
import { createRequire } from 'node:module';
import path from 'node:path';
import * as guardModule from '../src/guard';

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
if (!browser) console.warn('[round8.browser] skipped: no Playwright or Chrome (set MEALIO_PLAYWRIGHT)');

const PAGE = `<!doctype html><html><body><iframe name="sink"></iframe>
<script>
customElements.define('x-card', class extends HTMLElement {
  constructor() { super(); this.attachShadow({ mode: 'open' }).innerHTML = '<div class="frame"><slot></slot></div>'; }
});
customElements.define('x-closed', class extends HTMLElement {
  constructor() { super(); window.__closed = this.attachShadow({ mode: 'closed' }); }
});
</script></body></html>`;

/** A sign-in page at `start` whose query names checkout, guard at document start, armed. */
async function armedPage(start: string) {
  const ctx = await browser.newContext();
  const reached: string[] = [];
  await ctx.addInitScript(GUARD_SCRIPT);
  await ctx.route('https://www.heb.com/**', async (r: any) => {
    const req = r.request();
    const u = new URL(req.url());
    if (req.method() === 'GET' && u.pathname === '/login') return r.fulfill({ status: 200, contentType: 'text/html', body: PAGE });
    reached.push(`${req.method()} ${u.pathname}${u.search}`);
    return r.fulfill({ status: 200, contentType: 'text/plain', body: `ok ${req.postData() ?? ''}` });
  });
  const page = await ctx.newPage();
  await page.goto('https://www.heb.com' + start);
  await page.evaluate(GUARD_ARM_SCRIPT);
  const run = (body: string) => page.evaluate(`(async () => {
    const t = async (f) => { try { await f(); return 'sent'; } catch (e) { return String(e && e.message || e).replace('mealio guard: ', ''); } };
    const wait = (ms) => new Promise((r) => setTimeout(r, ms));
    ${body} })()`);
  return { ctx, page, reached, run };
}

describe.skipIf(!browser)('round 8: forms in the guard', () => {
  afterAll(async () => { await browser?.close(); });

  it('refuses a blocked form whose own handler stops propagation, and still runs that handler', async () => {
    const s = await armedPage('/login');
    const got = await s.run(`
      const out = { light: 0, shadow: 0, prevented: [] };
      // Each form posts into its own frame: a second submission into one frame cancels the first.
      for (const n of ['s1', 's2', 's3']) { const fr = document.createElement('iframe'); fr.name = n; document.body.appendChild(fr); }
      const f = document.createElement('form'); f.method = 'POST'; f.action = '/checkout/sp'; f.target = 's1';
      f.innerHTML = '<input name="a" value="1"><button>Pay</button>'; document.body.appendChild(f);
      f.addEventListener('submit', (e) => { out.light++; out.prevented.push(e.defaultPrevented); e.stopPropagation(); });
      f.querySelector('button').click();
      const g = document.createElement('form'); g.method = 'POST'; g.action = '/payment/si'; g.target = 's2';
      g.innerHTML = '<input name="a" value="1"><button>Pay</button>'; document.body.appendChild(g);
      g.addEventListener('submit', (e) => { out.light++; e.stopImmediatePropagation(); });
      g.querySelector('button').click();
      const host = document.createElement('x-closed'); document.body.appendChild(host);
      window.__closed.innerHTML = '<form method="post" action="/checkout/closed" target="s3"><button>Pay</button></form>';
      const cf = window.__closed.querySelector('form');
      cf.addEventListener('submit', (e) => { out.shadow++; e.stopPropagation(); });
      cf.querySelector('button').click();
      await wait(400);
      return out;`);
    expect(s.reached).toEqual([]);
    expect(got).toEqual({ light: 2, shadow: 1, prevented: [true] });
    await s.ctx.close();
  });

  it("runs the page's handler for a slotted sign-in form on /login?returnUrl=%2Fcheckout, and its fetch goes out", async () => {
    const s = await armedPage('/login?returnUrl=%2Fcheckout');
    const got = await s.run(`
      let js = 0;
      document.addEventListener('submit', (e) => {
        if (e.target.id !== 'slot') return;
        e.preventDefault(); js++;
        fetch('/api/login', { method: 'POST', body: 'u' });
      });
      const card = document.createElement('x-card'); document.body.appendChild(card);
      card.innerHTML = '<form id="slot" method="post" target="sink"><input name="user" value="u"><button id="go">Sign in</button></form>';
      document.getElementById('go').click();
      await wait(400);
      return js;`);
    expect(got).toBe(1);
    expect(s.reached).toEqual(['POST /api/login']);
    await s.ctx.close();
  });

  it('lets a form with no action post back to its page, judged by its fields only', async () => {
    const s = await armedPage('/login?returnUrl=%2Fcheckout');
    const got = await s.run(`
      const make = (html) => { const f = document.createElement('form'); f.method = 'POST'; f.target = 'sink'; f.innerHTML = html; document.body.appendChild(f); return f; };
      make('<input name="user" value="u"><button>Sign in</button>').querySelector('button').click();
      await wait(300);
      const out = {};
      out.submit = await t(() => make('<input name="user" value="v">').submit());
      await wait(300);
      out.requestSubmit = await t(() => make('<input name="user" value="w">').requestSubmit());
      await wait(300);
      const blank = make('<input name="user" value="x">'); blank.setAttribute('action', '  ');
      out.blankAction = await t(() => blank.submit());
      await wait(300);
      out.badFields = await t(() => make('<input name="operationName" value="PlaceOrder">').submit());
      make('<input name="operationName" value="PlaceOrder"><button>go</button>').querySelector('button').click();
      await wait(300);
      return out;`);
    expect(got).toEqual({ submit: 'sent', requestSubmit: 'sent', blankAction: 'sent', badFields: 'blocked_operation' });
    expect(s.reached).toEqual(Array(4).fill('POST /login?returnUrl=%2Fcheckout'));
    await s.ctx.close();
  });

  it('submit() and requestSubmit() throw for a blocked explicit target, even from inside a submit handler', async () => {
    const s = await armedPage('/login');
    const got = await s.run(`
      const make = (action) => { const f = document.createElement('form'); f.method = 'POST'; f.action = action; f.target = 'sink';
        f.innerHTML = '<input name="a" value="1"><button>go</button>'; document.body.appendChild(f); return f; };
      const out = {};
      out.requestSubmit = await t(() => make('/checkout/rs').requestSubmit());
      const f = make('/search'); f.querySelector('button').setAttribute('formaction', '/checkout/fa');
      out.formaction = await t(() => f.requestSubmit(f.querySelector('button')));
      const pd = make('/checkout/pd'); out.pd = null;
      pd.addEventListener('submit', (e) => { e.preventDefault(); try { e.target.submit(); out.pd = 'sent'; } catch (x) { out.pd = String(x.message).replace('mealio guard: ', ''); } });
      pd.querySelector('button').click();
      out.fine = await t(() => make('/search').requestSubmit());
      await wait(300);
      return out;`);
    expect(got).toEqual({ requestSubmit: 'blocked_path', formaction: 'blocked_path', pd: 'blocked_path', fine: 'sent' });
    expect(s.reached).toEqual(['POST /search']);
    await s.ctx.close();
  });
});
