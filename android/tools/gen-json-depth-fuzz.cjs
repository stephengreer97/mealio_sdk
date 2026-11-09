// Writes mealio-sdk/src/test/resources/json-depth-fuzz.json: random, mostly
// nested JSON-ish text, with what TS parseJson (packages/core/src/matcher.ts)
// makes of it at depth limit 3 and what JSON.parse makes of it. JsonParityTest
// checks StrictJson against it. Run from android/: node tools/gen-json-depth-fuzz.cjs
const path = require('path'), fs = require('fs');
const root = path.join(__dirname, '..', '..');
const esbuild = require(path.join(root, 'node_modules', 'esbuild'));
const r = esbuild.buildSync({ entryPoints: [path.join(root, 'packages/core/src/matcher.ts')], bundle: true, write: false, format: 'cjs', platform: 'node' });
const m = { exports: {} };
new Function('module', 'exports', 'require', r.outputFiles[0].text)(m, m.exports, require);
const { parseJson } = m.exports;
let seed = 6; const rnd = () => (seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff;
const pick = (a) => a[Math.floor(rnd() * a.length)];
const atoms = ['[', '[', '{', '{', ']', ']', '}', '}', ',', ',', ':', '"a"', '"a":', '1', '1e400', '-0', 'true', 'null', '"\\""', '"\\\\"', '"]"', '"}"', '"\\ud800"', ' ', '\n', '01', '"', '\\', '.5'];
// Numbers are '#': Kotlin keeps doubles, JS numbers print differently.
const shape = (v) => v === null ? 'null' : Array.isArray(v) ? '[' + v.map(shape).join(',') + ']'
  : typeof v === 'object' ? '{' + Object.keys(v).map(k => JSON.stringify(k) + ':' + shape(v[k])).join(',') + '}'
  : typeof v === 'number' ? '#' : JSON.stringify(v);
const gen = () => {
  const d = 3 + Math.floor(rnd() * 4);
  const val = (lvl) => {
    const x = rnd();
    if (lvl >= d || x < 0.25) return pick(['1', '"s"', 'null', 'true', '1e400', '"]"', '"\\\\"']);
    const n = Math.floor(rnd() * 3), a = [];
    if (x < 0.6) { for (let i = 0; i < n; i++) a.push(val(lvl + 1)); return '[' + a.join(',') + ']'; }
    for (let i = 0; i < n; i++) a.push(JSON.stringify(pick(['a', 'b', 'k'])) + ':' + val(lvl + 1));
    return '{' + a.join(',') + '}';
  };
  return val(0);
};
const out = [];
while (out.length < 6000) {
  let s = gen();
  const x = rnd();
  if (x < 0.6) { // damage it, often inside the too-deep part
    const n = 1 + Math.floor(rnd() * 2);
    for (let k = 0; k < n; k++) { const p = Math.floor(rnd() * (s.length + 1)); s = rnd() < 0.6 ? s.slice(0, p) + pick(atoms) + s.slice(p) : s.slice(0, p) + s.slice(p + 1); }
  }
  let full, lim;
  try { JSON.parse(s); full = 'ok'; } catch { full = 'bad'; }
  try { lim = shape(parseJson(s, 3)); } catch { lim = null; }
  out.push({ s, full, lim });
}
fs.writeFileSync(path.join(__dirname, '..', 'mealio-sdk/src/test/resources/json-depth-fuzz.json'), JSON.stringify(out));
console.log(out.length, 'cases;', out.filter(o => o.lim !== null && o.full === 'bad').length, 'accepted only past the limit');
