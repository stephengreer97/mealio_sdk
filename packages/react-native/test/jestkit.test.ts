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
