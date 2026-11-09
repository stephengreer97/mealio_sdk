// A ready mock for your tests:
//   jest.mock('@mealio/react-native-cart', () => require('@mealio/react-native-cart/jest'));
// No WebViews, no network. useMealio() is the same object everywhere, so a test
// can set what a call answers:
//   useMealio().prepareCart.mockResolvedValue(mockCart({ cartId: 'c1' }));
// To test a guest, setMockUser(null): hasUser turns false and MealioCartButton
// calls onSignInRequired (its own, else the provider's), or is disabled.
// setMockUser('u1') signs someone in, setMockUser(undefined) stops tracking.
// Everything resets after each test: mocked answers, the user, and recorded
// calls. Loaded at a file's top level (the usual jest.mock line), it registers
// that afterEach itself. Loaded inside a test or a hook (a lazy require,
// jest.isolateModules, a require in beforeAll), where Jest refuses new hooks,
// it does not; then add
//   require('@mealio/react-native-cart/jest').setupMealioMock();
// to a setup file (Jest's setupFilesAfterEnv) to register it for every test
// file. It registers once however often it is called.
// To run your screens on the real client and a fake server instead, see
// require('@mealio/react-native-cart/testing').
// Plain JS on purpose: partners' Jest loads it untransformed.
const React = require('react');

const fn = (impl) => (typeof jest !== 'undefined' ? jest.fn(impl) : impl);

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
 * Reset the mock after every test. Call it from a Jest setup file
 * (setupFilesAfterEnv) when the mock may first load inside a test. Returns
 * false where hooks cannot be added (no afterEach, or inside a test).
 */
let registered = false;
function setupMealioMock() {
  if (registered) return true;
  if (typeof afterEach !== 'function' || insideTest()) return false;
  // Jest also refuses a hook from inside beforeAll (or any hook), where no
  // test name is set yet; there it throws, and loading the mock must not.
  try {
    afterEach(() => resetMealioMock());
  } catch (e) {
    return false;
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
