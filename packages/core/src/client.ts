// The partner-facing flow, platform neutral. A platform SDK supplies a Host
// (WebViews + HTTP) and wraps this in its own idiom.

import { Runner, type Host } from './runner';
import { Allowlist } from './allowlist';
import { openEnvelope, EnvelopeError } from './verify';
import { SUPPORTED_OPS } from './protocol';
import type {
  AddResult, AllowlistPayload, CartItem, Envelope, PreparedCart, Recipe, Selection, StepRequest,
} from './protocol';

export const SDK_CORE_VERSION = '0.1.0';
export const DEFAULT_BASE_URL = 'https://mealio.co';

export type MealioErrorCode =
  | 'bad_envelope' | 'blocked' | 'store_unavailable' | 'login_cancelled' | 'session_expired'
  | 'network' | 'unsupported' | 'server' | string;

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
  private helloDone = false;
  private token: string | null = null;
  private base: string;
  private f: typeof fetch;

  constructor(private cfg: ClientConfig, host: Host) {
    this.runner = new Runner(host, new Allowlist(), cfg.keys);
    this.base = (cfg.baseUrl || DEFAULT_BASE_URL).replace(/\/$/, '');
    this.f = cfg.fetchImpl || fetch;
  }

  /** Start a cart: signs in to the store if needed, searches every ingredient. */
  async prepareCart(input: { store: string; recipe: Recipe; zip?: string | null }): Promise<CartSession> {
    await this.hello();
    const start = await this.post<JobStart>('/api/v1/sdk/carts', input);
    const result = await this.drive(start) as unknown as PreparedCart;
    return new CartSession(this, result);
  }

  /** Fill the store cart with the user's choices. */
  async addToCart(cartId: string, selections: Selection[]): Promise<AddResult> {
    await this.hello();
    const start = await this.post<JobStart>(`/api/v1/sdk/carts/${encodeURIComponent(cartId)}/add`, { selections });
    return await this.drive(start) as unknown as AddResult;
  }

  private async hello(): Promise<void> {
    if (this.helloDone) return;
    const epoch = this.cfg.getEpoch ? await this.cfg.getEpoch() : 0;
    const res = await this.post<{ ok: boolean; allowlist?: Envelope | null }>('/api/v1/sdk/hello', {
      sdk: { platform: this.cfg.platform, version: this.cfg.sdkVersion, core: SDK_CORE_VERSION, ops: SUPPORTED_OPS },
      epoch,
    });
    if (res.allowlist) {
      try {
        const p = openEnvelope(res.allowlist, this.cfg.keys);
        if (p.kind === 'allowlist') this.runner.allowlist.widen(p as AllowlistPayload);
      } catch { /* an allowlist we cannot verify is ignored, the bundled one stands */ }
    }
    this.helloDone = true;
  }

  private async drive(start: JobStart): Promise<unknown> {
    let env = start.envelope;
    let seq = 0;
    for (let guard = 0; guard < 200; guard += 1) {
      let out;
      try {
        out = await this.runner.run(env, start.job, seq);
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
      this.helloDone = false;
      return this.post<T>(path, body, true);
    }
    let json: any = null;
    try { json = await res.json(); } catch { /* fall through */ }
    if (res.status === 401) throw new MealioError('session_expired', 'The Mealio session expired');
    if (!res.ok) throw new MealioError(json?.error?.code || 'server', json?.error?.message || `Mealio answered ${res.status}`);
    return json as T;
  }
}

/** A prepared cart the app can show and edit before filling the store cart. */
export class CartSession {
  private picks = new Map<string, Selection>();

  constructor(private client: MealioClient, public readonly cart: PreparedCart) {
    for (const it of cart.ready) {
      if (it.chosen) this.picks.set(it.key, { key: it.key, productId: it.chosen.id, quantity: it.quantity, remember: true });
    }
  }

  get cartId(): string { return this.cart.cartId; }
  get store(): string { return this.cart.store; }
  get ready(): CartItem[] { return this.cart.ready; }
  get needsChoice(): CartItem[] { return this.cart.needsChoice; }
  get unavailable(): CartItem[] { return this.cart.unavailable; }

  /** Items still waiting on the user. */
  pending(): CartItem[] {
    return this.cart.needsChoice.filter((it) => !this.picks.has(it.key));
  }

  choose(key: string, productId: string, opts: { quantity?: number; remember?: boolean; preferenceId?: string | null } = {}): void {
    const item = this.find(key);
    if (!item) throw new MealioError('unknown_item', `No item ${key}`);
    const known = [item.chosen, ...(item.options || [])].some((p) => p && p.id === productId);
    if (!known) throw new MealioError('unknown_product', `Product ${productId} was not offered for ${key}`);
    this.picks.set(key, { key, productId, quantity: opts.quantity ?? item.quantity, remember: opts.remember ?? true, preferenceId: opts.preferenceId ?? null });
  }

  skip(key: string): void {
    this.picks.set(key, { key, productId: null, remember: false });
  }

  selections(): Selection[] {
    return [...this.picks.values()];
  }

  async addToCart(): Promise<AddResult> {
    return this.client.addToCart(this.cart.cartId, this.selections());
  }

  private find(key: string): CartItem | undefined {
    return [...this.cart.ready, ...this.cart.needsChoice].find((i) => i.key === key);
  }
}
