// The partner-facing flow: start a cart, drive the job through step calls,
// search again for one item, fill the cart. Mirrors packages/core/src/client.ts. This file has no
// UIKit in it; MealioCart (in MealioCart.swift) wires it to the WebViewHost.

import Foundation

/// SDK version, sent as `X-Mealio-SDK: ios/<version>` and in the `sdk` body field.
public let MEALIO_SDK_VERSION = "0.6.0"
/// The version of the reference core this SDK ports.
public let SDK_CORE_VERSION = "0.6.0"
public let DEFAULT_BASE_URL = URL(string: "https://mealio.co")!

/// An error the SDK raises to the app. `code` is one of `MealioError.Code`, or
/// a code the server sent (for example from a `fail` instruction).
public struct MealioError: Error, LocalizedError, Equatable, CustomStringConvertible {
    public let code: String
    public let message: String
    /// On a `cancelled` error: why. `.userChanged` means prepare again for the
    /// new user; `.closed` means the screen went away. Nil on other codes.
    public let reason: CancelReason?

    public init(code: String, message: String, reason: CancelReason? = nil) {
        self.code = code
        self.message = message
        self.reason = reason
    }

    public var errorDescription: String? { message }
    public var description: String { "MealioError(\(code)): \(message)" }

    /// PROTOCOL.md "Errors the SDK raises to the app", plus the few codes the
    /// SDK itself uses.
    public enum Code {
        /// Signature, expiry, job or sequence check failed.
        public static let badEnvelope = "bad_envelope"
        /// An instruction broke the allowlist.
        public static let blocked = "blocked"
        /// The server says the store cannot be reached now.
        public static let storeUnavailable = "store_unavailable"
        /// The user closed the login sheet.
        public static let loginCancelled = "login_cancelled"
        /// The SDK session token expired; get a new one from your server.
        public static let sessionExpired = "session_expired"
        /// Could not reach Mealio.
        public static let network = "network"
        /// An instruction op this SDK does not know.
        public static let unsupported = "unsupported"
        /// Mealio answered with an error or something the SDK could not read.
        public static let server = "server"
        /// Your session function failed or took over 30 seconds. `message` is your error's.
        public static let sessionFailed = "session_failed"
        /// `MealioCart.setUser(nil)`: nobody is signed in, so there is no session.
        public static let notSignedIn = "not_signed_in"
        /// The prepare or search was cancelled (the sheet closed, or the user changed).
        public static let cancelled = "cancelled"
        /// No store was given and the user has no default store yet: let them pick one.
        public static let storeRequired = "store_required"
        public static let storeNotAllowed = "store_not_allowed"
        public static let cartCapReached = "cart_cap_reached"
        public static let tooManyCarts = "too_many_carts"
        /// A Kroger family store has no saved location for the user: let them
        /// choose one with `storeLocations` and `setStore`. Raised before any sign-in.
        public static let locationRequired = "location_required"
        /// `CartSession.select` was given a key that is not in the cart.
        public static let unknownItem = "unknown_item"
        /// `CartSession.select` was given a product that was not offered.
        public static let unknownProduct = "unknown_product"
        /// `MealioCart.configure` has not been called.
        public static let notConfigured = "not_configured"
        /// `prepareCart` was given no recipe.
        public static let badRecipe = "bad_recipe"
        /// `prepareCart` was given more than `MAX_RECIPES` recipes.
        public static let tooManyRecipes = "too_many_recipes"
    }
}

/// The store-session epoch: a number the SDK bumps every time it signs out of
/// a store, kept in UserDefaults. Every job-starting call sends it as `epoch`
/// so the server knows the device's store sessions changed.
public enum StoreEpoch {
    static let defaultsKey = "co.mealio.sdk.storeEpoch"

    public static func current(_ defaults: UserDefaults = .standard) -> Int {
        defaults.integer(forKey: defaultsKey)
    }

    @discardableResult
    public static func bump(_ defaults: UserDefaults = .standard) -> Int {
        let next = current(defaults) + 1
        defaults.set(next, forKey: defaultsKey)
        return next
    }
}

/// Every HTTP request, and your session function, gets this long.
public let REQUEST_TIMEOUT_MS = 30_000

