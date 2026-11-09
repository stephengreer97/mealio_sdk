// A ready mock for your tests:
//   jest.mock('@mealio/react-native-cart', () => require('@mealio/react-native-cart/jest'));
// No WebViews, no network. useMealio() is the same object everywhere, so a test
// can set what a call answers:
//   useMealio().prepareCart.mockResolvedValue(mockCart({ cartId: 'c1' }));
// To test a guest, setMockUser(null): hasUser turns false and MealioCartButton
// calls onSignInRequired (its own, else the provider's), or is disabled.
// setMockUser('u1') signs someone in, setMockUser(undefined) stops tracking.
// Everything resets after each test: mocked answers, the user, and recorded
// calls. On Jest, loaded while a file is being collected (the usual jest.mock
// line at the top, or a require in a describe body), it registers that
// afterEach itself, on the file's root block, so it runs after every test in
// the file. Loaded once tests have started (a require inside a test or a hook
// such as beforeAll, a lazy require, jest.isolateModules), where Jest refuses
// new hooks, it does not. On other runners (Vitest) it registers the hook
// where it first loads: at a file's top level that covers the file, inside a
// describe body only that describe (and setupMealioMock() returns true). With
// the afterEach comes a beforeEach that undoes Jest's resetMocks on the
// default answers. The reliable path on any runner is a setup file (Jest's
// setupFilesAfterEnv, Vitest's setupFiles) with
//   require('@mealio/react-native-cart/jest').setupMealioMock();
// It registers once however often it is called.
// To run your screens on the real client and a fake server instead, see
// require('@mealio/react-native-cart/testing').
// Plain JS on purpose: partners' Jest loads it untransformed.
const React = require('react');

/**
 * Every mock made with a default answer, and that answer. Jest's resetMocks
 * (and restoreMocks on Jest 29) strips a jest.fn of its implementation before
 * each test; the beforeEach setupMealioMock registers puts the default back
 * on each one left with none, so useMealio().prepareCart() still gives a cart.
 * An answer the test scripted (mockResolvedValue, mockImplementation) is kept.
 */
const defaults = [];
let filling = false; // true while fill() makes useMealio()'s own mocks
const noop = () => undefined;
function fn(impl) {
  if (typeof jest === 'undefined' || !jest || typeof jest.fn !== 'function') return impl || noop;
  const m = jest.fn(impl);
  if (impl) defaults.push([m, impl, filling]);
  return m;
}
/** Puts each default answer back on a mock that has none left. */
function restoreDefaults() {
  for (let i = 0; i < defaults.length; i += 1) {
    const m = defaults[i][0];
    try {
      if (typeof m.getMockImplementation === 'function' && !m.getMockImplementation()) m.mockImplementation(defaults[i][1]);
    } catch (e) { /* a mock the test replaced oddly is left alone */ }
  }
}

let DEFAULT_STRINGS = {};
let textTools = null;
try {
  const strings = require('@mealio/sdk-core/dist/strings');
  DEFAULT_STRINGS = strings.DEFAULT_STRINGS;
  textTools = strings.textTools;
} catch (e) { /* words show as their keys */ }

class MealioError extends Error {
  constructor(code, message, reason) { super(message); this.name = 'MealioError'; this.code = code; if (reason) this.reason = reason; }
}

/** Like the real one: listeners run on cancel, and one added after it runs at once. */
class CancelToken {
  constructor() { this.cancelled = false; this.reason = null; this.listeners = []; }
  cancel(reason) {
    if (this.cancelled) return;
    this.cancelled = true;
    this.reason = reason || 'cancelled';
    const list = this.listeners;
    this.listeners = [];
    list.forEach((f) => { try { f(); } catch (e) { /* one listener never stops the rest */ } });
  }
  onCancel(f) {
    if (this.cancelled) { f(); return () => {}; }
    this.listeners.push(f);
    return () => { this.listeners = this.listeners.filter((x) => x !== f); };
  }
}

const result = (over) => ({ cartId: 'cart_mock', store: 'heb', added: [], skipped: [], failed: [], storeCartUrl: null, ...over });

/** Every public member of the real CartSession, so code that uses any of them runs. */
class CartSession {
  // new CartSession(client, cart) gives a mock cart too.
  constructor(_client, cart) { return mockCart(cart); }
}

