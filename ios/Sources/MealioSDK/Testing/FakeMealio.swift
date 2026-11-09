// MealioSDK testing support: run the REAL MealioClient and CartSession in
// your XCTest against a scripted fake Mealio, with no network. Mirrors
// `createFakeMealio` in `@mealio/sdk-core/testing`, with the same script
// format, so one JSON script can drive every platform's tests.
//
//     let fake = FakeMealio(script: [
//         "items": [["key": "milk", "remembered": "m1",
//                    "options": [["id": "m1", "name": "Milk", "unitPrice": 3]]]],
//         "search": ["oat milk": [["id": "o1", "name": "Oat milk", "unitPrice": 4]]],
//     ])
//     let client = fake.client()
//     let cart = try await client.prepareCart(recipe: recipe)
//
// It uses nothing but the SDK's public API: a URLSession whose requests a
// URLProtocol answers from the script, a fake store page (`fake.host`), and
// the protocol TEST signing key (`FakeMealio.testKeys`), which no production
// build trusts (MealioKeys.all holds only the production key).
//
// Debug builds only (#if DEBUG): it is compiled into your test runs, never
// into a release build of your app.

#if DEBUG
import CryptoKit
import Foundation

public final class FakeMealio: @unchecked Sendable {
    /// Which call a request was, as `FakeRequest.kind` in the TS kit.
    public enum Kind: String, Equatable {
        case prepare, search, add, warm, step, stores, preferences, locations, other
    }

    /// One call the client sent to the fake.
    public struct Request: Equatable {
        public let kind: Kind
        /// For example "/api/v1/sdk/carts".
        public let path: String
        public let body: JSONValue?
        /// The session token it carried, without "Bearer ".
        public let token: String?
    }

    /// The protocol test key ("ktest", protocol/test-vectors.json). Pass as `keys`.
    public static let testKeys: [String: String] = ["ktest": signer.publicKey.rawRepresentation.base64EncodedString()]

    // The deterministic TEST key of protocol/make-vectors.mjs: a seed of 32 bytes of 7.
    static let signer: Curve25519.Signing.PrivateKey = {
        // A 32-byte seed is always a valid key.
        try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
    }()

    private let lock = NSLock()
    private var _script: JSONValue
    private var _requests: [Request] = []
    private var _hostCalls: [String] = []
    private var carts: [String: (store: String, offered: [JSONValue])] = [:]
    /// Jobs waiting on their sign-in step: what to send for each outcome.
    private var jobs: [String: (store: String, cart: JSONValue)] = [:]
    /// Holds not yet taken by a request, by kind.
    private var holds: [Kind: [FakeHold]] = [:]
    /// Every hold made, so deinit can release them all.
    private var allHolds: [FakeHold] = []
    private var nJob = 0
    private var nCart = 0
    private var _searchHandler: ((String, String) -> [JSONValue])?
    private var _addHandler: (([Selection], [Product]) -> AddResult)?

    /// Where the client sends its calls. Unique per fake, so two fakes never
    /// answer each other. (The TS kit uses https://mealio.test.)
    public let baseURL: URL
    /// The session the client must use. `config` and `client` set it.
    public let urlSession: URLSession
    @MainActor private var madeHost: FakeStoreHost?
    /// The fake store page. Records into `hostCalls`.
    @MainActor public var host: FakeStoreHost {
        if let h = madeHost { return h }
        let h = FakeStoreHost(fake: self)
        madeHost = h
        return h
    }

