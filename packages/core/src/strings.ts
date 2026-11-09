// Every word the drop-in shows, in one table. Partners change or translate any
// of them with `strings`. {store}-style placeholders are filled in at runtime.
// A key ending _one or _other is the singular or plural of the same message.
//
// protocol/strings.json is the source. Every SDK carries the same table, and
// each one's tests check that it still matches.

export const DEFAULT_STRINGS = {
  addToCart: "Add to my grocery cart",
  addToCartShort: "Add to cart",
  close: "Close",
  somethingWrong: "Something went wrong",
  somethingWrongSentence: "Something went wrong.",
  couldNotAdd: "Could not add to your cart.",
  addFailedNote: "Some items may already be in your cart. Check it before adding again.",
  signInClosed: "Sign-in was closed before it finished.",
  tryAgain: "Try again",
  yourStore: "your store",
  meals: "{count} meals",
  titleInCartPlain: "In your cart",
  titleInCart: "In your {store} cart",
  titleLoadingPlain: "Getting your cart ready",
  titleLoading: "Getting your {store} cart ready",
  titleStores: "Choose your store",
  titleLocation: "Find your {store}",
  titleList: "Your {store} list",
  titleSettings: "Your grocery store",
  loginNote: "Sign in on {store}'s own page. Mealio never sees your password.",
  loadingNote: "Checking prices and stock at {store}.",
  stepSignIn: "Checking your {store} sign-in",
  stepFinding_one: "Finding your {count} ingredient",
  stepFinding_other: "Finding your {count} ingredients",
  change: "Change",
  choose: "Choose",
  done: "Done",
  current: "Current",
  selectedCount: "{count} of {total} selected",
  rememberNote: "Pick a product for each item and Mealio will remember your preferences.",
  pendingOptions_one: "1 checked item needs an option chosen before adding.",
  pendingOptions_other: "{count} checked items need an option chosen before adding.",
  total: "Total",
  estimatedTotal: "Estimated total",
  pricesAtCheckout: "Prices at checkout",
  aboutPrice: "about {price}",
  addItems_one: "Add 1 item to {store}",
  addItems_other: "Add {count} items to {store}",
  selectItems: "Select items to add",
  notFoundAt: "Not found at {store}",
  nothingFound: "Nothing found for \"{query}\".",
  searchFailed: "Search failed. Try again.",
  searchPlaceholder: "Search {store} for something else",
  search: "Search",
  yourUsual: "Your usual",
  notAddingThisTime: "Not adding this time",
  usualOutOfStock: "Your usual is out of stock",
  options_one: "1 option",
  options_other: "{count} options",
  chooseProduct: "Choose a product",
  chooseOne: "Choose one: {options}",
  weight: "Weight",
  quantity: "Quantity",
  usualNotAvailableNamed: "Your usual, {name}, is not available today. Pick another this time. It stays your usual.",
  usualNotAvailable: "Your usual is not available today. Pick another this time. It stays your usual.",
  usualOutNamed: "Your usual, {name}, is out of stock today. Pick another this time. It stays your usual.",
  usualOut: "Your usual is out of stock today. Pick another this time. It stays your usual.",
  outOfStock: "Out of stock",
  crowdFavorite: "Crowd favorite",
  itemsAdded_one: "1 item added",
  itemsAdded_other: "{count} items added",
  nothingAdded: "Nothing was added",
  cartUnchanged: "Your cart did not change.",
  leftOut: "Left out this time",
  neededOption: "Needed an option chosen",
  uncheckedThisTime: "Unchecked this time",
  notChosen: "Not chosen",
  reasonNotConfirmed: "not confirmed in your cart",
  reasonWeight: "sold by weight, which this store cannot take here",
  reasonOutOfStock: "out of stock",
  reasonNoAnswer: "the store did not answer",
  reasonRefused: "the store refused it",
  pricePerLb: "{price}/lb est.",
  priceEstimate: "{price} est.",
  forRecipes: "For {recipes}",
  and: "and",
  or: "or",
  backToList: "Back to your list",
  backToStores: "Back to your stores",
  differentStore: "Choose a different store",
  couldNotLoadStores: "Could not load stores. Close and try again.",
  couldNotLoadYourStores: "Could not load your stores.",
  couldNotLookUp: "Could not look up stores. Try again.",
  couldNotSaveStore: "Could not save that store. Try again.",
  zipPrompt: "Enter your zip code to see {store} stores near you.",
  zipCode: "Zip code",
  findStores: "Find stores",
  a11yLeaveOut: "Leave out {item}",
  a11yAdd: "Add {item}",
  a11yLess: "Less {item}",
  a11yMore: "More {item}",
  a11yChangeLocation: "Store location: {name}. Change location",
  a11yChangeStore: "Store: {store}. Change store",
  pantryHint: "You may already have this",
  capReached: "Adding to your grocery cart is paused in this app right now. Please try again later.",
  tooManyCarts: "You've started a lot of carts. Please try again a little later.",
  noStoresNear: "No {store} stores near {zip}. Try another zip code.",
};

export type MealioStrings = typeof DEFAULT_STRINGS;
export type StringKey = keyof MealioStrings;
export type StringVars = Record<string, string | number>;

/** Fill {placeholders}. One with no value stays as written, so a typo shows. */
export function fillText(template: string, vars: StringVars = {}): string {
  return template.replace(/\{(\w+)\}/g, (m, k: string) => (k in vars ? String(vars[k]) : m));
}

export interface TextTools {
  /** The text for a key, filled in. */
  tr(key: StringKey, vars?: StringVars): string;
  /** key_one for 1, key_other otherwise. `count` is filled in for you. */
  plural(base: string, count: number, vars?: StringVars): string;
}

export function textTools(overrides?: Partial<MealioStrings>): TextTools {
  const table = { ...DEFAULT_STRINGS, ...(overrides || {}) };
  const tr = (key: StringKey, vars?: StringVars) => fillText(table[key], vars);
  return {
    tr,
    plural: (base, count, vars) => tr(`${base}_${count === 1 ? 'one' : 'other'}` as StringKey, { count, ...(vars || {}) }),
  };
}