public struct MealioClientConfig {
    public var publishableKey: String
    /// Returns a token from POST /api/v1/sessions on the partner's server.
    /// Called again after a 401. If it throws or takes over 30 seconds, the
    /// call fails with `session_failed`, with your error's message as `message`.
    public var sessionTokenProvider: () async throws -> String
    public var baseURL: URL
    /// App Attest token, when the partner has turned attestation on.
    public var attestationProvider: (() async -> String?)?
    /// The device's store-session epoch.
    public var epochProvider: () -> Int
    /// Trusted signing keys. Only tests change this.
    public var keys: [String: String]
    public var urlSession: URLSession
    public var platform: String
    public var sdkVersion: String
    /// Clients that share one hidden page share one queue. Nil: a queue of its own.
    public var queue: JobQueue?
    /// How long each request may take. Only tests shorten it.
    var requestTimeoutMs = REQUEST_TIMEOUT_MS
    /// How long `runExclusive` may hold the queue. Only tests shorten it.
    var exclusiveCapMs = MealioClient.exclusiveCapMs

    public init(publishableKey: String,
                sessionTokenProvider: @escaping () async throws -> String,
                baseURL: URL = DEFAULT_BASE_URL,
                attestationProvider: (() async -> String?)? = nil,
                epochProvider: @escaping () -> Int = { StoreEpoch.current() },
                keys: [String: String] = MealioKeys.all,
                urlSession: URLSession = .shared,
                platform: String = "ios",
                sdkVersion: String = MEALIO_SDK_VERSION,
                queue: JobQueue? = nil) {
        self.publishableKey = publishableKey
        self.sessionTokenProvider = sessionTokenProvider
        self.baseURL = baseURL
        self.attestationProvider = attestationProvider
        self.epochProvider = epochProvider
        self.keys = keys
        self.urlSession = urlSession
        self.platform = platform
        self.sdkVersion = sdkVersion
        self.queue = queue
    }
}

/// What the SDK is doing right now, for a progress screen. Inferred from the
/// server's instruction ids (open-, session-, login-, search-, add-), never
/// from store specifics.
public enum Step: String, Equatable, CaseIterable {
    case connecting
    case checkingSignIn = "checking_sign_in"
    case signingIn = "signing_in"
    case searching
    case adding
}

/// Called before each instruction the SDK runs.
public typealias StepListener = @MainActor (Step, Instruction) -> Void

/// The progress step an instruction belongs to. Mirrors `stepOf` in client.ts.
public func stepOf(_ ins: Instruction) -> Step {
    if case .showLogin = ins { return .signingIn }
    let id = ins.id
    if id.hasPrefix("search") { return .searching }
    if id.hasPrefix("add") { return .adding }
    if id.hasPrefix("session") || id.hasPrefix("resession") { return .checkingSignIn }
    return .connecting
}

/// One job at a time on the hidden page. Prepare, search, add and warm all
/// run through here, and a new job waits for the one before it to end.
/// Mirrors JobQueue in client.ts.
@MainActor
public final class JobQueue {
    private struct Waiter {
        let id: Int
        /// Resumed with true when the page is handed over, false when the
        /// job was cancelled while it waited.
        let cont: CheckedContinuation<Bool, Never>
    }

    private var busy = false
    private var waiting: [Waiter] = []
    private var nextWaiter = 0
    /// Cart calls waiting or running. A warm-up does not start while any are.
    public internal(set) var pending = 0

    public init() {}

    /// Run `job` once every job queued before it has ended.
    public func run<T>(_ job: () async throws -> T) async throws -> T {
        try await run(cancel: nil, job)
    }

    /// As `run`, but a job cancelled while it waits leaves the line at once
    /// and fails with `cancelled`, without waiting for its turn.
    func run<T>(cancel: CancelToken?, _ job: () async throws -> T) async throws -> T {
        try await take(cancel)
        defer { next() }
        return try await job()
    }

    /// Wait for the page, then hold it until the returned `release` is
    /// called. Calling `release` again does nothing.
    func acquire() async -> @MainActor () -> Void {
        // Without a token, take never throws.
        try? await take(nil)
        var released = false
        return { [weak self] in
            if released { return }
            released = true
            self?.next()
        }
    }

    /// Wait for the page and hold it. Throws `cancelled` (having left the
    /// line) when `cancel` fires first.
    private func take(_ cancel: CancelToken?) async throws {
        if let c = cancel, c.cancelled { throw MealioClient.cancelled(c) }
        if !busy {
            busy = true
            return
        }
        nextWaiter += 1
        let id = nextWaiter
        var stopListening: (() -> Void)?
        let handedOver: Bool = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            waiting.append(Waiter(id: id, cont: c))
            if let token = cancel {
                stopListening = token.onCancel { [weak self] in self?.leave(id) }
            }
        }
        stopListening?()
        if !handedOver { throw MealioClient.cancelled(cancel) }
    }

    /// A waiting job was cancelled: out of the line, and told so.
    private func leave(_ id: Int) {
        guard let i = waiting.firstIndex(where: { $0.id == id }) else { return }
        let w = waiting.remove(at: i)
        w.cont.resume(returning: false)
    }

    /// Hand the page to the next job in line, or free it.
    private func next() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().cont.resume(returning: true)
        }
    }
}

