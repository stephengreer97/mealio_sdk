// The relay protocol, as Swift types. PROTOCOL.md is the spec and wins any
// disagreement. packages/core/src/protocol.ts is the reference these mirror.

import Foundation

/// Protocol version this SDK speaks.
public let PROTOCOL_VERSION = 1

/// Max instructions the SDK will accept in one envelope.
public let MAX_INSTRUCTIONS = 64

/// Clock skew allowed when checking `exp`, in seconds.
public let EXP_SKEW_SECONDS: Double = 120

/// Every instruction `op` this SDK can run. Sent to the server in the `sdk`
/// field of every job-starting call.
public let SUPPORTED_OPS: [String] = ["page_open", "page_script", "show_login", "fetch", "done", "fail"]

// MARK: - JSON

/// Any JSON value. Used where the protocol carries arbitrary JSON
/// (posted messages, the `done` result).
public enum JSONValue: Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

/// One message a store script posted. Always a JSON object.
public typealias JSONMessage = [String: JSONValue]

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        // Order matters: Bool before numbers, Int before Double, so `true`,
        // `1` and `1.5` each land in the right case.
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not a JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        var o: [String: JSONValue] = [:]
        for (k, v) in elements { o[k] = v }
        self = .object(o)
    }
}

public extension JSONValue {
    /// Parse JSON text. Nil when it is not valid JSON.
    static func parse(_ text: String) -> JSONValue? {
        parse(Data(text.utf8))
    }

    /// Parse JSON bytes. Nil when they are not valid JSON.
    static func parse(_ data: Data) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Build a JSONValue from any Encodable value.
    init<T: Encodable>(encoding value: T) throws {
        let data = try JSONEncoder().encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Decode this value into a Decodable type.
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(type, from: data)
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    /// The number as a Double, for either number case.
    var doubleValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    /// The number as an Int when it is a whole number.
    var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d):
            guard d.isFinite, d.rounded() == d, abs(d) < 9.0e15 else { return nil }
            return Int(d)
        default: return nil
        }
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// JavaScript-style strict equality for primitives, structural equality for
    /// arrays and objects. 1 and 1.0 are equal, as they are in JavaScript.
    /// (The TS reference compares objects with JSON.stringify, which also cares
    /// about key order. Swift dictionaries have no order, so here two objects
    /// with the same keys and values are equal whatever their order.)
    func jsEquals(_ other: JSONValue) -> Bool {
        switch (self, other) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.array(let a), .array(let b)):
            guard a.count == b.count else { return false }
            for (x, y) in zip(a, b) where !x.jsEquals(y) { return false }
            return true
        case (.object(let a), .object(let b)):
            guard a.count == b.count else { return false }
            for (k, x) in a {
                guard let y = b[k], x.jsEquals(y) else { return false }
            }
            return true
        default:
            if let a = self.doubleValue, let b = other.doubleValue { return a == b }
            return false
        }
    }
}

// MARK: - Envelope

/// A signed instruction batch, exactly as the server sent it.
public struct Envelope: Codable, Equatable {
    /// A JSON string. The signature covers its UTF-8 bytes as received.
    public let payload: String
    /// Base64 Ed25519 signature.
    public let sig: String
    /// Which public key signed it.
    public let kid: String

    public init(payload: String, sig: String, kid: String) {
        self.payload = payload
        self.sig = sig
        self.kid = kid
    }

    /// Read an envelope out of a JSON value. Nil when `payload` or `sig` is not
    /// a string (the "shape" refusal). A missing `kid` becomes "" and is
    /// refused later as unknown.
    public init?(json: JSONValue?) {
        guard let json = json,
              let payload = json["payload"]?.stringValue,
              let sig = json["sig"]?.stringValue else { return nil }
        self.payload = payload
        self.sig = sig
        self.kid = json["kid"]?.stringValue ?? ""
    }
}

// MARK: - Matcher

/// PROTOCOL.md "Matcher": `{ type, eq?, ne? }`.
public struct Matcher: Codable, Equatable {
    public let type: String
    public let eq: [String: JSONValue]?
    public let ne: [String: JSONValue]?

    public init(type: String, eq: [String: JSONValue]? = nil, ne: [String: JSONValue]? = nil) {
        self.type = type
        self.eq = eq
        self.ne = ne
    }

    /// Nil when the value is not an object with a string `type`.
    public init?(json: JSONValue) {
        guard let type = json["type"]?.stringValue else { return nil }
        self.type = type
        self.eq = json["eq"]?.objectValue
        self.ne = json["ne"]?.objectValue
    }
}

// MARK: - Instructions

