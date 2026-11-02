// The partner-facing flow: hello, start a cart, drive the job through step
// calls, fill the cart. Mirrors packages/core/src/client.ts. This file has no
// UIKit in it; MealioCart (in MealioCart.swift) wires it to the WebViewHost.

import Foundation

/// SDK version, sent as `X-Mealio-SDK: ios/<version>` and in `hello`.
public let MEALIO_SDK_VERSION = "0.1.0"
/// The version of the reference core this SDK ports.
public let SDK_CORE_VERSION = "0.1.0"
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
        /// `CartSession.choose` was given a key that is not in the cart.
        public static let unknownItem = "unknown_item"
        /// `CartSession.choose` was given a product that was not offered.
        public static let unknownProduct = "unknown_product"
        /// `MealioCart.configure` has not been called.
        public static let notConfigured = "not_configured"
    }
}

/// The store-session epoch: a number the SDK bumps every time it signs out of
/// a store, kept in UserDefaults. `hello` sends it so the server knows the
/// device's store sessions changed.
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

@MainActor
public final class MealioClient {
    public let config: MealioClientConfig
    let runner: Runner
    private var helloDone = false
    private var token: String?
    private let base: String

    /// Max envelopes in one job before the SDK gives up on it.
    static let maxSteps = 200

    public init(config: MealioClientConfig, host: MealioHost) {
        self.config = config
        self.runner = Runner(host: host, allowlist: Allowlist(), keys: config.keys)
        var b = config.baseURL.absoluteString
        while b.hasSuffix("/") { b.removeLast() }
        self.base = b
    }

    /// The allowlist in force, including any hosts `hello` widened it with.
    public var allowlist: Allowlist { runner.allowlist }

    /// Start a cart: signs in to the store if needed, searches every ingredient.
    public func prepareCart(store: String, recipe: Recipe, zip: String? = nil) async throws -> CartSession {
        try await hello()
        struct Body: Encodable { let store: String; let recipe: Recipe; let zip: String? }
        let start = try await post("/api/v1/sdk/carts", body: Body(store: store, recipe: recipe, zip: zip))
        let result = try await drive(start)
        do {
            return CartSession(client: self, cart: try result.decode(PreparedCart.self))
        } catch {
            throw MealioError(code: MealioError.Code.server, message: "Mealio sent a cart the SDK could not read")
        }
    }

    /// Fill the store cart with the user's choices.
    public func addToCart(cartId: String, selections: [Selection]) async throws -> AddResult {
        try await hello()
        struct Body: Encodable { let selections: [Selection] }
        let start = try await post("/api/v1/sdk/carts/\(MealioClient.encodeComponent(cartId))/add", body: Body(selections: selections))
        let result = try await drive(start)
        do {
            return try result.decode(AddResult.self)
        } catch {
            throw MealioError(code: MealioError.Code.server, message: "Mealio sent a result the SDK could not read")
        }
    }

    /// Make the next call say hello again (after the store-session epoch changed).
    public func resetHello() {
        helloDone = false
    }

    func hello() async throws {
        if helloDone { return }
        struct SDKInfo: Encodable { let platform: String; let version: String; let core: String; let ops: [String] }
        struct Body: Encodable { let sdk: SDKInfo; let epoch: Int }
        let body = Body(sdk: SDKInfo(platform: config.platform, version: config.sdkVersion, core: SDK_CORE_VERSION, ops: SUPPORTED_OPS),
                        epoch: config.epochProvider())
        let res = try await post("/api/v1/sdk/hello", body: body)
        if let envJson = res["allowlist"], envJson != .null {
            // An allowlist we cannot verify is ignored; the bundled one stands.
            if let p = try? openEnvelope(Envelope(json: envJson), keys: config.keys), let a = p.asAllowlist() {
                runner.allowlist.widen(a)
            }
        }
        helloDone = true
    }

    private func drive(_ start: JSONValue) async throws -> JSONValue {
        guard let job = start["job"]?.stringValue else {
            throw MealioError(code: MealioError.Code.server, message: "Mealio did not start a job")
        }
        var env = Envelope(json: start["envelope"])
        var seq = 0
        for _ in 0..<MealioClient.maxSteps {
            let out: StepOutcome
            do {
                out = try await runner.run(env, job: job, lastSeq: seq)
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
            self.helloDone = false
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