/// Whether a `runExclusive` work has ended, shared by its two tasks.
@MainActor
final class ExclusiveRun {
    var ended = false
}

/// An add's token, fixed when the add was asked for. Renewed on a 401 only
/// while the session is still the one of that moment (`gen`).
@MainActor
final class SessionPin {
    var token: String
    /// The session generation the add was asked for in.
    let gen: Int

    init(token: String, gen: Int) {
        self.token = token
        self.gen = gen
    }
}

@MainActor
public final class MealioClient {
    public let config: MealioClientConfig
    let runner: Runner
    private var token: String?
    /// Bumped by `resetSession`, so a token still on its way is not kept.
    private var sessionGen = 0
    private let base: String
    private let queue: JobQueue
    /// The prepares and searches waiting or running, so they can be cancelled.
    private var active: [ObjectIdentifier: CancelToken] = [:]

    /// Who is signed in to the app. Not tracked until `setUser` is first called.
    private enum UserState: Equatable { case untracked, nobody, signedIn(String) }
    private var user: UserState = .untracked

    /// How long a warm-up is offered to the next prepare. The server holds the same line (WARM_TTL_MS).
    public static let warmFreshSeconds: TimeInterval = 4 * 60

    /// A finished warm-up the next prepare may start from.
    struct Warmed { let job: String; let store: String; let at: TimeInterval; let pageOpens: Int; let epoch: Int }
    private var warmed: Warmed?
    private var warming: Task<Void, Never>?
    private var warmCancel: CancelToken?
    private var warmGen = 0
    private var lastWarmAt: TimeInterval = 0

    /// Max envelopes in one job before the SDK gives up on it.
    static let maxSteps = 200

    public init(config: MealioClientConfig, host: MealioHost) {
        self.config = config
        self.runner = Runner(host: host, allowlist: Allowlist(), keys: config.keys)
        self.queue = config.queue ?? JobQueue()
        var b = config.baseURL.absoluteString
        while b.hasSuffix("/") { b.removeLast() }
        self.base = b
    }

    /// The allowlist in force, including any signed widening applied with `widenAllowlist`.
    public var allowlist: Allowlist { runner.allowlist }

    /// Who is calling, carried in the body of every job-starting call (this
    /// used to be a separate hello round trip).
    struct SDKInfo: Encodable { let platform: String; let version: String; let core: String; let ops: [String] }

    private func about() -> (sdk: SDKInfo, epoch: Int) {
        (SDKInfo(platform: config.platform, version: config.sdkVersion, core: SDK_CORE_VERSION, ops: SUPPORTED_OPS),
         config.epochProvider())
    }

