// A ready mock for your tests:
//   jest.mock('@mealio/react-native-cart', () => require('@mealio/react-native-cart/jest'));
// No WebViews, no network. useMealio() is the same object everywhere, so a test
// can set what a call answers:
//   useMealio().prepareCart.mockResolvedValue(mockCart({ cartId: 'c1' }));
// Plain JS on purpose: partners' Jest loads it untransformed.
const React = require('react');

const fn = (impl) => (typeof jest !== 'undefined' ? jest.fn(impl) : impl);

let DEFAULT_STRINGS = {};
try { DEFAULT_STRINGS = require('@mealio/sdk-core/dist/strings').DEFAULT_STRINGS; } catch (e) { /* words show as their keys */ }

class MealioError extends Error {
  constructor(code, message) { super(message); this.name = 'MealioError'; this.code = code; }
}

class CancelToken {
  constructor() { this.cancelled = false; }
  cancel() { this.cancelled = true; }
  onCancel() { return () => {}; }
}

const result = (over) => ({ cartId: 'cart_mock', store: 'heb', added: [], skipped: [], failed: [], storeCartUrl: null, ...over });

/** A cart that behaves enough like CartSession. Pass PreparedCart fields to override. */
function mockCart(over) {
  const cart = { cartId: 'cart_mock', store: 'heb', storeName: 'H-E-B', items: [], ready: [], needsChoice: [], unavailable: [], warnings: [], ...over };
  return {
    cart, cartId: cart.cartId, store: cart.store, items: cart.items, recipes: cart.recipes || [], warnings: cart.warnings,
    searching: false,
    selected: fn(() => null), selectedId: fn(() => null), isSelected: fn(() => false), options: fn(() => []),
    select: fn(), deselect: fn(), quantity: fn(() => 1), setQuantity: fn((_k, n) => n), maxQuantity: fn(() => 99),
    search: fn(async () => []), cancelSearches: fn(), restorePicks: fn(),
    selections: fn(() => []), addToCart: fn(async () => result()),
    estimate: fn(() => ({ total: 0, count: 0, estimated: false, unpriced: 0 })),
    addedTotal: fn(() => ({ total: 0, count: 0, estimated: false, unpriced: 0 })),
  };
}

const ui = {
  tr: (key) => DEFAULT_STRINGS[key] || key,
  plural: (base, count) => `${base} ${count}`,
  money: (n) => `$${n.toFixed(2)}`,
  emit: fn(),
  customMoney: false,
  sheet: { showTotal: true, height: 'auto', logo: null },
};

const api = {
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
  openStoreSettings: fn(),
};

const useMealio = () => api;
const MealioProvider = ({ children }) => children;
const nothing = () => null;

/** Tapping it reports a finished add through onAdded and onClose, with no sheet. */
function MealioCartButton(props) {
  const onPress = () => {
    const r = result();
    if (props.onAdded) props.onAdded(r);
    if (props.onClose) props.onClose(r);
  };
  const label = props.label || ui.tr('addToCart');
  const disabled = !!props.disabled;
  if (props.renderButton) return props.renderButton({ onPress, disabled, label });
  const { Pressable, Text } = require('react-native');
  return React.createElement(Pressable, { onPress, disabled, accessibilityRole: 'button', accessibilityLabel: label },
    React.createElement(Text, null, label));
}

module.exports = {
  MealioProvider, useMealio, MealioCartButton, mockCart,
  MealioCartFlow: nothing, MealioCartList: nothing, MealioCartSheet: nothing, MealioStoreSettings: nothing,
  forRecipes: () => null,
  CancelToken, MealioError, CartSession: class CartSession {},
  DEFAULT_STRINGS, MAX_RECIPES: 10, SDK_VERSION: 'mock',
  DEFAULT_THEME: {}, DEFAULT_DARK_THEME: {},
};