public struct PageOpen: Equatable {
    public let id: String
    public let url: String
    public let timeoutMs: Int
}

public struct PageScript: Equatable {
    public let id: String
    public let script: String
    public let until: [Matcher]
    public let timeoutMs: Int
}

/// The script the login sheet injects to tell whether the user is signed in.
public struct LoginCheck: Equatable {
    public let script: String
    public let intervalMs: Int

    public init(script: String, intervalMs: Int) {
        self.script = script
        self.intervalMs = intervalMs
    }
}

public struct ShowLogin: Equatable {
    public let id: String
    public let url: String
    public let title: String
    public let check: LoginCheck?
    public let doneWhen: [Matcher]
    public let doneWhenUrl: String?
    public let timeoutMs: Int
}

public struct FetchRequest: Codable, Equatable {
    public let method: String
    public let url: String
    public let headers: [String: String]?
    public let body: String?

    public init(method: String, url: String, headers: [String: String]? = nil, body: String? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct FetchOp: Equatable {
    public let id: String
    public let request: FetchRequest
    public let timeoutMs: Int
    public let maxBytes: Int
}

public struct DoneOp: Equatable {
    public let id: String
    public let result: JSONValue
}

public struct FailOp: Equatable {
    public let id: String
    public let code: String
    public let message: String
}

/// One instruction from a signed envelope.
public enum Instruction: Equatable {
    case pageOpen(PageOpen)
    case pageScript(PageScript)
    case showLogin(ShowLogin)
    case fetch(FetchOp)
    case done(DoneOp)
    case fail(FailOp)
    /// An op this SDK does not know, or a known op missing a field it needs.
    /// checkInstructions refuses envelopes that contain one.
    case unsupported(op: String?)

    public var id: String {
        switch self {
        case .pageOpen(let i): return i.id
        case .pageScript(let i): return i.id
        case .showLogin(let i): return i.id
        case .fetch(let i): return i.id
        case .done(let i): return i.id
        case .fail(let i): return i.id
        case .unsupported: return ""
        }
    }

    /// Read one instruction from its JSON. Never fails: anything it cannot
    /// read becomes `.unsupported`. Numeric fields the server left out get the
    /// defaults PROTOCOL.md uses in its examples.
    public init(json: JSONValue) {
        guard let op = json["op"]?.stringValue, let id = json["id"]?.stringValue else {
            self = .unsupported(op: json["op"]?.stringValue)
            return
        }
        func int(_ key: String, _ fallback: Int) -> Int {
            json[key]?.intValue ?? fallback
        }
        func matchers(_ key: String) -> [Matcher] {
            (json[key]?.arrayValue ?? []).compactMap { Matcher(json: $0) }
        }
        switch op {
        case "page_open":
            guard let url = json["url"]?.stringValue else { self = .unsupported(op: op); return }
            self = .pageOpen(PageOpen(id: id, url: url, timeoutMs: int("timeoutMs", 15000)))
        case "page_script":
            guard let script = json["script"]?.stringValue else { self = .unsupported(op: op); return }
            self = .pageScript(PageScript(id: id, script: script, until: matchers("until"), timeoutMs: int("timeoutMs", 20000)))
        case "show_login":
            guard let url = json["url"]?.stringValue else { self = .unsupported(op: op); return }
            var check: LoginCheck?
            if let c = json["check"], let script = c["script"]?.stringValue {
                check = LoginCheck(script: script, intervalMs: c["intervalMs"]?.intValue ?? 3000)
            }
            self = .showLogin(ShowLogin(
                id: id, url: url, title: json["title"]?.stringValue ?? "",
                check: check, doneWhen: matchers("doneWhen"),
                doneWhenUrl: json["doneWhenUrl"]?.stringValue,
                timeoutMs: int("timeoutMs", 600_000)))
        case "fetch":
            guard let req = json["request"], let url = req["url"]?.stringValue else { self = .unsupported(op: op); return }
            var headers: [String: String]?
            if let h = req["headers"]?.objectValue {
                var out: [String: String] = [:]
                for (k, v) in h { if let s = v.stringValue { out[k] = s } }
                headers = out
            }
            let request = FetchRequest(method: req["method"]?.stringValue ?? "GET", url: url,
                                       headers: headers, body: req["body"]?.stringValue)
            self = .fetch(FetchOp(id: id, request: request, timeoutMs: int("timeoutMs", 12000), maxBytes: int("maxBytes", 400_000)))
        case "done":
            self = .done(DoneOp(id: id, result: json["result"] ?? .null))
        case "fail":
            self = .fail(FailOp(id: id, code: json["code"]?.stringValue ?? "server", message: json["message"]?.stringValue ?? ""))
        default:
            self = .unsupported(op: op)
        }
    }
}

// MARK: - Payloads

/// A verified, parsed payload. `kind` says which kind it is; use
/// `checkInstructions` or `asAllowlist()` to read it further.
public struct Payload {
    /// The payload object exactly as parsed.
    public let raw: [String: JSONValue]
    public var kind: String? { raw["kind"]?.stringValue }
    public var exp: Double? { raw["exp"]?.doubleValue }

    /// The payload as an allowlist update, when `kind` is "allowlist".
    public func asAllowlist() -> AllowlistPayload? {
        guard kind == "allowlist" else { return nil }
        var stores: [String: AllowlistPayload.StorePatch] = [:]
        for (store, v) in raw["stores"]?.objectValue ?? [:] {
            stores[store] = AllowlistPayload.StorePatch(
                hosts: v["hosts"]?.arrayValue?.compactMap { $0.stringValue },
                authHosts: v["authHosts"]?.arrayValue?.compactMap { $0.stringValue })
        }
        return AllowlistPayload(v: raw["v"]?.intValue ?? 0, exp: exp ?? 0, stores: stores)
    }
}

public struct InstructionsPayload: Equatable {
    public let v: Int
    public let job: String
    public let seq: Int
    public let exp: Double
    public let store: String
    public let instructions: [Instruction]
}

public struct AllowlistPayload: Equatable {
    public struct StorePatch: Equatable {
        public let hosts: [String]?
        public let authHosts: [String]?
        public init(hosts: [String]? = nil, authHosts: [String]? = nil) {
            self.hosts = hosts
            self.authHosts = authHosts
        }
    }
    public let v: Int
    public let exp: Double
    public let stores: [String: StorePatch]

    public init(v: Int = 1, exp: Double = 0, stores: [String: StorePatch]) {
        self.v = v
        self.exp = exp
        self.stores = stores
    }
}

// MARK: - Results

public enum LoginOutcomeKind: String, Codable, Equatable {
    case signedIn = "signed_in"
    case cancelled
    case timeout
}

/// One result per instruction, in order. A single struct covers every op;
/// only the fields that op uses are set, and nil fields are left out of the
/// JSON, so each op's result has the shape PROTOCOL.md gives it.
public struct InstructionResult: Codable, Equatable {
    public var id: String
    public var ok: Bool
    public var ms: Int
    public var skipped: Bool?
    public var error: String?
    // page_open
    public var finalUrl: String?
    // page_script and show_login
    public var messages: [JSONMessage]?
    // page_script
    public var timedOut: Bool?
    // show_login
    public var outcome: LoginOutcomeKind?
    // fetch
    public var status: Int?
    public var headers: [String: String]?
    public var body: String?
    public var truncated: Bool?

    public init(id: String, ok: Bool, ms: Int, skipped: Bool? = nil, error: String? = nil, finalUrl: String? = nil,
                messages: [JSONMessage]? = nil, timedOut: Bool? = nil, outcome: LoginOutcomeKind? = nil,
                status: Int? = nil, headers: [String: String]? = nil, body: String? = nil, truncated: Bool? = nil) {
        self.id = id
        self.ok = ok
        self.ms = ms
        self.skipped = skipped
        self.error = error
        self.finalUrl = finalUrl
        self.messages = messages
        self.timedOut = timedOut
        self.outcome = outcome
        self.status = status
        self.headers = headers
        self.body = body
        self.truncated = truncated
    }
}

/// Body of `POST /api/v1/sdk/jobs/{job}/step`.
public struct StepRequest: Codable, Equatable {
    public let seq: Int
    public let results: [InstructionResult]
}

// MARK: - What a finished job hands back

public struct ProductPreference: Codable, Equatable, Identifiable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public struct Product: Codable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let price: String?
    public let imageUrl: String?
    public let size: String?
    public let outOfStock: Bool?
    /// Why this option sits where it does: "picked_before", "popular" or
    /// "partner_pick". Ranking only, never an automatic pick.
    public let badge: String?
    /// Variants the user must pick one of before this product can be added.
    /// Pass the chosen id as `preferenceId`.
    public let preferences: [ProductPreference]?
    /// One unit's price as a number, for an estimated total.
    public let unitPrice: Double?
    /// Sold by weight: the price is the store's estimate. False when the
    /// server did not say.
    public let estimated: Bool

    public init(id: String, name: String, price: String? = nil, imageUrl: String? = nil, size: String? = nil,
                outOfStock: Bool? = nil, badge: String? = nil, preferences: [ProductPreference]? = nil,
                unitPrice: Double? = nil, estimated: Bool = false) {
        self.id = id
        self.name = name
        self.price = price
        self.imageUrl = imageUrl
        self.size = size
        self.outOfStock = outOfStock
        self.badge = badge
        self.preferences = preferences
        self.unitPrice = unitPrice
        self.estimated = estimated
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, price, imageUrl, size, outOfStock, badge, preferences, unitPrice, estimated
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        price = try c.decodeIfPresent(String.self, forKey: .price)
        imageUrl = try c.decodeIfPresent(String.self, forKey: .imageUrl)
        size = try c.decodeIfPresent(String.self, forKey: .size)
        outOfStock = try c.decodeIfPresent(Bool.self, forKey: .outOfStock)
        badge = try c.decodeIfPresent(String.self, forKey: .badge)
        preferences = try c.decodeIfPresent([ProductPreference].self, forKey: .preferences)
        unitPrice = try c.decodeIfPresent(Double.self, forKey: .unitPrice)
        estimated = try c.decodeIfPresent(Bool.self, forKey: .estimated) ?? false
    }
}

/// Where an item stands when the cart is prepared.
public enum ItemStatus: String, Codable, Equatable {
    /// The user's remembered product, in stock, pre-selected.
    case remembered
    /// Nothing remembered yet: the user picks.
    case choose
    /// The remembered product is out of stock or gone this time.
    case rememberedUnavailable = "remembered_unavailable"
    /// Nothing found; `reason` says why.
    case unavailable
}

public struct CartItem: Codable, Equatable, Identifiable {
    public let key: String
    public let ingredient: String
    public let quantity: Int
    public let status: ItemStatus
    /// Every option, best first. The remembered product leads when the store has it.
    public let options: [Product]
    /// Pre-selected product id for this run, or nil.
    public let selectedId: String?
    /// The user's remembered product, whatever its stock.
    public let remembered: Product?
    public let rememberedPreferenceId: String?
    /// Why nothing could be offered, e.g. "no_results".
    public let reason: String?
    /// Deprecated 0.1 shape: the remembered product when it was in stock.
    public let chosen: Product?

