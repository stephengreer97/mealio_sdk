// The partner-facing flow, platform neutral. A platform SDK supplies a Host
// (WebViews + HTTP) and wraps this in its own idiom.

import { Runner, type Host } from './runner';
import { Allowlist } from './allowlist';
import { openEnvelope, EnvelopeError } from './verify';
import { SUPPORTED_OPS } from './protocol';
import type {
  AddResult, AllowlistPayload, CartItem, Envelope, Instruction, PreparedCart, Product, Recipe, SearchResult, Selection, StepRequest, StoreInfo,
} from './protocol';

export const SDK_CORE_VERSION = '0.1.0';
export const DEFAULT_BASE_URL = 'https://mealio.co';

export type MealioErrorCode =
  | 'bad_envelope' | 'blocked' | 'store_unavailable' | 'login_cancelled' | 'session_expired'
  | 'network' | 'unsupported' | 'server' | string;

/**
 * What the SDK is doing right now, for a progress screen. Inferred from the
 * server's instruction ids (open-, session-, login-, search-, add-), never
 * from store specifics.
 */
export type Step = 'connecting' | 'checking_sign_in' | 'signing_in' | 'searching' | 'adding';
export type StepListener = (step: Step, ins: Instruction) => void;

export function stepOf(ins: Instruction): Step {
  if (ins.op === 'show_login') return 'signing_in';
  const id = ins.id || '';
  if (id.startsWith('search')) return 'searching';
  if (id.startsWith('add')) return 'adding';
  if (id.startsWith('session') || id.startsWith('resession')) return 'checking_sign_in';
  return 'connecting';
}

export class MealioError extends Error {
  constructor(public code: MealioErrorCode, message: string) { super(message); this.name = 'MealioError'; }
}

export interface ClientConfig {
  publishableKey: string;
  /** From POST /api/v1/sessions on the partner's server. Called again after session_expired. */
  getSessionToken: () => Promise<string>;
  platform: 'react-native' | 'ios' | 'android' | 'flutter' | 'web-test';
  sdkVersion: string;
  baseUrl?: string;
  /** App Attest / Play Integrity token, when the partner has turned attestation on. */
  getAttestation?: () => Promise<string | null>;
  /** The device's store-session epoch (bumped by signOutOfAllStores). */
  getEpoch?: () => Promise<number>;
  fetchImpl?: typeof fetch;
  keys?: Record<string, string>;
}

interface JobStart { job: string; envelope: Envelope }

export class MealioClient {
  private runner: Runner;
  private token: string | null = null;
  private base: string;
  private f: typeof fetch;

  constructor(private cfg: ClientConfig, host: Host) {
    this.runner = new Runner(host, new Allowlist(), cfg.keys);
    this.base = (cfg.baseUrl || DEFAULT_BASE_URL).replace(/\/$/, '');
    this.f = cfg.fetchImpl || fetch;
  }

  /** Start a cart: signs in to the store if needed, searches every ingredient. */
  /** Stores the SDK supports right now. Public, no session needed. */
  async stores(): Promise<StoreInfo[]> {
    try {
      const res = await this.f(this.base + '/api/v1/stores');
      const j = await res.json();
      return Array.isArray(j?.stores) ? j.stores : [];
    } catch {
      throw new MealioError('network', 'Could not reach Mealio');
    }
  }

  /**
   * Start a cart: signs in to the store if needed, searches every ingredient.
   * `store` is optional: without it Mealio uses the user's default store, and
   * fails with `store_required` when they have none yet.
   */
  async prepareCart(input: { store?: string | null; recipe: Recipe; zip?: string | null }, opts: { onStep?: StepListener } = {}): Promise<CartSession> {
    const start = await this.post<JobStart>('/api/v1/sdk/carts', { ...input, ...(await this.about()) });
    const result = await this.drive(start, opts.onStep) as unknown as PreparedCart;
    return new CartSession(this, result);
  }

  /** Search the store again for one item ("minced garlic jar"). */
  async search(cartId: string, key: string, query: string, opts: { onStep?: StepListener } = {}): Promise<SearchResult> {
    const start = await this.post<JobStart>(`/api/v1/sdk/carts/${encodeURIComponent(cartId)}/search`, { key, query, ...(await this.about()) });
    return await this.drive(start, opts.onStep) as unknown as SearchResult;
  }