    /// - Parameter script: the TS kit's FakeScript as plain data: `store`,
    ///   `storeName`, `items` (key, ingredient, quantity, options, remembered,
    ///   rememberedPreferenceId, rememberedUnavailable, startUnchecked,
    ///   weightLb, recipes, unavailable), `recipes`, `warnings`, `search`
    ///   (results by query, case-insensitive), `add` (`{"fail": error}`),
    ///   `signIn` ("signed_in", "cancelled", "timeout"), `errors` (by call:
    ///   prepare, search, add, warm, stores, preferences, locations, session;
    ///   a code, or {code, message, status}; with a status it is an HTTP
    ///   error, without one a job that fails), `stores`, `preferences`,
    ///   `locations`, `warm` ({signedIn} or null).
    public init(script: JSONValue = [:]) {
        _script = script
        let id = UUID().uuidString.lowercased()
        baseURL = URL(string: "https://\(id).mealio.test")!
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeMealioURLProtocol.self]
        urlSession = URLSession(configuration: config)
        FakeMealioURLProtocol.register(self, host: baseURL.host ?? id)
    }

    /// A script from JSON text, for one file shared with the other platforms.
    /// Throws `bad_script` when it is not one: text JSON.parse would refuse
    /// (trailing text included), an unknown field or a value of the wrong
    /// type at any level. The message names the field.
    public convenience init(json: String) throws {
        guard let script = JSONValue.parse(json) else {
            throw MealioError(code: "bad_script", message: "The fake Mealio script is not JSON")
        }
        try FakeScriptCheck.script(script)
        self.init(script: script)
    }

    deinit {
        FakeMealioURLProtocol.unregister(host: baseURL.host ?? "")
        // A request still held is let go: it finds no fake and fails, instead
        // of waiting for ever.
        for h in allHolds { h.release() }
    }

    /// The script in force. Change it between calls.
    public var script: JSONValue {
        get { lock.lock(); defer { lock.unlock() }; return _script }
        set { lock.lock(); _script = newValue; lock.unlock() }
    }

    /// Set one top-level field of the script (nil removes it), e.g.
    /// `fake.set("add", nil)`.
    public func set(_ key: String, _ value: JSONValue?) {
        lock.lock(); defer { lock.unlock() }
        guard case .object(var o) = _script else { return }
        o[key] = value
        _script = .object(o)
    }

    /// The TS kit's `search` as a function: (query, key) -> products as JSON.
    public var searchHandler: ((String, String) -> [JSONValue])? {
        get { lock.lock(); defer { lock.unlock() }; return _searchHandler }
        set { lock.lock(); _searchHandler = newValue; lock.unlock() }
    }

    /// The TS kit's `add` as a function: (selections, offered) -> result.
    public var addHandler: (([Selection], [Product]) -> AddResult)? {
        get { lock.lock(); defer { lock.unlock() }; return _addHandler }
        set { lock.lock(); _addHandler = newValue; lock.unlock() }
    }

    /// Every request the client sent, in order.
    public var requests: [Request] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    /// What the fake store page was asked to do: "open <url>", "script",
    /// "login", "fetch", "reset".
    public var hostCalls: [String] {
        lock.lock(); defer { lock.unlock() }
        return _hostCalls
    }

    func hostDid(_ call: String) {
        lock.lock(); _hostCalls.append(call); lock.unlock()
    }

    /// A config on this fake. `token` is your session function; by default
    /// it returns "session_test", or fails as `errors.session` says.
    public func config(publishableKey: String = "pk_test_fake",
                       token: (() async throws -> String)? = nil,
                       queue: JobQueue? = nil) -> MealioClientConfig {
        let provider: () async throws -> String
        if let token = token {
            provider = token
        } else {
            provider = { [weak self] () async throws -> String in
                if let e = self?.script["errors"]?["session"] {
                    let x = FakeMealio.errorParts(e)
                    throw MealioError(code: x.code, message: x.message)
                }
                return "session_test"
            }
        }
        return MealioClientConfig(publishableKey: publishableKey, sessionTokenProvider: provider, baseURL: baseURL,
                                  epochProvider: { 0 }, keys: FakeMealio.testKeys, urlSession: urlSession, queue: queue)
    }

    /// A real MealioClient on this fake and its store page.
    @MainActor
    public func client(publishableKey: String = "pk_test_fake", token: (() async throws -> String)? = nil,
                       queue: JobQueue? = nil) -> MealioClient {
        MealioClient(config: config(publishableKey: publishableKey, token: token, queue: queue), host: host)
    }

    /// The products a cart offered so far (prepare and its own searches).
    public func offered(_ cartId: String) -> [Product] {
        lock.lock(); defer { lock.unlock() }
        return (carts[cartId]?.offered ?? []).compactMap { try? $0.decode(Product.self) }
    }

    /// Hold the next request of this kind until the returned function is
    /// called. No thread waits meanwhile: the request is answered when it is
    /// released. Releasing twice does nothing. Releasing before the request
    /// comes lets it through at once. When the fake goes away, every hold is
    /// released.
    public func hold(_ kind: Kind) -> () -> Void {
        let h = FakeHold()
        lock.lock()
        holds[kind, default: []].append(h)
        allHolds.append(h)
        lock.unlock()
        return { h.release() }
    }

    // MARK: - the server

    static func kind(of path: String) -> Kind {
        let p = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        switch path {
        case "/api/v1/stores": return .stores
        case "/api/v1/sdk/preferences": return .preferences
        case "/api/v1/sdk/locations": return .locations
        case "/api/v1/sdk/warm": return .warm
        case "/api/v1/sdk/carts": return .prepare
        default: break
        }
        if p.count == 6, p[0] == "api", p[2] == "sdk" {
            if p[3] == "carts", p[5] == "search" { return .search }
            if p[3] == "carts", p[5] == "add" { return .add }
            if p[3] == "jobs", p[5] == "step" { return .step }
        }
        return .other
    }

    static let noFake: (Int, JSONValue) = (404, ["error": ["code": "server", "message": "No fake Mealio at this address"]])

    /// Record one request and answer it through `reply`: at once, or when its
    /// hold is released. Never blocks the calling thread.
    func receive(path: String, body: JSONValue?, auth: String?, reply: @escaping (Int, JSONValue) -> Void) {
        let kind = FakeMealio.kind(of: path)
        var token: String?
        if let a = auth { token = a.hasPrefix("Bearer ") ? String(a.dropFirst(7)) : a }
        lock.lock()
        _requests.append(Request(kind: kind, path: path, body: body, token: token))
        var gate: FakeHold?
        if kind != .other, var list = holds[kind], !list.isEmpty {
            gate = list.removeFirst()
            holds[kind] = list
        }
        lock.unlock()
        guard let gate = gate else {
            let (status, json) = answer(kind: kind, path: path, body: body)
            reply(status, json)
            return
        }
        gate.then { [weak self] in
            guard let self = self else {
                reply(FakeMealio.noFake.0, FakeMealio.noFake.1)
                return
            }
            let (status, json) = self.answer(kind: kind, path: path, body: body)
            reply(status, json)
        }
    }

    /// The answer to one request: (status, JSON body).
    private func answer(kind: Kind, path: String, body: JSONValue?) -> (Int, JSONValue) {
        let s = script
        let segment = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let id = segment.count > 4 ? (segment[4].removingPercentEncoding ?? segment[4]) : ""
        switch kind {
        case .stores:
            if let e = s["errors"]?["stores"] { return httpError(e) }
            let fallback: JSONValue = [["id": "heb", "name": "H-E-B", "via": "device"]]
            return (200, .object(["stores": s["stores"] ?? fallback]))
        case .preferences:
            if let e = s["errors"]?["preferences"] { return httpError(e) }
            if let store = body?["store"]?.stringValue {
                var location: JSONValue = prefs(s)["location"] ?? .null
                if let lid = body?["locationId"]?.stringValue {
                    location = (s["locations"]?.arrayValue ?? []).first { $0["id"]?.stringValue == lid } ?? .null
                }
                set("preferences", ["defaultStore": .string(store), "location": location])
                return (200, prefs(script))
            }
            return (200, prefs(s))
        case .locations:
            if let e = s["errors"]?["locations"] { return httpError(e) }
            return (200, ["locations": s["locations"] ?? []])
        case .warm:
            let store = body?["store"]?.stringValue ?? prefs(s)["defaultStore"]?.stringValue
            if case .null? = s["warm"] { return (200, ["warm": .null]) }
            guard let store = store else { return (200, ["warm": .null]) }
            if let e = s["errors"]?["warm"] { return jobError(store, e) }
            let warmed: JSONValue = ["store": .string(store), "signedIn": .bool(s["warm"]?["signedIn"]?.boolValue ?? true)]
            return start(store, [done(warmed)])
        case .prepare:
            return prepare(s, body)
        case .search:
            return search(s, id, body)
        case .add:
            return add(s, id, body)
        case .step:
            lock.lock()
            let j = jobs.removeValue(forKey: id)
            lock.unlock()
            guard let j = j else { return (404, ["error": ["code": "unknown_job", "message": "No such job"]]) }
            let outcome = (body?["results"]?.arrayValue ?? []).compactMap { $0["outcome"]?.stringValue }.first
            let next: [JSONValue] = outcome == "signed_in" ? [done(j.cart)]
                : [failOp(["code": "login_cancelled", "message": "Sign-in was closed"])]
            let seq = (body?["seq"]?.intValue ?? 1) + 1
            return (200, ["envelope": FakeMealio.signTestEnvelope(job: id, seq: seq, store: j.store, instructions: next)])
        case .other:
            return (200, [:])
        }
    }

    private func prefs(_ s: JSONValue) -> JSONValue {
        s["preferences"] ?? ["defaultStore": s["store"] ?? "heb", "location": .null]
    }

    private func home(_ store: String) -> String {
        "https://www.\(Allowlist().hostsFor(store)?.hosts.first ?? "heb.com")/"
    }

    private func loginURL(_ store: String) -> String {
        let h = Allowlist().hostsFor(store)
        if let first = h?.hosts.first { return "https://www.\(first)/login" }
        return "https://\(h?.authHosts.first ?? "www.heb.com")/login"
    }

    private func prepare(_ s: JSONValue, _ body: JSONValue?) -> (Int, JSONValue) {
        guard let store = body?["store"]?.stringValue ?? s["store"]?.stringValue ?? prefs(s)["defaultStore"]?.stringValue else {
            return httpError(["code": "store_required", "message": "Pick a store", "status": 400])
        }
        if let e = s["errors"]?["prepare"] { return jobError(store, e) }
        let items = (s["items"]?.arrayValue ?? []).map(FakeMealio.cartItem)
        lock.lock()
        nCart += 1
        let cartId = "cart_\(nCart)"
        carts[cartId] = (store, items.flatMap { $0["options"]?.arrayValue ?? [] })
        lock.unlock()
        let recipes: JSONValue
        if let r = s["recipes"] {
            recipes = r
        } else {
            var given: [JSONValue] = body?["recipes"]?.arrayValue ?? []
            if given.isEmpty, let one = body?["recipe"] { given = [one] }
            recipes = .array(given.map { (r: JSONValue) -> JSONValue in
                .object(["id": r["id"] ?? .null, "title": r["title"] ?? .null])
            })
        }
        let cart: JSONValue = [
            "cartId": .string(cartId), "store": .string(store),
            "storeName": s["storeName"] ?? .string(store == "heb" ? "H-E-B" : store),
            "items": .array(items), "ready": [], "needsChoice": [], "unavailable": [],
            "recipes": recipes, "warnings": s["warnings"] ?? [],
        ]
        // A Kroger family store has no page of its own: only its sign-in.
        var open: [JSONValue] = []
        if Allowlist().hostsFor(store)?.hosts.first != nil {
            open = [["op": "page_open", "id": "open-1", "url": .string(home(store)), "timeoutMs": 15000]]
        }
        let signIn = s["signIn"]?.stringValue
        if signIn == nil { return start(store, open + [done(cart)]) }
        let login: JSONValue = ["op": "show_login", "id": "login-1", "url": .string(loginURL(store)), "title": "Sign in",
                                "doneWhen": [["type": "FAKE_SIGNED_IN"]], "timeoutMs": 120_000]
        return start(store, open + [login], waitingOn: cart)
    }

    private func search(_ s: JSONValue, _ cartId: String, _ body: JSONValue?) -> (Int, JSONValue) {
        lock.lock()
        let store = carts[cartId]?.store ?? "heb"
        let handler = _searchHandler
        lock.unlock()
        if let e = s["errors"]?["search"] { return jobError(store, e) }
        let key = body?["key"]?.stringValue ?? ""
        let query = body?["query"]?.stringValue ?? ""
        var found: [JSONValue] = []
        if let handler = handler {
            found = handler(query, key)
        } else if case .object(let byQuery)? = s["search"] {
            found = byQuery.first { $0.key.lowercased() == query.lowercased() }?.value.arrayValue ?? []
        }
        lock.lock()
        carts[cartId]?.offered.append(contentsOf: found)
        lock.unlock()
        return start(store, [done(["key": .string(key), "query": .string(query), "options": .array(found)])])
    }

    private func add(_ s: JSONValue, _ cartId: String, _ body: JSONValue?) -> (Int, JSONValue) {
        lock.lock()
        let store = carts[cartId]?.store ?? "heb"
        let offeredJSON = carts[cartId]?.offered ?? []
        let handler = _addHandler
        lock.unlock()
        if let e = s["errors"]?["add"] { return jobError(store, e) }
        if let e = s["add"]?["fail"] { return jobError(store, e) }
        let offered = offeredJSON.compactMap { try? $0.decode(Product.self) }
        let selections = (body?["selections"]?.arrayValue ?? []).compactMap { try? $0.decode(Selection.self) }
        if let handler = handler {
            let result = (try? JSONValue(encoding: handler(selections, offered))) ?? .null
            return start(store, [done(result)])
        }
        var added: [JSONValue] = []
        var skipped: [JSONValue] = []
        var failed: [JSONValue] = []
        for sel in selections {
            guard let pid = sel.productId else {
                skipped.append(["key": .string(sel.key), "reason": "not_selected"])
                continue
            }
            guard let p = offeredJSON.first(where: { $0["id"]?.stringValue == pid }) else {
                failed.append(["key": .string(sel.key), "productId": .string(pid), "name": .string(pid), "reason": "not_offered"])
                continue
            }
            var a: [String: JSONValue] = ["key": .string(sel.key), "productId": .string(pid),
                                          "name": p["name"] ?? .string(pid), "quantity": .int(sel.quantity ?? 1)]
            if let w = sel.weightLb { a["weightLb"] = .double(w) }
            if let v = p["unitPrice"], v.doubleValue != nil { a["unitPrice"] = v }
            if let v = p["pricePerLb"], v.doubleValue != nil { a["pricePerLb"] = v }
            if p["estimated"]?.boolValue == true { a["estimated"] = true }
            added.append(.object(a))
        }
        let result: JSONValue = ["cartId": .string(cartId), "store": .string(store), "added": .array(added),
                                 "skipped": .array(skipped), "failed": .array(failed),
                                 "storeCartUrl": .string(home(store) + "cart"), "verified": true]
        return start(store, [done(result)])
    }

    private func start(_ store: String, _ instructions: [JSONValue], waitingOn cart: JSONValue? = nil) -> (Int, JSONValue) {
        lock.lock()
        nJob += 1
        let job = "job_\(nJob)"
        if let cart = cart { jobs[job] = (store, cart) }
        lock.unlock()
        return (200, ["job": .string(job), "envelope": FakeMealio.signTestEnvelope(job: job, seq: 1, store: store, instructions: instructions)])
    }

    private func done(_ result: JSONValue) -> JSONValue {
        ["op": "done", "id": "done-1", "result": result]
    }

    static func errorParts(_ e: JSONValue) -> (code: String, message: String, status: Int?) {
        if let code = e.stringValue { return (code, code, nil) }
        let code = e["code"]?.stringValue ?? "server"
        return (code, e["message"]?.stringValue ?? code, e["status"]?.intValue)
    }

    private func failOp(_ e: JSONValue) -> JSONValue {
        let x = FakeMealio.errorParts(e)
        return ["op": "fail", "id": "fail-1", "code": .string(x.code), "message": .string(x.message)]
    }

    /// With a status: an HTTP error. Without: a job that fails.
    private func jobError(_ store: String, _ e: JSONValue) -> (Int, JSONValue) {
        let x = FakeMealio.errorParts(e)
        if let status = x.status { return (status, ["error": ["code": .string(x.code), "message": .string(x.message)]]) }
        return start(store, [failOp(e)])
    }

    private func httpError(_ e: JSONValue) -> (Int, JSONValue) {
        let x = FakeMealio.errorParts(e)
        return (x.status ?? 400, ["error": ["code": .string(x.code), "message": .string(x.message)]])
    }

    /// An envelope signed with the test key, for tests that script
    /// instructions themselves. Same as `signTestEnvelope` in the TS kit.
    public static func signTestEnvelope(job: String, seq: Int, store: String, instructions: [JSONValue]) -> JSONValue {
        let payload: JSONValue = [
            "v": 1, "kind": "instructions", "job": .string(job), "seq": .int(seq),
            "exp": .int(4_102_444_800), "store": .string(store), "instructions": .array(instructions),
        ]
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        let text = (try? enc.encode(payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let sig = (try? signer.signature(for: Data(text.utf8)))?.base64EncodedString() ?? ""
        return ["payload": .string(text), "sig": .string(sig), "kid": "ktest"]
    }

    /// A cart item from a script line, as the server builds it. Same as
    /// `fakeCartItem` in the TS kit.
    public static func cartItem(_ f: JSONValue) -> JSONValue {
        let key = f["key"]?.stringValue ?? ""
        let options = f["options"]?.arrayValue ?? []
        var rem: JSONValue?
        if let rid = f["remembered"]?.stringValue {
            rem = options.first { $0["id"]?.stringValue == rid } ?? ["id": .string(rid), "name": .string(rid)]
        }
        let remId = rem?["id"]?.stringValue
        let usable = remId != nil && f["rememberedUnavailable"]?.boolValue != true && rem?["outOfStock"]?.boolValue != true
            && options.contains { $0["id"]?.stringValue == remId }
        let unavailable = f["unavailable"]?.stringValue
        let status: String = (unavailable != nil || options.isEmpty) ? "unavailable"
            : usable ? "remembered" : (remId != nil ? "remembered_unavailable" : "choose")
        var o: [String: JSONValue] = [
            "key": .string(key), "ingredient": f["ingredient"] ?? .string(key), "quantity": f["quantity"] ?? 1,
            "status": .string(status), "options": .array(options),
            "selectedId": usable ? .string(remId ?? "") : .null,
            "remembered": .null,
        ]
        if case .object(var r)? = rem {
            if !usable { r["outOfStock"] = true }
            o["remembered"] = .object(r)
        }
        if let v = f["rememberedPreferenceId"] { o["rememberedPreferenceId"] = v }
        if f["startUnchecked"]?.boolValue == true { o["startUnchecked"] = true }
        if let v = f["weightLb"] { o["weightLb"] = v }
        if let v = f["recipes"] { o["recipes"] = v }
        if status == "unavailable" { o["reason"] = .string(unavailable ?? "not_found") }
        return .object(o)
    }
}

/// One `hold`: the work it keeps back runs when it is released.
final class FakeHold: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var waiting: (() -> Void)?

    /// Run `work` now if released, else on release.
    func then(_ work: @escaping () -> Void) {
        lock.lock()
        if released {
            lock.unlock()
            work()
            return
        }
        waiting = work
        lock.unlock()
    }

    func release() {
        lock.lock()
        if released {
            lock.unlock()
            return
        }
        released = true
        let work = waiting
        waiting = nil
        lock.unlock()
        if let work = work { DispatchQueue.global().async { work() } }
    }
}

