// The partner-facing flow, platform neutral. A platform SDK supplies a Host
// (WebViews + HTTP) and wraps this in its own idiom.

import { CancelToken, Runner, type CancelReason, type Host } from './runner';
import { Allowlist } from './allowlist';
import { openEnvelope, EnvelopeError } from './verify';
import { MAX_RECIPES, SUPPORTED_OPS } from './protocol';
import type {
  AddedItem, AddResult, AllowlistPayload, CartItem, CartWarning, Envelope, Instruction, ItemRecipe, PreparedCart, PrepareCartInput, Product, SearchResult, Selection, StepRequest, StoreInfo, StoreLocation, StorePreferences,
} from './protocol';

export const SDK_CORE_VERSION = '0.6.1';
export const DEFAULT_BASE_URL = 'https://mealio.co';

export type MealioErrorCode =
  | 'bad_envelope' | 'blocked' | 'store_unavailable' | 'login_cancelled' | 'session_expired'
  | 'session_failed' | 'not_signed_in' | 'cancelled' | 'network' | 'unsupported' | 'server' | string;

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
  /**
   * Set when `code` is `cancelled`: why (see CancelReason). `user_changed`
   * means a prepare for the new user is what the screen wants next.
   */
  reason?: CancelReason;
  constructor(public code: MealioErrorCode, message: string, reason?: CancelReason) {
    super(message);
    this.name = 'MealioError';
    if (reason) this.reason = reason;
  }
}

export interface ClientConfig {
  publishableKey: string;
  /**
   * From POST /api/v1/sessions on the partner's server. Called again after
   * session_expired. If it fails or takes over 30 seconds, the call fails with
   * `session_failed`, with your error's message as `message`.
   */
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
  /** Who is signed in to the app, or null for nobody. Leave it out to not track users. See setUser. */
  userId?: string | null;
  /** Clients that share one hidden page share one queue. Defaults to a queue of its own. */
  queue?: JobQueue;
  /** Log server warnings to the console. Debug builds only. */
  debug?: boolean;
}

interface JobStart { job: string; envelope: Envelope }

/** How long a warm-up is offered to the next prepare. The server holds the same line (WARM_TTL_MS). */
export const WARM_FRESH_MS = 4 * 60_000;

/** A finished warm-up the next prepare may start from. */
interface Warmed { job: string; store: string; at: number; pageOpens: number; epoch: number }

/** Every HTTP request, and your session function, gets this long. */
export const REQUEST_TIMEOUT_MS = 30_000;

/** `p`, or a rejection with `onLate()` once `ms` passes. */
function deadline<T>(p: Promise<T>, ms: number, onLate: () => Error): Promise<T> {
  let timer: ReturnType<typeof setTimeout>;
  const late = new Promise<never>((_, reject) => { timer = setTimeout(() => reject(onLate()), ms); });
  return Promise.race([p, late]).finally(() => clearTimeout(timer));
}

/** How long runExclusive may hold the queue, whatever its work does. */
export const EXCLUSIVE_CAP_MS = 60_000;

/** How long each bounded step of a page reset or a store sign-out may take. */
export const PAGE_RESET_MS = 10_000;

/**
 * One job at a time on the hidden page. Prepare, search, add and warm all run
 * through here, and a new job waits for the one before it to end.
 */
export class JobQueue {
  private tail: Promise<unknown> = Promise.resolve();
  /** Cart calls waiting or running. A warm-up does not start while any are. */
  pending = 0;
  /**
   * Exclusive work outlived EXCLUSIVE_CAP_MS and may still be touching the
   * hidden page. The next job resets the page before it starts.
   */
  dirty = false;

  /**
   * Run `job` after every job before it. With `cancel`: cancelled while it
   * waits, it settles at once with `cancelled` and never runs (its turn
   * passes straight on).
   */
  run<T>(job: () => Promise<T>, cancel?: CancelToken): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      let state: 'waiting' | 'running' | 'gone' = 'waiting';
      const off = cancel?.onCancel(() => {
        if (state !== 'waiting') return;
        state = 'gone';
        reject(cancelledError(cancel));
      });
      const turn = this.tail.then(async () => {
        if (state === 'gone') return;
        state = 'running';
        off?.();
        try { resolve(await job()); } catch (e) { reject(e); }
      });
      this.tail = turn.catch(() => {});
    });
  }
}

