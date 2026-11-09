// 0.6 round 6, item 3: the raw multipart scan is linear in the body, and finds
// exactly what MULTIPART_FIELD (the spec, as a regex) finds. Item 2's guard
// fixes that need no browser are here too; the rest are in round6.browser.
import { describe, it, expect } from 'vitest';
import vm from 'node:vm';
import vectors from '../../../protocol/test-vectors.json';
import { GUARD_ARM_SCRIPT, MULTIPART_FIELD, bodyBlocked, isJsSpace, multipartFields } from '../src';

type Scan = { prefix: string; fill: string; times: number; suffix: string; blocked: boolean };
const scans = (vectors as any).multipartScan as Scan[];
const bodyOf = (v: Scan) => v.prefix + v.fill.repeat(v.times) + v.suffix;

/** The spec: every match of MULTIPART_FIELD, flag g. */
function byRegex(s: string): Array<[string, string]> {
  const out: Array<[string, string]> = [];
  const re = new RegExp(MULTIPART_FIELD, 'g');
  for (let m = re.exec(s); m; m = re.exec(s)) out.push([m[1], m[2]]);
  return out;
}

/** Raw multipart-ish text, as the Android/Flutter audit's generator (genmp.cjs) makes it. */
function fuzz(count: number, seed: number): string[] {
  const rnd = () => (seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff;
  const pick = <T>(a: T[]) => a[Math.floor(rnd() * a.length)];
  const atoms = ['name=', 'name="', "name='", 'operations', 'operationName', 'query', 'operationsX', 'Query', '"', "'", ';', ' ', '\t', '\v', '\f',
    ' ', ' ', '　', '﻿', '​', '\u0085', '\r', '\n', '\r\n', '\r\r\n', '\n\n', '\r\n\r\n', '--', '\n--', '\r\n--', '-', 'X: y',
    'Content-Disposition: form-data; ', 'a', 'mutation{placeOrder{id}}', '{"query":"mutation{checkout}"}', 'PlaceOrder', '=', '&', '\u0000', 'é', '\ud800'];
  const NL = ['\r\n', '\n', '\r', '\r\r\n', '\n\r', ''];
  const part = () => {
    let s = pick(['name=', 'name="', "name='", 'name= ', 'xname=', 'name=="']) + pick(['operations', 'operationName', 'query', 'operationsX', 'Query', 'operation'])
      + pick(['"', "'", ';', ' ', '\t', '\v', ' ', '﻿', '​', 'x', '', '\r', '\n']) + pick(['', '; filename="a"', 'abc']) + pick(NL);
    const h = Math.floor(rnd() * 4);
    for (let k = 0; k < h; k++) s += pick(['X: y', 'Content-Type: a', '\r', '', 'a\rb']) + pick(NL);
    return s + pick(NL) + pick(['mutation{placeOrder{id}}', '{"query":"mutation{checkout}"}', 'PlaceOrder', '', 'a\n-', 'a\r\n-x', '\n--', 'x\r\n--y'])
      + pick(['', '\r\n--B', '\n--B', '\r--B', '\r\n-B', '--', pick(NL)]);
  };
  const out: string[] = [];
  for (let i = 0; i < count; i++) {
    let s = rnd() < 0.5 ? '--B\r\nContent-Disposition: form-data; ' : '';
    if (i % 2) { const n = 1 + Math.floor(rnd() * 20); for (let k = 0; k < n; k++) s += pick(atoms); }
    else { const n = 1 + Math.floor(rnd() * 3); for (let k = 0; k < n; k++) s += part(); }
    out.push(s);
  }
  return out;
}

function guardWindow() {
  const win: any = { location: { href: 'https://www.heb.com/' }, encodeURIComponent };
  win.fetch = () => Promise.resolve('ok');
  win.window = win;
  vm.createContext(win);
  vm.runInContext(GUARD_ARM_SCRIPT, win);
  return win;
}
const refused = (win: any, body: string) => win.fetch('/graphql', { method: 'POST', body }).then(() => false, () => true);

describe('round 6: the multipart scan', () => {
  it('isJsSpace is exactly JavaScript\'s \\s', () => {
    for (let c = 0; c <= 0xffff; c++) expect(isJsSpace(c), c.toString(16)).toBe(/\s/.test(String.fromCharCode(c)));
  });

  it('multipartFields finds exactly what the MULTIPART_FIELD regex finds', () => {
    const cases = [
      'name=query', 'name=query\n', 'name=query\n\n', 'name=query\r\n\r\n', 'name="query"\r\n\r\nX\r\n--', 'name=query\n\n\n--',
      'name=query\n\n\r\n--', 'name=queryname=query\n\nA', 'name=query\nH\n\nV\r\n--x\nname=operations\n\n{"query":"mutation{checkout}"}',
      'name=query\r\r\n\r\n', 'name=query\rX\n\nv', 'name=query\nH\rX\n\nv', 'name=\'query"\n\nv', 'name=""query\n\nv', 'name=query\n\n\r\n--',
      'name=query\nname=operationName\n\nPlaceOrder', 'name=query x\nname=operations\nY: z\n\n[]\n--b', ...fuzz(60000, 4242),
    ];
    let found = 0;
    for (const s of cases) {
      const want = byRegex(s);
      found += want.length;
      expect(multipartFields(s), JSON.stringify(s)).toEqual(want);
    }
    expect(found).toBeGreaterThan(3000); // the fuzz reaches real matches, not only misses
  });

  it('judges every multipartScan vector in well under a second', () => {
    expect(scans.length).toBeGreaterThan(0);
    for (const v of scans) {
      expect(bodyOf(v).length).toBeLessThanOrEqual(1048576);
      const t0 = Date.now();
      expect(bodyBlocked(bodyOf(v)), `${v.times}× ${JSON.stringify(v.fill)}`).toBe(v.blocked);
      expect(Date.now() - t0).toBeLessThan(1000);
    }
  });

  it('the guard script judges them the same way, as quickly', async () => {
    const win = guardWindow();
    for (const v of scans) {
      const t0 = Date.now();
      expect(await refused(win, bodyOf(v)), `${v.times}× ${JSON.stringify(v.fill)}`).toBe(v.blocked);
      expect(Date.now() - t0).toBeLessThan(1000);
    }
  });

  it('the guard script and bodyBlocked agree on fuzzed multipart bodies', async () => {
    let win = guardWindow();
    let blocked = 0, i = 0;
    for (const s of fuzz(20000, 777)) {
      if (++i % 200 === 0) win = guardWindow(); // under the 240-a-minute cap
      const want = bodyBlocked(s);
      if (want) blocked += 1;
      expect(await refused(win, s), JSON.stringify(s)).toBe(want);
    }
    expect(blocked).toBeGreaterThan(200);
  });
});

describe('round 6: guard bodies that are neither text nor a known type', () => {
  function guard() {
    const sent: unknown[] = [];
    const win: any = { location: { href: 'https://www.heb.com/' }, Blob, ArrayBuffer, URLSearchParams, FormData, ReadableStream, Request, encodeURIComponent };
    win.fetch = (_u: unknown, init?: any) => { sent.push(init?.body); return Promise.resolve('ok'); };
    win.window = win;
    vm.createContext(win);
    vm.runInContext(GUARD_ARM_SCRIPT, win);
    return { win, sent };
  }
  const PO = JSON.stringify({ operationName: 'PlaceOrder' });
  const outcome = (p: Promise<unknown>) => p.then(() => 'sent', () => 'refused');

  it('reads a String object and an object with toString as their text', async () => {
    const { win, sent } = guard();
    // eslint-disable-next-line no-new-wrappers
    expect(await outcome(win.fetch('/graphql', { method: 'POST', body: new String(PO) }))).toBe('refused');
    expect(await outcome(win.fetch('/graphql', { method: 'POST', body: { toString: () => PO } }))).toBe('refused');
    expect(sent).toEqual([]);
  });

  it('sends the text it judged: an object cannot show one text and send another', async () => {
    const { win, sent } = guard();
    let n = 0;
    const flip = { toString: () => (n++ === 0 ? '{"operationName":"Search"}' : PO) };
    expect(await outcome(win.fetch('/graphql', { method: 'POST', body: flip }))).toBe('sent');
    expect(sent).toEqual(['{"operationName":"Search"}']);
    // Nor can a getter on the options.
    let m = 0;
    const init = { method: 'POST', get body() { return m++ === 0 ? '{"operationName":"Search"}' : PO; } };
    expect(await outcome(win.fetch('/graphql', init))).toBe('sent');
    expect(sent[1]).toBe('{"operationName":"Search"}');
  });

  it('still passes Blob, FormData and stream bodies on as they are', async () => {
    const { win, sent } = guard();
    const blob = new Blob(['{"operationName":"Search"}']);
    const fd = new FormData();
    fd.append('operationName', 'Search');
    const stream = new ReadableStream();
    for (const b of [blob, fd, stream]) expect(await outcome(win.fetch('/graphql', { method: 'POST', body: b, duplex: 'half' }))).toBe('sent');
    expect(sent).toEqual([blob, fd, stream]);
  });
});