/// One answer carried across threads by `perform(_:on:with:waitUntilDone:)`.
final class FakeAnswer: NSObject {
    let url: URL?
    let status: Int
    let json: JSONValue

    init(url: URL?, status: Int, json: JSONValue) {
        self.url = url
        self.status = status
        self.json = json
    }
}

/// Answers each fake's requests. Fakes are found by host name.
final class FakeMealioURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var fakes: [String: WeakFake] = [:]

    private final class WeakFake {
        weak var fake: FakeMealio?
        init(_ fake: FakeMealio) { self.fake = fake }
    }

    static func register(_ fake: FakeMealio, host: String) {
        lock.lock(); fakes[host] = WeakFake(fake); lock.unlock()
    }

    static func unregister(host: String) {
        lock.lock(); fakes[host] = nil; lock.unlock()
    }

    private static func fake(for host: String) -> FakeMealio? {
        lock.lock(); defer { lock.unlock() }
        return fakes[host]?.fake
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// Set by stopLoading: a held answer that comes later is dropped.
    private let stateLock = NSLock()
    private var stopped = false

    override func startLoading() {
        let url = request.url
        let data = request.httpBody ?? FakeMealioURLProtocol.read(request.httpBodyStream)
        let json = data.flatMap { JSONValue.parse($0) }
        guard let host = url?.host, let fake = FakeMealioURLProtocol.fake(for: host) else {
            finish(url, FakeMealio.noFake.0, FakeMealio.noFake.1)
            return
        }
        // URLProtocol's client must be called on the thread that called
        // startLoading. A held answer is released from another thread, so it
        // is handed back to this one.
        let thread = Thread.current
        // ...and in the run loop mode it is running in: URLSession's loader
        // thread may not be running the default mode, and an answer
        // performed only in default mode would then never arrive.
        let modes = Array(Set([RunLoop.current.currentMode?.rawValue, RunLoop.Mode.default.rawValue].compactMap { $0 }))
        fake.receive(path: url?.path ?? "", body: json, auth: request.value(forHTTPHeaderField: "Authorization")) { status, answer in
            // Kept until answered; stopLoading makes this a no-op.
            if Thread.current === thread {
                self.finish(url, status, answer)
            } else {
                self.perform(#selector(FakeMealioURLProtocol.deliver(_:)), on: thread,
                             with: FakeAnswer(url: url, status: status, json: answer), waitUntilDone: false, modes: modes)
            }
        }
    }

    /// A held answer, back on the startLoading thread.
    @objc private func deliver(_ answer: FakeAnswer) {
        finish(answer.url, answer.status, answer.json)
    }

    private func finish(_ url: URL?, _ status: Int, _ answer: JSONValue) {
        stateLock.lock()
        let gone = stopped
        stateLock.unlock()
        if gone { return }
        let out = (try? JSONEncoder().encode(answer)) ?? Data("{}".utf8)
        if let url = url, let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                                         headerFields: ["Content-Type": "application/json"]) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: out)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        stateLock.lock()
        stopped = true
        stateLock.unlock()
    }

    private static func read(_ stream: InputStream?) -> Data? {
        guard let stream = stream else { return nil }
        stream.open()
        defer { stream.close() }
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            out.append(buffer, count: n)
        }
        return out
    }
}