export class MealioClient {
  private runner: Runner;
  private token: string | null = null;
  /** Bumped by resetSession, so a token still on its way is not kept. */
  private sessionGen = 0;
  private base: string;
  private f: typeof fetch;
  private warmed: Warmed | null = null;
  private queue: JobQueue;
  /** Tokens of the prepares and searches waiting or running. */
  private active = new Set<CancelToken>();
  /** undefined: users are not tracked. null: nobody is signed in. */
  private user: string | null | undefined;
  private warming: Promise<void> | null = null;
  private warmCancel: CancelToken | null = null;
  private lastWarmAt = 0;

  constructor(private cfg: ClientConfig, private host: Host) {
    this.runner = new Runner(host, new Allowlist(), cfg.keys);
    this.base = (cfg.baseUrl || DEFAULT_BASE_URL).replace(/\/$/, '');
    // Bound, because a browser's fetch throws "Illegal invocation" when called as a method of another object.
    this.f = cfg.fetchImpl || fetch.bind(globalThis);
    this.queue = cfg.queue ?? new JobQueue();
    this.user = cfg.userId;
  }

  /** The stores this app offers right now. No session needed. */
  async stores(): Promise<StoreInfo[]> {
    const { status, ok, json } = await this.request('/api/v1/stores', { headers: { 'x-mealio-publishable-key': this.cfg.publishableKey } });
    return Array.isArray(answer<{ stores?: StoreInfo[] }>(status, ok, json).stores) ? json.stores : [];
  }

  /**
   * A Kroger family chain's stores near a zip, nearest first, for the user to
   * choose from. Save their choice with setStore.
   */
  async storeLocations(store: string, zip: string): Promise<StoreLocation[]> {
    const j = await this.post<{ locations?: StoreLocation[] }>('/api/v1/sdk/locations', { store, zip });
    return Array.isArray(j?.locations) ? j.locations : [];
  }

  /** The user's default store, and their exact store if it is in the Kroger family. */
  storePreferences(): Promise<StorePreferences> {
    return this.post<StorePreferences>('/api/v1/sdk/preferences', {});
  }

  /**
   * Make a store the user's default. A Kroger family store needs `locationId`
   * from storeLocations the first time, and otherwise fails with
   * `location_required`. Sending it later moves them to that store.
   */
  setStore(store: string, locationId?: string | null): Promise<StorePreferences> {
    return this.post<StorePreferences>('/api/v1/sdk/preferences', { store, ...(locationId ? { locationId } : {}) });
  }

  /**
   * Start a cart: signs in to the store if needed, searches every ingredient.
   * A Kroger family store the user has not chosen a location for fails with
   * `location_required`, before any sign-in. Pass `zip` to use the nearest store
   * instead of asking them.
   * `store` is optional: without it Mealio uses the user's default store, and
   * fails with `store_required` when they have none yet.
   * Pass `cancel` to stop it: it stops after the current step, sends nothing
   * more, never shows sign-in, and fails with `cancelled`.
   */
  async prepareCart(input: PrepareCartInput, opts: { onStep?: StepListener; cancel?: CancelToken } = {}): Promise<CartSession> {
    const recipes = input.recipes ?? (input.recipe ? [input.recipe] : []);
    if (recipes.length === 0) throw new MealioError('bad_recipe', 'Pass recipe, or recipes with at least one recipe.');
    if (recipes.length > MAX_RECIPES) throw new MealioError('too_many_recipes', `At most ${MAX_RECIPES} recipes in one cart.`);
    // One recipe goes as `recipe`, so a server from before multi-recipe still understands it.
    const body = recipes.length === 1
      ? { store: input.store, zip: input.zip, recipe: recipes[0] }
      : { store: input.store, zip: input.zip, recipes };
    const cancel = opts.cancel ?? new CancelToken();
    return this.cartJob(async () => {
      const about = await this.about();
      stopIf(cancel);
      const warm = this.takeWarm(input.store ?? null, about.epoch);
      const start = await this.post<JobStart>('/api/v1/sdk/carts', { ...body, ...about, ...(warm ? { warm } : {}) }, { cancel });
      const result = await this.driveLoop(start, opts.onStep, { cancel }) as unknown as PreparedCart;
      if (this.cfg.debug) {
        for (const w of result.warnings ?? []) console.warn(`[mealio] ${w.code}: ${w.message}`);
      }
      return new CartSession(this, result);
    }, cancel);
  }

