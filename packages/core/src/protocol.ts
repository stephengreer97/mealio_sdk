// The relay protocol, as types. PROTOCOL.md is the prose version and wins any
// disagreement; this file exists so the reference SDK cannot drift from it
// without a compile error.

export const PROTOCOL_VERSION = 1;

/** Max instructions the SDK will accept in one envelope. */
export const MAX_INSTRUCTIONS = 64;

/** Clock skew allowed when checking `exp`, in seconds. */
export const EXP_SKEW_SECONDS = 120;

export type Json = null | boolean | number | string | Json[] | { [k: string]: Json };

export interface Envelope {
  payload: string;
  sig: string;
  kid: string;
}

export interface Matcher {
  type: string;
  eq?: Record<string, Json>;
  ne?: Record<string, Json>;
}

export interface PageOpen {
  op: 'page_open';
  id: string;
  url: string;
  timeoutMs: number;
}

export interface PageScript {
  op: 'page_script';
  id: string;
  script: string;
  until: Matcher[];
  timeoutMs: number;
}

export interface ShowLogin {
  op: 'show_login';
  id: string;
  url: string;
  title: string;
  check?: { script: string; intervalMs: number } | null;
  doneWhen: Matcher[];
  doneWhenUrl?: string | null;
  timeoutMs: number;
}

export interface FetchRequest {
  method: string;
  url: string;
  headers?: Record<string, string>;
  body?: string | null;
}

export interface FetchOp {
  op: 'fetch';
  id: string;
  request: FetchRequest;
  timeoutMs: number;
  maxBytes: number;
}

export interface DoneOp {
  op: 'done';
  id: string;
  result: Json;
}

export interface FailOp {
  op: 'fail';
  id: string;
  code: string;
  message: string;
}

export type Instruction = PageOpen | PageScript | ShowLogin | FetchOp | DoneOp | FailOp;

export const SUPPORTED_OPS: Instruction['op'][] = ['page_open', 'page_script', 'show_login', 'fetch', 'done', 'fail'];

export interface InstructionsPayload {
  v: number;
  kind: 'instructions';
  job: string;
  seq: number;
  exp: number;
  store: string;
  instructions: Instruction[];
}

export interface AllowlistPayload {
  v: number;
  kind: 'allowlist';
  exp: number;
  stores: Record<string, { hosts?: string[]; authHosts?: string[] }>;
}

export type Payload = InstructionsPayload | AllowlistPayload;

// ── results ────────────────────────────────────────────────────────────────

export type JsonMessage = Record<string, Json>;

export interface PageOpenResult { id: string; ok: boolean; finalUrl?: string; error?: string; ms: number; skipped?: boolean }
export interface PageScriptResult { id: string; ok: boolean; messages: JsonMessage[]; timedOut: boolean; error?: string; ms: number; skipped?: boolean }
export interface ShowLoginResult { id: string; ok: boolean; outcome: 'signed_in' | 'cancelled' | 'timeout'; messages: JsonMessage[]; error?: string; ms: number; skipped?: boolean }
export interface FetchResult {
  id: string; ok: boolean; status?: number; headers?: Record<string, string>;
  body?: string; truncated?: boolean; error?: string; ms: number; skipped?: boolean;
}

export type InstructionResult = PageOpenResult | PageScriptResult | ShowLoginResult | FetchResult;

export interface StepRequest {
  seq: number;
  results: InstructionResult[];
}

// ── what the server hands back from a finished job ─────────────────────────

export interface Product {
  id: string;
  name: string;
  price?: string | null;
  imageUrl?: string | null;
  size?: string | null;
  outOfStock?: boolean;
  /** Why this option sits where it does. Ranking only, never an automatic pick. */
  badge?: 'picked_before' | 'popular' | 'partner_pick' | null;
  /**
   * Variants the user must pick one of before this product can be added
   * (H-E-B: "sliced or shaved?"). Pass the chosen id as Selection.preferenceId.
   */
  preferences?: Array<{ id: string; label: string }>;
  /** One unit's price as a number, for an estimated total. */
  unitPrice?: number | null;
  /** Sold by weight: the price is the store's estimate. */
  estimated?: boolean;
  /** The store's per-order cap, when it states one. */
  maxQuantity?: number | null;
  /** Sold by weight (deli, fish counter). */
  soldByWeight?: boolean;
  /** Weights offered for a sold-by-weight item, in lb, ascending. Absent when the store lists none. */
  weightOptions?: number[];
  /**
   * Price per lb for a sold-by-weight item priced by the pound. Null for a
   * weight item priced as a package. Absent on count items.
   */
  pricePerLb?: number | null;
}

export type ItemStatus = 'remembered' | 'choose' | 'remembered_unavailable' | 'unavailable';