/// The fake store page: every page opens, every script answers, and a
/// sign-in ends as the script's `signIn` says.
@MainActor
public final class FakeStoreHost: MealioHost {
    private weak var fake: FakeMealio?

    init(fake: FakeMealio) {
        self.fake = fake
    }

    public func openPage(store: String, url: String, timeoutMs: Int) async throws -> PageOpenOutcome {
        fake?.hostDid("open \(url)")
        return PageOpenOutcome(ok: true, finalUrl: url)
    }

    public func runScript(store: String, guardScript: String, script: String, until: [Matcher], timeoutMs: Int) async throws -> ScriptOutcome {
        fake?.hostDid("script")
        return ScriptOutcome(messages: [], timedOut: false)
    }

    public func showLogin(_ request: LoginRequest) async throws -> LoginOutcome {
        fake?.hostDid("login")
        if request.cancel?.cancelled == true { return LoginOutcome(outcome: .cancelled, messages: []) }
        let said = fake?.script["signIn"]?.stringValue ?? "signed_in"
        return LoginOutcome(outcome: LoginOutcomeKind(rawValue: said) ?? .signedIn, messages: [])
    }

    public func fetch(store: String, request: FetchRequest, timeoutMs: Int, maxBytes: Int) async throws -> FetchOutcome {
        fake?.hostDid("fetch")
        return FetchOutcome(ok: true, status: 200, headers: [:], body: "")
    }

