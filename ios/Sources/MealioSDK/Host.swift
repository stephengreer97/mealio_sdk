// The Host is the only platform-specific part of the relay: WebViews, HTTP
// and UI. WebViewHost is the real one; tests use a fake. Mirrors the `Host`
// interface in packages/core/src/runner.ts.

import Foundation

public struct PageOpenOutcome: Equatable {
    public var ok: Bool
    public var finalUrl: String?
    /// "timeout", "blocked" or "load_failed" when `ok` is false.
    public var error: String?

    public init(ok: Bool, finalUrl: String? = nil, error: String? = nil) {
        self.ok = ok
        self.finalUrl = finalUrl
        self.error = error
    }
}

public struct ScriptOutcome: Equatable {
    public var messages: [JSONMessage]
    public var timedOut: Bool
    public var error: String?

    public init(messages: [JSONMessage], timedOut: Bool, error: String? = nil) {
        self.messages = messages
        self.timedOut = timedOut
        self.error = error
    }
}

public struct LoginRequest {
    public let store: String
    public let url: String
    public let title: String
    /// GUARD_SCRIPT, the document-start copy: every frame of the sheet's
    /// WebView gets it (WebViewHost's configuration already injects it).
    public let guardScript: String
    /// GUARD_ARM_SCRIPT: installs the guard if missing and arms it. Inject it
    /// into the top frame before `check.script` every time.
    public let armGuardScript: String
    public let check: LoginCheck?
    public let doneWhen: [Matcher]
    /// A regex source. A main-frame URL matching it means signed in.
    public let doneWhenUrl: String?
    public let timeoutMs: Int
    /// Ask this for every top-frame navigation; cancel it when false.
    public let allowNavigation: (String) -> Bool
    /// Close the sheet as `cancelled` when this fires.
    public let cancel: CancelToken?

    public init(store: String, url: String, title: String, guardScript: String, check: LoginCheck?,
                doneWhen: [Matcher], doneWhenUrl: String?, timeoutMs: Int, allowNavigation: @escaping (String) -> Bool,
                cancel: CancelToken? = nil, armGuardScript: String = MealioScripts.guardArmScript) {
        self.store = store
        self.url = url
        self.title = title
        self.guardScript = guardScript
        self.armGuardScript = armGuardScript
        self.check = check
        self.doneWhen = doneWhen
        self.doneWhenUrl = doneWhenUrl
        self.timeoutMs = timeoutMs
        self.allowNavigation = allowNavigation
        self.cancel = cancel
    }
}

public struct LoginOutcome: Equatable {
    public var outcome: LoginOutcomeKind
    public var messages: [JSONMessage]

    public init(outcome: LoginOutcomeKind, messages: [JSONMessage]) {
        self.outcome = outcome
        self.messages = messages
    }
}

public struct FetchOutcome: Equatable {
    /// A response arrived, whatever its status.
    public var ok: Bool
    public var status: Int?
    public var headers: [String: String]?
    public var body: String?
    public var truncated: Bool?
    public var error: String?

    public init(ok: Bool, status: Int? = nil, headers: [String: String]? = nil, body: String? = nil,
                truncated: Bool? = nil, error: String? = nil) {
        self.ok = ok
        self.status = status
        self.headers = headers
        self.body = body
        self.truncated = truncated
        self.error = error
    }
}

/// What the Runner needs from the platform. Everything runs on the main actor
/// because WebViews and UIKit do.
@MainActor
public protocol MealioHost: AnyObject {
    /// Load `url` in the hidden WebView and wait for it to finish loading.
    func openPage(store: String, url: String, timeoutMs: Int) async throws -> PageOpenOutcome

    /// Inject `guardScript` (GUARD_ARM_SCRIPT, which arms the guard) then
    /// `script` into the hidden page. Return every
    /// JSON message posted after injection, stopping at the first that matches
    /// `until` or when `timeoutMs` passes.
    func runScript(store: String, guardScript: String, script: String, until: [Matcher], timeoutMs: Int) async throws -> ScriptOutcome

    /// Show the visible login sheet. See `LoginRequest`.
    func showLogin(_ request: LoginRequest) async throws -> LoginOutcome

    /// One HTTP request with the store's cookies.
    func fetch(store: String, request: FetchRequest, timeoutMs: Int, maxBytes: Int) async throws -> FetchOutcome

    /// Drop whatever the hidden page shows (load about:blank, or a fresh
    /// page). Called before a job when earlier exclusive work outlived its
    /// cap. Optional: the default does nothing.
    func resetPage()

    /// The job is over (done, failed or cancelled). WebViewHost takes the
    /// hidden page's network block off here (round 8: it went on at the
    /// job's first script and stayed on across navigations). Optional: the
    /// default does nothing.
    func endJob()

    /// Throws when this host cannot run a job safely. Called before every
    /// job's first instruction. WebViewHost waits (bounded) for its network
    /// block of checkout paths and refuses without it. Optional: the default
    /// is always ready.
    func ready() async throws
}

public extension MealioHost {
    func resetPage() {}
    func endJob() {}
    func ready() async throws {}
}

/// Resumes a continuation exactly once, from any thread. Used by every wait
/// in the SDK that can end more than one way (message, timeout, close).
final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    var isDone: Bool {
        lock.lock(); defer { lock.unlock() }
        return continuation == nil
    }

    /// Returns true if this call did the resume.
    @discardableResult
    func resume(_ value: T) -> Bool {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        guard let c = c else { return false }
        c.resume(returning: value)
        return true
    }
}

/// Milliseconds as nanoseconds for Task.sleep, never negative.
func nanoseconds(_ ms: Int) -> UInt64 {
    UInt64(max(ms, 0)) * 1_000_000
}
