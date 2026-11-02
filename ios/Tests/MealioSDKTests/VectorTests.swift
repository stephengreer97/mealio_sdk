// The shared protocol vectors. Every case must get the same answer here as in
// packages/core/test/core.test.ts.

import XCTest
@testable import MealioSDK

final class VectorTests: XCTestCase {

    @MainActor
    func testSignedCases() async throws {
        let v = try Fixtures.vectors()
        let keys = try Fixtures.keys(v)
        let cases = try XCTUnwrap(v["cases"]?.arrayValue)
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let name = c["name"]?.stringValue ?? "?"
            let env = Envelope(json: c["envelope"])
            let job = c["job"]?.stringValue
            let lastSeq = c["lastSeq"]?.intValue ?? 0
            let expect = try XCTUnwrap(c["expect"]?.stringValue, name)
            let runner = Runner(host: FakeHost(), allowlist: Allowlist(), keys: keys)

            if expect == "ok" {
                let out = try await runner.run(env, job: job, lastSeq: lastSeq)
                if let firstError = c["firstResultError"]?.stringValue {
                    XCTAssertEqual(out.results.first?.error, firstError, name)
                } else {
                    XCTAssertTrue(out.results.allSatisfy { $0.ok } || out.terminal != nil, name)
                }
            } else {
                do {
                    _ = try await runner.run(env, job: job, lastSeq: lastSeq)
                    XCTFail("\(name): expected refusal \(expect)")
                } catch let e as EnvelopeError {
                    XCTAssertEqual(e.why, expect, name)
                }
            }
        }
    }

    func testAllowlistCases() throws {
        let v = try Fixtures.vectors()
        let a = Allowlist()
        let cases = try XCTUnwrap(v["allowlist"]?.arrayValue)
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let store = try XCTUnwrap(c["store"]?.stringValue)
            let url = try XCTUnwrap(c["url"]?.stringValue)
            let use = try XCTUnwrap(UrlUse(rawValue: try XCTUnwrap(c["use"]?.stringValue)))
            let ok = try XCTUnwrap(c["ok"]?.boolValue)
            XCTAssertEqual(a.check(store, url, use).ok, ok, "\(store) \(url) \(use)")
        }
    }

    func testMatcherCases() throws {
        let v = try Fixtures.vectors()
        let cases = try XCTUnwrap(v["matchers"]?.arrayValue)
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let msg = try XCTUnwrap(c["msg"]?.objectValue)
            let m = try XCTUnwrap(Matcher(json: try XCTUnwrap(c["m"])))
            XCTAssertEqual(matches(msg, m), try XCTUnwrap(c["ok"]?.boolValue), "\(msg) \(m)")
        }
    }

    @MainActor
    func testDoneCarriesUnicodeResultIntact() async throws {
        let v = try Fixtures.vectors()
        let c = try XCTUnwrap(v["cases"]?.arrayValue?.first { $0["name"]?.stringValue == "valid_unicode_done" })
        let out = try await Runner(host: FakeHost(), allowlist: Allowlist(), keys: try Fixtures.keys(v))
            .run(Envelope(json: c["envelope"]), job: "job_test", lastSeq: 1)
        XCTAssertEqual(out.terminal, .done(["hello": "café ✓"]))
    }

    func testRefusesTheProductionKeyForTestEnvelopes() throws {
        let v = try Fixtures.vectors()
        let c = try XCTUnwrap(v["cases"]?.arrayValue?.first)
        XCTAssertThrowsError(try openEnvelope(Envelope(json: c["envelope"]))) { error in
            XCTAssertEqual((error as? EnvelopeError)?.why, "unknown_kid")
        }
    }

    func testTestSignerMatchesTheVectorKey() throws {
        let v = try Fixtures.vectors()
        XCTAssertEqual(TestSigner.publicKeyBase64, v["publicKey"]?.stringValue)
    }

    // MARK: guard and shim text

    func testGuardScriptMatchesTheReferenceByteForByte() throws {
        XCTAssertEqual(MealioScripts.guardScript, try Fixtures.text("guard-script", "js"))
    }

    func testBridgeShimMatchesTheReferenceByteForByte() throws {
        XCTAssertEqual(MealioScripts.bridgeShim, try Fixtures.text("bridge-shim", "js"))
    }

    // MARK: allowlist widening (same as the TS "allowlist widening" test)

    func testWideningAddsOnlyHostsOnAKnownRegistrableDomain() {
        let a = Allowlist()
        a.widen(AllowlistPayload(v: 1, exp: 0, stores: [
            "heb": .init(hosts: ["api.heb.com", "heb-cdn.net"]),
            "nope": .init(hosts: ["x.com"]),
        ]))
        XCTAssertTrue(a.hostsFor("heb")!.hosts.contains("api.heb.com"))
        XCTAssertFalse(a.hostsFor("heb")!.hosts.contains("heb-cdn.net"))
        XCTAssertNil(a.hostsFor("nope"))
        XCTAssertFalse(a.check("heb", "https://www.heb.com/checkout", .page).ok)
    }

    func testRegistrableDomain() {
        XCTAssertEqual(Allowlist.registrableDomain("www.heb.com"), "heb.com")
        XCTAssertEqual(Allowlist.registrableDomain("shop.tesco.co.uk"), "tesco.co.uk")
        XCTAssertEqual(Allowlist.registrableDomain("heb.com"), "heb.com")
        XCTAssertEqual(Allowlist.registrableDomain("HEB.COM."), "heb.com")
    }

    func testAllowlistReasons() {
        let a = Allowlist()
        XCTAssertEqual(a.check("heb", "not a url", .page), .refused(.badUrl))
        XCTAssertEqual(a.check("heb", "http://www.heb.com/", .page), .refused(.notHttps))
        XCTAssertEqual(a.check("heb", "https://evil.io/", .page), .refused(.host))
        XCTAssertEqual(a.check("heb", "https://www.heb.com/Account/Password", .page), .refused(.blockedPath))
        XCTAssertEqual(a.check("nostore", "https://www.heb.com/", .page), .refused(.unknownStore))
        XCTAssertEqual(a.check("heb", "https://www.heb.com:443", .page), .allowed)
        XCTAssertEqual(a.check("heb", "https://mealio.co/return", .login), .allowed)
        XCTAssertEqual(a.check("heb", "https://mealio.co/return", .fetch), .refused(.host))
    }

    // MARK: JSON and base64 basics

    func testJSONValueKeepsBoolsIntsAndDoublesApart() {
        XCTAssertEqual(JSONValue.parse("true"), .bool(true))
        XCTAssertEqual(JSONValue.parse("1"), .int(1))
        XCTAssertEqual(JSONValue.parse("1.5"), .double(1.5))
        XCTAssertEqual(JSONValue.parse("[0,false]"), .array([.int(0), .bool(false)]))
        XCTAssertTrue(JSONValue.int(1).jsEquals(.double(1.0)))
        XCTAssertFalse(JSONValue.int(1).jsEquals(.bool(true)))
        XCTAssertFalse(JSONValue.null.jsEquals(.bool(false)))
    }

    func testParseMessageDropsNonObjects() {
        XCTAssertNil(parseMessage("[1,2]"))
        XCTAssertNil(parseMessage("not json"))
        XCTAssertNil(parseMessage("5"))
        XCTAssertEqual(parseMessage(#"{"type":"X"}"#), ["type": "X"])
    }

    func testBase64AcceptsUrlSafeAndUnpadded() {
        let std = "AYOlGPRNr9JDsN2aKQ/WAVe0P2pUNTCzVM0C0uiuAdQ="
        let urlSafe = "AYOlGPRNr9JDsN2aKQ_WAVe0P2pUNTCzVM0C0uiuAdQ"
        XCTAssertEqual(base64ToBytes(std), Data(base64Encoded: std))
        XCTAssertEqual(base64ToBytes(urlSafe), Data(base64Encoded: std))
        XCTAssertEqual(base64ToBytes(std).count, 32)
    }
}
