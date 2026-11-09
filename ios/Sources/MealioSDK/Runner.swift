// The relay loop: verify an envelope, check every URL against the allowlist,
// run each instruction on the platform's Host, and return the results.
// Mirrors packages/core/src/runner.ts.

import Foundation

/// Fetch instructions per store per minute (PROTOCOL.md "Rate caps").
public let FETCH_PER_MINUTE = 120

/// How long past an instruction's own timeout a Host may take to answer. A
/// Host that never answers ends the step here, so no job can hang.
public let HOST_GRACE_MS = 5_000

/// Why a prepare or search was cancelled. Carried as `MealioError.reason`
/// on the `cancelled` error, so a custom screen can tell a user change (prepare
/// again for the new user) from its own close.
public enum CancelReason: String, Equatable {
    /// `setUser` changed the signed-in user.
    case userChanged = "user_changed"
    /// The sheet or screen that asked for it closed.
    case closed
    /// Anything else: `cancelJobs`, a store sign-out, a session reset, your own token.
    case cancelled
}

/// Stops a prepare or a search. See `MealioClient.prepareCart`.
@MainActor
public final class CancelToken {
    public private(set) var cancelled = false
    /// Why, once cancelled. The first cancel's reason stands.
    public private(set) var reason: CancelReason?
    private var listeners: [Int: () -> Void] = [:]
    private var nextId = 0

    public init() {}

    public func cancel(reason: CancelReason = .cancelled) {
        if cancelled { return }
        cancelled = true
        self.reason = reason
        let list = listeners.sorted { $0.key < $1.key }.map(\.value)
        listeners = [:]
        for fn in list { fn() }
    }

    /// Call `fn` on cancel, or now if already cancelled. Returns how to stop listening.
    @discardableResult
    public func onCancel(_ fn: @escaping () -> Void) -> () -> Void {
        if cancelled {
            fn()
            return {}
        }
        nextId += 1
        let id = nextId
        listeners[id] = fn
        return { [weak self] in self?.listeners[id] = nil }
    }
}

/// `op`, or `fallback` once `ms` passes. A late `op` is left to finish on its own.
@MainActor
func bounded<T>(_ ms: Int, fallback: T, _ op: @escaping @MainActor () async throws -> T) async throws -> T {
    try await withDeadline(ms, late: { .success(fallback) }, op)
}

/// `op`, or what `late` says once `ms` passes. The task running `op` is
/// cancelled then, which stops a URLSession request. When `cancel` fires
/// first, the task is cancelled the same way and this throws `cancelled`.
@MainActor
func withDeadline<T>(_ ms: Int, late: @escaping @MainActor () -> Result<T, Error>,
                     cancel: CancelToken? = nil,
                     _ op: @escaping @MainActor () async throws -> T) async throws -> T {
    if let c = cancel, c.cancelled { throw MealioClient.cancelled(c) }
    let box = TaskBox()
    var stopListening: (() -> Void)?
    defer { stopListening?() }
    let result: Result<T, Error> = await withCheckedContinuation { (cont: CheckedContinuation<Result<T, Error>, Never>) in
        let once = ResumeOnce(cont)
        let timer = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: nanoseconds(ms)) } catch { return }
            if once.resume(late()) { box.task?.cancel() }
        }
        box.task = Task { @MainActor in
            do {
                let value = try await op()
                once.resume(.success(value))
            } catch {
                once.resume(.failure(error))
            }
            timer.cancel()
        }
        if let token = cancel {
            stopListening = token.onCancel {
                timer.cancel()
                if once.resume(.failure(MealioClient.cancelled(token))) { box.task?.cancel() }
            }
        }
    }
    return try result.get()
}

/// Run `op` until it ends, `ms` passes, or `cancel` fires, whichever is
/// first. Returns true when `op` ended. A late `op` is cancelled and left to
/// finish on its own. Used for every step of a store sign-out.
@MainActor
@discardableResult
func boundedStep(_ ms: Int, cancel: CancelToken?, _ op: @escaping @MainActor () async -> Void) async -> Bool {
    if cancel?.cancelled == true { return false }
    let box = TaskBox()
    var stopListening: (() -> Void)?
    let finished: Bool = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
        let once = ResumeOnce(cont)
        let timer = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: nanoseconds(ms)) } catch { return }
            if once.resume(false) { box.task?.cancel() }
        }
        if let token = cancel {
            stopListening = token.onCancel {
                timer.cancel()
                if once.resume(false) { box.task?.cancel() }
            }
        }
        box.task = Task { @MainActor in
            await op()
            once.resume(true)
            timer.cancel()
        }
    }
    stopListening?()
    return finished
}

