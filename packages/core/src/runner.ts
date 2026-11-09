// The relay loop: verify an envelope, check every URL against the allowlist,
// run each instruction on the platform's Host, and return the results. The
// Host is the only platform-specific part (WebViews, HTTP, UI).

import { Allowlist, bodyBlocked } from './allowlist';
import { GUARD_ARM_SCRIPT, GUARD_SCRIPT } from './guard';
import { checkInstructions, openEnvelope, EnvelopeError } from './verify';
import type {
  Envelope, FetchOp, FetchResult, Instruction, InstructionResult, Json, JsonMessage, Matcher,
  PageOpenResult, PageScriptResult, ShowLoginResult, InstructionsPayload,
} from './protocol';

/** Fetch instructions per store per minute (PROTOCOL.md "Rate caps"). */
export const FETCH_PER_MINUTE = 120;

/**
 * How long past an instruction's own timeout a Host may take to answer. A Host
 * that never answers ends the step here, so no job can hang.
 */
export const HOST_GRACE_MS = 5_000;

/**
 * Why a job was cancelled, carried on its `cancelled` error:
 * - `user_changed`: setUser moved to another user, or resetSession ran while
 *   the job waited for its session. Prepare again for the new user.
 * - `closed`: the screen that asked for it went away.
 * - `cancelled`: anything else (cancelJobs, a store sign-out, your own token).
 */
export type CancelReason = 'user_changed' | 'closed' | 'cancelled';

/** Stops a prepare or a search. See MealioClient.prepareCart. */
export class CancelToken {
  cancelled = false;
  /** Why it was cancelled. Null until it is. The first cancel's reason stands. */
  reason: CancelReason | null = null;
  private listeners: Array<() => void> = [];

  cancel(reason: CancelReason = 'cancelled'): void {
    if (this.cancelled) return;
    this.cancelled = true;
    this.reason = reason;
    const list = this.listeners;
    this.listeners = [];
    for (const fn of list) { try { fn(); } catch { /* one listener never stops the rest */ } }
  }

  /** Call `fn` on cancel, or now if already cancelled. Returns how to stop listening. */
  onCancel(fn: () => void): () => void {
    if (this.cancelled) { fn(); return () => {}; }
    this.listeners.push(fn);
    return () => { this.listeners = this.listeners.filter((x) => x !== fn); };
  }
}

/** `p`, or `fallback` once `ms` passes. */
function bounded<T>(p: Promise<T>, ms: number, fallback: T): Promise<T> {
  let timer: ReturnType<typeof setTimeout>;
  const late = new Promise<T>((resolve) => { timer = setTimeout(() => resolve(fallback), ms); });
  return Promise.race([p, late]).finally(() => clearTimeout(timer));
}

export interface Host {
  /** Load `url` in the hidden WebView. */
  openPage(store: string, url: string, timeoutMs: number): Promise<{ ok: boolean; finalUrl?: string; error?: string }>;
  /**
   * Inject `guard` then `script` into the hidden page's top frame. `guard` is
   * GUARD_ARM_SCRIPT, the per-script copy that arms the guard; the hidden
   * WebView's document-start copy is GUARD_SCRIPT. Resolve with every JSON
   * message posted after injection, stopping at the first that matches `until`
   * or when `timeoutMs` passes.
   */
  runScript(store: string, guard: string, script: string, until: Matcher[], timeoutMs: number):
    Promise<{ messages: JsonMessage[]; timedOut: boolean; error?: string }>;
  /**
   * Show the login sheet. `allowNavigation(url)` must be asked for every
   * top-frame navigation; refuse it when false.
   */
  showLogin(opts: {
    store: string; url: string; title: string;
    /** GUARD_SCRIPT: inject it into every frame at document start. It installs the guard unarmed. */
    guard: string;
    /** GUARD_ARM_SCRIPT: inject it into the top frame right before each `check.script`. */
    armGuard: string;
    check?: { script: string; intervalMs: number } | null;
    doneWhen: Matcher[]; doneWhenUrl?: string | null; timeoutMs: number;
    allowNavigation: (url: string) => boolean;
    /** Close the sheet as `cancelled` when this fires. */
    cancel?: CancelToken;
  }): Promise<{ outcome: 'signed_in' | 'cancelled' | 'timeout'; messages: JsonMessage[] }>;
  /**
   * Optional. Load about:blank in the hidden page and forget which store it
   * was on. Called before the next job when exclusive work (runExclusive) was
   * cut off by its cap and may have left the page in any state. Bounded by
   * the client at PAGE_RESET_MS.
   */
  resetPage?(): Promise<void>;
  /** One HTTP request with the store's cookies. */
  fetch(store: string, req: FetchOp['request'], timeoutMs: number, maxBytes: number):
    Promise<{ ok: boolean; status?: number; headers?: Record<string, string>; body?: string; truncated?: boolean; error?: string }>;
}

