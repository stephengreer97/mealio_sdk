// The relay loop: verify an envelope, check every URL against the allowlist,
// run each instruction on the platform's Host, and return the results. The
// Host is the only platform-specific part (WebViews, HTTP, UI).

import { Allowlist } from './allowlist';
import { GUARD_SCRIPT } from './guard';
import { checkInstructions, openEnvelope, EnvelopeError } from './verify';
import type {
  Envelope, FetchOp, FetchResult, Instruction, InstructionResult, Json, JsonMessage, Matcher,
  PageOpenResult, PageScriptResult, ShowLoginResult, InstructionsPayload,
} from './protocol';

/** Fetch instructions per store per minute (PROTOCOL.md "Rate caps"). */
export const FETCH_PER_MINUTE = 120;

export interface Host {
  /** Load `url` in the hidden WebView. */
  openPage(store: string, url: string, timeoutMs: number): Promise<{ ok: boolean; finalUrl?: string; error?: string }>;
  /**
   * Inject `guard` then `script` into the hidden page. Resolve with every JSON
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
    store: string; url: string; title: string; guard: string;
    check?: { script: string; intervalMs: number } | null;
    doneWhen: Matcher[]; doneWhenUrl?: string | null; timeoutMs: number;
    allowNavigation: (url: string) => boolean;
  }): Promise<{ outcome: 'signed_in' | 'cancelled' | 'timeout'; messages: JsonMessage[] }>;
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
}

const now = () => Date.now();

export class Runner {
  private fetchStamps: Record<string, number[]> = {};

  constructor(private host: Host, public allowlist: Allowlist = new Allowlist(), private keys?: Record<string, string>) {}

  /** Verify and run one envelope. Throws EnvelopeError when it must be refused. */
  async run(env: Envelope, job: string | null, lastSeq: number, onStep?: (ins: Instruction) => void): Promise<StepOutcome> {
    const payload = checkInstructions(openEnvelope(env, this.keys), job, lastSeq);
    const results: InstructionResult[] = [];
    let terminal: Terminal | null = null;
    let failed = false;

    for (const ins of payload.instructions) {
      if (ins.op === 'done') { terminal = { kind: 'done', result: ins.result }; break; }
      if (ins.op === 'fail') { terminal = { kind: 'fail', code: ins.code, message: ins.message }; break; }
      if (failed) { results.push(skipped(ins)); continue; }
      try { onStep?.(ins); } catch { /* a progress callback never breaks a run */ }
      const r = await this.one(payload.store, ins);
      results.push(r);
      if (!r.ok) failed = true;
    }
    return { payload, results, terminal };
  }

  private async one(store: string, ins: Instruction): Promise<InstructionResult> {
    const t0 = now();
    switch (ins.op) {
      case 'page_open': {
        const v = this.allowlist.check(store, ins.url, 'page');
        if (!v.ok) return { id: ins.id, ok: false, error: 'blocked', ms: 0 } as PageOpenResult;
        try {
          const r = await this.host.openPage(store, ins.url, ins.timeoutMs);
          return { id: ins.id, ok: r.ok, finalUrl: r.finalUrl, error: r.error, ms: now() - t0 } as PageOpenResult;
        } catch (e) {
          return { id: ins.id, ok: false, error: 'load_failed', ms: now() - t0 } as PageOpenResult;
        }
      }
      case 'page_script': {
        try {
          const r = await this.host.runScript(store, GUARD_SCRIPT, ins.script, ins.until || [], ins.timeoutMs);
          return { id: ins.id, ok: !r.error, messages: r.messages, timedOut: r.timedOut, error: r.error, ms: now() - t0 } as PageScriptResult;
        } catch (e) {
          return { id: ins.id, ok: false, messages: [], timedOut: false, error: String(e).slice(0, 120), ms: now() - t0 } as PageScriptResult;
        }
      }
      case 'show_login': {
        const v = this.allowlist.check(store, ins.url, 'login');
        if (!v.ok) return { id: ins.id, ok: false, outcome: 'cancelled', messages: [], error: 'blocked', ms: 0 } as ShowLoginResult;
        try {
          const r = await this.host.showLogin({
            store, url: ins.url, title: ins.title, guard: GUARD_SCRIPT, check: ins.check ?? null,
            doneWhen: ins.doneWhen || [], doneWhenUrl: ins.doneWhenUrl ?? null, timeoutMs: ins.timeoutMs,
            allowNavigation: (u) => this.allowlist.check(store, u, 'login').ok,
          });
          return { id: ins.id, ok: true, outcome: r.outcome, messages: r.messages, ms: now() - t0 } as ShowLoginResult;
        } catch (e) {
          return { id: ins.id, ok: false, outcome: 'cancelled', messages: [], error: String(e).slice(0, 120), ms: now() - t0 } as ShowLoginResult;
        }
      }
      case 'fetch': {
        const v = this.allowlist.check(store, ins.request.url, 'fetch');
        if (!v.ok) return { id: ins.id, ok: false, error: 'blocked', ms: 0 } as FetchResult;
        if (this.overRate(store)) return { id: ins.id, ok: false, error: 'rate', ms: 0 } as FetchResult;
        try {
          const r = await this.host.fetch(store, ins.request, ins.timeoutMs, ins.maxBytes);
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
