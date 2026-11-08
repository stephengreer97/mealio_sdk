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