/// The task running a deadline's work, so the timer can cancel it.
final class TaskBox: @unchecked Sendable {
    var task: Task<Void, Never>?
}

/// How a job ended.
public enum Terminal: Equatable {
    case done(JSONValue)
    case fail(code: String, message: String)
}

public struct StepOutcome {
    public let payload: InstructionsPayload
    public let results: [InstructionResult]
    public let terminal: Terminal?
    /// The cancel token fired before the envelope finished.
    public var cancelled = false
}

@MainActor
public final class Runner {
    public let allowlist: Allowlist
    private let host: MealioHost
    private let keys: [String: String]
    private var fetchStamps: [String: [TimeInterval]] = [:]
    /// Added to every instruction's timeout before a silent Host ends the step.
    /// Only tests shorten it.
    var hostGraceMs = HOST_GRACE_MS
    /// How many times the hidden page has been told to load. A warm-up is only
    /// worth anything while the page it left behind is still the one showing,
    /// and this is how the client knows nothing has loaded over it since.
    public private(set) var pageOpens = 0

    /// Load a blank hidden page (work that outlived its cap may have left
    /// anything on it). A warm-up's page is gone after this.
    func resetPage() {
        pageOpens += 1
        host.resetPage()
    }

    /// A job is over, however it ended (MealioHost.endJob).
    func jobEnded() {
        host.endJob()
    }

    /// The host can run a job (MealioHost.ready); throws when it cannot.
    func hostReady() async throws {
        try await host.ready()
    }

    public init(host: MealioHost, allowlist: Allowlist = Allowlist(), keys: [String: String] = MealioKeys.all) {
        self.host = host
        self.allowlist = allowlist
        self.keys = keys
    }

    /// Verify and run one envelope. Throws `EnvelopeError` when it must be refused.
    /// `onStep` is called before each instruction that actually runs (not for
    /// `done`, `fail` or skipped ones), for a progress screen. With
    /// `allowLogin` false (a warm-up) every `show_login` is refused. Once
    /// `cancel` fires, nothing more runs: the outcome says `cancelled`.
    public func run(_ env: Envelope?, job: String?, lastSeq: Int, allowLogin: Bool = true,
                    cancel: CancelToken? = nil,
                    onStep: (@MainActor (Instruction) -> Void)? = nil) async throws -> StepOutcome {
        let payload = try checkInstructions(try openEnvelope(env, keys: keys), job: job, lastSeq: lastSeq)
        var results: [InstructionResult] = []
        var terminal: Terminal?
        var failed = false

        for ins in payload.instructions {
            if case .done(let d) = ins { terminal = .done(d.result); break }
            if case .fail(let f) = ins { terminal = .fail(code: f.code, message: f.message); break }
            if failed { results.append(Runner.skipped(ins)); continue }
            // Checked right before each step, so a cancelled job never opens sign-in.
            if cancel?.cancelled == true {
                return StepOutcome(payload: payload, results: results, terminal: nil, cancelled: true)
            }
            onStep?(ins)
            let r = try await one(payload.store, ins, allowLogin: allowLogin, cancel: cancel)
            results.append(r)
            if !r.ok { failed = true }
        }
        return StepOutcome(payload: payload, results: results, terminal: terminal)
    }