    public func resetPage() {
        fake?.hostDid("reset")
    }
}
#endif

// MARK: - Strict script check

/// The TypeScript FakeScript type, field by field, as Kotlin's and Dart's
/// loaders check it. `null` only where the TS type says `| null`.
enum FakeScriptCheck {
    static func fail(_ path: String, _ what: String) -> MealioError {
        MealioError(code: "bad_script", message: "The fake Mealio script: \(path) \(what)")
    }

    /// A field's value against its type.
    private struct Fields {
        let o: [String: JSONValue]
        let path: String

        init(_ v: JSONValue, _ path: String, known: Set<String>?, required: Set<String> = []) throws {
            guard let o = v.objectValue else { throw FakeScriptCheck.fail(path, "must be an object") }
            self.o = o
            self.path = path
            if let known = known {
                for k in o.keys.sorted() where !known.contains(k) { throw FakeScriptCheck.fail("\(path).\(k)", "is not a known field") }
            }
            for k in required.sorted() where o[k] == nil { throw FakeScriptCheck.fail("\(path).\(k)", "is required") }
        }

        func at(_ k: String) -> String { "\(path).\(k)" }

        /// The value to check, or nil when absent (or null and allowed to be).
        private func value(_ k: String, _ nullable: Bool) -> JSONValue? {
            guard let v = o[k] else { return nil }
            if nullable, case .null = v { return nil }
            return v
        }

