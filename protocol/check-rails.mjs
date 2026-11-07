// Checks the blocked lists against the store rails, so a new blocked path or
// mutation name never stops a rail's own search or add. Read only.
//   npm run build -w @mealio/sdk-core
//   node protocol/check-rails.mjs [path to mealio_central/lib/cart-relay/stores]
// Exits 1 if any path the rails request, or any GraphQL they send, is blocked.
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';

const here = path.dirname(new URL(import.meta.url).pathname);
const require = createRequire(import.meta.url);
const { isBlockedPath, bodyBlocked } = require(path.join(here, '../packages/core/dist/allowlist.js'));
const esbuild = require('esbuild');

const dir = path.resolve(process.argv[2] || process.env.RAILS_DIR || path.join(here, '../../central-docs/lib/cart-relay/stores'));
const files = fs.readdirSync(path.join(dir, 'webview-scripts')).filter((f) => f.endsWith('.ts')).map((f) => path.join(dir, 'webview-scripts', f));
const bad = [];
let paths = 0, docs = 0, names = 0;

for (const file of files) {
  const text = fs.readFileSync(file, 'utf8');
  const short = path.relative(dir, file);
  // Every quoted path or same-store URL, with template holes filled in.
  for (const m of text.matchAll(/(['"`])((?:https:\/\/[^/'"`\s]+)?\/[^'"`\s]*)\1/g)) {
    const p = m[2].replace(/^https:\/\/[^/]+/, '').replace(/\$\{[^}]*\}/g, 'x');
    if (!/[a-z]/i.test(p)) continue;
    paths += 1;
    if (isBlockedPath(p)) bad.push(`${short}: path ${p}`);
  }
  // Operation names passed to the rails' GraphQL helpers.
  for (const m of text.matchAll(/(?:Gql\(|gql\(\s*'[^']*',\s*|operationName:\s*)'([A-Za-z_]\w*)'/g)) {
    names += 1;
    if (bodyBlocked(JSON.stringify({ operationName: m[1] }))) bad.push(`${short}: operation ${m[1]}`);
  }
}

// GraphQL documents written inline in a rail's script text, like the clear
// write in heb-network-search.ts: a quoted string that starts with `query` or
// `mutation`, joined with `+` to the quoted strings after it (comments between
// them allowed). A part that is not a quoted string ends the document there.
const LIT = String.raw`'(?:[^'\\\n]|\\.)*'|"(?:[^"\\\n]|\\.)*"`;
const GAP = String.raw`(?:\s|\/\/[^\n]*\n)*`;
const unquote = (q) => q.slice(1, -1).replace(/\\(.)/g, (_, c) => (c === 'n' ? '\n' : c));
function inlineDocs(text) {
  const out = [];
  const head = new RegExp(String.raw`(['"])(?:query|mutation)\b`, 'g');
  for (let m = head.exec(text); m; m = head.exec(text)) {
    const first = new RegExp(LIT, 'y');
    first.lastIndex = m.index;
    const f = first.exec(text);
    if (!f) continue;
    let doc = unquote(f[0]), end = first.lastIndex;
    const next = new RegExp(GAP + String.raw`\+` + GAP + '(' + LIT + ')', 'y');
    next.lastIndex = first.lastIndex;
    for (let n = next.exec(text); n; n = next.exec(text)) { doc += unquote(n[1]); end = next.lastIndex; }
    // A bare 'query' or 'mutation' is an argument naming the kind, not a document.
    if (/[{(]/.test(doc)) out.push(doc);
    head.lastIndex = end;
  }
  return out;
}

for (const file of files) {
  for (const doc of inlineDocs(fs.readFileSync(file, 'utf8'))) {
    docs += 1;
    if (bodyBlocked(JSON.stringify({ query: doc }))) bad.push(`${path.relative(dir, file)}: inline ${doc.slice(0, 60)}`);
  }
}

// The GraphQL documents themselves: every exported string that holds one, and
// every exported *Doc builder, run for a few lines with a weight line among them.
for (const file of files) {
  const out = esbuild.buildSync({ entryPoints: [file], bundle: true, write: false, format: 'cjs', platform: 'node', logLevel: 'silent' });
  const mod = { exports: {} };
  new Function('module', 'exports', 'require', out.outputFiles[0].text)(mod, mod.exports, require);
  for (const [name, v] of Object.entries(mod.exports)) {
    const doc = typeof v === 'string' ? v : typeof v === 'function' && /Doc$/.test(name) ? v(3, [false, true, false]) : null;
    if (typeof doc !== 'string' || !/\b(query|mutation)\b/.test(doc)) continue;
    docs += 1;
    if (bodyBlocked(JSON.stringify({ query: doc }))) bad.push(`${path.relative(dir, file)}: ${name}`);
  }
}

console.log(`checked ${paths} paths, ${names} operation names, ${docs} GraphQL documents in ${dir}`);
if (bad.length) { console.log('BLOCKED:\n  ' + bad.join('\n  ')); process.exit(1); }
console.log('none blocked');
