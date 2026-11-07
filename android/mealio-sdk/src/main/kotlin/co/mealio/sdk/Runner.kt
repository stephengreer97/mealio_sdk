package co.mealio.sdk

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withTimeoutOrNull

// The relay loop: verify an envelope, check every URL against the allowlist,
// run each instruction on the Host, and return the results. Port of
// packages/core/src/runner.ts.

/** Fetch instructions per store per minute (PROTOCOL.md "Rate caps"). */
const val FETCH_PER_MINUTE = 120

/**
 * How long past an instruction's own timeout a Host may take to answer. A Host
 * that never answers ends the step here, so no job can hang.
 */
const val HOST_GRACE_MS = 5_000L

/** Stops a prepare or a search. See MealioClient.prepareCart. */
class CancelToken {
    @Volatile var cancelled = false
        private set
    private val listeners = ArrayList<() -> Unit>()

    fun cancel() {
        val list = synchronized(this) {
            if (cancelled) return
            cancelled = true
            listeners.toList().also { listeners.clear() }
        }
        for (fn in list) {
            try {
                fn()
            } catch (e: Exception) {
                // one listener never stops the rest
            }
        }
    }

    /** Call `fn` on cancel, or now if already cancelled. Returns how to stop listening. */
    fun onCancel(fn: () -> Unit): () -> Unit {
        synchronized(this) {
            if (!cancelled) {
                listeners.add(fn)
                return { synchronized(this) { listeners.remove(fn) } }
            }
        }
        fn()
        return {}
    }
}

/** `block`, or `fallback` once `ms` passes. */
private suspend fun <T : Any> bounded(ms: Long, fallback: T, block: suspend () -> T): T =
    withTimeoutOrNull(ms) { block() } ?: fallback

sealed class Terminal {
    /** `result` is a raw JSON value. */
    data class Done(val result: Any?) : Terminal()
    data class Fail(val code: String, val message: String) : Terminal()
}

data class StepOutcome(
    val payload: InstructionsPayload,
    val results: List<InstructionResult>,
    val terminal: Terminal?,
    /** The cancel token fired before the envelope finished. */
    val cancelled: Boolean = false,
)