        func string(_ k: String, nullable: Bool = false, oneOf: [String]? = nil) throws {
            guard let v = value(k, nullable) else { return }
            guard let s = v.stringValue else {
                throw FakeScriptCheck.fail(at(k), nullable ? "must be a string or null" : "must be a string")
            }
            if let oneOf = oneOf, !oneOf.contains(s) {
                throw FakeScriptCheck.fail(at(k), "must be one of \(oneOf.joined(separator: ", ")), not \"\(s)\"")
            }
        }

        func number(_ k: String, nullable: Bool = false, integer: Bool = false) throws {
            guard let v = value(k, nullable) else { return }
            guard let d = v.doubleValue else {
                throw FakeScriptCheck.fail(at(k), nullable ? "must be a number or null" : "must be a number")
            }
            if integer, d.rounded(.down) != d { throw FakeScriptCheck.fail(at(k), "must be a whole number") }
        }

        func boolean(_ k: String, nullable: Bool = false) throws {
            guard let v = value(k, nullable) else { return }
            if v.boolValue == nil {
                throw FakeScriptCheck.fail(at(k), nullable ? "must be true, false or null" : "must be true or false")
            }
        }

        func obj(_ k: String, nullable: Bool = false, _ check: (JSONValue, String) throws -> Void) throws {
            guard let v = value(k, nullable) else { return }
            guard v.objectValue != nil else {
                throw FakeScriptCheck.fail(at(k), nullable ? "must be an object or null" : "must be an object")
            }
            try check(v, at(k))
        }