/** A recipe that calls for a cart item, in a cart made from one or more recipes. */
export interface ItemRecipe {
  id: string;
  title: string | null;
  /** This recipe's share of the item's quantity. */
  quantity: number;
}

export interface CartItem {
  key: string;
  ingredient: string;
  /** Packages to buy: every recipe's share added together. */
  quantity: number;
  /**
   * The recipes that call for this item. A cart from several recipes merges an
   * ingredient they share into one item, and a pick on it is remembered under
   * each of them. Absent from servers older than multi-recipe.
   */
  recipes?: ItemRecipe[];
  /** The recipe's own weight for this line, in lb, when it gave one in a weight unit. */
  weightLb?: number;
  /**
   * remembered              the user's remembered product, in stock, pre-selected
   * choose                  nothing remembered yet: the user picks
   * remembered_unavailable  the remembered product is out of stock or gone this time
   * unavailable             nothing found; `reason` says why
   */
  status: ItemStatus;
  /** Every option, best first. The remembered product leads when the store has it. */
  options: Product[];
  /** Pre-selected product id for this run, or null. */
  selectedId: string | null;
  /** The user's remembered product, whatever its stock. */
  remembered: Product | null;
  rememberedPreferenceId?: string | null;
  reason?: string | null;
  /** @deprecated 0.1 shape. */
  chosen?: Product | null;
}

export interface PreparedCart {
  cartId: string;
  store: string;
  /** Display name, e.g. "H-E-B". */
  storeName?: string;
  /** The recipes this cart was made from, in the order they were sent. */
  recipes?: Array<{ id: string; title: string | null }>;
  /** Every recipe line, in recipe order. Show them all. */
  items: CartItem[];
  /** @deprecated 0.1 groupings derived from items. */
  ready: CartItem[];
  needsChoice: CartItem[];
  unavailable: CartItem[];
}

export interface SearchResult {
  key: string;
  query: string;
  options: Product[];
}

/**
 * One line the store took. Everything after weightLb is for the finished-run
 * screen and comes from the product the user chose (the server does not
 * search again). Each is optional: present only when known, and absent from
 * servers older than the finished-run screen.
 */
export interface AddedItem {
  key: string;
  productId: string;
  name: string;
  quantity: number;
  /** Set on an item added by weight: the pounds asked for. */
  weightLb?: number;
  /** The product's image, from the search that offered it. */
  imageUrl?: string;
  /** The recipe line it was added for, as the partner wrote it. */
  ingredient?: string;
  /** One unit's price. On a weight item priced as a package, the package price. */
  unitPrice?: number;
  /** Price per lb for a weight item priced by the pound. */
  pricePerLb?: number;
  /** The price is the store's estimate (weighed or "Avg." items). */
  estimated?: boolean;
}

export interface AddResult {
  cartId: string;
  store: string;
  added: AddedItem[];
  skipped: Array<{ key: string; reason: string }>;
  failed: Array<{ key: string; productId: string; name: string; reason: string }>;
  storeCartUrl: string | null;
  /** True when a cart read after adding confirmed every added item. */
  verified?: boolean;
}

export interface StoreInfo {
  id: string;
  name: string;
  /** "device": runs on the phone with the user's store login. "kroger_api": through Kroger's API. */
  via: 'device' | 'kroger_api';
}

export interface Selection {
  key: string;
  productId: string | null;
  quantity?: number;
  /**
   * Save this product as the remembered choice. Default true. A selection with
   * productId null leaves the item out of this run and never forgets the
   * remembered choice.
   */
  remember?: boolean;
  /** Required when the chosen Product has `preferences`. */
  preferenceId?: string | null;
  /**
   * Pounds, for a Product with soldByWeight. Above 0 and at most 20. The
   * store writes it by weight where it can (H-E-B, Albertsons family);
   * elsewhere the item fails as weight_not_supported. Ignored for count items.
   */
  weightLb?: number;
}

export interface RecipeIngredient {
  name: string;
  /** Packages to buy. Defaults to 1. */
  quantity?: number;
  amount?: number | null;
  unit?: string | null;
}

export interface Recipe {
  id: string;
  title?: string;
  ingredients: RecipeIngredient[];
}

/** At most this many recipes in one prepareCart. */
export const MAX_RECIPES = 10;

/**
 * What prepareCart takes. Send `recipe` for one, or `recipes` for up to
 * MAX_RECIPES at once: ingredients they share become one item, and each pick
 * is remembered under every recipe that calls for it.
 */
export type PrepareCartInput = { store?: string | null; zip?: string | null } & (
  | { recipe: Recipe; recipes?: undefined }
  | { recipes: Recipe[]; recipe?: undefined }
);
