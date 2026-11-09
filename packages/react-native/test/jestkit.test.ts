// The Jest kit resets itself after every test when Jest's afterEach exists
// (0.6 round 3, item 6). Vitest's afterEach stands in for Jest's here.
import { describe, it, expect, afterEach } from 'vitest';

(globalThis as any).afterEach = afterEach;
// eslint-disable-next-line @typescript-eslint/no-var-requires
const kit = require('../jest.js');
delete (globalThis as any).afterEach;

describe('Jest kit state does not leak between tests', () => {
  it('first test: signs out and scripts an answer', async () => {
    kit.setMockUser(null);
    kit.useMealio().prepareCart = async () => 'scripted';
    kit.MealioProvider({ children: null, onSignInRequired: () => {} });
    expect(kit.useMealio().hasUser).toBe(false);
  });

  it('second test: starts clean, on the same object', async () => {
    const api = kit.useMealio();
    expect(api).toBe(kit.useMealio());
    expect(api.hasUser).toBe(true);
    expect(api.userId).toBeUndefined();
    expect(await api.prepareCart()).not.toBe('scripted');
    expect(typeof kit.resetMealioMock).toBe('function');
  });
});

// 0.6 round 4: loaded inside a test (a lazy require, jest.isolateModules), the
// mock must not add a hook, which Jest refuses there and fails the test for.
describe('the Jest kit loaded inside a test', () => {
  // Jest's expect is a global; Vitest's is not unless set.
  const fresh = () => {
    const path = require.resolve('../jest.js');
    delete require.cache[path];
    (globalThis as any).expect = expect;
    try { return require('../jest.js'); } finally { delete (globalThis as any).expect; }
  };

  it('adds no afterEach, and setupMealioMock says it could not', () => {
    let hooks = 0;
    (globalThis as any).afterEach = () => { hooks += 1; };
    try {
      const m = fresh();
      expect(hooks).toBe(0);
      m.setMockUser(null);
      expect(m.useMealio().hasUser).toBe(false);
      (globalThis as any).expect = expect;
      expect(m.setupMealioMock()).toBe(false);
      delete (globalThis as any).expect;
      expect(hooks).toBe(0);
    } finally {
      delete (globalThis as any).afterEach;
    }
  });

  it('at a file\'s top level it registers the reset once, however often setupMealioMock is called', () => {
    let hooks = 0;
    const state = expect.getState();
    expect.setState({ currentTestName: undefined });
    (globalThis as any).afterEach = () => { hooks += 1; };
    try {
      const m = fresh();
      expect(hooks).toBe(1);
      (globalThis as any).expect = expect;
      expect(m.setupMealioMock()).toBe(true);
      delete (globalThis as any).expect;
      expect(hooks).toBe(1);
    } finally {
      delete (globalThis as any).afterEach;
      expect.setState({ currentTestName: state.currentTestName });
    }
  });
});

// 0.6 round 5: Jest refuses a hook from inside beforeAll by throwing, and no
// test name is set there yet, so the mock must catch it, not crash the load.
describe('the Jest kit loaded inside beforeAll', () => {
  it('loads, adds no hook, and setupMealioMock says it could not', () => {
    const state = expect.getState();
    expect.setState({ currentTestName: undefined });
    const path = require.resolve('../jest.js');
    delete require.cache[path];
    let tries = 0;
    (globalThis as any).afterEach = () => { tries += 1; throw new Error('Hooks cannot be defined inside tests. Hook of type "afterEach" is nested within "beforeAll".'); };
    (globalThis as any).expect = expect;
    try {
      const m = require('../jest.js');
      expect(tries).toBe(1);
      expect(typeof m.setMockUser).toBe('function');
      m.setMockUser(null);
      expect(m.useMealio().hasUser).toBe(false);
      expect(m.setupMealioMock()).toBe(false);
    } finally {
      delete (globalThis as any).afterEach;
      delete (globalThis as any).expect;
      expect.setState({ currentTestName: state.currentTestName });
    }
  });
});

// 0.6 round 6: real Jest does NOT throw there. Once tests have started it
// records "Cannot add a hook after tests have started running", which fails
// the whole file. The mock reads jest-circus's state (an unregistered symbol
// named JEST_STATE_SYMBOL) and adds no hook once hasStarted is set. Checked
// against real Jest 29 and 30 by scripts/check-jest-mock.mjs.
describe('the Jest kit loaded after Jest has started running tests', () => {
  it('adds no hook when jest-circus says tests have started', () => {
    const state = expect.getState();
    expect.setState({ currentTestName: undefined });
    const sym = Symbol('JEST_STATE_SYMBOL');
    const path = require.resolve('../jest.js');
    let hooks = 0;
    (globalThis as any).afterEach = () => { hooks += 1; }; // records, never throws, as Jest
    (globalThis as any).expect = expect;
    try {
      (globalThis as any)[sym] = { hasStarted: true };
      delete require.cache[path];
      const m = require('../jest.js');
      expect(hooks).toBe(0);
      expect(m.setupMealioMock()).toBe(false);
      // Before the run starts (a setup file, a file's top level) it registers.
      (globalThis as any)[sym] = { hasStarted: false };
      expect(m.setupMealioMock()).toBe(true);
      expect(hooks).toBe(1);
    } finally {
      delete (globalThis as any)[sym];
      delete (globalThis as any).afterEach;
      delete (globalThis as any).expect;
      expect.setState({ currentTestName: state.currentTestName });
    }
  });
});

