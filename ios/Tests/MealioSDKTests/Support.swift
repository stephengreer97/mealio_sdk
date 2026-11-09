// Shared test helpers: fixtures, a fake Host, a test signer and an HTTP stub.

import CryptoKit
import Foundation
import XCTest
@testable import MealioSDK

enum Fixtures {
    static func data(_ name: String, _ ext: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext), "missing fixture \(name).\(ext)")
        return try Data(contentsOf: url)
    }

    static func text(_ name: String, _ ext: String) throws -> String {
        try XCTUnwrap(String(data: try data(name, ext), encoding: .utf8))
    }

    /// protocol/test-vectors.json, shared with the TS, Kotlin and Dart suites.
    static func vectors() throws -> JSONValue {
        try XCTUnwrap(JSONValue.parse(try data("test-vectors", "json")))
    }

    /// protocol/strings.json, the table every SDK carries.
    static func strings() throws -> [String: JSONValue] {
        try XCTUnwrap(JSONValue.parse(try data("strings", "json"))?.objectValue)
    }

    /// The test key, as the vectors name it ("ktest").
    static func keys(_ vectors: JSONValue) throws -> [String: String] {
        let kid = try XCTUnwrap(vectors["kid"]?.stringValue)
        let publicKey = try XCTUnwrap(vectors["publicKey"]?.stringValue)
        return [kid: publicKey]
    }
}

/// Signs payloads with the same deterministic TEST key that made the vectors
/// (protocol/make-vectors.mjs: a seed of 32 bytes of 7). Lets tests build
/// envelopes the shared vectors do not cover.
enum TestSigner {
    static let privateKey: Curve25519.Signing.PrivateKey = {
        // rawRepresentation of an Ed25519 private key is its 32-byte seed.
        try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
    }()

    static var publicKeyBase64: String { privateKey.publicKey.rawRepresentation.base64EncodedString() }
    static var keys: [String: String] { ["ktest": publicKeyBase64] }

    static func envelope(_ payload: String) -> Envelope {
        let sig = try! privateKey.signature(for: Data(payload.utf8))
        return Envelope(payload: payload, sig: sig.base64EncodedString(), kid: "ktest")
    }

    static func payload(seq: Int, instructions: [JSONValue], job: String = "job_test", store: String = "heb",
                        exp: Int = 4_102_444_800, v: Int = 1, kind: String = "instructions") -> String {
        let obj: JSONValue = [
            "v": .int(v), "kind": .string(kind), "job": .string(job), "seq": .int(seq),
            "exp": .int(exp), "store": .string(store), "instructions": .array(instructions),
        ]
        return json(obj)
    }

    static func json(_ v: JSONValue) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return String(data: try! enc.encode(v), encoding: .utf8)!
    }
}

/// Records every call and answers like the TS test's fakeHost.
@MainActor
final class FakeHost: MealioHost {
    var calls: [String] = []
    var lastLogin: LoginRequest?
    /// The guard handed with the last page_script.
    var lastScriptGuard: String?

    func openPage(store: String, url: String, timeoutMs: Int) async throws -> PageOpenOutcome {
        calls.append("open \(url)")
        return PageOpenOutcome(ok: true, finalUrl: url)
    }

    func runScript(store: String, guardScript: String, script: String, until: [Matcher], timeoutMs: Int) async throws -> ScriptOutcome {
        lastScriptGuard = guardScript
        calls.append("script")
        return ScriptOutcome(messages: [["type": .string(until.first?.type ?? "X"), "loggedIn": true]], timedOut: false)
    }

    func showLogin(_ request: LoginRequest) async throws -> LoginOutcome {
        calls.append("login")
        lastLogin = request
        return LoginOutcome(outcome: .signedIn, messages: [])
    }

    func fetch(store: String, request: FetchRequest, timeoutMs: Int, maxBytes: Int) async throws -> FetchOutcome {
        calls.append("fetch")
        return FetchOutcome(ok: true, status: 200, body: "{}")
    }
}

/// What the stub server saw. Written from URLSession's thread.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _paths: [String] = []
    private var _requests: [URLRequest] = []
    private var _bodies: [String: JSONValue] = [:]

    func record(_ request: URLRequest, body: Data?) {
        lock.lock(); defer { lock.unlock() }
        let path = request.url?.path ?? ""
        _paths.append(path)
        _requests.append(request)
        if let body = body, let json = JSONValue.parse(body) { _bodies[path] = json }
    }

    var paths: [String] { lock.lock(); defer { lock.unlock() }; return _paths }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    func body(_ path: String) -> JSONValue? { lock.lock(); defer { lock.unlock() }; return _bodies[path] }
}

/// A URLProtocol that answers every request from `handler`.
final class StubURLProtocol: URLProtocol {
    /// (request, body) -> (status, response body)
    static var handler: ((URLRequest, Data?) -> (Int, Data))?
    /// True: no request is ever answered, as a server that never replies.
    static var hangs = false

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if StubURLProtocol.hangs { return }
        // URLSession moves httpBody into a stream before it reaches a URLProtocol.
        let body = request.httpBody ?? StubURLProtocol.read(request.httpBodyStream)
        let (status, data) = StubURLProtocol.handler?(request, body) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

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

func jsonData(_ v: JSONValue) -> Data {
    try! JSONEncoder().encode(v)
}