    public var id: String { key }

    public init(key: String, ingredient: String, quantity: Int = 1, status: ItemStatus, options: [Product] = [],
                selectedId: String? = nil, remembered: Product? = nil, rememberedPreferenceId: String? = nil,
                reason: String? = nil, chosen: Product? = nil) {
        self.key = key
        self.ingredient = ingredient
        self.quantity = quantity
        self.status = status
        self.options = options
        self.selectedId = selectedId
        self.remembered = remembered
        self.rememberedPreferenceId = rememberedPreferenceId
        self.reason = reason
        self.chosen = chosen
    }

    private enum CodingKeys: String, CodingKey {
        case key, ingredient, quantity, status, options, selectedId, remembered, rememberedPreferenceId, reason, chosen
    }

    /// Every field past `key` is optional, so a 0.1 payload (chosen / options /
    /// reason only) still decodes, with the new fields derived from it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        ingredient = try c.decodeIfPresent(String.self, forKey: .ingredient) ?? key
        quantity = try c.decodeIfPresent(Int.self, forKey: .quantity) ?? 1
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        chosen = try c.decodeIfPresent(Product.self, forKey: .chosen)
        let opts = try c.decodeIfPresent([Product].self, forKey: .options)
        remembered = try c.decodeIfPresent(Product.self, forKey: .remembered) ?? chosen
        rememberedPreferenceId = try c.decodeIfPresent(String.self, forKey: .rememberedPreferenceId)
        let derived: ItemStatus = chosen != nil ? .remembered : ((opts?.isEmpty ?? true) ? .unavailable : .choose)
        let st = (try c.decodeIfPresent(String.self, forKey: .status)).flatMap { ItemStatus(rawValue: $0) } ?? derived
        status = st
        options = opts ?? (chosen.map { [$0] } ?? [])
        if c.contains(.selectedId) {
            selectedId = try c.decodeIfPresent(String.self, forKey: .selectedId)
        } else {
            selectedId = st == .remembered ? (chosen ?? remembered)?.id : nil
        }
    }
}