  /**
   * Run the login check for the user's store now, before they tap, so the cart
   * that follows can start at search. Mealio picks the store: the user's
   * default, or none, in which case nothing happens (a new user has no store
   * to check yet). Never shows sign-in, never throws, and does nothing if it
   * ran in the last few minutes. MealioCartButton calls it when it appears.
   */
  warm(opts: { store?: string | null } = {}): Promise<void> {
    if (this.user === null) return Promise.resolve();
    if (this.warming && !this.warmCancel?.cancelled) return this.warming;
    // A cart is already driving the one hidden page: a warm-up now would load
    // over it mid-run. Nothing to gain either, the cart has the session.
    if (this.queue.pending > 0) return Promise.resolve();
    if (Date.now() - this.lastWarmAt < WARM_FRESH_MS) return Promise.resolve();
    this.lastWarmAt = Date.now();
    const cancel = new CancelToken();
    this.warmCancel = cancel;
    const warming: Promise<void> = this.queue.run(async () => {
      try {
        stopIf(cancel);
        await this.cleanPage();
        const about = await this.about();
        stopIf(cancel);
        const start = await this.post<JobStart | { warm: null }>('/api/v1/sdk/warm', { store: opts.store ?? undefined, ...about }, { cancel });
        if (!('job' in start)) return;
        const r = await this.driveLoop(start, undefined, { warm: true, cancel }) as { store?: string; signedIn?: boolean | null };
        this.warmed = r && r.signedIn === true && typeof r.store === 'string'
          ? { job: start.job, store: r.store, at: Date.now(), pageOpens: this.runner.pageOpens, epoch: about.epoch }
          : null;
      } catch {
        // A warm-up that fails costs the user nothing: the cart runs as it always has.
        if (!cancel.cancelled) this.warmed = null;
      }
    }, cancel).catch(() => { /* cancelled while it waited */ }).finally(() => {
      if (this.warming === warming) this.warming = null;
    });
    this.warming = warming;
    return warming;
  }

  /**
   * The signed-in user changed. Forget the session, so the next call asks your
   * server for a new one. Signing out of the stores does this too. A warm-up
   * under way stops, and its result is never offered to the next prepare.
   */
  resetSession(): void {
    this.sessionGen += 1;
    this.token = null;
    this.warmCancel?.cancel('user_changed');
    this.clearWarm();
  }

  /**
   * Tell the SDK who is signed in to your app, or null for nobody. On a change
   * it cancels any prepare or search and resets the session. An add runs on.
   * While null, warm does nothing and calls that need a session fail with
   * `not_signed_in`, without asking your server. Returns true when the old
   * value was a user: the platform then signs out of the stores.
   */
  setUser(id: string | null): boolean {
    const old = this.user;
    if (id === old) return false;
    this.user = id;
    this.cancelJobs('user_changed');
    this.resetSession();
    return typeof old === 'string';
  }

  /**
   * Cancel every prepare and search, waiting or running. An add is not
   * touched. Each fails with `cancelled` and this `reason`. One waiting in the
   * queue fails at once.
   */
  cancelJobs(reason: CancelReason = 'cancelled'): void {
    for (const c of [...this.active]) c.cancel(reason);
    this.warmCancel?.cancel(reason);
  }

