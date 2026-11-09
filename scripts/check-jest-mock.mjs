// Loads the React Native Jest mock the way partners do, on real Jest 29 and
// 30, from the packed tarballs: at a file's top level (it must reset itself
// after every test) and inside beforeAll (it must load without adding a hook,
// which Jest would turn into a failed file). Needs the npm registry for Jest.
//   node scripts/check-jest-mock.mjs [29 30]
import { execSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'mealio-jest-'));
const run = (cmd, cwd) => execSync(cmd, { cwd, stdio: ['ignore', 'pipe', 'pipe'] }).toString();
run(`npm pack -w @mealio/sdk-core -w @mealio/react-native-cart --pack-destination ${JSON.stringify(work)}`, root);
const tgz = fs.readdirSync(work).filter((f) => f.endsWith('.tgz')).map((f) => path.join(work, f));

const tests = {
  'beforeall.test.js': `let m;
beforeAll(() => { m = require('@mealio/react-native-cart/jest'); });
test('loads and works', () => { m.setMockUser(null); expect(m.useMealio().hasUser).toBe(false); expect(m.setupMealioMock()).toBe(false); });
test('a second test runs', () => { expect(typeof m.resetMealioMock).toBe('function'); });
`,
  'toplevel.test.js': `jest.mock('@mealio/react-native-cart', () => require('@mealio/react-native-cart/jest'));
const { setMockUser, useMealio } = require('@mealio/react-native-cart');
test('signs out', () => { setMockUser(null); expect(useMealio().hasUser).toBe(false); });
test('starts clean', () => { expect(useMealio().hasUser).toBe(true); });
`,
};

let failed = false;
for (const v of process.argv.slice(2).length ? process.argv.slice(2) : ['29', '30']) {
  const dir = path.join(work, `jest${v}`);
  fs.mkdirSync(path.join(dir, '__tests__'), { recursive: true });
  fs.writeFileSync(path.join(dir, 'package.json'), JSON.stringify({ name: `partner${v}`, private: true, jest: { testEnvironment: 'node' } }));
  for (const [f, src] of Object.entries(tests)) fs.writeFileSync(path.join(dir, '__tests__', f), src);
  run(`npm install --no-audit --no-fund --legacy-peer-deps jest@${v} react@18 ${tgz.map((t) => JSON.stringify(t)).join(' ')}`, dir);
  try {
    run('npx jest -w 2', dir);
    console.log(`jest ${v}: ok`);
  } catch (e) {
    failed = true;
    console.log(`jest ${v}: FAILED\n${e.stdout}${e.stderr}`);
  }
}
fs.rmSync(work, { recursive: true, force: true });
process.exit(failed ? 1 : 0);