    private func one(_ store: String, _ ins: Instruction, allowLogin: Bool, cancel: CancelToken?) async throws -> InstructionResult {
        let t0 = Runner.now()
        func ms() -> Int { Int((Runner.now() - t0) * 1000) }
        let host = self.host
        let grace = hostGraceMs

        switch ins {
        case .pageOpen(let op):
            guard allowlist.check(store, op.url, .page).ok else {
                return InstructionResult(id: op.id, ok: false, ms: 0, error: "blocked")
            }
            pageOpens += 1
            do {
                let r = try await bounded(op.timeoutMs + grace, fallback: PageOpenOutcome(ok: false, error: "timeout")) {
                    try await host.openPage(store: store, url: op.url, timeoutMs: op.timeoutMs)
                }
                return InstructionResult(id: op.id, ok: r.ok, ms: ms(), error: r.error, finalUrl: r.finalUrl)
            } catch {
                return InstructionResult(id: op.id, ok: false, ms: ms(), error: "load_failed")
            }

        case .pageScript(let op):
            do {
                let r = try await bounded(op.timeoutMs + grace, fallback: ScriptOutcome(messages: [], timedOut: true)) {
                    try await host.runScript(store: store, guardScript: MealioScripts.guardArmScript, script: op.script,
                                             until: op.until, timeoutMs: op.timeoutMs)
                }
                return InstructionResult(id: op.id, ok: r.error == nil, ms: ms(), error: r.error,
                                         messages: r.messages, timedOut: r.timedOut)
            } catch {
                return InstructionResult(id: op.id, ok: false, ms: ms(), error: Runner.short(error),
                                         messages: [], timedOut: false)
            }

        case .showLogin(let op):
            // A warm-up runs before the user has tapped anything: it may check
            // who is signed in, never put a sign-in sheet in front of them.
            guard allowLogin, cancel?.cancelled != true else {
                return InstructionResult(id: op.id, ok: false, ms: 0, error: "not_allowed", messages: [], outcome: .cancelled)
            }
            guard allowlist.check(store, op.url, .login).ok else {
                return InstructionResult(id: op.id, ok: false, ms: 0, error: "blocked", messages: [], outcome: .cancelled)
            }
            let allowlist = self.allowlist
            let request = LoginRequest(
                store: store, url: op.url, title: op.title, guardScript: MealioScripts.guardScript,
                check: op.check, doneWhen: op.doneWhen, doneWhenUrl: op.doneWhenUrl, timeoutMs: op.timeoutMs,
                allowNavigation: { url in allowlist.check(store, url, .login).ok }, cancel: cancel,
                armGuardScript: MealioScripts.guardArmScript)
            do {
                let r = try await bounded(op.timeoutMs + grace, fallback: LoginOutcome(outcome: .timeout, messages: [])) {
                    try await host.showLogin(request)
                }
                return InstructionResult(id: op.id, ok: true, ms: ms(), messages: r.messages, outcome: r.outcome)
            } catch {
                return InstructionResult(id: op.id, ok: false, ms: ms(), error: Runner.short(error),
                                         messages: [], outcome: .cancelled)
            }

        case .fetch(let op):
            guard allowlist.check(store, op.request.url, .fetch).ok else {
                return InstructionResult(id: op.id, ok: false, ms: 0, error: "blocked")
            }
            // The guard stops a page script naming an order or a payment; this op
            // never passes through a page, so the same rule is applied here.
            if Allowlist.bodyBlocked(op.request.body) {
                return InstructionResult(id: op.id, ok: false, ms: 0, error: "blocked")
            }
            if overRate(store) {
                return InstructionResult(id: op.id, ok: false, ms: 0, error: "rate")
            }
            do {
                let r = try await bounded(op.timeoutMs + grace, fallback: FetchOutcome(ok: false, error: "timeout")) {
                    try await host.fetch(store: store, request: op.request, timeoutMs: op.timeoutMs, maxBytes: op.maxBytes)
                }
                return InstructionResult(id: op.id, ok: r.ok, ms: ms(), error: r.error, status: r.status,
                                         headers: r.headers, body: r.body, truncated: r.truncated)
            } catch {
                return InstructionResult(id: op.id, ok: false, ms: ms(), error: "no_response")
            }

        case .done, .fail, .unsupported:
            // done and fail end the loop in run(); checkInstructions refuses
            // unsupported ops before anything runs.
            throw EnvelopeError(.unsupportedOp)
        }
    }

    private func overRate(_ store: String) -> Bool {
        let t = Runner.now()
        var list = fetchStamps[store] ?? []
        while let first = list.first, t - first > 60 { list.removeFirst() }
        if list.count >= FETCH_PER_MINUTE {
            fetchStamps[store] = list
            return true
        }
        list.append(t)
        fetchStamps[store] = list
        return false
    }

    private static func skipped(_ ins: Instruction) -> InstructionResult {
        switch ins {
        case .pageScript(let op):
            return InstructionResult(id: op.id, ok: false, ms: 0, skipped: true, messages: [], timedOut: false)
        case .showLogin(let op):
            return InstructionResult(id: op.id, ok: false, ms: 0, skipped: true, messages: [], outcome: .cancelled)
        default:
            return InstructionResult(id: ins.id, ok: false, ms: 0, skipped: true)
        }
    }

    /// Seconds on a clock that never jumps.
    private static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private static func short(_ error: Error) -> String {
        String(String(describing: error).prefix(120))
    }
}
