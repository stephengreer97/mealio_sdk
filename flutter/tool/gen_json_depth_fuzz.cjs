// node flutter/tool/gen_json_depth_fuzz.cjs: writes
// flutter/test/fixtures/json-depth-fuzz.json, what TypeScript parseJson
// (packages/core/src/matcher.ts) makes of fuzzed text at depth limits 3 and
// 512. json_depth_parity_test.dart checks decodeJsonLimited against it.
const path = require('path'), fs = require('fs');
const repo = path.join(__dirname, '../..');
const esbuild = require(path.join(repo, 'node_modules/esbuild'));
const r = esbuild.buildSync({ entryPoints: [path.join(repo, 'packages/core/src/matcher.ts')], bundle: true, write: false, format: 'cjs', platform: 'node' });
const m = { exports: {} };
new Function('module', 'exports', 'require', r.outputFiles[0].text)(m, m.exports, require);
const { parseJson } = m.exports;

let seed = 6061;
const rnd = () => (seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff;
const pick = (a) => a[Math.floor(rnd() * a.length)];
const atoms = ['[', '{', ']', '}', ',', ':', '"a"', '"a":', '"b":', '1', '-1.5e3', '1e400', '-0', 'true', 'null', '"\\""', '"\\\\"', '"]"', '"}"', '"["', '"\\u0041"', '"\\ud800"', ' ', '\n', '\t', '\f', '01', '"x\u0001"', 'tru', '"', '\\', '"\\x"', '.5', '1.', '2E+2', 'junk'];
const shape = (v) => v === null ? 'null' : Array.isArray(v) ? '[' + v.map(shape).join(',') + ']'
  : typeof v === 'object' ? '{' + Object.keys(v).map((k) => JSON.stringify(k) + ':' + shape(v[k])).join(',') + '}'
  : typeof v === 'number' ? '#' : JSON.stringify(v);
const indexKey = (v) => v !== null && typeof v === 'object' && (Array.isArray(v) ? v.some(indexKey) : Object.keys(v).some((k) => /^(0|[1-9]\d*)$/.test(k) || indexKey(v[k])));
const gen = () => {
  const d = Math.floor(rnd() * 9);
  const val = (lvl) => {
    const r = rnd();
    if (lvl >= d || r < 0.25) return pick(['1', '"s"', 'null', 'true', '-2.5', '"\\ud83d"', '1e400', '"]"', '"{"', '"\\"]"']);
    const n = Math.floor(rnd() * 3), a = [];
    if (r < 0.62) { for (let i = 0; i < n; i++) a.push(val(lvl + 1)); return '[' + a.join(',') + ']'; }
    for (let i = 0; i < n; i++) a.push(JSON.stringify(pick(['a', 'b', '__proto__', 'k'])) + ':' + val(lvl + 1));
    return '{' + a.join(',') + '}';
  };
  return val(0);
};
const mutate = (s, times) => {
  for (let k = 0; k < times; k++) {
    const p = Math.floor(rnd() * (s.length + 1));
    s = rnd() < 0.5 ? s.slice(0, p) + pick(atoms) + s.slice(p) : s.slice(0, p) + s.slice(p + 1);
  }
  return s;
};
const texts = [];
for (let i = 0; i < 24000; i++) {
  const r = rnd();
  if (r < 0.35) texts.push(gen());
  else if (r < 0.75) texts.push(mutate(gen(), 1 + Math.floor(rnd() * 2)));
  else { let s = ''; const n = 1 + Math.floor(rnd() * 14); for (let k = 0; k < n; k++) s += pick(atoms); texts.push(s); }
}
// Deeper than 512, with text that is not JSON inside the part kept empty.
for (let i = 0; i < 40; i++) {
  const depth = 510 + Math.floor(rnd() * 8), inner = mutate('[1,{"a":"]"}]', 1 + Math.floor(rnd() * 3));
  texts.push('{"type":"x","v":' + '['.repeat(depth) + inner + ']'.repeat(depth) + '}');
}
const run = (s, d) => { try { const v = parseJson(s, d); return indexKey(v) ? undefined : shape(v); } catch { return null; } };
const cases = [];
for (const s of texts) {
  const at3 = run(s, 3), at512 = run(s, 512);
  if (at3 === undefined || at512 === undefined) continue;
  cases.push([s, at3, at512]);
}
fs.writeFileSync(path.join(__dirname, '../test/fixtures/json-depth-fuzz.json'), JSON.stringify(cases));
console.log(cases.length, 'cases;', cases.filter((c) => c[1] !== null).length, 'parse at 3;', cases.filter((c) => c[2] !== null).length, 'at 512');
