// Keeps skills/mealio-integrate/SKILL.md honest. Run in CI, and by hand:
//   node scripts/check-skill.mjs            the skill against this repo
//   node scripts/check-skill.mjs --hosted   also, the copy on developers.mealio.co
//
// Two directions. Everything the skill names must exist in the SDK, so a rename
// breaks this check. Everything a partner can set must be in the skill, so a new
// option breaks it too until the skill teaches it.
import fs from 'node:fs';
import path from 'node:path';

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');
const SKILL_PATH = process.env.SKILL_FILE || 'skills/mealio-integrate/SKILL.md';
const skill = read(SKILL_PATH);

function walk(dir, exts, out = []) {
  for (const e of fs.readdirSync(path.join(root, dir), { withFileTypes: true })) {
    if (['node_modules', 'dist', 'build', 'test', 'androidTest', '__tests__', '.dart_tool'].includes(e.name)) continue;
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, exts, out);
    else if (exts.includes(path.extname(e.name))) out.push(p);
  }
  return out;
}
const words = (dirs, exts) => new Set(dirs.flatMap((d) => walk(d, exts)).map(read).join('\n').match(/\w+/g));
const SOURCES = {
  ts: words(['packages/core/src', 'packages/react-native/src'], ['.ts', '.tsx']),
  swift: words(['ios/Sources'], ['.swift']),
  kotlin: words(['android/mealio-sdk/src/main', 'android/mealio-sdk-compose/src/main'], ['.kt']),
  dart: words(['flutter/lib'], ['.dart']),
};
const anywhere = (w) => Object.values(SOURCES).some((s) => s.has(w));

const problems = [];

// Fenced code, by language. `ts` blocks are partly the partner's own code, so
// only calls on the SDK's objects are checked there.
const fences = [...skill.matchAll(/```(\w+)\n([\s\S]*?)```/g)].map(([, lang, code]) => ({ lang, code }));
// Argument names, per language. Strings and comments do not count.
const LABELS = { swift: /\b(\w+):\s/g, kotlin: /\b(\w+) = /g, dart: /\b(\w+):\s/g, tsx: /\s(\w+)=\{/g };
const SOURCE_FOR = { swift: 'swift', kotlin: 'kotlin', dart: 'dart', tsx: 'ts' };
// Argument names that belong to the app's own frameworks in the examples (go_router, Flutter), not to the SDK.
const FRAMEWORK = new Set(['routes', 'routerConfig']);
const clean = (c) => c.replace(/\/\/.*$/gm, '').replace(/#.*$/gm, '').replace(/'[^'\n]*'|"[^"\n]*"/g, '""');

for (const { lang, code } of fences) {
  const pattern = LABELS[lang];
  if (!pattern) continue;
  for (const [, label] of clean(code).matchAll(pattern)) {
    if (!FRAMEWORK.has(label) && !SOURCES[SOURCE_FOR[lang]].has(label)) problems.push(`${lang} example uses "${label}", which is not in the ${lang} SDK`);
  }
}

// Calls on the SDK's objects, in any fence or inline.
for (const [, obj, name] of skill.matchAll(/\b(mealio|cart|MealioCart)\.(?:instance\.)?([a-zA-Z]+)\b/g)) {
  if (!anywhere(name)) problems.push(`skill calls ${obj}.${name}, which is not in any SDK`);
}
// Every Mealio type or widget named, anywhere in the file.
for (const name of new Set(skill.match(/\bMealio[A-Z]\w+/g))) {
  if (name !== 'MealioSDK' && !anywhere(name)) problems.push(`skill names ${name}, which is not in any SDK`); // MealioSDK is the iOS package
}

const inline = new Set([...skill.matchAll(/`([^`\n]+)`/g)].map((m) => m[1]));
const taught = (w) => inline.has(w) || new RegExp(`\`[^\`\\n]*\\b${w}\\b[^\`\\n]*\``).test(skill) || fences.some((f) => new RegExp(`\\b${w}\\b`).test(f.code));

// The other direction: what a partner can set must be in the skill.
const ts = (p) => read(p);
const bodyOf = (src, name) => {
  const m = new RegExp(`export interface ${name}(?: extends [^{]+)? \\{([\\s\\S]*?)\\n\\}`).exec(src);
  if (!m) throw new Error(`check-skill: ${name} not found. Update this script.`);
  return m[1];
};
const keysOf = (body) => [...body.matchAll(/^ {2}(\w+)\??\s*[:(]/gm)].map((m) => m[1]);
const provider = ts('packages/react-native/src/MealioProvider.tsx');
const button = ts('packages/react-native/src/MealioCartButton.tsx');
const theme = ts('packages/react-native/src/theme.ts');
const protocol = ts('packages/core/src/protocol.ts');
const events = ts('packages/core/src/events.ts');
const client = ts('packages/core/src/client.ts');
const dartErrors = read('flutter/lib/src/errors.dart');

const required = {
  'provider prop': keysOf(bodyOf(provider, 'MealioProviderProps')).filter((k) => k !== 'children'),
  'mealio method': keysOf(bodyOf(provider, 'MealioApi')).filter((k) => !['theme', 'ui'].includes(k)),
  'button prop': keysOf(bodyOf(button, 'MealioCartButtonProps')),
  'button variant': [...(/MealioButtonVariant = ([^;]+);/.exec(button)?.[1] ?? '').matchAll(/'(\w+)'/g)].map((m) => m[1]),
  'sheet option': keysOf(bodyOf(provider, 'MealioSheetOptions')),
  'theme field': keysOf(bodyOf(theme, 'MealioTheme')),
  'recipe field': keysOf(bodyOf(protocol, 'Recipe')),
  'ingredient field': keysOf(bodyOf(protocol, 'RecipeIngredient')),
  'item status': [...(/ItemStatus = ([^;]+);/.exec(protocol)?.[1] ?? '').matchAll(/'(\w+)'/g)].map((m) => m[1]),
  event: [...events.matchAll(/type: '(\w+)'/g)].map((m) => m[1]),
  'error code': [...dartErrors.matchAll(/static const String \w+ = '(\w+)'/g)].map((m) => m[1]),
  'cart method': ['select', 'deselect', 'search', 'options', 'selectedId', 'estimate', 'addToCart', 'needsPreference', 'pendingPreferences', 'isWeight', 'setWeight', 'setQuantity', 'recipesFor'],
};
for (const [what, list] of Object.entries(required)) {
  if (list.length === 0) throw new Error(`check-skill: found no ${what}. Update this script.`);
  for (const w of new Set(list)) if (!taught(w)) problems.push(`${what} "${w}" is in the SDK but not in the skill`);
}
for (const w of ['select', 'deselect', 'search', 'estimate', 'recipesFor', 'needsPreference']) {
  if (!client.includes(`${w}(`)) problems.push(`check-skill.mjs lists cart method ${w}, which is gone from core`);
}

if (process.argv.includes('--hosted')) {
  const url = 'https://developers.mealio.co/SKILL.md';
  const res = await fetch(url);
  const hosted = res.ok ? await res.text() : null;
  if (hosted !== skill) problems.push(`${url} differs from ${SKILL_PATH}. Run scripts/sync-developer-skill.sh in mealio_central and deploy.`);
}

if (problems.length) {
  console.error(`${problems.length} problem(s) in ${SKILL_PATH}:`);
  for (const p of [...new Set(problems)]) console.error(`  - ${p}`);
  process.exit(1);
}
console.log(`ok ${SKILL_PATH}`);