class Runner @JvmOverloads constructor(
    private val host: Host,
    val allowlist: Allowlist = Allowlist(),
    private val keys: Map<String, String> = KEYS,
    /** Wall clock in ms. Swappable for tests. */
    private val clock: () -> Long = { System.currentTimeMillis() },
) {
    private val fetchStamps = HashMap<String, ArrayDeque<Long>>()

    @Volatile private var opens = 0

    /**
     * How many times the hidden page has been told to load, or was lost (see
     * Host.pagesLost). A warm-up is only worth anything while the page it left
     * behind is still the one showing, and this is how the client knows nothing
     * has loaded over it since.
     */
    val pageOpens: Int get() = opens + host.pagesLost

    /**
     * Verify and run one envelope. Throws EnvelopeException when it must be refused.
     * `onStep` is called before each instruction that is executed (not for
     * done/fail or skipped ones). An exception it throws never breaks the run.
     */
    suspend fun run(
        env: Envelope?,
        job: String?,
        lastSeq: Int,
        onStep: ((Instruction) -> Unit)?,
    ): StepOutcome = run(env, job, lastSeq, allowLogin = true, onStep = onStep)

    /**
     * As above. `allowLogin` false (a warm-up) refuses show_login with
     * "not_allowed" without asking the host.
     */
    suspend fun run(
        env: Envelope?,
        job: String?,
        lastSeq: Int,
        /** False for a warm-up: show_login is refused without asking the host. */
        allowLogin: Boolean = true,
        onStep: ((Instruction) -> Unit)? = null,
        /** Stops the run before its next step. A sign-in open when it fires is closed. */
        cancel: CancelToken? = null,
    ): StepOutcome {
        val payload = checkInstructions(openEnvelope(env, keys, clock()), job, lastSeq)
        val results = ArrayList<InstructionResult>()
        var terminal: Terminal? = null
        var failed = false

        for (ins in payload.instructions) {
            if (ins is Instruction.Done) { terminal = Terminal.Done(ins.result); break }
            if (ins is Instruction.Fail) { terminal = Terminal.Fail(ins.code, ins.message); break }
            // After a failure the rest of the envelope is reported, not run.
            if (failed) { results.add(skipped(ins)); continue }
            // Checked right before each step, so a cancelled job never opens sign-in.
            if (cancel?.cancelled == true) return StepOutcome(payload, results, null, cancelled = true)
            if (onStep != null) {
                try {
                    onStep(ins)
                } catch (e: Exception) {
                    // a progress callback never breaks a run
                }
            }
            val r = one(payload.store, ins, allowLogin, cancel)
            results.add(r)
            if (!r.ok) failed = true
        }
        return StepOutcome(payload, results, terminal)
    }

    private suspend fun one(store: String, ins: Instruction, allowLogin: Boolean = true, cancel: CancelToken? = null): InstructionResult {
        val t0 = clock()
        fun ms() = clock() - t0
        return when (ins) {
            is Instruction.PageOpen -> {
                if (!allowlist.check(store, ins.url, UrlUse.PAGE).ok) {
                    return InstructionResult.PageOpenResult(ins.id, ok = false, error = "blocked", ms = 0)
                }
                opens += 1
                try {
                    val r = bounded(ins.timeoutMs + HOST_GRACE_MS, PageLoad(ok = false, error = "timeout")) {
                        host.openPage(store, ins.url, ins.timeoutMs)
                    }
                    InstructionResult.PageOpenResult(ins.id, r.ok, r.finalUrl, r.error, ms())
                } catch (e: Throwable) {
                    rethrowIfCancelled(e)
                    InstructionResult.PageOpenResult(ins.id, ok = false, error = "load_failed", ms = ms())
                }
            }
            is Instruction.PageScript -> {
                try {
                    val r = bounded(ins.timeoutMs + HOST_GRACE_MS, ScriptRun(emptyList(), timedOut = true)) {
                        host.runScript(store, GUARD_SCRIPT, ins.script, ins.until, ins.timeoutMs)
                    }
                    InstructionResult.PageScriptResult(ins.id, r.error == null, r.messages, r.timedOut, r.error, ms())
                } catch (e: Throwable) {
                    rethrowIfCancelled(e)
                    InstructionResult.PageScriptResult(ins.id, false, emptyList(), false, describe(e), ms())
                }
            }
            is Instruction.ShowLogin -> {
                // A warm-up runs before the user has tapped anything: it may check
                // who is signed in, never put a sign-in sheet in front of them.
                if (!allowLogin || cancel?.cancelled == true) {
                    return InstructionResult.ShowLoginResult(ins.id, false, LoginOutcome.CANCELLED, emptyList(), "not_allowed", 0)
                }
                if (!allowlist.check(store, ins.url, UrlUse.LOGIN).ok) {
                    return InstructionResult.ShowLoginResult(ins.id, false, LoginOutcome.CANCELLED, emptyList(), "blocked", 0)
                }
                try {
                    val r = bounded(ins.timeoutMs + HOST_GRACE_MS, LoginResult(LoginOutcome.TIMEOUT, emptyList())) {
                        host.showLogin(
                            LoginRequest(
                                store = store, url = ins.url, title = ins.title, guard = GUARD_SCRIPT, check = ins.check,
                                doneWhen = ins.doneWhen, doneWhenUrl = ins.doneWhenUrl, timeoutMs = ins.timeoutMs,
                                allowNavigation = { u -> allowlist.check(store, u, UrlUse.LOGIN).ok },
                                cancel = cancel,
                            ),
                        )
                    }
                    InstructionResult.ShowLoginResult(ins.id, true, r.outcome, r.messages, null, ms())
                } catch (e: Throwable) {
                    rethrowIfCancelled(e)
                    InstructionResult.ShowLoginResult(ins.id, false, LoginOutcome.CANCELLED, emptyList(), describe(e), ms())
                }
            }
            is Instruction.Fetch -> {
                if (!allowlist.check(store, ins.request.url, UrlUse.FETCH).ok) {
                    return InstructionResult.FetchResult(ins.id, ok = false, error = "blocked", ms = 0)
                }
                // The guard stops a page script naming an order or a payment; this op
                // never passes through a page, so the same rule is applied here.
                if (bodyBlocked(ins.request.body)) {
                    return InstructionResult.FetchResult(ins.id, ok = false, error = "blocked", ms = 0)
                }
                if (overRate(store)) return InstructionResult.FetchResult(ins.id, ok = false, error = "rate", ms = 0)
                try {
                    val r = bounded(ins.timeoutMs + HOST_GRACE_MS, FetchResponse(ok = false, error = "timeout")) {
                        host.fetch(store, ins.request, ins.timeoutMs, ins.maxBytes)
                    }
                    InstructionResult.FetchResult(ins.id, r.ok, r.status, r.headers, r.body, r.truncated, r.error, ms())
                } catch (e: Throwable) {
                    rethrowIfCancelled(e)
                    InstructionResult.FetchResult(ins.id, ok = false, error = "no_response", ms = ms())
                }
            }
            // checkInstructions only lets supported ops through and run() handles
            // done/fail, so this cannot happen. Kept to match the reference.
            is Instruction.Done, is Instruction.Fail -> throw EnvelopeException("unsupported_op")
        }
    }

    @Synchronized
    private fun overRate(store: String): Boolean {
        val t = clock()
        val list = fetchStamps.getOrPut(store) { ArrayDeque() }
        while (list.isNotEmpty() && t - list.first() > 60_000) list.removeFirst()
        if (list.size >= FETCH_PER_MINUTE) return true
        list.addLast(t)
        return false
    }
}

/**
 * A host error becomes a failed result, but a cancelled run must stay
 * cancelled. A timeout thrown inside the host (while our coroutine is still
 * active) is just an error.
 */
internal suspend fun rethrowIfCancelled(e: Throwable) {
    if (e is CancellationException && !currentCoroutineContext().isActive) throw e
}

/** String(e).slice(0, 120) in the reference. */
private fun describe(e: Throwable): String = e.toString().take(120)

private fun skipped(ins: Instruction): InstructionResult = when (ins) {
    is Instruction.PageScript -> InstructionResult.PageScriptResult(ins.id, false, emptyList(), false, null, 0, skipped = true)
    is Instruction.ShowLogin -> InstructionResult.ShowLoginResult(ins.id, false, LoginOutcome.CANCELLED, emptyList(), null, 0, skipped = true)
    is Instruction.Fetch -> InstructionResult.FetchResult(ins.id, ok = false, ms = 0, skipped = true)
    else -> InstructionResult.PageOpenResult(ins.id, ok = false, ms = 0, skipped = true)
}