    /// The stores this app offers right now. No session token is sent.
    public func stores() async throws -> [StoreInfo] {
        guard let url = URL(string: base + "/api/v1/stores") else {
            throw MealioError(code: MealioError.Code.network, message: "Could not reach Mealio")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(config.publishableKey, forHTTPHeaderField: "X-Mealio-Publishable-Key")
        let answer = try await request(req)
        let json = try MealioClient.answer(status: answer.status, json: answer.json)
        guard let list = json["stores"]?.arrayValue else { return [] }
        return list.compactMap { try? $0.decode(StoreInfo.self) }
    }

    /// A Kroger family chain's stores near a zip, nearest first, for the user to
    /// choose from. Save their choice with `setStore`.
    public func storeLocations(store: String, zip: String) async throws -> [StoreLocation] {
        struct Body: Encodable { let store: String; let zip: String }
        let json = try await post("/api/v1/sdk/locations", body: Body(store: store, zip: zip))
        guard let list = json["locations"]?.arrayValue else { return [] }
        return list.compactMap { try? $0.decode(StoreLocation.self) }
    }

    /// The user's default store, and their exact store if it is in the Kroger family.
    public func storePreferences() async throws -> StorePreferences {
        // An empty object reads. JSONValue so that it is `{}` on the wire for certain.
        try await preferences(from: post("/api/v1/sdk/preferences", body: JSONValue.object([:])))
    }

    /// Make a store the user's default. A Kroger family store needs `locationId`
    /// from `storeLocations` the first time, and otherwise fails with
    /// `location_required`. Sending it later moves them to that store.
    @discardableResult
    public func setStore(_ store: String, locationId: String? = nil) async throws -> StorePreferences {
        struct Body: Encodable { let store: String; let locationId: String? }
        let id = locationId?.isEmpty == true ? nil : locationId
        return try await preferences(from: post("/api/v1/sdk/preferences", body: Body(store: store, locationId: id)))
    }

    private func preferences(from json: JSONValue) throws -> StorePreferences {
        do {
            return try json.decode(StorePreferences.self)
        } catch {
            throw MealioError(code: MealioError.Code.server, message: "Mealio sent store preferences the SDK could not read")
        }
    }

    /// Start a cart: signs in to the store if needed, searches every ingredient.
    /// A Kroger family store the user has not chosen a location for fails with
    /// `location_required`, before any sign-in. Pass `zip` to use the nearest
    /// store instead of asking them.
    /// `store` is optional: without it Mealio uses the user's default store,
    /// and fails with `store_required` when they have none yet.
    /// Pass `cancel` to stop it: it stops after the current step, sends nothing
    /// more, never shows sign-in, and fails with `cancelled`.
    public func prepareCart(store: String? = nil, recipe: Recipe, zip: String? = nil,
                            cancel: CancelToken? = nil, onStep: StepListener? = nil) async throws -> CartSession {
        try await prepareCart(store: store, recipes: [recipe], zip: zip, cancel: cancel, onStep: onStep)
    }

    /// Start one cart from several recipes (1 to `MAX_RECIPES`). Ingredients
    /// they share become one item, and each pick is remembered under every
    /// recipe that calls for it. Throws `bad_recipe` for an empty list and
    /// `too_many_recipes` past the limit, before any network call.
    public func prepareCart(store: String? = nil, recipes: [Recipe], zip: String? = nil,
                            cancel: CancelToken? = nil, onStep: StepListener? = nil) async throws -> CartSession {
        if recipes.isEmpty {
            throw MealioError(code: MealioError.Code.badRecipe, message: "Pass recipe, or recipes with at least one recipe.")
        }
        if recipes.count > MAX_RECIPES {
            throw MealioError(code: MealioError.Code.tooManyRecipes, message: "At most \(MAX_RECIPES) recipes in one cart.")
        }
        struct One: Encodable { let store: String?; let recipe: Recipe; let zip: String?; let sdk: SDKInfo; let epoch: Int; let warm: String? }
        struct Many: Encodable { let store: String?; let recipes: [Recipe]; let zip: String?; let sdk: SDKInfo; let epoch: Int; let warm: String? }
        let token = cancel ?? CancelToken()
        let result: JSONValue = try await cartJob(cancel: token) { () async throws -> JSONValue in
            let a = self.about()
            try MealioClient.stopIf(token)
            let warm = self.takeWarm(store: store, epoch: a.epoch)
            // One recipe goes as `recipe`, so a server from before multi-recipe still understands it.
            let start: JSONValue
            if recipes.count == 1 {
                start = try await self.post("/api/v1/sdk/carts", body: One(store: store, recipe: recipes[0], zip: zip, sdk: a.sdk, epoch: a.epoch, warm: warm), cancel: token)
            } else {
                start = try await self.post("/api/v1/sdk/carts", body: Many(store: store, recipes: recipes, zip: zip, sdk: a.sdk, epoch: a.epoch, warm: warm), cancel: token)
            }
            return try await self.drive(start, onStep: onStep, cancel: token)
        }
        let cart: PreparedCart
        do {
            cart = try result.decode(PreparedCart.self)
        } catch {
            throw MealioError(code: MealioError.Code.server, message: "Mealio sent a cart the SDK could not read")
        }
        #if DEBUG
        for w in cart.warnings ?? [] { print("[mealio] \(w.code): \(w.message)") }
        #endif
        return CartSession(client: self, cart: cart)
    }

    // MARK: - warm-up

    /// Run the login check for the user's store now, before they tap, so the
    /// cart that follows can start at search. Mealio picks the store: the
    /// user's default, or none, in which case nothing happens (a new user has
    /// no store to check yet). Never shows sign-in, never throws, and does
    /// nothing if it ran in the last few minutes, or while nobody is signed
    /// in. MealioCartButton calls it when it appears. Mirrors
    /// MealioClient.warm() in packages/core.
    public func warm(store: String? = nil) async {
        if user == .nobody { return }
        if let inFlight = warming, warmCancel?.cancelled != true {
            await inFlight.value
            return
        }
        // A cart is already driving or waiting for the one hidden page: a
        // warm-up now has nothing to gain, the cart has the session.
        if queue.pending > 0 { return }
        let now = Date().timeIntervalSince1970
        if now - lastWarmAt < MealioClient.warmFreshSeconds { return }
        lastWarmAt = now
        let cancel = CancelToken()
        warmCancel = cancel
        warmGen += 1
        let gen = warmGen
        let task = Task { [weak self] in
            guard let self = self else { return }
            await self.runWarm(store: store, cancel: cancel)
            if self.warmGen == gen { self.warming = nil }
        }
        warming = task
        await task.value
    }

    private func runWarm(store: String?, cancel: CancelToken) async {
        struct Body: Encodable { let store: String?; let sdk: SDKInfo; let epoch: Int }
        do {
            try await queue.run(cancel: cancel) { () async throws -> Void in
                try MealioClient.stopIf(cancel)
                try await self.runner.hostReady()
                await self.cleanPageIfDirty()
                try MealioClient.stopIf(cancel)
                let a = self.about()
                let start = try await self.post("/api/v1/sdk/warm", body: Body(store: store, sdk: a.sdk, epoch: a.epoch), cancel: cancel)
                guard let job = start["job"]?.stringValue else { return }
                let r = try await self.drive(start, onStep: nil, warm: true, cancel: cancel)
                if r["signedIn"]?.boolValue == true, let s = r["store"]?.stringValue {
                    self.warmed = Warmed(job: job, store: s, at: Date().timeIntervalSince1970,
                                         pageOpens: self.runner.pageOpens, epoch: a.epoch)
                } else {
                    self.warmed = nil
                }
            }
        } catch {
            // A warm-up that fails costs the user nothing: the cart runs as it
            // always has. One cancelled by a reset leaves the reset's state alone.
            if !cancel.cancelled { warmed = nil }
        }
    }

    /// The signed-in user changed. Forget the session, so the next call asks
    /// your server for a new one. Signing out of the stores does this too. A
    /// warm-up under way stops, and its result is never offered to the next prepare.
    public func resetSession() {
        sessionGen += 1
        token = nil
        warmCancel?.cancel(reason: .userChanged)
        clearWarm()
    }

    /// Tell the SDK who is signed in to your app, or nil for nobody. On a
    /// change it cancels any prepare or search and resets the session. An add
    /// runs on. While nil, warm does nothing and calls that need a session
    /// fail with `not_signed_in`, without asking your server. Returns true
    /// when the old value was a user: the platform then signs out of the stores.
    @discardableResult
    public func setUser(_ id: String?) -> Bool {
        let next: UserState = id.map { UserState.signedIn($0) } ?? .nobody
        let old = user
        if next == old { return false }
        user = next
        cancelJobs(reason: .userChanged)
        resetSession()
        if case .signedIn = old { return true }
        return false
    }

    /// Cancel every prepare and search, waiting or running. An add is not
    /// touched. Their `cancelled` error carries `reason`.
    public func cancelJobs(reason: CancelReason = .cancelled) {
        for c in Array(active.values) { c.cancel(reason: reason) }
        warmCancel?.cancel(reason: reason)
    }

    /// The most `runExclusive` holds the queue: past this the queue moves on
    /// even if its work has not ended, and the next job starts from a clean page.
    public static let exclusiveCapMs = 60_000

    /// Run `fn` with the hidden page to itself, in the queue with the jobs. For
    /// work that must not land in the middle of one, like clearing store
    /// sessions. It gets 30 seconds, then fails with `network`. The queue is
    /// held until `fn` has really ended or for 60 seconds, whichever is first;
    /// after the 60 the page is reset before the next job starts.
    public func runExclusive<T>(_ fn: @escaping @MainActor () async throws -> T) async throws -> T {
        try await runExclusive(stoppable: { _ in try await fn() })
    }

    /// As `runExclusive`, and `fn` gets a token that fires at the deadline,
    /// so each of its steps can stop.
    func runExclusive<T>(stoppable fn: @escaping @MainActor (CancelToken) async throws -> T) async throws -> T {
        let ms = config.requestTimeoutMs
        let cap = config.exclusiveCapMs
        let stop = CancelToken()
        // Its place in the queue is taken now, before the first suspension.
        let release = await queue.acquire()
        // The queue is let go when `fn` really ends, or at the cap, whichever
        // is first. Only the caller hears about the shorter deadline.
        let state = ExclusiveRun()
        let capTimer = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: nanoseconds(cap)) } catch { return }
            if state.ended { return }
            // Whatever it left on the hidden page is not trusted.
            self?.pageDirty = true
            stop.cancel()
            release()
        }
        let work = Task { @MainActor [weak self] () async throws -> T in
            defer {
                state.ended = true
                capTimer.cancel()
                release()
            }
            await self?.cleanPageIfDirty()
            return try await fn(stop)
        }
        return try await withDeadline(ms, late: {
            stop.cancel()
            work.cancel()
            return .failure(MealioError(code: MealioError.Code.network, message: "That took too long"))
        }, { try await work.value })
    }

    /// Set when exclusive work outlived its cap: the next job loads a blank
    /// page before it starts.
    private(set) var pageDirty = false

    /// Called at the start of every queued job.
    private func cleanPageIfDirty() async {
        guard pageDirty else { return }
        pageDirty = false
        runner.resetPage()
    }

    /// The current token. One that arrives after a reset belongs to the last
    /// user, so it is never kept. What happens then depends on the job:
    /// - `cancel` (prepare, search, warm): the job is over, `cancelled`. It
    ///   never asks for the next user's token.
    /// - `gen` (an add): the add belongs to the session of that generation. If
    ///   the session changed before the call or while waiting, `session_expired`.
    /// - neither: ask again, for whoever is signed in now.
    private func sessionToken(cancel: CancelToken? = nil, gen pinned: Int? = nil) async throws -> String {
        while true {
            if let c = cancel { try MealioClient.stopIf(c) }
            if let p = pinned, p != sessionGen { throw MealioClient.sessionChanged }
            if user == .nobody {
                throw MealioError(code: MealioError.Code.notSignedIn, message: "Nobody is signed in")
            }
            if let t = token { return t }
            let gen = sessionGen
            let provider = config.sessionTokenProvider
            var t = ""
            var failed: Error?
            do {
                t = try await withDeadline(config.requestTimeoutMs,
                                           late: { .failure(MealioError(code: MealioError.Code.sessionFailed, message: "The session function did not answer in time")) },
                                           { try await provider() })
            } catch {
                failed = error
            }
            // Cancelled while the token was on its way (cancelJobs): that is
            // the answer, even if the fetch failed too.
            if let c = cancel { try MealioClient.stopIf(c) }
            if gen != sessionGen {
                // A reset during the fetch: the session belongs to someone else now.
                if cancel != nil {
                    throw MealioError(code: MealioError.Code.cancelled, message: "Cancelled", reason: .userChanged)
                }
                if pinned != nil { throw MealioClient.sessionChanged }
                continue
            }
            if let failed = failed {
                throw MealioError(code: MealioError.Code.sessionFailed, message: MealioClient.message(of: failed))
            }
            token = t
            return t
        }
    }

    /// The partner's own words for an error, for `session_failed`.
    static func message(of error: Error) -> String {
        if let m = error as? MealioError, !m.message.isEmpty { return m.message }
        if let l = error as? LocalizedError, let d = l.errorDescription, !d.isEmpty { return d }
        let d = (error as NSError).localizedDescription
        return d.isEmpty ? "Could not start a Mealio session" : d
    }

    /// Forget any warm-up, e.g. after signing out of the stores.
    public func clearWarm() {
        warmed = nil
        lastWarmAt = 0
    }

    /// The warm job id, once, if the page it left is still showing and it is still fresh.
    private func takeWarm(store: String?, epoch: Int) -> String? {
        guard let w = warmed else { return nil }
        warmed = nil
        if let store = store, store != w.store { return nil }
        if w.pageOpens != runner.pageOpens || w.epoch != epoch { return nil }
        if Date().timeIntervalSince1970 - w.at > MealioClient.warmFreshSeconds { return nil }
        return w.job
    }

    /// Search the store again for one item ("minced garlic jar"). Pass
    /// `cancel` to stop it, as with `prepareCart`.
    public func search(cartId: String, key: String, query: String, cancel: CancelToken? = nil,
                       onStep: StepListener? = nil) async throws -> SearchResult {
        struct Body: Encodable { let key: String; let query: String; let sdk: SDKInfo; let epoch: Int }
        let token = cancel ?? CancelToken()
        let result: JSONValue = try await cartJob(cancel: token) { () async throws -> JSONValue in
            let a = self.about()
            try MealioClient.stopIf(token)
            let start = try await self.post("/api/v1/sdk/carts/\(MealioClient.encodeComponent(cartId))/search",
                                            body: Body(key: key, query: query, sdk: a.sdk, epoch: a.epoch), cancel: token)
            return try await self.drive(start, onStep: onStep, cancel: token)
        }
        do {
            return try result.decode(SearchResult.self)
        } catch {
            throw MealioError(code: MealioError.Code.server, message: "Mealio sent search results the SDK could not read")
        }
    }

    /// Fill the store cart with the user's choices. It cannot be cancelled:
    /// once tapped it runs to its end under the session it was called with
    /// (taken now, not after a wait in the queue), even if the user changes
    /// meanwhile. A 401 after the user changed fails with `session_expired`.
    /// Every wait in it is bounded, so it does end.
    public func addToCart(cartId: String, selections: [Selection],
                          onStep: StepListener? = nil) async throws -> AddResult {
        struct Body: Encodable { let selections: [Selection]; let sdk: SDKInfo; let epoch: Int }
        // The session is the one of the moment the add was asked for. Its
        // token is fetched while the add waits in line: the add takes its
        // place in the queue now, so a job asked for after it cannot run
        // first while the token is on its way.
        let gen = sessionGen
        let first = Task { @MainActor () async throws -> String in try await self.sessionToken(gen: gen) }
        let result: JSONValue = try await cartJob(cancel: nil) { () async throws -> JSONValue in
            let token = try await first.value
            let pin = SessionPin(token: token, gen: gen)
            let a = self.about()
            let start = try await self.post("/api/v1/sdk/carts/\(MealioClient.encodeComponent(cartId))/add",
                                            body: Body(selections: selections, sdk: a.sdk, epoch: a.epoch), pin: pin)
            return try await self.drive(start, onStep: onStep, pin: pin)
        }
        do {
            return try result.decode(AddResult.self)
        } catch {
            throw MealioError(code: MealioError.Code.server, message: "Mealio sent a result the SDK could not read")
        }
    }

    /// Apply a signed allowlist widening, if the server ever sends one. An
    /// allowlist that does not verify is ignored; the bundled one stands.
    public func widenAllowlist(_ env: Envelope) {
        if let p = try? openEnvelope(env, keys: config.keys), let a = p.asAllowlist() {
            runner.allowlist.widen(a)
        }
    }

    /// There is no hello call any more: every call carries the epoch. Kept so
    /// 0.1 code still compiles.
    @available(*, deprecated, message: "No longer needed: the epoch rides on every call.")
    public func resetHello() {}

    /// A cart call, queued. It counts as pending from the moment it is called,
    /// so a warm-up cannot slip in ahead of it. A cancelled call never starts.
    private func cartJob<T>(cancel: CancelToken?, _ fn: () async throws -> T) async throws -> T {
        queue.pending += 1
        if let c = cancel { active[ObjectIdentifier(c)] = c }
        defer {
            queue.pending -= 1
            if let c = cancel { active[ObjectIdentifier(c)] = nil }
        }
        return try await queue.run(cancel: cancel) { () async throws -> T in
            if let c = cancel { try MealioClient.stopIf(c) }
            // No job starts on a host that is not safe to use (on iOS: the
            // network block of checkout paths is not in place).
            try await self.runner.hostReady()
            await self.cleanPageIfDirty()
            if let c = cancel { try MealioClient.stopIf(c) }
            return try await fn()
        }
    }

    static func stopIf(_ cancel: CancelToken) throws {
        if cancel.cancelled { throw cancelled(cancel) }
    }

    /// The `cancelled` error, with the token's reason.
    static func cancelled(_ token: CancelToken?) -> MealioError {
        MealioError(code: MealioError.Code.cancelled, message: "Cancelled", reason: token?.reason ?? .cancelled)
    }

    static let cancelledError = MealioError(code: MealioError.Code.cancelled, message: "Cancelled", reason: .cancelled)
    static let sessionChanged = MealioError(code: MealioError.Code.sessionExpired, message: "The signed-in user changed")

    /// Drive a job to its end. A warm-up job may never show sign-in. `pin`
    /// holds the session an add was called with.
    private func drive(_ start: JSONValue, onStep: StepListener?, warm: Bool = false,
                       cancel: CancelToken? = nil, pin: SessionPin? = nil) async throws -> JSONValue {
        guard let job = start["job"]?.stringValue else {
            throw MealioError(code: MealioError.Code.server, message: "Mealio did not start a job")
        }
        var env = Envelope(json: start["envelope"])
        var seq = 0
        for _ in 0..<MealioClient.maxSteps {
            let out: StepOutcome
            do {
                if let onStep = onStep {
                    out = try await runner.run(env, job: job, lastSeq: seq, allowLogin: !warm, cancel: cancel) { ins in onStep(stepOf(ins), ins) }
                } else {
                    out = try await runner.run(env, job: job, lastSeq: seq, allowLogin: !warm, cancel: cancel)
                }
            } catch let e as EnvelopeError {
                let code = e.reason == .unsupportedOp ? MealioError.Code.unsupported : MealioError.Code.badEnvelope
                throw MealioError(code: code, message: e.description)
            }
            if let c = cancel { try MealioClient.stopIf(c) }
            seq = out.payload.seq
            if let t = out.terminal {
                switch t {
                case .done(let result): return result
                case .fail(let code, let message): throw MealioError(code: code, message: message)
                }
            }
            let next = try await post("/api/v1/sdk/jobs/\(MealioClient.encodeComponent(job))/step",
                                      body: StepRequest(seq: seq, results: out.results), pin: pin, cancel: cancel)
            env = Envelope(json: next["envelope"])
        }
        throw MealioError(code: MealioError.Code.server, message: "job did not finish")
    }

    /// One HTTP call, bounded: headers and body both inside the request
    /// timeout. `json` is nil when the body is not JSON. `cancel` aborts the
    /// URLSession task in flight and fails with `cancelled`; an answer that
    /// lands after the cancel is dropped the same way.
    private func request(_ req: URLRequest, cancel: CancelToken? = nil) async throws -> (status: Int, json: JSONValue?) {
        let session = config.urlSession
        let got: (Data, URLResponse)
        do {
            got = try await withDeadline(config.requestTimeoutMs,
                                         late: { .failure(URLError(.timedOut)) },
                                         cancel: cancel,
                                         { try await session.data(for: req) })
        } catch {
            if let c = cancel { try MealioClient.stopIf(c) }
            throw MealioError(code: MealioError.Code.network, message: "Could not reach Mealio")
        }
        if let c = cancel { try MealioClient.stopIf(c) }
        return ((got.1 as? HTTPURLResponse)?.statusCode ?? 0, JSONValue.parse(got.0))
    }

    /// The body of a good answer, or the error it stands for.
    static func answer(status: Int, json: JSONValue?) throws -> JSONValue {
        guard (200..<300).contains(status) else {
            let code = json?["error"]?["code"]?.stringValue ?? MealioError.Code.server
            let message = json?["error"]?["message"]?.stringValue ?? "Mealio answered \(status)"
            throw MealioError(code: code, message: message)
        }
        // A captive portal or a proxy can answer 200 with a web page.
        guard let body = json, body.objectValue != nil || body.arrayValue != nil else {
            throw MealioError(code: MealioError.Code.server, message: "Mealio sent an answer that could not be read")
        }
        return body
    }

    /// `pin`: an add's own session. `cancel`: the job's, checked once its session arrives.
    private func post<B: Encodable>(_ path: String, body: B, pin: SessionPin? = nil,
                                    cancel: CancelToken? = nil) async throws -> JSONValue {
        let data: Data
        do {
            if let b = body as? JSONNodeConvertible {
                // A JSON value or a step body, which may carry a page message
                // already 513 deep: JSONEncoder stops at 512, this writer does not.
                data = try JSONWriter().data(b.jsonNode)
            } else {
                // Typed bodies (recipes, selections, ids) hold no page message.
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.withoutEscapingSlashes]
                data = try encoder.encode(body)
            }
        } catch {
            throw MealioError(code: MealioError.Code.server, message: "Could not encode the request")
        }
        return try await post(path, data: data, pin: pin, cancel: cancel, retried: false)
    }

    private func post(_ path: String, data: Data, pin: SessionPin?, cancel: CancelToken?,
                      retried: Bool) async throws -> JSONValue {
        let token: String
        if let pin = pin {
            token = pin.token
        } else {
            token = try await sessionToken(cancel: cancel)
        }
        if let c = cancel { try MealioClient.stopIf(c) }
        guard let url = URL(string: base + path) else {
            throw MealioError(code: MealioError.Code.network, message: "Could not reach Mealio")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = data
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(config.publishableKey, forHTTPHeaderField: "X-Mealio-Publishable-Key")
        req.setValue("\(config.platform)/\(config.sdkVersion)", forHTTPHeaderField: "X-Mealio-SDK")
        if let attest = config.attestationProvider {
            let a: String? = try? await withDeadline(config.requestTimeoutMs, late: { .success(nil) }, { await attest() })
            if let a = a, !a.isEmpty {
                req.setValue(a, forHTTPHeaderField: "X-Mealio-Attestation")
            }
        }

        if let c = cancel { try MealioClient.stopIf(c) }
        let answer = try await request(req, cancel: cancel)
        if answer.status == 401 && !retried {
            // An add never moves to another session than the one it was asked
            // for in. Within it, it may get a fresh token.
            if let pin = pin, pin.gen != sessionGen { throw MealioClient.sessionChanged }
            if self.token == token { self.token = nil }
            if let pin = pin { pin.token = try await sessionToken(gen: pin.gen) }
            return try await post(path, data: data, pin: pin, cancel: cancel, retried: true)
        }
        if answer.status == 401 {
            throw MealioError(code: MealioError.Code.sessionExpired, message: "The Mealio session expired")
        }
        return try MealioClient.answer(status: answer.status, json: answer.json)
    }

    /// encodeURIComponent: everything but A-Z a-z 0-9 - _ . ! ~ * ' ( ) is escaped.
    static func encodeComponent(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
