// 0.6 round 5: body limits (item 2), message depth (item 3) and which guard
// copy a host is handed (item 1). The guard's browser behavior is in
// round5.browser.test.ts.
import { describe, it, expect } from 'vitest';
import vm from 'node:vm';
import crypto from 'node:crypto';
import vectors from '../../../protocol/test-vectors.json';
import {
  Allowlist, BODY_MAX_DEPTH, BODY_MAX_TEXT, GUARD_ARM, GUARD_ARM_SCRIPT, GUARD_SCRIPT, MESSAGE_MAX_DEPTH, Runner, bodyBlocked, matches, parseJson, parseMessage,
  type Envelope, type Host,
} from '../src';

type Limit = { rule: string; prefix: string; fill: string; times: number; suffix: string; blocked: boolean };
const limits = (vectors as any).bodyLimits as Limit[];
const bodyOf = (v: Limit) => v.prefix + v.fill.repeat(v.times) + v.suffix;

type Deep = { prefix: string; open: string; close: string; times: number; suffix: string; depth: number; keep: number };
const deep = (vectors as any).deepMessages as Deep[];
const messageOf = (v: Deep) => v.prefix + v.open.repeat(v.times) + v.close.repeat(v.times) + v.suffix;

/** Nesting depth of a parsed value, without recursion (an empty container is one level). */
function depthOf(v: unknown): number {
  let max = 0;
  const stack: [unknown, number][] = [[v, 1]];
  while (stack.length) {
    const [x, d] = stack.pop()!;
    if (!x || typeof x !== 'object') continue;
    if (d > max) max = d;
    for (const c of Object.values(x as object)) stack.push([c, d + 1]);
  }
  return max;
}

describe('round 5: request body limits', () => {
  it('the limits are the protocol\'s', () => {
    expect(BODY_MAX_DEPTH).toBe(8);
    expect(BODY_MAX_TEXT).toBe(1048576);
    expect(new Set(limits.map((v) => v.rule))).toEqual(new Set(['depth', 'size']));
  });

  it('bodyBlocked follows every bodyLimits vector, quickly and without deep recursion', () => {
    for (const v of limits) {
      const t0 = Date.now();
      expect(bodyBlocked(bodyOf(v)), `${v.rule} ${v.times}× ${JSON.stringify(v.fill)} ${v.suffix.slice(0, 30)}`).toBe(v.blocked);
      expect(Date.now() - t0).toBeLessThan(2000);
    }
  });

  it('the guard script follows them too', async () => {
    const win: any = { location: { href: 'https://www.heb.com/' }, encodeURIComponent };
    win.fetch = () => Promise.resolve('ok');
    win.window = win;
    vm.createContext(win);
    vm.runInContext(GUARD_ARM_SCRIPT, win);
    for (const v of limits) {
      const got = await win.fetch('/graphql', { method: 'POST', body: bodyOf(v) }).then(() => false, () => true);
      expect(got, `${v.rule} ${v.times}× ${v.suffix.slice(0, 30)}`).toBe(v.blocked);
    }
  });
});

describe('round 5: messages are built at most 512 deep', () => {
  it('parseMessage keeps a too-deep container empty, and the message stays usable', () => {
    expect(MESSAGE_MAX_DEPTH).toBe(512);
    for (const v of deep) {
      const raw = messageOf(v);
      const msg = parseMessage(raw);
      const what = `${v.open}×${v.times}`;
      expect(msg, what).not.toBeNull();
      expect(depthOf(msg), what).toBe(v.depth);
      expect(msg!.keep, what).toBe(v.keep);
      // What the runner does with it next: match it, and send it to the server.
      expect(matches(msg!, { type: 'X', eq: { keep: 1 } }), what).toBe(true);
      expect(() => JSON.stringify(msg), what).not.toThrow();
    }
  });

  it('is JSON.parse for anything not too deep, strings with brackets in them included', () => {
    for (const s of ['{"a":"[[{{\\"]]"}', '[1,{"b":[2,"}"]}]', '"x"', '3', 'null', '{"a":"\\\\"}']) expect(parseJson(s)).toEqual(JSON.parse(s));
    for (const s of ['{', '[1,', '{"a":}', '[' + '['.repeat(600) + ']'.repeat(599)]) expect(() => parseJson(s), s).toThrow();
    expect(parseMessage('[' + '['.repeat(600) + ']'.repeat(600) + ']')).toBeNull(); // not an object
  });
});

// The test key from protocol/make-vectors.mjs, to sign a show_login envelope.
const seed = Buffer.alloc(32, 7);
const key = crypto.createPrivateKey({ key: Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), seed]), format: 'der', type: 'pkcs8' });
function signed(instructions: object[]): Envelope {
  const payload = JSON.stringify({ v: 1, kind: 'instructions', job: 'job_test', seq: 1, exp: 4102444800, store: 'heb', instructions });
  return { payload, sig: crypto.sign(null, Buffer.from(payload), key).toString('base64'), kid: 'ktest' };
}

describe('round 5: which guard copy a host gets', () => {
  it('GUARD_ARM_SCRIPT is GUARD_SCRIPT then the arm call', () => {
    expect(GUARD_ARM).toBe('window.__mealioArm(); true;');
    expect(GUARD_ARM_SCRIPT).toBe(`${GUARD_SCRIPT}\n${GUARD_ARM}`);
  });

  it('page_script gets the arming copy; show_login gets the document-start copy and the arming copy', async () => {
    const seen: Record<string, string> = {};
    const host: Host = {
      async openPage() { return { ok: true }; },
      async runScript(_s, guard) { seen.runScript = guard; return { messages: [], timedOut: false }; },
      async showLogin(o) { seen.loginGuard = o.guard; seen.loginArm = o.armGuard; return { outcome: 'signed_in', messages: [] }; },
      async fetch() { return { ok: true, status: 200, body: '{}' }; },
    };
    const env = signed([
      { op: 'page_script', id: 'i1', script: 'true;', until: [], timeoutMs: 1000 },
      { op: 'show_login', id: 'i2', url: 'https://www.heb.com/login', title: 'Sign in', check: { script: 'true;', intervalMs: 3000 }, doneWhen: [], timeoutMs: 1000 },
    ]);
    await new Runner(host, new Allowlist(), { [vectors.kid]: vectors.publicKey }).run(env, 'job_test', 0);
    expect(seen).toEqual({ runScript: GUARD_ARM_SCRIPT, loginGuard: GUARD_SCRIPT, loginArm: GUARD_ARM_SCRIPT });
  });

  it('GUARD_SCRIPT alone checks nothing; the arm call turns every check on', async () => {
    const sent: string[] = [];
    const win: any = { location: { href: 'https://www.heb.com/' }, encodeURIComponent };
    win.fetch = (u: string) => { sent.push(u); return Promise.resolve('ok'); };
    win.window = win;
    vm.createContext(win);
    vm.runInContext(GUARD_SCRIPT, win);
    await win.fetch('/checkout/a', { method: 'POST' });
    for (let i = 0; i < 300; i++) await win.fetch('/boot');
    expect(vm.runInContext('window.__mealioArmed()', win)).toBe(false);
    vm.runInContext(GUARD_ARM, win);
    expect(vm.runInContext('window.__mealioArmed()', win)).toBe(true);
    await expect(win.fetch('/checkout/b', { method: 'POST' })).rejects.toThrow(/blocked_path/);
    await expect(win.fetch('/after')).resolves.toBe('ok'); // the 301 before arming did not count
    expect(sent.filter((u) => u.startsWith('/checkout'))).toEqual(['/checkout/a']);
  });
});