/** A cart that behaves enough like CartSession. Pass PreparedCart fields to override. */
function mockCart(over) {
  const cart = { cartId: 'cart_mock', store: 'heb', storeName: 'H-E-B', items: [], ready: [], needsChoice: [], unavailable: [], warnings: [], ...over };
  const none = { total: 0, count: 0, estimated: false, unpriced: 0 };
  const c = Object.create(CartSession.prototype);
  Object.assign(c, {
    cart, cartId: cart.cartId, store: cart.store, items: cart.items, recipes: cart.recipes || [], warnings: cart.warnings || [],
    ready: cart.ready || [], needsChoice: cart.needsChoice || [], unavailable: cart.unavailable || [],
    searching: false,
    recipesFor: fn(() => []),
    options: fn(() => []), selected: fn(() => null), selectedId: fn(() => null), isSelected: fn(() => false),
    select: fn(), deselect: fn(), selectedCount: fn(() => 0),
    quantity: fn(() => 1), setQuantity: fn((_k, n) => n), maxQuantity: fn(() => 99),
    isWeight: fn(() => false), weight: fn(() => 0), setWeight: fn((_k, lb) => lb), stepWeight: fn(() => 0),
    weightRange: fn(() => ({ min: 0.25, max: 20 })),
    preferenceId: fn(() => null), needsPreference: fn(() => false), pendingPreferences: fn(() => []),
    search: fn(async () => []), cancelSearches: fn(), restorePicks: fn(async () => {}),
    selections: fn(() => []), addToCart: fn(async () => result()),
    estimate: fn(() => ({ ...none })), addedTotal: fn(() => ({ ...none })), addedPrice: fn(() => null),
    choose: fn(), skip: fn(), pending: fn(() => []),
  });
  return c;
}

const words = textTools ? textTools() : {
  tr: (key) => DEFAULT_STRINGS[key] || key,
  plural: (base, count) => DEFAULT_STRINGS[`${base}_${count === 1 ? 'one' : 'other'}`] || base,
};

const ui = {
  tr: words.tr,
  plural: words.plural,
  money: (n) => `$${n.toFixed(2)}`,
  emit: fn(),
  customMoney: false,
  sheet: { showTotal: true, height: 'auto', logo: null },
};

/** The one object useMealio() returns. resetMealioMock refills it in place. */
const api = {};
function fill() {
  filling = true;
  try { fillApi(); } finally { filling = false; }
}
function fillApi() {
  ui.emit = fn();
  Object.assign(api, {
    userId: undefined,
    hasUser: true,
    theme: {},
    ui,
    prepareCart: fn(async () => mockCart()),
    stores: fn(async () => []),
    signOutOfAllStores: fn(async () => {}),
    resetSession: fn(),
    warm: fn(async () => {}),
    storeLocations: fn(async () => []),
    storePreferences: fn(async () => ({ defaultStore: null, location: null })),
    setStore: fn(async (store) => ({ defaultStore: store, location: null })),
    openStoreSettings: fn(() => { if (!api.hasUser && providerSignIn) providerSignIn(); }),
  });
}

/** The provider's onSignInRequired, from the last MealioProvider rendered. */
let providerSignIn = null;

/** Back to the start: default answers, no recorded calls, a signed-in user, no provider. */
function resetMealioMock() {
  providerSignIn = null;
  // The old mocks are gone from useMealio(); carts made earlier keep theirs.
  for (let i = defaults.length - 1; i >= 0; i -= 1) if (defaults[i][2]) defaults.splice(i, 1);
  fill();
}
fill();

/** True while a test (or its beforeEach/afterEach) runs: Jest and Vitest both name it. */
function insideTest() {
  try {
    return typeof expect !== 'undefined' && typeof expect.getState === 'function' && !!expect.getState().currentTestName;
  } catch (e) {
    return false;
  }
}

/**
 * Jest's test-runner state (jest-circus). Jest keeps it on the global under a
 * symbol named JEST_STATE_SYMBOL that it does not register, so it is found by
 * its name; Symbol.for is tried first in case a later Jest registers it.
 */
