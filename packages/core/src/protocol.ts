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
}

export type ItemStatus = 'remembered' | 'choose' | 'remembered_unavailable' | 'unavailable';

export interface CartItem {
  key: string;
  ingredient: string;
  quantity: number;
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

export interface AddResult {
  cartId: string;
  store: string;
  added: Array<{ key: string; productId: string; name: string; quantity: number }>;
  skipped: Array<{ key: string; reason: string }>;
  failed: Array<{ key: string; productId: string; name: string; reason: string }>;
  storeCartUrl: string | null;
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