  /**
   * Run `fn` with the hidden page to itself, in the queue with the jobs. For
   * work that must not land in the middle of one, like clearing store sessions.
   * After REQUEST_TIMEOUT_MS the caller gets `network` and `fn`'s cancel token
   * fires. The queue stays held until `fn` ends or EXCLUSIVE_CAP_MS passes,
   * whichever is first; past the cap the queue moves on and the next job
   * resets the hidden page (Host.resetPage) before it starts.
   */
  runExclusive<T>(fn: (cancel: CancelToken) => Promise<T>): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      void this.queue.run(async () => {
        await this.cleanPage();
        const cancel = new CancelToken();
        const timer = setTimeout(() => { cancel.cancel(); reject(new MealioError('network', 'That took too long')); }, REQUEST_TIMEOUT_MS);
        let cap: ReturnType<typeof setTimeout> | undefined;
        const work = Promise.resolve().then(() => fn(cancel)).then(resolve, reject).finally(() => clearTimeout(timer));
        const capped = new Promise<void>((done) => {
          cap = setTimeout(() => { this.queue.dirty = true; cancel.cancel(); done(); }, EXCLUSIVE_CAP_MS);
        });
        await Promise.race([work, capped]);
        clearTimeout(cap);
      });
    });
  }

  /**
   * Before a job: if exclusive work was cut off by its cap, load about:blank
   * in the hidden page, bounded by PAGE_RESET_MS. A warm-up is no longer worth
   * anything after that.
   */
  private async cleanPage(): Promise<void> {
    if (!this.queue.dirty) return;
    this.queue.dirty = false;
    this.runner.pageOpens += 1;
    if (!this.host.resetPage) return;
    let timer: ReturnType<typeof setTimeout> | undefined;
    await Promise.race([
      Promise.resolve().then(() => this.host.resetPage!()).catch(() => {}),
      new Promise<void>((r) => { timer = setTimeout(r, PAGE_RESET_MS); }),
    ]);
    clearTimeout(timer);
  }

  /**
   * The current token. One that arrives after a reset belongs to the last user,
   * so it is never kept. What happens then depends on the job:
   * - `cancel` (prepare, search, warm): the job is over, `cancelled`. It never
   *   asks for the next user's token.
   * - `gen` (an add): the add belongs to the session of that generation. If the
   *   session changed before the call or while waiting, `session_expired`.
   * - neither: ask again, for whoever is signed in now.
   */
  private async sessionToken(opts: { cancel?: CancelToken; gen?: number } = {}): Promise<string> {
    if (opts.cancel) stopIf(opts.cancel);
    if (opts.gen !== undefined && opts.gen !== this.sessionGen) throw sessionChanged();
    if (this.user === null) throw new MealioError('not_signed_in', 'Nobody is signed in');
    if (this.token) return this.token;
    const gen = this.sessionGen;
    let token = '';
    let failed: any = null;
    try {
      token = await deadline(Promise.resolve().then(() => this.cfg.getSessionToken()), REQUEST_TIMEOUT_MS,
        () => new Error('getSessionToken did not answer in time'));
    } catch (e: any) {
      failed = e ?? new Error('Could not start a Mealio session');
    }
    // Cancelled while the token was on its way: that is the answer, even if
    // the fetch failed too.
    if (opts.cancel?.cancelled) stopIf(opts.cancel);
    if (gen !== this.sessionGen) {
      if (opts.cancel) throw new MealioError('cancelled', 'Cancelled', 'user_changed');
      if (opts.gen !== undefined) throw sessionChanged();
      return this.sessionToken();
    }
    if (failed) throw new MealioError('session_failed', failed?.message || 'Could not start a Mealio session');
    this.token = token;
    return token;
  }

  /** Forget any warm-up, e.g. after signing out of the stores. */
  clearWarm(): void {
    this.warmed = null;
    this.lastWarmAt = 0;
  }

  /** The warm job id, once, if the page it left is still showing and it is still fresh. */
  private takeWarm(store: string | null, epoch: number): string | null {
    const w = this.warmed;
    this.warmed = null;
    if (!w) return null;
    if (store && store !== w.store) return null;
    if (w.pageOpens !== this.runner.pageOpens || w.epoch !== epoch) return null;
    if (Date.now() - w.at > WARM_FRESH_MS) return null;
    return w.job;
  }

  /** Search the store again for one item ("minced garlic jar"). */
  async search(cartId: string, key: string, query: string, opts: { onStep?: StepListener; cancel?: CancelToken } = {}): Promise<SearchResult> {
    const cancel = opts.cancel ?? new CancelToken();
    return this.cartJob(async () => {
      const about = await this.about();
      stopIf(cancel);
      const start = await this.post<JobStart>(`/api/v1/sdk/carts/${encodeURIComponent(cartId)}/search`, { key, query, ...about }, { cancel });
      return await this.driveLoop(start, opts.onStep, { cancel }) as unknown as SearchResult;
    }, cancel);
  }

  /**
   * Fill the store cart with the user's choices. It cannot be cancelled: once
   * tapped it runs to its end under the session of the moment it was called,
   * even if the user changes meanwhile; a 401 after such a change fails it with
   * `session_expired`. Every wait in it is bounded, so it does end.
   */
  async addToCart(cartId: string, selections: Selection[], opts: { onStep?: StepListener } = {}): Promise<AddResult> {
    // The session is the one of the moment the add was asked for, not of the
    // moment it leaves the queue: a user change while it waits cannot hand it
    // the next user's token.
    const gen = this.sessionGen;
    const first = this.sessionToken({ gen });
    first.catch(() => { /* read in the job */ });
    return this.cartJob(async () => {
      const pin: Pin = { token: await first, gen };
      const start = await this.post<JobStart>(`/api/v1/sdk/carts/${encodeURIComponent(cartId)}/add`, { selections, ...(await this.about()) }, { pin });
      return await this.driveLoop(start, opts.onStep, { pin }) as unknown as AddResult;
    });
  }

  /** Who is calling, carried on every job-starting call (this used to be a separate hello round trip). */
  private async about(): Promise<{ sdk: Record<string, unknown>; epoch: number }> {
    const epoch = this.cfg.getEpoch
      ? await deadline(this.cfg.getEpoch(), REQUEST_TIMEOUT_MS, () => new MealioError('network', 'Could not read the store sign-out state'))
      : 0;
    return { sdk: { platform: this.cfg.platform, version: this.cfg.sdkVersion, core: SDK_CORE_VERSION, ops: SUPPORTED_OPS }, epoch };
  }

  /** The allowlist in force. Hosts use it to check where their pages go. */
  get allowlist(): Allowlist {
    return this.runner.allowlist;
  }

  /** Apply a signed allowlist widening, if the server ever sends one. */
  widenAllowlist(env: Envelope): void {
    try {
      const p = openEnvelope(env, this.cfg.keys);
      if (p.kind === 'allowlist') this.runner.allowlist.widen(p as AllowlistPayload);
    } catch { /* an allowlist we cannot verify is ignored, the bundled one stands */ }
  }

  /**
   * A cart call, queued. It counts as pending from the moment it is called, so
   * a warm-up cannot slip in ahead of it. A cancelled call never starts.
   */
  private async cartJob<T>(fn: () => Promise<T>, cancel?: CancelToken): Promise<T> {
    this.queue.pending += 1;
    if (cancel) this.active.add(cancel);
    try {
      return await this.queue.run(async () => {
        if (cancel) stopIf(cancel);
        await this.cleanPage();
        return fn();
      }, cancel);
    } finally {
      this.queue.pending -= 1;
      if (cancel) this.active.delete(cancel);
    }
  }

  private async driveLoop(start: JobStart, onStep: StepListener | undefined,
    opts: { warm?: boolean; cancel?: CancelToken; pin?: Pin } = {}): Promise<unknown> {
    let env = start.envelope;
    let seq = 0;
    for (let guard = 0; guard < 200; guard += 1) {
      let out;
      try {
        out = await this.runner.run(env, start.job, seq, onStep ? (ins) => onStep(stepOf(ins), ins) : undefined, { allowLogin: !opts.warm, cancel: opts.cancel });
      } catch (e) {
        if (e instanceof EnvelopeError) throw new MealioError(e.why === 'unsupported_op' ? 'unsupported' : 'bad_envelope', e.message);
        throw e;
      }
      if (opts.cancel) stopIf(opts.cancel);
      seq = out.payload.seq;
      if (out.terminal) {
        if (out.terminal.kind === 'done') return out.terminal.result;
        throw new MealioError(out.terminal.code, out.terminal.message);
      }
      const body: StepRequest = { seq, results: out.results };
      const next = await this.post<{ envelope: Envelope }>(`/api/v1/sdk/jobs/${encodeURIComponent(start.job)}/step`, body, { cancel: opts.cancel, pin: opts.pin });
      env = next.envelope;
    }
    throw new MealioError('server', 'job did not finish');
  }

  /** One HTTP call, bounded: headers and body both inside REQUEST_TIMEOUT_MS. `json` is null if it was not JSON. */
  private async request(path: string, init: RequestInit, cancel?: CancelToken): Promise<{ status: number; ok: boolean; json: any }> {
    const ctl = new AbortController();
    const send = async () => {
      const res = await this.f(this.base + path, { ...init, signal: ctl.signal });
      let json: any = null;
      try { json = await res.json(); } catch { /* the caller decides what that means */ }
      return { status: res.status, ok: res.ok, json };
    };
    // A cancel aborts the request in flight, so the job ends now, not when Mealio answers.
    let off = () => {};
    const stopped = new Promise<never>((_, reject) => {
      off = cancel ? cancel.onCancel(() => { ctl.abort(); reject(cancelledError(cancel)); }) : off;
    });
    try {
      return await Promise.race([deadline(send(), REQUEST_TIMEOUT_MS, () => { ctl.abort(); return new Error('timeout'); }), stopped]);
    } catch (e) {
      if (cancel?.cancelled) throw cancelledError(cancel);
      throw new MealioError('network', 'Could not reach Mealio');
    } finally {
      off();
    }
  }

  /**
   * POST with the session. `cancel`: nothing is sent once it fires. `pin`: an
   * add's own token. On a 401 it is renewed only while the session is still
   * the one the add started in, else the add fails with `session_expired`.
   */
  private async post<T>(path: string, body: unknown, opts: { cancel?: CancelToken; pin?: Pin; retried?: boolean } = {}): Promise<T> {
    const token = opts.pin ? opts.pin.token : await this.sessionToken({ cancel: opts.cancel });
    if (opts.cancel) stopIf(opts.cancel);
    const headers: Record<string, string> = {
      'content-type': 'application/json',
      authorization: `Bearer ${token}`,
      'x-mealio-publishable-key': this.cfg.publishableKey,
      'x-mealio-sdk': `${this.cfg.platform}/${this.cfg.sdkVersion}`,
    };
    if (this.cfg.getAttestation) {
      const a = await deadline(this.cfg.getAttestation(), REQUEST_TIMEOUT_MS, () => new Error('timeout')).catch(() => null);
      if (a) headers['x-mealio-attestation'] = a;
    }
    const { status, ok, json } = await this.request(path, { method: 'POST', headers, body: JSON.stringify(body) }, opts.cancel);
    if (status === 401 && !opts.retried) {
      if (opts.pin && opts.pin.gen !== this.sessionGen) throw sessionChanged();
      if (this.token === token) this.token = null;
      if (opts.pin) opts.pin.token = await this.sessionToken({ gen: opts.pin.gen });
      return this.post<T>(path, body, { ...opts, retried: true });
    }
    if (status === 401) throw new MealioError('session_expired', 'The Mealio session expired');
    return answer<T>(status, ok, json);
  }
}