public struct PreparedCart: Codable, Equatable {
    public let cartId: String
    public let store: String
    /// Display name, e.g. "H-E-B".
    public let storeName: String?
    /// Every recipe line, in recipe order. Show them all. Rebuilt from the
    /// 0.1 groupings when an older server leaves it out.
    public let items: [CartItem]
    /// Deprecated 0.1 groupings derived from `items`.
    public let ready: [CartItem]
    public let needsChoice: [CartItem]
    public let unavailable: [CartItem]

    public init(cartId: String, store: String, storeName: String? = nil, items: [CartItem],
                ready: [CartItem] = [], needsChoice: [CartItem] = [], unavailable: [CartItem] = []) {
        self.cartId = cartId
        self.store = store
        self.storeName = storeName
        self.items = items
        self.ready = ready
        self.needsChoice = needsChoice
        self.unavailable = unavailable
    }

    private enum CodingKeys: String, CodingKey { case cartId, store, storeName, items, ready, needsChoice, unavailable }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cartId = try c.decode(String.self, forKey: .cartId)
        store = try c.decode(String.self, forKey: .store)
        storeName = try c.decodeIfPresent(String.self, forKey: .storeName)
        ready = try c.decodeIfPresent([CartItem].self, forKey: .ready) ?? []
        needsChoice = try c.decodeIfPresent([CartItem].self, forKey: .needsChoice) ?? []
        unavailable = try c.decodeIfPresent([CartItem].self, forKey: .unavailable) ?? []
        items = try c.decodeIfPresent([CartItem].self, forKey: .items) ?? (ready + needsChoice + unavailable)
    }
}