  /** Fill the store cart with the user's choices. */
  async addToCart(cartId: string, selections: Selection[], opts: { onStep?: StepListener } = {}): Promise<AddResult> {
    const start = await this.post<JobStart>(`/api/v1/sdk/carts/${encodeURIComponent(cartId)}/add`, { selections, ...(await this.about()) });
    return await this.drive(start, opts.onStep) as unknown as AddResult;
  }

  /** Who is calling, carried on every job-starting call (this used to be a separate hello round trip). */
  private async about(): Promise<{ sdk: Record<string, unknown>; epoch: number }> {
    const epoch = this.cfg.getEpoch ? await this.cfg.getEpoch() : 0;
    return { sdk: { platform: this.cfg.platform, version: this.cfg.sdkVersion, core: SDK_CORE_VERSION, ops: SUPPORTED_OPS }, epoch };
  }

  /** Apply a signed allowlist widening, if the server ever sends one. */
  widenAllowlist(env: Envelope): void {
    try {
      const p = openEnvelope(env, this.cfg.keys);
      if (p.kind === 'allowlist') this.runner.allowlist.widen(p as AllowlistPayload);
    } catch { /* an allowlist we cannot verify is ignored, the bundled one stands */ }
  }

  private async drive(start: JobStart, onStep?: StepListener): Promise<unknown> {
    let env = start.envelope;
    let seq = 0;
    for (let guard = 0; guard < 200; guard += 1) {
      let out;
      try {
        out = await this.runner.run(env, start.job, seq, onStep ? (ins) => onStep(stepOf(ins), ins) : undefined);
      } catch (e) {
        if (e instanceof EnvelopeError) throw new MealioError(e.why === 'unsupported_op' ? 'unsupported' : 'bad_envelope', e.message);
        throw e;
      }
      seq = out.payload.seq;
      if (out.terminal) {
        if (out.terminal.kind === 'done') return out.terminal.result;
        throw new MealioError(out.terminal.code, out.terminal.message);
      }
      const body: StepRequest = { seq, results: out.results };
      const next = await this.post<{ envelope: Envelope }>(`/api/v1/sdk/jobs/${encodeURIComponent(start.job)}/step`, body);
      env = next.envelope;
    }
    throw new MealioError('server', 'job did not finish');
  }

  private async post<T>(path: string, body: unknown, retried = false): Promise<T> {
    if (!this.token) this.token = await this.cfg.getSessionToken();
    const headers: Record<string, string> = {
      'content-type': 'application/json',
      authorization: `Bearer ${this.token}`,
      'x-mealio-publishable-key': this.cfg.publishableKey,
      'x-mealio-sdk': `${this.cfg.platform}/${this.cfg.sdkVersion}`,
    };
    if (this.cfg.getAttestation) {
      const a = await this.cfg.getAttestation().catch(() => null);
      if (a) headers['x-mealio-attestation'] = a;
    }
    let res: Response;
    try {
      res = await this.f(this.base + path, { method: 'POST', headers, body: JSON.stringify(body) });
    } catch (e) {
      throw new MealioError('network', 'Could not reach Mealio');
    }
    if (res.status === 401 && !retried) {
      this.token = null;
      return this.post<T>(path, body, true);
    }
    let json: any = null;
    try { json = await res.json(); } catch { /* fall through */ }
    if (res.status === 401) throw new MealioError('session_expired', 'The Mealio session expired');
    if (!res.ok) throw new MealioError(json?.error?.code || 'server', json?.error?.message || `Mealio answered ${res.status}`);
    return json as T;
  }
}

/**
 * A prepared cart. Every item is shown every run. Remembered products start
 * selected; the user can select another option, search for something else,
 * or deselect an item to leave it out of THIS run (its remembered choice is
 * kept for next time).
 */
/** The weight step (lb) for a sold-by-weight item whose store lists no weights. */
export const WEIGHT_STEP = 0.25;
/** The most a selection may ask for, in lb. The server refuses more. */
export const MAX_WEIGHT_LB = 20;

function nearestIndex(opts: number[], v: number): number {
  let best = 0;
  opts.forEach((o, i) => { if (Math.abs(o - v) < Math.abs(opts[best] - v) - 1e-9) best = i; });
  return best;
}

export class CartSession {
  private picks = new Map<string, { productId: string; preferenceId: string | null }>();
  private extra = new Map<string, Product[]>();
  private qty = new Map<string, number>();
  private lb = new Map<string, number>();