export type Terminal =
  | { kind: 'done'; result: Json }
  | { kind: 'fail'; code: string; message: string };

export interface StepOutcome {
  payload: InstructionsPayload;
  results: InstructionResult[];
  terminal: Terminal | null;
  /** The cancel token fired before the envelope finished. */
  cancelled?: boolean;
}

const now = () => Date.now();

export class Runner {
  private fetchStamps: Record<string, number[]> = {};
  /**
   * How many times the hidden page has been told to load. A warm-up is only
   * worth anything while the page it left behind is still the one showing, and
   * this is how the client knows nothing has loaded over it since.
   */
  pageOpens = 0;

  constructor(private host: Host, public allowlist: Allowlist = new Allowlist(), private keys?: Record<string, string>) {}

  /** Verify and run one envelope. Throws EnvelopeError when it must be refused. */
  async run(env: Envelope, job: string | null, lastSeq: number, onStep?: (ins: Instruction) => void,
    opts: { allowLogin?: boolean; cancel?: CancelToken } = {}): Promise<StepOutcome> {
    const payload = checkInstructions(openEnvelope(env, this.keys), job, lastSeq);
    const results: InstructionResult[] = [];
    let terminal: Terminal | null = null;
    let failed = false;

    for (const ins of payload.instructions) {
      if (ins.op === 'done') { terminal = { kind: 'done', result: ins.result }; break; }
      if (ins.op === 'fail') { terminal = { kind: 'fail', code: ins.code, message: ins.message }; break; }
      if (failed) { results.push(skipped(ins)); continue; }
      // Checked right before each step, so a cancelled job never opens sign-in.
      if (opts.cancel?.cancelled) return { payload, results, terminal: null, cancelled: true };
      try { onStep?.(ins); } catch { /* a progress callback never breaks a run */ }
      const r = await this.one(payload.store, ins, opts.allowLogin !== false, opts.cancel);
      results.push(r);
      if (!r.ok) failed = true;
    }
    return { payload, results, terminal };
  }