// 0.6 round 7: first required inside a describe body (while Jest collects the
// file), the hook must go on the file's root block, not on that describe, or
// tests in the next describe never reset. Jest's afterEach adds the hook to
// jest-circus's state.currentDescribeBlock; the fake below records where it
// would land. Checked against real Jest 29 and 30 by scripts/check-jest-mock.mjs.
describe('the Jest kit first required inside a describe', () => {
  it('registers the reset on the root block and puts the current block back', () => {
    const state = expect.getState();
    expect.setState({ currentTestName: undefined });
    const sym = Symbol('JEST_STATE_SYMBOL');
    const path = require.resolve('../jest.js');
    const root = { name: 'ROOT_DESCRIBE_BLOCK' };
    const inner = { name: 'cart screen', parent: root };
    const circus: any = { hasStarted: false, rootDescribeBlock: root, currentDescribeBlock: inner };
    const landed: unknown[] = [];
    (globalThis as any).afterEach = () => { landed.push(circus.currentDescribeBlock); };
    (globalThis as any).expect = expect;
    try {
      (globalThis as any)[sym] = circus;
      delete require.cache[path];
      require('../jest.js');
      expect(landed).toEqual([root]);
      expect(circus.currentDescribeBlock).toBe(inner);
    } finally {
      delete (globalThis as any)[sym];
      delete (globalThis as any).afterEach;
      delete (globalThis as any).expect;
      expect.setState({ currentTestName: state.currentTestName });
    }
  });

  it('puts the current block back even when the runner refuses the hook', () => {
    const state = expect.getState();
    expect.setState({ currentTestName: undefined });
    const sym = Symbol('JEST_STATE_SYMBOL');
    const path = require.resolve('../jest.js');
    const root = {}; const inner = {};
    const circus: any = { hasStarted: false, rootDescribeBlock: root, currentDescribeBlock: inner };
    (globalThis as any).afterEach = () => { throw new Error('no hooks here'); };
    (globalThis as any).expect = expect;
    try {
      (globalThis as any)[sym] = circus;
      delete require.cache[path];
      const m = require('../jest.js');
      expect(circus.currentDescribeBlock).toBe(inner);
      expect(m.setupMealioMock()).toBe(false);
    } finally {
      delete (globalThis as any)[sym];
      delete (globalThis as any).afterEach;
      delete (globalThis as any).expect;
      expect.setState({ currentTestName: state.currentTestName });
    }
  });
});

// 0.6 round 8: Jest's resetMocks strips every jest.fn of its implementation
// before each test, which left useMealio().prepareCart() answering undefined.
// The before-each the mock registers with its after-each puts each default
// answer back, and keeps one the test scripted. A small jest.fn with Jest's
// own reset (no implementation left at all; Vitest's leaves an empty one)
// stands in. Checked against real Jest 29 and 30 with resetMocks: true too.
function jestFn(impl?: (...a: any[]) => any) {
  let cur = impl;
  const m: any = (...a: any[]) => (cur ? cur(...a) : undefined);
  m._isMockFunction = true;
  m.getMockImplementation = () => cur;
  m.mockImplementation = (f: any) => { cur = f; return m; };
  m.mockResolvedValue = (v: any) => m.mockImplementation(async () => v);
  m.mockReset = () => { cur = undefined; return m; };
  return m;
}
describe('the Jest kit under resetMocks', () => {
  it('puts the default answers back before each test, and keeps scripted ones', async () => {
    const state = expect.getState();
    expect.setState({ currentTestName: undefined });
    const path = require.resolve('../jest.js');
    const after: Array<() => void> = [], before: Array<() => void> = [];
    (globalThis as any).jest = { fn: jestFn };
    (globalThis as any).afterEach = (f: () => void) => { after.push(f); };
    (globalThis as any).beforeEach = (f: () => void) => { before.push(f); };
    (globalThis as any).expect = expect;
    let m: any;
    try {
      delete require.cache[path];
      m = require('../jest.js');
    } finally {
      delete (globalThis as any).afterEach;
      delete (globalThis as any).beforeEach;
      delete (globalThis as any).expect;
      expect.setState({ currentTestName: state.currentTestName });
    }
    try {
      expect([after.length, before.length]).toEqual([1, 1]);
      const api = m.useMealio();
      const early = m.mockCart();
      // What resetMocks does before a test: every mock loses its implementation.
      const resetAll = () => {
        for (const v of [...Object.values(api), ...Object.values(early)]) if (v && (v as any)._isMockFunction) (v as any).mockReset();
      };
      resetAll();
      expect(api.prepareCart()).toBeUndefined();
      before.forEach((f) => f());
      expect((await api.prepareCart()).cartId).toBe('cart_mock');
      expect((await early.addToCart()).cartId).toBe('cart_mock');
      expect(api.setStore('heb') instanceof Promise).toBe(true);
      // A scripted answer survives the before-each.
      api.prepareCart.mockResolvedValue('scripted');
      before.forEach((f) => f());
      expect(await api.prepareCart()).toBe('scripted');
      // After the after-each reset, the new mocks are covered too.
      after.forEach((f) => f());
      resetAll();
      before.forEach((f) => f());
      expect((await m.useMealio().prepareCart()).cartId).toBe('cart_mock');
    } finally {
      delete (globalThis as any).jest;
    }
  });

  it('gives plain functions, not undefined, for mocks with no answer when there is no jest', () => {
    const c = kit.mockCart();
    expect(typeof c.select).toBe('function');
    expect(c.select('k', 'id')).toBeUndefined();
    expect(typeof kit.useMealio().ui.emit).toBe('function');
  });
});