  constructor(private client: MealioClient, public readonly cart: PreparedCart) {
    for (const it of this.items) {
      if (it.selectedId) this.picks.set(it.key, { productId: it.selectedId, preferenceId: it.rememberedPreferenceId ?? null });
    }
  }

  get cartId(): string { return this.cart.cartId; }
  get store(): string { return this.cart.store; }
  /** Every item in recipe order (older servers: rebuilt from the 0.1 groupings). */
  get items(): CartItem[] {
    if (this.cart.items) return this.cart.items;
    return [...this.cart.ready, ...this.cart.needsChoice, ...this.cart.unavailable];
  }
  /** @deprecated */ get ready(): CartItem[] { return this.cart.ready; }
  /** @deprecated */ get needsChoice(): CartItem[] { return this.cart.needsChoice; }
  /** @deprecated */ get unavailable(): CartItem[] { return this.cart.unavailable; }

  /** Options for an item, including any found with search(). */
  options(key: string): Product[] {
    const it = this.find(key);
    const base = it ? (it.options || (it.chosen ? [it.chosen] : [])) : [];
    const more = this.extra.get(key) || [];
    const seen = new Set(base.map((p) => p.id));
    return [...base, ...more.filter((p) => !seen.has(p.id))];
  }

  selectedId(key: string): string | null { return this.picks.get(key)?.productId ?? null; }

  /** Packages to add for an item: the recipe's quantity until the user changes it. */
  quantity(key: string): number {
    return this.qty.get(key) ?? Math.max(1, Math.floor(this.find(key)?.quantity || 1));
  }

  /** The most the user can add: the selected product's store cap, else 99. */
  maxQuantity(key: string): number {
    const cap = this.selected(key)?.maxQuantity;
    return typeof cap === 'number' && cap > 0 ? Math.min(99, cap) : 99;
  }

  /** Set the quantity, clamped to 1 and the store's cap. Returns what was set. */
  setQuantity(key: string, n: number): number {
    const v = Math.max(1, Math.min(this.maxQuantity(key), Math.floor(Number.isFinite(n) ? n : 1)));
    this.qty.set(key, v);
    return v;
  }

  /** True when the selected product is sold by weight: use weight(), not quantity(). */
  isWeight(key: string): boolean { return !!this.selected(key)?.soldByWeight; }

  /**
   * The lightest and heaviest weight (lb) the user can pick for the selected
   * product: its first and last weightOption, else 0.25 to 20.
   */
  weightRange(key: string): { min: number; max: number } {
    const opts = this.weightOptions(key);
    if (!opts.length) return { min: WEIGHT_STEP, max: MAX_WEIGHT_LB };
    return { min: opts[0], max: Math.min(MAX_WEIGHT_LB, opts[opts.length - 1]) };
  }

  /**
   * Pounds to add for a sold-by-weight item: the user's, else the recipe's own
   * weight, else the store's first weight option, else 0.25. Always a weight
   * the selected product can be bought in (see setWeight). 0 for count items.
   */
  weight(key: string): number {
    if (!this.isWeight(key)) return 0;
    const set = this.lb.get(key);
    if (set != null) return this.snapWeight(key, set);
    const recipe = this.find(key)?.weightLb;
    if (typeof recipe === 'number' && recipe > 0) return this.snapWeight(key, recipe);
    return this.weightOptions(key)[0] ?? WEIGHT_STEP;
  }

  /**
   * Set the weight in lb. Snapped to the nearest weightOption when the store
   * lists them, else to 0.25 lb steps, and clamped to weightRange. Returns
   * what was set.
   */
  setWeight(key: string, lb: number): number {
    const v = this.snapWeight(key, Number.isFinite(lb) ? lb : 0);
    this.lb.set(key, v);
    return v;
  }

  /** One step heavier (+1) or lighter (-1): the next weightOption, else 0.25 lb. Returns the new weight. */
  stepWeight(key: string, dir: 1 | -1): number {
    const cur = this.weight(key);
    const opts = this.weightOptions(key);
    if (!opts.length) return this.setWeight(key, cur + dir * WEIGHT_STEP);
    const i = nearestIndex(opts, cur);
    return this.setWeight(key, opts[Math.max(0, Math.min(opts.length - 1, i + dir))]);
  }