  private async one(store: string, ins: Instruction, allowLogin = true, cancel?: CancelToken): Promise<InstructionResult> {
    const t0 = now();
    switch (ins.op) {
      case 'page_open': {
        const v = this.allowlist.check(store, ins.url, 'page');
        if (!v.ok) return { id: ins.id, ok: false, error: 'blocked', ms: 0 } as PageOpenResult;
        this.pageOpens += 1;
        try {
          const r = await bounded(this.host.openPage(store, ins.url, ins.timeoutMs), ins.timeoutMs + HOST_GRACE_MS, { ok: false, error: 'timeout' });
          return { id: ins.id, ok: r.ok, finalUrl: r.finalUrl, error: r.error, ms: now() - t0 } as PageOpenResult;
        } catch (e) {
          return { id: ins.id, ok: false, error: 'load_failed', ms: now() - t0 } as PageOpenResult;
        }
      }
      case 'page_script': {
        try {
          const r = await bounded(this.host.runScript(store, GUARD_ARM_SCRIPT, ins.script, ins.until || [], ins.timeoutMs),
            ins.timeoutMs + HOST_GRACE_MS, { messages: [], timedOut: true });
          return { id: ins.id, ok: !r.error, messages: r.messages, timedOut: r.timedOut, error: r.error, ms: now() - t0 } as PageScriptResult;
        } catch (e) {
          return { id: ins.id, ok: false, messages: [], timedOut: false, error: String(e).slice(0, 120), ms: now() - t0 } as PageScriptResult;
        }
      }
      case 'show_login': {
        // A warm-up runs before the user has tapped anything: it may check
        // who is signed in, never put a sign-in sheet in front of them.
        if (!allowLogin || cancel?.cancelled) return { id: ins.id, ok: false, outcome: 'cancelled', messages: [], error: 'not_allowed', ms: 0 } as ShowLoginResult;
        const v = this.allowlist.check(store, ins.url, 'login');
        if (!v.ok) return { id: ins.id, ok: false, outcome: 'cancelled', messages: [], error: 'blocked', ms: 0 } as ShowLoginResult;
        try {
          const r = await bounded(this.host.showLogin({
            store, url: ins.url, title: ins.title, guard: GUARD_SCRIPT, armGuard: GUARD_ARM_SCRIPT, check: ins.check ?? null,
            doneWhen: ins.doneWhen || [], doneWhenUrl: ins.doneWhenUrl ?? null, timeoutMs: ins.timeoutMs,
            allowNavigation: (u) => this.allowlist.check(store, u, 'login').ok,
            cancel,
          }), ins.timeoutMs + HOST_GRACE_MS, { outcome: 'timeout', messages: [] });
          return { id: ins.id, ok: true, outcome: r.outcome, messages: r.messages, ms: now() - t0 } as ShowLoginResult;
        } catch (e) {
          return { id: ins.id, ok: false, outcome: 'cancelled', messages: [], error: String(e).slice(0, 120), ms: now() - t0 } as ShowLoginResult;
        }
      }
      case 'fetch': {
        const v = this.allowlist.check(store, ins.request.url, 'fetch');
        if (!v.ok) return { id: ins.id, ok: false, error: 'blocked', ms: 0 } as FetchResult;
        // The guard stops a page script naming an order or a payment; this op
        // never passes through a page, so the same rule is applied here.
        if (bodyBlocked(ins.request.body)) return { id: ins.id, ok: false, error: 'blocked', ms: 0 } as FetchResult;
        if (this.overRate(store)) return { id: ins.id, ok: false, error: 'rate', ms: 0 } as FetchResult;
        try {
          const r = await bounded(this.host.fetch(store, ins.request, ins.timeoutMs, ins.maxBytes),
            ins.timeoutMs + HOST_GRACE_MS, { ok: false, error: 'timeout' });
          return { id: ins.id, ...r, ms: now() - t0 } as FetchResult;
        } catch (e) {
          return { id: ins.id, ok: false, error: 'no_response', ms: now() - t0 } as FetchResult;
        }
      }
      default:
        throw new EnvelopeError('unsupported_op');
    }
  }

  private overRate(store: string): boolean {
    const t = now();
    const list = (this.fetchStamps[store] ||= []);
    while (list.length && t - list[0] > 60_000) list.shift();
    if (list.length >= FETCH_PER_MINUTE) return true;
    list.push(t);
    return false;
  }
}

function skipped(ins: Instruction): InstructionResult {
  switch (ins.op) {
    case 'page_script': return { id: ins.id, ok: false, messages: [], timedOut: false, skipped: true, ms: 0 };
    case 'show_login': return { id: ins.id, ok: false, outcome: 'cancelled', messages: [], skipped: true, ms: 0 };
    default: return { id: ins.id, ok: false, skipped: true, ms: 0 } as PageOpenResult;
  }
}
