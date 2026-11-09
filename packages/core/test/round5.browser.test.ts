// 0.6 round 5, item 1: the guard is installed early but stays off until a
// Mealio script runs, never runs in a cross-origin frame, and once armed
// closes the setHTMLUnsafe, Range and document.write ways to a fresh frame.
// Real Chrome, as guard.browser.test.ts (skipped without Playwright).
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
  // No host resolves: a request the routes below miss (a sandboxed frame's
  // can) fails instead of reaching a real store.
  const args = ['--host-resolver-rules=MAP * ~NOTFOUND , EXCLUDE localhost'];
  for (const opts of [{ channel: 'chrome', args }, { args }]) {
    try { return await pw.chromium.launch(opts); } catch { /* try the next */ }
  }
  return null;
}

const browser = await launch(loadPlaywright());
if (!browser) console.warn('[round5.browser] skipped: no Playwright or Chrome (set MEALIO_PLAYWRIGHT)');

const M = JSON.stringify({ query: 'mutation { placeOrder { id } }' });
const T = `const t = async (f) => { try { await f(); return 'sent'; } catch (e) { return String(e && e.message || e).replace('mealio guard: ', ''); } };`;

/** A store page at https://www.heb.com/ with the guard at document start in every frame, as every SDK injects it. */
async function storePage(pages: Record<string, string>, opts: { initScript?: boolean } = {}) {
  const ctx = await browser.newContext();
  const reached: string[] = [];
  if (opts.initScript !== false) await ctx.addInitScript(GUARD_SCRIPT);
  const serve = async (r: any) => {
    const u = new URL(r.request().url());
    const key = u.host === 'www.heb.com' ? u.pathname : u.host + u.pathname;
    if (pages[key] !== undefined) return r.fulfill({ status: 200, contentType: key.endsWith('.js') ? 'text/javascript' : 'text/html', body: pages[key] });
    reached.push(key);
    return r.fulfill({ status: 200, contentType: 'application/json', body: '{}', headers: { 'access-control-allow-origin': '*' } });
  };
  await ctx.route('https://www.heb.com/**', serve);
  await ctx.route('https://challenges.cloudflare.com/**', serve);
  const page = await ctx.newPage();
  const run = (body: string) => page.evaluate(`(async () => { ${T} const M = ${JSON.stringify(M)}; ${body} })()`);
  return { ctx, page, reached, run };
}