        func list(_ k: String, _ each: (JSONValue, String) throws -> Void) throws {
            guard let v = o[k] else { return }
            guard let a = v.arrayValue else { throw FakeScriptCheck.fail(at(k), "must be an array") }
            for (i, x) in a.enumerated() { try each(x, "\(at(k))[\(i)]") }
        }

        func objects(_ k: String, _ check: (JSONValue, String) throws -> Void) throws {
            try list(k) { v, p in
                guard v.objectValue != nil else { throw FakeScriptCheck.fail(p, "must be an object") }
                try check(v, p)
            }
        }
    }

    static let errorKinds: Set<String> = ["prepare", "search", "add", "warm", "stores", "preferences", "locations", "session"]

    static func script(_ v: JSONValue) throws {
        guard v.objectValue != nil else {
            throw MealioError(code: "bad_script", message: "The fake Mealio script must be a JSON object")
        }
        let f = try Fields(v, "script", known: ["store", "storeName", "items", "recipes", "warnings", "search", "add", "signIn",
                                                "errors", "stores", "preferences", "locations", "warm"])
        try f.string("store")
        try f.string("storeName")
        try f.objects("items", item)
        try f.objects("recipes") { r, p in
            let g = try Fields(r, p, known: ["id", "title"], required: ["id", "title"])
            try g.string("id")
            try g.string("title", nullable: true)
        }
        try f.objects("warnings") { w, p in
            let g = try Fields(w, p, known: ["code", "message"], required: ["code", "message"])
            try g.string("code")
            try g.string("message")
        }
        try f.obj("search") { m, p in
            let g = try Fields(m, p, known: nil)
            for q in g.o.keys.sorted() { try g.objects(q, product) }
        }
        try f.obj("add") { a, p in
            let g = try Fields(a, p, known: ["fail"], required: ["fail"])
            try error(g.o["fail"] ?? .null, g.at("fail"))
        }
        try f.string("signIn", nullable: true, oneOf: ["signed_in", "cancelled", "timeout"])
        try f.obj("errors") { m, p in
            let g = try Fields(m, p, known: errorKinds)
            for k in g.o.keys.sorted() { try error(g.o[k] ?? .null, g.at(k)) }
        }
        try f.objects("stores") { s, p in
            let g = try Fields(s, p, known: ["id", "name", "via"], required: ["id", "name", "via"])
            try g.string("id")
            try g.string("name")
            try g.string("via", oneOf: ["device", "kroger_api"])
        }
        try f.obj("preferences") { s, p in
            let g = try Fields(s, p, known: ["defaultStore", "location"], required: ["defaultStore", "location"])
            try g.string("defaultStore", nullable: true)
            try g.obj("location", nullable: true, location)
        }
        try f.objects("locations", location)
        // {} is signed in, as TS reads it (warm?.signedIn ?? true).
        try f.obj("warm", nullable: true) { w, p in
            try Fields(w, p, known: ["signedIn"]).boolean("signedIn", nullable: true)
        }
    }