function jestState() {
  try {
    const g = typeof globalThis !== 'undefined' ? globalThis : global;
    const named = g[Symbol.for('JEST_STATE_SYMBOL')];
    if (named) return named;
    const syms = Object.getOwnPropertySymbols(g);
    for (let i = 0; i < syms.length; i += 1) {
      if (String(syms[i]) === 'Symbol(JEST_STATE_SYMBOL)') return g[syms[i]];
    }
  } catch (e) { /* not Jest */ }
  return null;
}

/**
 * True once Jest has started running tests (in beforeAll, a test, any hook).
 * There Jest refuses a new hook WITHOUT throwing: it records an error that
 * fails the whole file ("Cannot add a hook after tests have started
 * running"), so the hook must not be added at all.
 */
function testsStarted() {
  const state = jestState();
  return !!(state && state.hasStarted);
}

/**
 * Reset the mock after every test. Call it from a Jest setup file
 * (setupFilesAfterEnv) when the mock may first load inside a test. Returns
 * false where hooks cannot be added (no afterEach, or inside a test).
 *
 * A hook added while a describe block is being collected belongs to that
 * block alone, so a mock first required inside one describe would reset
 * only that block's tests. On Jest the hook is added to the file's root
 * block instead, so it runs after every test in the file. Other runners
 * (Vitest) cannot be reached that way: there the hook goes where this is
 * called, a describe body included, and the return is still true. A setup
 * file is the reliable path on any runner.
 *
 * A beforeEach is registered with it by the same rules: it puts each default
 * answer back on a mock that Jest's resetMocks left with none.
 */
let registered = false;
function setupMealioMock() {
  if (registered) return true;
  if (typeof afterEach !== 'function' || insideTest() || testsStarted()) return false;
  const state = jestState();
  const cur = state && state.currentDescribeBlock;
  const root = state && state.rootDescribeBlock;
  const nested = !!(cur && root && cur !== root);
  // Another runner may refuse a hook by throwing; loading the mock must not.
  try {
    if (nested) state.currentDescribeBlock = root;
    afterEach(() => resetMealioMock());
    // Registered by the same rules, so it runs before every test the reset
    // runs after: it undoes Jest's resetMocks on the default answers.
    if (typeof beforeEach === 'function') {
      try { beforeEach(() => restoreDefaults()); } catch (e) { /* the reset alone still works */ }
    }
  } catch (e) {
    return false;
  } finally {
    if (nested) state.currentDescribeBlock = cur;
  }
  registered = true;
  return true;
}
// Each test starts clean, without the partner having to remember to.
setupMealioMock();

/** Sign a user in (an id), out (null), or stop tracking users (undefined). */
function setMockUser(id) {
  api.userId = id;
  api.hasUser = id !== null;
}

const useMealio = () => api;
// A userId prop works like setMockUser.
const MealioProvider = ({ children, onSignInRequired, userId }) => {
  providerSignIn = onSignInRequired || null;
  if (userId !== undefined) setMockUser(userId);
  return children;
};
const nothing = () => null;

/** Tapping it reports a finished add through onAdded and onClose, with no sheet. */
function MealioCartButton(props) {
  const signIn = api.hasUser ? null : props.onSignInRequired || providerSignIn;
  const onPress = () => {
    if (!api.hasUser) { if (signIn) signIn(); return; }
    const r = result();
    if (props.onAdded) props.onAdded(r);
    if (props.onClose) props.onClose(r);
  };
  const label = props.label || ui.tr('addToCart');
  const disabled = !!props.disabled || (!api.hasUser && !signIn);
  if (props.renderButton) return props.renderButton({ onPress, disabled, label });
  const { Pressable, Text } = require('react-native');
  return React.createElement(Pressable, { onPress, disabled, accessibilityRole: 'button', accessibilityLabel: label },
    React.createElement(Text, null, label));
}

module.exports = {
  MealioProvider, useMealio, MealioCartButton, mockCart, setMockUser, resetMealioMock, setupMealioMock,
  MealioCartFlow: nothing, MealioCartList: nothing, MealioCartSheet: nothing, MealioStoreSettings: nothing,
  forRecipes: () => null,
  CancelToken, MealioError, CartSession,
  DEFAULT_STRINGS, MAX_RECIPES: 10, SDK_VERSION: 'mock',
  DEFAULT_THEME: {}, DEFAULT_DARK_THEME: {},
};