describe.skipIf(!browser)('round 5: the guard arms when Mealio uses the page', () => {
  afterAll(async () => { await browser?.close(); });

  it('never runs in a cross-origin frame: a Turnstile-style blob worker works there, armed or not', async () => {
    // The challenge frame makes a blob: worker and fetches its own /payment
    // path, as Cloudflare's does, on load and again when asked.
    const challenge = `<script>
      function go() {
        var out = { guard: typeof window.__mealioGuard, arm: typeof window.__mealioArm };
        var src = 'postMessage("pow")';
        try {
          var w = new Worker(URL.createObjectURL(new Blob([src], { type: 'text/javascript' })));
          w.onmessage = function (e) {
            out.worker = e.data;
            fetch('/payment/pat', { method: 'POST' }).then(function () { out.fetch = 'sent'; }, function (e) { out.fetch = String(e.message); })
              .then(function () { parent.postMessage(out, '*'); });
          };
        } catch (e) { out.worker = String(e.message); parent.postMessage(out, '*'); }
      }
      addEventListener('message', go); go();
    </script>`;
    const s = await storePage({
      '/': '<html><head><script>window.msgs = []; addEventListener("message", function (e) { msgs.push(e.data); });</script></head><body><iframe src="https://challenges.cloudflare.com/turnstile"></iframe></body></html>',
      'challenges.cloudflare.com/turnstile': challenge,
    });
    await s.page.goto('https://www.heb.com/');
    await s.page.waitForFunction('msgs.length === 1');
    const want = { guard: 'undefined', arm: 'undefined', worker: 'pow', fetch: 'sent' };
    expect(await s.page.evaluate('msgs[0]')).toEqual(want);
    await s.page.evaluate(GUARD_ARM_SCRIPT);
    await s.page.evaluate(`frames[0].postMessage('again', '*')`);
    await s.page.waitForFunction('msgs.length === 2');
    expect(await s.page.evaluate('msgs[1]')).toEqual(want);
    expect(s.reached.filter((p) => p.includes('/payment/pat'))).toHaveLength(2);
    await s.ctx.close();
  });

  it('leaves the store\'s boot alone (its worker, its /payment fetches, its traffic volume), then blocks once armed', async () => {
    const boot = `<script>
      window.boot = { fetches: 0 };
      var w = new Worker(URL.createObjectURL(new Blob(['postMessage("boot worker")'], { type: 'text/javascript' })));
      w.onmessage = function (e) { window.boot.worker = e.data; };
      fetch('/api/payment/config').then(function () { window.boot.payment = 'sent'; }, function (e) { window.boot.payment = e.message; });
      var x = new XMLHttpRequest(); x.open('POST', '/graphql'); x.send(${JSON.stringify(M)}); window.boot.xhr = 'sent';
      for (var i = 0; i < 250; i++) fetch('/api/boot/' + i).then(function () { window.boot.fetches++; }, function () {});
    </script>`;
    const s = await storePage({ '/': `<html><head>${boot}</head><body></body></html>` });
    await s.page.goto('https://www.heb.com/');
    await s.page.waitForFunction('window.boot.fetches === 250 && window.boot.worker && window.boot.payment');
    expect(await s.page.evaluate('window.boot')).toEqual({ fetches: 250, worker: 'boot worker', payment: 'sent', xhr: 'sent' });
    expect(s.reached).toContain('/api/payment/config');
    expect(s.reached).toContain('/graphql');
    await s.page.evaluate(GUARD_ARM_SCRIPT);
    const out = await s.run(`return {
      after: await t(() => fetch('/api/after')),
      payment: await t(() => fetch('/api/payment/config')),
      body: await t(() => fetch('/graphql', { method: 'POST', body: M })),
      worker: await t(() => new Worker(URL.createObjectURL(new Blob(['1'], { type: 'text/javascript' })))),
    };`);
    // The 250 boot requests did not count toward the 240 a minute.
    expect(out).toEqual({ after: 'sent', payment: 'blocked_path', body: 'blocked_operation', worker: 'blocked_worker' });
    await s.ctx.close();
  });

  it('arming arms the frames the page already has, nested ones too, and frames that load later', async () => {
    const s = await storePage({
      '/': '<html><body><iframe src="/frame"></iframe></body></html>',
      '/frame': '<html><body><iframe></iframe></body></html>',
      '/later': '<html><body>later</body></html>',
    });
    await s.page.goto('https://www.heb.com/');
    const send = (k: string) => `await t(() => ${k}.fetch('/checkout/x', { method: 'POST' }))`;
    const before = await s.run(`
      const a = document.createElement('iframe'); document.body.appendChild(a);
      return { top: ${send('window')}, frame: ${send('frames[0]')}, nested: ${send('frames[0].frames[0]')}, added: ${send('frames[1]')}, armed: window.__mealioArmed() };
    `);
    expect(before).toEqual({ top: 'sent', frame: 'sent', nested: 'sent', added: 'sent', armed: false });
    await s.page.evaluate(GUARD_ARM_SCRIPT);
    const after = await s.run(`
      const b = document.createElement('iframe'); b.src = '/later'; document.body.appendChild(b);
      await new Promise((r) => b.addEventListener('load', r));
      return { top: ${send('window')}, frame: ${send('frames[0]')}, nested: ${send('frames[0].frames[0]')}, added: ${send('frames[1]')}, later: ${send('frames[2]')} };
    `);
    expect(after).toEqual({ top: 'blocked_path', frame: 'blocked_path', nested: 'blocked_path', added: 'blocked_path', later: 'blocked_path' });
    expect(s.reached.filter((p) => p.includes('checkout'))).toHaveLength(4);
    // The page cannot turn it off or swap the switch.
    const tamper = await s.run(`
      try { window.__mealioArm = () => {}; window.__mealioArmed = () => false; delete window.__mealioArm; } catch (e) {}
      return { armed: window.__mealioArmed(), send: ${send('window')} };
    `);
    expect(tamper).toEqual({ armed: true, send: 'blocked_path' });
    await s.ctx.close();
  });

  it('once armed, blocks a frame made by setHTMLUnsafe, a shadow root, a Range, execCommand or document.write', async () => {
    const s = await storePage({ '/': '<html><body><div id="h"></div></body></html>' }, { initScript: false });
    await s.page.goto('https://www.heb.com/');
    // The Android path: no document-start copy, only the per-script one.
    await s.page.evaluate(GUARD_ARM_SCRIPT);
    const out = await s.run(`
      const last = () => window[window.length - 1];
      const box = () => { const b = document.createElement('div'); document.body.appendChild(b); return b; };
      const send = (w) => t(() => (w || last()).fetch('/checkout/r5', { method: 'POST', body: M }));
      const r = {};
      box().setHTMLUnsafe('<iframe></iframe>'); r.setHTMLUnsafe = await send();
      // A frame in a shadow tree is not in window.frames: only its element reaches it.
      { const sr = box().attachShadow({ mode: 'open' }); sr.setHTMLUnsafe('<iframe></iframe>'); r.shadowSetHTMLUnsafe = await send(sr.querySelector('iframe').contentWindow); }
      { const sr = box().attachShadow({ mode: 'open' }); sr.innerHTML = '<iframe></iframe>'; r.shadowInnerHTML = await send(sr.querySelector('iframe').contentWindow); }
      { const g = document.createRange(); g.selectNodeContents(box()); g.insertNode(document.createElement('iframe')); } r.rangeInsertNode = await send();
      { const b = box(); b.appendChild(document.createElement('span')); const g = document.createRange(); g.selectNodeContents(b); g.surroundContents(document.createElement('iframe')); } r.surroundContents = await send();
      { const d = document.getElementById('h'); d.contentEditable = 'true'; d.focus(); document.execCommand('insertHTML', false, '<iframe></iframe>'); } r.execCommand = await send();
      { const a = document.createElement('iframe'); document.body.appendChild(a); a.contentDocument.write('<iframe></iframe>'); r.frameWrite = await send(a.contentWindow.frames[0]); }
      { const a = document.createElement('iframe'); document.body.appendChild(a); a.contentDocument.writeln('<iframe></iframe>'); r.frameWriteln = await send(a.contentWindow.frames[0]); }
      return r;
    `);
    expect(Object.keys(out)).toHaveLength(8);
    expect(out).toEqual(Object.fromEntries(Object.keys(out).map((k) => [k, 'blocked_path'])));
    // Last, as it replaces the page: document.write on the loaded top document, then frames[n].fetch.
    const write = await s.run(`
      document.write('<body><iframe></iframe></body>');
      const r = await t(() => frames[0].fetch('/graphql', { method: 'POST', body: M }));
      document.close();
      return r;
    `);
    expect(write).toBe('blocked_operation');
    expect(s.reached.filter((p) => p.includes('checkout') || p.includes('graphql'))).toEqual([]);
    await s.ctx.close();
  });
});