/// What `POST /api/v1/sdk/carts/{cartId}/search` hands back when its job is done.
public struct SearchResult: Codable, Equatable {
    public let key: String
    public let query: String
    public let options: [Product]

    private enum CodingKeys: String, CodingKey { case key, query, options }

    public init(key: String, query: String, options: [Product]) {
        self.key = key
        self.query = query
        self.options = options
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        query = try c.decodeIfPresent(String.self, forKey: .query) ?? ""
        options = try c.decodeIfPresent([Product].self, forKey: .options) ?? []
    }
}

public struct AddResult: Codable, Equatable {
    public struct Added: Codable, Equatable { public let key: String; public let productId: String; public let name: String; public let quantity: Int }
    public struct Skipped: Codable, Equatable { public let key: String; public let reason: String }
    public struct Failed: Codable, Equatable { public let key: String; public let productId: String; public let name: String; public let reason: String }

    public let cartId: String
    public let store: String
    public let added: [Added]
    public let skipped: [Skipped]
    public let failed: [Failed]
    public let storeCartUrl: String?
    /// True when a cart read after adding confirmed every added item. An
    /// item the read did not find comes back in `failed` with reason
    /// "not_confirmed".
    public let verified: Bool?
}

/// One store the SDK supports, from `GET /api/v1/stores`.
public struct StoreInfo: Codable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// "device": runs on the phone with the user's store login.
    /// "kroger_api": through Kroger's API.
    public let via: String?

    public init(id: String, name: String, via: String? = nil) {
        self.id = id
        self.name = name
        self.via = via
    }
}

/// The user's decision for one item. `productId` nil leaves it out of this
/// run; with `remember: false` the remembered choice is kept for next time.
public struct Selection: Codable, Equatable {
    public let key: String
    public let productId: String?
    public let quantity: Int?
    /// Save this choice for the next time this recipe is carted.
    public let remember: Bool?
    /// Required when the chosen Product has `preferences`.
    public let preferenceId: String?

    public init(key: String, productId: String?, quantity: Int? = nil, remember: Bool? = nil, preferenceId: String? = nil) {
        self.key = key
        self.productId = productId
        self.quantity = quantity
        self.remember = remember
        self.preferenceId = preferenceId
    }

    private enum CodingKeys: String, CodingKey { case key, productId, quantity, remember, preferenceId }

    // productId is always sent, as null for a skip.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(productId, forKey: .productId)
        try c.encodeIfPresent(quantity, forKey: .quantity)
        try c.encodeIfPresent(remember, forKey: .remember)
        try c.encodeIfPresent(preferenceId, forKey: .preferenceId)
    }
}

public struct RecipeIngredient: Codable, Equatable {
    public let name: String
    /// Packages to buy. Defaults to 1 on the server.
    public let quantity: Int?
    public let amount: Double?
    public let unit: String?

    public init(name: String, quantity: Int? = nil, amount: Double? = nil, unit: String? = nil) {
        self.name = name
        self.quantity = quantity
        self.amount = amount
        self.unit = unit
    }
}

public struct Recipe: Codable, Equatable {
    public let id: String
    public let title: String?
    public let ingredients: [RecipeIngredient]

    public init(id: String, title: String? = nil, ingredients: [RecipeIngredient]) {
        self.id = id
        self.title = title
        self.ingredients = ingredients
    }
}