  private weightOptions(key: string): number[] {
    const raw = this.selected(key)?.weightOptions || [];
    const opts = [...new Set(raw.map(Number).filter((n) => Number.isFinite(n) && n > 0 && n <= MAX_WEIGHT_LB))];
    return opts.sort((a, b) => a - b);
  }

  private snapWeight(key: string, lb: number): number {
    const { min, max } = this.weightRange(key);
    const opts = this.weightOptions(key);
    const v = Math.max(min, Math.min(max, lb));
    if (opts.length) return opts[nearestIndex(opts, v)];
    return Math.max(min, Math.min(max, Math.round(v / WEIGHT_STEP) * WEIGHT_STEP));
  }

  isSelected(key: string): boolean { return this.picks.has(key); }
  selectedCount(): number { return this.picks.size; }

  select(key: string, productId: string, opts: { preferenceId?: string | null } = {}): void {
    if (!this.find(key)) throw new MealioError('unknown_item', `No item ${key}`);
    if (!this.options(key).some((p) => p.id === productId)) throw new MealioError('unknown_product', `Product ${productId} was not offered for ${key}`);
    this.picks.set(key, { productId, preferenceId: opts.preferenceId ?? null });
  }

  /** Leave the item out of this run. Its remembered choice is kept. */
  deselect(key: string): void { this.picks.delete(key); }

  /** Search the store for something else and add the results to this item's options. */
  async search(key: string, query: string): Promise<Product[]> {
    const r = await this.client.search(this.cart.cartId, key, query);
    const prev = this.extra.get(key) || [];
    const seen = new Set(prev.map((p) => p.id));
    this.extra.set(key, [...r.options.filter((p) => !seen.has(p.id)), ...prev]);
    return r.options;
  }

  selections(): Selection[] {
    return this.items.map((it) => {
      const p = this.picks.get(it.key);
      if (!p) return { key: it.key, productId: null, remember: false };
      if (this.isWeight(it.key)) {
        return { key: it.key, productId: p.productId, quantity: 1, weightLb: this.weight(it.key), remember: true, preferenceId: p.preferenceId };
      }
      return { key: it.key, productId: p.productId, quantity: Math.min(this.quantity(it.key), this.maxQuantity(it.key)), remember: true, preferenceId: p.preferenceId };
    });
  }

  async addToCart(opts: { onStep?: StepListener } = {}): Promise<AddResult> {
    return this.client.addToCart(this.cart.cartId, this.selections(), opts);
  }

  /** The selected product for an item, from its options. */
  selected(key: string): Product | null {
    const id = this.selectedId(key);
    return id ? this.options(key).find((p) => p.id === id) || null : null;
  }

  /**
   * Estimated total of the selected items: unit price times quantity, and for a
   * sold-by-weight item price per lb times the weight (one package price when
   * the store prices it as a package). `estimated` is true when any item is
   * sold by weight or has no price, so show it as "about".
   */
  estimate(): { total: number; count: number; estimated: boolean; unpriced: number } {
    let total = 0, count = 0, unpriced = 0, estimated = false;
    for (const it of this.items) {
      const p = this.selected(it.key);
      if (!p) continue;
      count += 1;
      if (p.soldByWeight) {
        estimated = true;
        if (typeof p.pricePerLb === 'number') total += p.pricePerLb * this.weight(it.key);
        else if (typeof p.unitPrice === 'number') total += p.unitPrice;
        else unpriced += 1;
        continue;
      }
      if (typeof p.unitPrice === 'number') total += p.unitPrice * Math.min(this.quantity(it.key), this.maxQuantity(it.key));
      else unpriced += 1;
      if (p.estimated) estimated = true;
    }
    return { total: Math.round(total * 100) / 100, count, estimated: estimated || unpriced > 0, unpriced };
  }

  /** @deprecated use select() */
  choose(key: string, productId: string, opts: { quantity?: number; remember?: boolean; preferenceId?: string | null } = {}): void {
    this.select(key, productId, { preferenceId: opts.preferenceId });
  }
  /** @deprecated use deselect() */
  skip(key: string): void { this.deselect(key); }
  /** @deprecated */
  pending(): CartItem[] { return this.items.filter((it) => it.status !== 'unavailable' && !this.picks.has(it.key)); }

  private find(key: string): CartItem | undefined {
    return this.items.find((i) => i.key === key);
  }
}
