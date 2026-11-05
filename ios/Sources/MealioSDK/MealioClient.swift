// The partner-facing flow: start a cart, drive the job through step calls,
// search again for one item, fill the cart. Mirrors packages/core/src/client.ts. This file has no
// UIKit in it; MealioCart (in MealioCart.swift) wires it to the WebViewHost.

import Foundation

/// SDK version, sent as `X-Mealio-SDK: ios/<version>` and in the `sdk` body field.
public let MEALIO_SDK_VERSION = "0.4.0"
/// The version of the reference core this SDK ports.
public let SDK_CORE_VERSION = "0.2.0"
public let DEFAULT_BASE_URL = URL(string: "https://mealio.co")!

/// An error the SDK raises to the app. `code` is one of `MealioError.Code`, or
/// a code the server sent (for example from a `fail` instruction).
public struct MealioError: Error, LocalizedError, Equatable, CustomStringConvertible {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
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
        /// No store was given and the user has no default store yet: let them pick one.
        public static let storeRequired = "store_required"
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

public struct MealioClientConfig {
    public var publishableKey: String
    /// Returns a token from POST /api/v1/sessions on the partner's server.
    /// Called again after a 401.
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

    public init(publishableKey: String,
                sessionTokenProvider: @escaping () async throws -> String,
                baseURL: URL = DEFAULT_BASE_URL,
                attestationProvider: (() async -> String?)? = nil,
                epochProvider: @escaping () -> Int = { StoreEpoch.current() },
                keys: [String: String] = MealioKeys.all,
                urlSession: URLSession = .shared,
                platform: String = "ios",
                sdkVersion: String = MEALIO_SDK_VERSION) {
        self.publishableKey = publishableKey
        self.sessionTokenProvider = sessionTokenProvider
        self.baseURL = baseURL
        self.attestationProvider = attestationProvider
        self.epochProvider = epochProvider
        self.keys = keys
        self.urlSession = urlSession
        self.platform = platform
        self.sdkVersion = sdkVersion
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

@MainActor
public final class MealioClient {
    public let config: MealioClientConfig
    let runner: Runner
    private var token: String?
    private let base: String

    /// How long a warm-up is offered to the next prepare. The server holds the same line (WARM_TTL_MS).
    public static let warmFreshSeconds: TimeInterval = 4 * 60

    /// A finished warm-up the next prepare may start from.
    struct Warmed { let job: String; let store: String; let at: TimeInterval; let pageOpens: Int; let epoch: Int }
    // Warm-up state. Touched only inside the small synchronous helpers below,
    // never across an await, so a plain lock is enough.
    private let warmLock = NSLock()
    private var warmed: Warmed?
    private var warming: Task<Void, Never>?
    private var lastWarmAt: TimeInterval = 0
    /// Cart jobs (prepare, search, add) driving the hidden page right now.
    private var running = 0

    /// Max envelopes in one job before the SDK gives up on it.
    static let maxSteps = 200

    public init(config: MealioClientConfig, host: MealioHost) {
        self.config = config
        self.runner = Runner(host: host, allowlist: Allowlist(), keys: config.keys)
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

    /// Stores the SDK supports right now. Public: no session token is sent.
    public func stores() async throws -> [StoreInfo] {
        guard let url = URL(string: base + "/api/v1/stores") else {
            throw MealioError(code: MealioError.Code.network, message: "Could not reach Mealio")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        let data: Data
        do {
            let (d, _) = try await config.urlSession.data(for: req)
            data = d
        } catch {
            throw MealioError(code: MealioError.Code.network, message: "Could not reach Mealio")
        }
        guard let json = JSONValue.parse(data) else {
            throw MealioError(code: MealioError.Code.network, message: "Could not reach Mealio")
        }
        guard let list = json["stores"]?.arrayValue else { return [] }
        return list.compactMap { try? $0.decode(StoreInfo.self) }
    }

    /// Start a cart: signs in to the store if needed, searches every ingredient.
    /// `store` is optional: without it Mealio uses the user's default store,
    /// and fails with `store_required` when they have none yet.
    public func prepareCart(store: String? = nil, recipe: Recipe, zip: String? = nil,
                            onStep: StepListener? = nil) async throws -> CartSession {
        try await prepareCart(store: store, recipes: [recipe], zip: zip, onStep: onStep)
    }

    /// Start one cart from several recipes (1 to `MAX_RECIPES`). Ingredients
    /// they share become one item, and each pick is remembered under every
    /// recipe that calls for it. Throws `bad_recipe` for an empty list and
    /// `too_many_recipes` past the limit, before any network call.
    public func prepareCart(store: String? = nil, recipes: [Recipe], zip: String? = nil,
                            onStep: StepListener? = nil) async throws -> CartSession {
        if recipes.isEmpty {
            throw MealioError(code: MealioError.Code.badRecipe, message: "Pass recipe, or recipes with at least one recipe.")
        }
        if recipes.count > MAX_RECIPES {
            throw MealioError(code: MealioError.Code.tooManyRecipes, message: "At most \(MAX_RECIPES) recipes in one cart.")
        }
        struct One: Encodable { let store: String?; let recipe: Recipe; let zip: String?; let sdk: SDKInfo; let epoch: Int; let warm: String? }
        struct Many: Encodable { let store: String?; let recipes: [Recipe]; let zip: String?; let sdk: SDKInfo; let epoch: Int; let warm: String? }
        enterJob()
        defer { leaveJob() }
        await settleWarm()
        let a = about()
        let warm = takeWarm(store: store, epoch: a.epoch)
        // One recipe goes as `recipe`, so a server from before multi-recipe still understands it.
        let start: JSONValue
        if recipes.count == 1 {
            start = try await post("/api/v1/sdk/carts", body: One(store: store, recipe: recipes[0], zip: zip, sdk: a.sdk, epoch: a.epoch, warm: warm))
        } else {
            start = try await post("/api/v1/sdk/carts", body: Many(store: store, recipes: recipes, zip: zip, sdk: a.sdk, epoch: a.epoch, warm: warm))
        }
        let result = try await drive(start, onStep: onStep)
        do {
            return CartSession(client: self, cart: try result.decode(PreparedCart.self))
        } catch {
            throw MealioError(code: MealioError.Code.server, message: "Mealio sent a cart the SDK could not read")
        }
    }

    // MARK: - warm-up

    /// Run the login check for the user's store now, before they tap, so the
    /// cart that follows can start at search. Mealio picks the store: the
    /// user's default, or none, in which case nothing happens (a new user has
    /// no store to check yet). Never shows sign-in, never throws, and does
    /// nothing if it ran in the last few minutes. MealioCartButton calls it
    /// when it appears. Mirrors MealioClient.warm() in packages/core.
    public func warm(store: String? = nil) async {
        guard let task = beginWarm(store: store) else {
            if let inFlight = currentWarm() { await inFlight.value }
            return
        }
        await task.value
    }

    /// Forget any warm-up, e.g. after signing out of the stores.
    public func clearWarm() {
        warmLock.lock(); defer { warmLock.unlock() }
        warmed = nil
        lastWarmAt = 0
    }

    private func beginWarm(store: String?) -> Task<Void, Never>? {
        warmLock.lock(); defer { warmLock.unlock() }
        let now = Date().timeIntervalSince1970
        if warming != nil { return nil }
        // A cart is already driving the one hidden page: a warm-up now would load
        // over it mid-run. Nothing to gain either, the cart has the session.
        if running > 0 { return nil }
        if now - lastWarmAt < MealioClient.warmFreshSeconds { return nil }
        lastWarmAt = now
        let task = Task<Void, Never> { [weak self] in
            guard let self = self else { return }
            await self.runWarm(store: store)
        }
        warming = task
        return task
    }

    private func currentWarm() -> Task<Void, Never>? {
        warmLock.lock(); defer { warmLock.unlock() }
        return warming
    }

    private func finishWarm(_ w: Warmed?) {
        warmLock.lock(); defer { warmLock.unlock() }
        warmed = w
        warming = nil
    }

    private func runWarm(store: String?) async {
        struct Body: Encodable { let store: String?; let sdk: SDKInfo; let epoch: Int }
        let a = about()
        var result: Warmed?
        do {
            let start = try await post("/api/v1/sdk/warm", body: Body(store: store, sdk: a.sdk, epoch: a.epoch))
            if let job = start["job"]?.stringValue {
                let r = try await drive(start, onStep: nil, warm: true)
                if r["signedIn"]?.boolValue == true, let s = r["store"]?.stringValue {
                    result = Warmed(job: job, store: s, at: Date().timeIntervalSince1970, pageOpens: runner.pageOpens, epoch: a.epoch)
                }
            }
        } catch {
            // A warm-up that fails costs the user nothing: the cart runs as it always has.
        }
        finishWarm(result)
    }

    /// A cart call (prepare, search, add) counts as running from before it
    /// settles any warm-up until it returns, so no warm-up starts during its
    /// first POST or its drive. The warm-up's own drive does not count.
    private func enterJob() {
        warmLock.lock(); defer { warmLock.unlock() }
        running += 1
    }

    private func leaveJob() {
        warmLock.lock(); defer { warmLock.unlock() }
        running -= 1
    }

    /// Every job drives the one hidden page: none may start while a warm-up is driving it.
    private func settleWarm() async {
        if let w = currentWarm() { await w.value }
    }

    /// The warm job id, once, if the page it left is still showing and it is still fresh.
    private func takeWarm(store: String?, epoch: Int) -> String? {
        warmLock.lock(); defer { warmLock.unlock() }
        guard let w = warmed else { return nil }
        warmed = nil
        if let store = store, store != w.store { return nil }
        if w.pageOpens != runner.pageOpens || w.epoch != epoch { return nil }
        if Date().timeIntervalSince1970 - w.at > MealioClient.warmFreshSeconds { return nil }
        return w.job
    }

    /// Search the store again for one item ("minced garlic jar").
    public func search(cartId: String, key: String, query: String,
                       onStep: StepListener? = nil) async throws -> SearchResult {
        struct Body: Encodable { let key: String; let query: String; let sdk: SDKInfo; let epoch: Int }
        enterJob()
        defer { leaveJob() }
        await settleWarm()
        let a = about()
        let start = try await post("/api/v1/sdk/carts/\(MealioClient.encodeComponent(cartId))/search",
                                   body: Body(key: key, query: query, sdk: a.sdk, epoch: a.epoch))
        let result = try await drive(start, onStep: onStep)
        do {
            return try result.decode(SearchResult.self)
        } catch {
            throw MealioError(code: MealioError.Code.server, message: "Mealio sent search results the SDK could not read")
        }
    }

    /// Fill the store cart with the user's choices.
    public func addToCart(cartId: String, selections: [Selection],
                          onStep: StepListener? = nil) async throws -> AddResult {
        struct Body: Encodable { let selections: [Selection]; let sdk: SDKInfo; let epoch: Int }
        enterJob()
        defer { leaveJob() }
        await settleWarm()
        let a = about()
        let start = try await post("/api/v1/sdk/carts/\(MealioClient.encodeComponent(cartId))/add",
                                   body: Body(selections: selections, sdk: a.sdk, epoch: a.epoch))
        let result = try await drive(start, onStep: onStep)
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

    /// Drive a job to its end. A warm-up job may never show sign-in.
    private func drive(_ start: JSONValue, onStep: StepListener?, warm: Bool = false) async throws -> JSONValue {
        guard let job = start["job"]?.stringValue else {
            throw MealioError(code: MealioError.Code.server, message: "Mealio did not start a job")
        }
        var env = Envelope(json: start["envelope"])
        var seq = 0
        for _ in 0..<MealioClient.maxSteps {
            let out: StepOutcome
            do {
                if let onStep = onStep {
                    out = try await runner.run(env, job: job, lastSeq: seq, allowLogin: !warm) { ins in onStep(stepOf(ins), ins) }
                } else {
                    out = try await runner.run(env, job: job, lastSeq: seq, allowLogin: !warm)
                }
            } catch let e as EnvelopeError {
                let code = e.reason == .unsupportedOp ? MealioError.Code.unsupported : MealioError.Code.badEnvelope
                throw MealioError(code: code, message: e.description)
            }
            seq = out.payload.seq
            if let t = out.terminal {
                switch t {
                case .done(let result): return result
                case .fail(let code, let message): throw MealioError(code: code, message: message)
                }
            }
            let next = try await post("/api/v1/sdk/jobs/\(MealioClient.encodeComponent(job))/step",
                                      body: StepRequest(seq: seq, results: out.results))
            env = Envelope(json: next["envelope"])
        }
        throw MealioError(code: MealioError.Code.server, message: "job did not finish")
    }

    private func post<B: Encodable>(_ path: String, body: B) async throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(body)
        } catch {
            throw MealioError(code: MealioError.Code.server, message: "Could not encode the request")
        }
        return try await post(path, data: data, retried: false)
    }

    private func post(_ path: String, data: Data, retried: Bool) async throws -> JSONValue {
        let token: String
        if let t = self.token {
            token = t
        } else {
            token = try await config.sessionTokenProvider()
            self.token = token
        }
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
        if let attest = config.attestationProvider, let a = await attest(), !a.isEmpty {
            req.setValue(a, forHTTPHeaderField: "X-Mealio-Attestation")
        }

        let responseData: Data
        let status: Int
        do {
            let (d, resp) = try await config.urlSession.data(for: req)
            responseData = d
            status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            throw MealioError(code: MealioError.Code.network, message: "Could not reach Mealio")
        }

        if status == 401 && !retried {
            self.token = nil
            return try await post(path, data: data, retried: true)
        }
        let json = JSONValue.parse(responseData)
        if status == 401 {
            throw MealioError(code: MealioError.Code.sessionExpired, message: "The Mealio session expired")
        }
        guard (200..<300).contains(status) else {
            let code = json?["error"]?["code"]?.stringValue ?? MealioError.Code.server
            let message = json?["error"]?["message"]?.stringValue ?? "Mealio answered \(status)"
            throw MealioError(code: code, message: message)
        }
        guard let body = json else {
            throw MealioError(code: MealioError.Code.server, message: "Mealio sent a response the SDK could not read")
        }
        return body
    }

    /// encodeURIComponent: everything but A-Z a-z 0-9 - _ . ! ~ * ' ( ) is escaped.
    static func encodeComponent(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