    static func item(_ v: JSONValue, _ path: String) throws {
        let f = try Fields(v, path, known: ["key", "ingredient", "quantity", "options", "remembered", "rememberedPreferenceId",
                                            "rememberedUnavailable", "startUnchecked", "weightLb", "recipes", "unavailable"],
                           required: ["key"])
        try f.string("key")
        try f.string("ingredient")
        try f.number("quantity", integer: true)
        try f.objects("options", product)
        try f.string("remembered", nullable: true)
        try f.string("rememberedPreferenceId", nullable: true)
        try f.boolean("rememberedUnavailable")
        try f.boolean("startUnchecked")
        try f.number("weightLb")
        try f.objects("recipes") { r, p in
            let g = try Fields(r, p, known: ["id", "title", "quantity"], required: ["id", "title", "quantity"])
            try g.string("id")
            try g.string("title", nullable: true)
            try g.number("quantity", integer: true)
        }
        try f.string("unavailable")
    }

    static func product(_ v: JSONValue, _ path: String) throws {
        let f = try Fields(v, path, known: ["id", "name", "price", "imageUrl", "size", "outOfStock", "badge", "badgeLabel",
                                            "preferences", "unitPrice", "estimated", "maxQuantity", "soldByWeight",
                                            "weightOptions", "pricePerLb"],
                           required: ["id", "name"])
        try f.string("id")
        try f.string("name")
        try f.string("price", nullable: true)
        try f.string("imageUrl", nullable: true)
        try f.string("size", nullable: true)
        try f.boolean("outOfStock")
        try f.string("badge", nullable: true, oneOf: ["picked_before", "popular", "partner_pick"])
        try f.string("badgeLabel", nullable: true)
        try f.objects("preferences") { p, at in
            let g = try Fields(p, at, known: ["id", "label"], required: ["id", "label"])
            try g.string("id")
            try g.string("label")
        }
        try f.number("unitPrice", nullable: true)
        try f.boolean("estimated")
        try f.number("maxQuantity", nullable: true, integer: true)
        try f.boolean("soldByWeight")
        try f.list("weightOptions") { x, at in
            if x.doubleValue == nil { throw FakeScriptCheck.fail(at, "must be a number") }
        }
        try f.number("pricePerLb", nullable: true)
    }

    static func location(_ v: JSONValue, _ path: String) throws {
        let f = try Fields(v, path, known: ["id", "name", "address", "zip"], required: ["id", "name", "address", "zip"])
        try f.string("id")
        try f.string("name")
        try f.string("address")
        try f.string("zip", nullable: true)
    }

    static func error(_ v: JSONValue, _ path: String) throws {
        if v.stringValue != nil { return }
        guard v.objectValue != nil else { throw fail(path, "must be a code or {code, message?, status?}") }
        let f = try Fields(v, path, known: ["code", "message", "status"], required: ["code"])
        try f.string("code")
        try f.string("message")
        try f.number("status", integer: true)
    }
}
