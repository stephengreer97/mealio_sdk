// The relay loop: verify an envelope, check every URL against the allowlist,
// run each instruction on the platform's Host, and return the results.
// Mirrors packages/core/src/runner.ts.

import Foundation

/// Fetch instructions per store per minute (PROTOCOL.md "Rate caps").
public let FETCH_PER_MINUTE = 120

/// How a job ended.
public enum Terminal: Equatable {
    case done(JSONValue)
    case fail(code: String, message: String)
}

public struct StepOutcome {
    public let payload: InstructionsPayload
    public let results: [InstructionResult]
    public let terminal: Terminal?
}

@MainActor
public final class Runner {
    public let allowlist: Allowlist
    private let host: MealioHost
    private let keys: [String: String]
    private var fetchStamps: [String: [TimeInterval]] = [:]

    public init(host: MealioHost, allowlist: Allowlist = Allowlist(), keys: [String: String] = MealioKeys.all) {
        self.host = host
        self.allowlist = allowlist
        self.keys = keys
    }

    /// Verify and run one envelope. Throws `EnvelopeError` when it must be refused.
    /// `onStep` is called before each instruction that actually runs (not for
    /// `done`, `fail` or skipped ones), for a progress screen.
    public func run(_ env: Envelope?, job: String?, lastSeq: Int,
                    onStep: (@MainActor (Instruction) -> Void)? = nil) async throws -> StepOutcome {
        let payload = try checkInstructions(try openEnvelope(env, keys: keys), job: job, lastSeq: lastSeq)
        var results: [InstructionResult] = []
        var terminal: Terminal?
        var failed = false

        for ins in payload.instructions {
            if case .done(let d) = ins { terminal = .done(d.result); break }
            if case .fail(let f) = ins { terminal = .fail(code: f.code, message: f.message); break }
            if failed { results.append(Runner.skipped(ins)); continue }
            onStep?(ins)
            let r = try await one(payload.store, ins)
            results.append(r)
            if !r.ok { failed = true }
        }
        return StepOutcome(payload: payload, results: results, terminal: terminal)
    }

    private func one(_ store: String, _ ins: Instruction) async throws -> InstructionResult {
        let t0 = Runner.now()
        func ms() -> Int { Int((Runner.now() - t0) * 1000) }

        switch ins {
        case .pageOpen(let op):
            guard allowlist.check(store, op.url, .page).ok else {
                return InstructionResult(id: op.id, ok: false, ms: 0, error: "blocked")
            }
            do {
                let r = try await host.openPage(store: store, url: op.url, timeoutMs: op.timeoutMs)
                return InstructionResult(id: op.id, ok: r.ok, ms: ms(), error: r.error, finalUrl: r.finalUrl)
            } catch {
                return InstructionResult(id: op.id, ok: false, ms: ms(), error: "load_failed")
            }

        case .pageScript(let op):
            do {
                let r = try await host.runScript(store: store, guardScript: MealioScripts.guardScript, script: op.script,
                                                 until: op.until, timeoutMs: op.timeoutMs)
                return InstructionResult(id: op.id, ok: r.error == nil, ms: ms(), error: r.error,
                                         messages: r.messages, timedOut: r.timedOut)
            } catch {
                return InstructionResult(id: op.id, ok: false, ms: ms(), error: Runner.short(error),
                                         messages: [], timedOut: false)
            }

        case .showLogin(let op):
            guard allowlist.check(store, op.url, .login).ok else {
                return InstructionResult(id: op.id, ok: false, ms: 0, error: "blocked", messages: [], outcome: .cancelled)
            }
            let allowlist = self.allowlist
            let request = LoginRequest(
                store: store, url: op.url, title: op.title, guardScript: MealioScripts.guardScript,
                check: op.check, doneWhen: op.doneWhen, doneWhenUrl: op.doneWhenUrl, timeoutMs: op.timeoutMs,
                allowNavigation: { url in allowlist.check(store, url, .login).ok })
            do {
                let r = try await host.showLogin(request)
                return InstructionResult(id: op.id, ok: true, ms: ms(), messages: r.messages, outcome: r.outcome)
            } catch {
                return InstructionResult(id: op.id, ok: false, ms: ms(), error: Runner.short(error),
                                         messages: [], outcome: .cancelled)
            }

        case .fetch(let op):
            guard allowlist.check(store, op.request.url, .fetch).ok else {
                return InstructionResult(id: op.id, ok: false, ms: 0, error: "blocked")
            }
            if overRate(store) {
                return InstructionResult(id: op.id, ok: false, ms: 0, error: "rate")
            }
            do {
                let r = try await host.fetch(store: store, request: op.request, timeoutMs: op.timeoutMs, maxBytes: op.maxBytes)
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
