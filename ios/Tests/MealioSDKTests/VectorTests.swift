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

    func testBlockedBodyCases() throws {
        let v = try Fixtures.vectors()
        let cases = try XCTUnwrap(v["blockedBodies"]?.arrayValue)
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let body = try XCTUnwrap(c["body"]?.stringValue)
            let blocked = try XCTUnwrap(c["blocked"]?.boolValue)
            XCTAssertEqual(Allowlist.bodyBlocked(body), blocked, body)
        }
        XCTAssertFalse(Allowlist.bodyBlocked(nil))
    }

    func testParseUrlTakesOnlyPlainHostNames() throws {
        XCTAssertNil(Allowlist.parseUrl("https://www.heb.com:x@evil.com/"))
        XCTAssertNil(Allowlist.parseUrl(#"https://evil.com\.heb.com/"#))
        let a = try XCTUnwrap(Allowlist.parseUrl("https://www.heb.com:443/a?b=1#c"))
        XCTAssertEqual(a.scheme, "https")
        XCTAssertEqual(a.host, "www.heb.com")
        XCTAssertEqual(a.rest, "/a?b=1")
        let b = try XCTUnwrap(Allowlist.parseUrl("https://www.heb.com"))
        XCTAssertEqual(b.host, "www.heb.com")
        XCTAssertEqual(b.rest, "/")
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

    /// The per-script copy is the document-start copy plus the arm call
    /// (GUARD_ARM_SCRIPT = GUARD_SCRIPT + "\n" + GUARD_ARM).
    func testGuardArmScriptIsTheGuardThenTheArmCall() throws {
        XCTAssertEqual(MealioScripts.guardArm, try Fixtures.text("guard-arm", "js"))
        XCTAssertEqual(MealioScripts.guardArmScript, MealioScripts.guardScript + "\n" + MealioScripts.guardArm)
    }

    func testTheGuardJudgesRawMultipartWithTheSamePatternAsBodyBlocked() {
        XCTAssertTrue(MealioScripts.guardScript.contains("  var PART = " + MealioScripts.jsStringLiteral(Allowlist.multipartField) + ";\n"))
    }

    func testABodyWithOnlyAByteOrderMarkIsNotBlocked() {
        XCTAssertFalse(Allowlist.bodyBlocked("\u{FEFF}"))
        XCTAssertTrue(Allowlist.bodyBlocked("\u{FEFF}{\"query\":\"mutation { placeOrder { id } }\"}"))
    }

    // MARK: round 4: JSON as JSON.parse reads it, multipart names in any quotes

    func testJudgesTheJSONStrictnessVectorsAsJSONParseReadsThem() throws {
        let list = try XCTUnwrap(try Fixtures.vectors()["jsonBodies"]?.arrayValue)
        XCTAssertEqual(Set(list.compactMap { $0["rule"]?.stringValue }), ["depth", "hex", "surrogate"])
        for v in list {
            let body = try XCTUnwrap(v["body"]?.stringValue)
            let rule = v["rule"]?.stringValue ?? ""
            XCTAssertEqual(Allowlist.bodyBlocked(body), try XCTUnwrap(v["blocked"]?.boolValue), "\(rule): \(body.prefix(60))")
        }
    }

    func testReadsAMultipartPartWhateverQuotesItsNameHas() {
        func part(_ name: String, _ value: String) -> String {
            "--b\r\nContent-Disposition: form-data; name=\(name)\r\n\r\n\(value)\r\n--b--"
        }
        let m = #"{"query":"mutation { placeOrder { id } }"}"#
        for q in ["\"", "'", ""] {
            XCTAssertTrue(Allowlist.bodyBlocked(part("\(q)operations\(q)", m)), q)
            XCTAssertTrue(Allowlist.bodyBlocked(part("\(q)query\(q)", "mutation { placeOrder { id } }")), q)
            XCTAssertTrue(Allowlist.bodyBlocked(part("\(q)operationName\(q)", "PlaceOrder")), q)
            XCTAssertFalse(Allowlist.bodyBlocked(part("\(q)operationsX\(q)", m)), q)
        }
    }

    func testJSONValueParseAcceptsExactlyWhatJSONParseAccepts() {
        // Nesting far past Foundation's 512 levels.
        let deep = String(repeating: "[", count: 3000) + String(repeating: "]", count: 3000)
        XCTAssertNotNil(JSONValue.parse(deep))
        // A lone or reversed surrogate is JSON; Swift holds it as U+FFFD.
        XCTAssertEqual(JSONValue.parse(#""a\ud800z""#), .string("a\u{FFFD}z"))
        XCTAssertEqual(JSONValue.parse(#""\udc00\ud800""#), .string("\u{FFFD}\u{FFFD}"))
        XCTAssertEqual(JSONValue.parse(#""\ud83d\ude00""#), .string("\u{1F600}"))
        XCTAssertEqual(JSONValue.parse(#""\u004F\u004f""#), .string("OO"))
        // \u takes four ASCII hex digits only.
        XCTAssertNil(JSONValue.parse("\"\\u\u{0660}\u{0660}4F\""))
        XCTAssertNil(JSONValue.parse("\"\\u\u{FF10}\u{FF10}4F\""))
        XCTAssertNil(JSONValue.parse(#""\u04F""#))
        // What JSON.parse refuses.
        for bad in ["", " ", "[1,]", "{\"a\":1,}", "01", "1.", ".5", "+1", "-", "1e", "'a'", "\"\t\"", "[1]x",
                    "\u{FEFF}{}", "{\u{A0}}", "NaN", "Infinity", "tru", "nul", "{a:1}", "\"\\x41\"", "[1 2]"] {
            XCTAssertNil(JSONValue.parse(bad), bad)
        }
        // What it accepts.
        XCTAssertEqual(JSONValue.parse(" \t\r\n{\"a\":1,\"a\":2} "), ["a": 2])
        XCTAssertEqual(JSONValue.parse("-0"), .int(0))
        XCTAssertEqual(JSONValue.parse("2.0"), .int(2))
        XCTAssertEqual(JSONValue.parse("1e400"), .double(.infinity))
        XCTAssertEqual(JSONValue.parse(#""\/\b\f\n\r\t\"\\""#), .string("/\u{08}\u{0C}\n\r\t\"\\"))
        // Bytes as a fetch Response's json() reads them: a UTF-8 BOM is dropped.
        XCTAssertEqual(JSONValue.parse(Data([0xEF, 0xBB, 0xBF]) + Data("[1]".utf8)), [1])
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