/** The body of a good answer, or the error it stands for. */
function answer<T>(status: number, ok: boolean, json: any): T {
  if (!ok) throw new MealioError(json?.error?.code || 'server', json?.error?.message || `Mealio answered ${status}`);
  // A captive portal or a proxy can answer 200 with a web page.
  if (json === null || typeof json !== 'object') throw new MealioError('server', 'Mealio sent an answer that could not be read');
  return json as T;
}

/** An add's token, fixed when it was asked for. Renewed only within its generation. */
interface Pin { token: string; gen: number }

function sessionChanged(): MealioError {
  return new MealioError('session_expired', 'The signed-in user changed');
}

function cancelledError(cancel?: CancelToken): MealioError {
  return new MealioError('cancelled', 'Cancelled', cancel?.reason ?? 'cancelled');
}

function stopIf(cancel: CancelToken): void {
  if (cancel.cancelled) throw cancelledError(cancel);
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

/** A total. `total` is null when any counted item has no price: show no number then. */
export interface Estimate { total: number | null; count: number; estimated: boolean; unpriced: number }

/**
 * What one added line cost, or null when its price is unknown. By weight:
 * price per lb times the pounds, else the package price once. Otherwise unit
 * price times quantity. `fallback` is the chosen Product, for servers whose
 * added entries carry no prices.
 */
export function addedPrice(a: Pick<AddedItem, 'quantity' | 'weightLb' | 'unitPrice' | 'pricePerLb' | 'estimated'>, fallback?: Product | null): { amount: number; estimated: boolean } | null {
  const perLb = typeof a.pricePerLb === 'number' ? a.pricePerLb : (typeof fallback?.pricePerLb === 'number' ? fallback.pricePerLb : null);
  const unit = typeof a.unitPrice === 'number' ? a.unitPrice : (typeof fallback?.unitPrice === 'number' ? fallback.unitPrice : null);
  const est = !!(a.estimated ?? fallback?.estimated);
  const round = (n: number) => Math.round(n * 100) / 100;
  if (typeof a.weightLb === 'number') {
    if (perLb != null) return { amount: round(perLb * a.weightLb), estimated: true };
    if (unit != null) return { amount: round(unit), estimated: true };
    return null;
  }
  if (unit == null) return null;
  return { amount: round(unit * Math.max(1, a.quantity || 1)), estimated: est };
}

/** Whole cents, so adding lines up stays exact. The list and done totals both sum these. */
const cents = (amount: number) => Math.round(amount * 100);

export class CartSession {
  private picks = new Map<string, { productId: string; preferenceId: string | null }>();
  private extra = new Map<string, Product[]>();
  private qty = new Map<string, number>();
  private lb = new Map<string, number>();
  private adding: Promise<AddResult> | null = null;
  private searches = new Set<CancelToken>();
  /** Per item, per product found with search(): the query that found it, for restorePicks on a new cart. */
  private foundBy = new Map<string, Map<string, string>>();

  constructor(private client: MealioClient, public readonly cart: PreparedCart) {
    for (const it of this.items) {
      if (it.selectedId && !it.startUnchecked) this.picks.set(it.key, { productId: it.selectedId, preferenceId: it.rememberedPreferenceId ?? null });
    }
  }

  get cartId(): string { return this.cart.cartId; }
  get store(): string { return this.cart.store; }
  /** Every item in recipe order (older servers: rebuilt from the 0.1 groupings). */
  get items(): CartItem[] {
    if (this.cart.items) return this.cart.items;
    return [...this.cart.ready, ...this.cart.needsChoice, ...this.cart.unavailable];
  }
  /** The recipes this cart was made from. Older servers: none listed. */
  get recipes(): Array<{ id: string; title: string | null }> { return this.cart.recipes ?? []; }
  /** What the server changed or ignored in what you sent. Empty from older servers. */
  get warnings(): CartWarning[] { return this.cart.warnings ?? []; }
  /** The recipes that call for an item, for a "for Tacos, Pasta" line. Empty from older servers. */
  recipesFor(key: string): ItemRecipe[] { return this.find(key)?.recipes ?? []; }
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

  /**
   * Packages to add for an item: the recipe's quantity until the user changes
   * it, never over the selected product's cap. What this returns is what is sent.
   */
  quantity(key: string): number {
    const n = this.qty.get(key) ?? Math.max(1, Math.floor(this.find(key)?.quantity || 1));
    return Math.min(n, this.maxQuantity(key));
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

  /** The preference chosen for an item's product, or null. */
  preferenceId(key: string): string | null { return this.picks.get(key)?.preferenceId ?? null; }

  /**
   * True when the item is ticked but its product offers preferences (H-E-B
   * deli slicing, for example) and none is chosen. Such an item stays out of
   * the add and the total until one is, the same rule as the Mealio app: a
   * missing preference is a different request from "No preference".
   */
  needsPreference(key: string): boolean {
    if (!this.picks.has(key)) return false;
    const prefs = this.selected(key)?.preferences;
    return !!prefs && prefs.length > 0 && !this.picks.get(key)?.preferenceId;
  }

  /** Keys of ticked items still waiting on a preference. */
  pendingPreferences(): string[] { return this.items.filter((it) => this.needsPreference(it.key)).map((it) => it.key); }
  selectedCount(): number { return this.picks.size; }

  select(key: string, productId: string, opts: { preferenceId?: string | null } = {}): void {
    if (!this.find(key)) throw new MealioError('unknown_item', `No item ${key}`);
    if (!this.options(key).some((p) => p.id === productId)) throw new MealioError('unknown_product', `Product ${productId} was not offered for ${key}`);
    this.picks.set(key, { productId, preferenceId: opts.preferenceId ?? null });
  }

  /** Leave the item out of this run. Its remembered choice is kept. */
  deselect(key: string): void { this.picks.delete(key); }

  /**
   * Take the user's picks from an earlier cart, after a failed add. Works by
   * item key, on the same store: what they unticked stays unticked, and a
   * product still offered comes back with its quantity, weight and preference.
   * A product no longer offered leaves the item as this cart set it.
   *
   * A product the user found with search() is known to the server only on the
   * cart it was found in, so it is never sent to this cart directly. Instead
   * the search that found the picked product (not merely the item's last
   * search) runs again on this cart (it counts toward the search cap), and the
   * product is picked if it comes back. If it does not, or the search fails,
   * the item keeps this cart's own pick.
   *
   * Everything except those searches is done before this returns; the promise
   * resolves when the searches end. It never rejects: it ends with whatever it
   * could restore. Pass `cancel` to stop the searches (closing the screen).
   * cancelJobs and setUser cancel that same token, so check
   * `cancel.cancelled` afterwards: a cancel from outside is not a finished
   * restore, and the caller handles it like any other cancelled job.
   */
  async restorePicks(from: CartSession, opts: { cancel?: CancelToken } = {}): Promise<void> {
    if (from.store !== this.store) return;
    const again: Array<{ key: string; productId: string; query: string }> = [];
    for (const it of this.items) {
      if (!from.find(it.key)) continue;
      const productId = from.selectedId(it.key);
      if (!productId) { this.deselect(it.key); continue; }
      if (this.options(it.key).some((p) => p.id === productId)) { this.takePick(from, it.key, productId); continue; }
      const query = from.foundBy.get(it.key)?.get(productId);
      if (query) again.push({ key: it.key, productId, query });
    }
    for (const a of again) {
      if (opts.cancel?.cancelled) return;
      try { await this.search(a.key, a.query, { cancel: opts.cancel }); } catch { continue; }
      if (this.options(a.key).some((p) => p.id === a.productId)) this.takePick(from, a.key, a.productId);
    }
  }

  /** Select `productId` (offered on this cart) with `from`'s preference, quantity and weight for it. */
  private takePick(from: CartSession, key: string, productId: string): void {
    const product = this.options(key).find((p) => p.id === productId);
    if (!product || !this.find(key)) return;
    const pref = from.preferenceId(key);
    this.select(key, productId, { preferenceId: product.preferences?.some((p) => p.id === pref) ? pref : null });
    if (from.qty.has(key)) this.setQuantity(key, from.qty.get(key) as number);
    if (from.lb.has(key)) this.setWeight(key, from.lb.get(key) as number);
  }

  /** True while a search runs. Keep Add disabled until it ends. */
  get searching(): boolean { return this.searches.size > 0; }

  /** Stop every search of this cart. Closing the sheet does this. */
  cancelSearches(): void {
    for (const c of [...this.searches]) c.cancel();
  }

  /** Search the store for something else and add the results to this item's options. */
  async search(key: string, query: string, opts: { cancel?: CancelToken } = {}): Promise<Product[]> {
    const cancel = opts.cancel ?? new CancelToken();
    this.searches.add(cancel);
    try {
      const r = await this.client.search(this.cart.cartId, key, query, { cancel });
      const prev = this.extra.get(key) || [];
      const seen = new Set(prev.map((p) => p.id));
      this.extra.set(key, [...r.options.filter((p) => !seen.has(p.id)), ...prev]);
      const by = this.foundBy.get(key) ?? new Map<string, string>();
      for (const p of r.options) if (!by.has(p.id)) by.set(p.id, query);
      this.foundBy.set(key, by);
      return r.options;
    } finally {
      this.searches.delete(cancel);
    }
  }

  selections(): Selection[] {
    return this.items.map((it) => {
      const p = this.picks.get(it.key);
      if (!p || this.needsPreference(it.key)) return { key: it.key, productId: null, remember: false };
      if (this.isWeight(it.key)) {
        return { key: it.key, productId: p.productId, quantity: 1, weightLb: this.weight(it.key), remember: true, preferenceId: p.preferenceId };
      }
      return { key: it.key, productId: p.productId, quantity: this.quantity(it.key), remember: true, preferenceId: p.preferenceId };
    });
  }

  /** A second call while one is running returns the same promise. */
  addToCart(opts: { onStep?: StepListener } = {}): Promise<AddResult> {
    if (this.adding) return this.adding;
    const adding = this.client.addToCart(this.cart.cartId, this.selections(), opts)
      .finally(() => { this.adding = null; });
    this.adding = adding;
    return adding;
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
   *
   * `total` is null when even one selected item has no price (`unpriced` > 0):
   * a total that leaves an item out is wrong, so show no number at all
   * ("Prices at checkout"). A weight item priced per lb counts as priced.
   */
  estimate(): Estimate {
    let total = 0, count = 0, unpriced = 0, estimated = false;
    for (const it of this.items) {
      const p = this.selected(it.key);
      if (!p || this.needsPreference(it.key)) continue;
      count += 1;
      // Priced line by line as the done screen will price it, so the two agree.
      const line = addedPrice({ quantity: this.quantity(it.key), weightLb: p.soldByWeight ? this.weight(it.key) : undefined }, p);
      if (p.soldByWeight) estimated = true;
      if (!line) { unpriced += 1; continue; }
      total += cents(line.amount);
      if (line.estimated) estimated = true;
    }
    return { total: unpriced > 0 ? null : total / 100, count, estimated: estimated || unpriced > 0, unpriced };
  }

  /**
   * The total of what the store took, for the finished-run screen. Same rule
   * as estimate(): `total` is null when any added item has no price. Prices
   * come from the added entries, else (an older server) from the product
   * selected in this session.
   */
  addedTotal(result: AddResult): Estimate {
    let total = 0, unpriced = 0, estimated = false;
    for (const a of result.added) {
      const p = addedPrice(a, this.selected(a.key));
      if (!p) { unpriced += 1; continue; }
      total += cents(p.amount);
      if (p.estimated) estimated = true;
    }
    return { total: unpriced > 0 ? null : total / 100, count: result.added.length, estimated: estimated || unpriced > 0, unpriced };
  }

  /** One added line's price (see addedPrice), with this session's product as the fallback. */
  addedPrice(a: AddedItem): { amount: number; estimated: boolean } | null {
    return addedPrice(a, this.selected(a.key));
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
