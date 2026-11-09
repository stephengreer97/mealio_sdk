// 0.6 round 5: body checks that never recurse deeply, page messages with a
// depth limit, ICU patterns that read text as JS does, and the testing kit's
// strict script loader. Mirrors packages/core/test/round5.test.ts where the
// two meet.

import XCTest
@testable import MealioSDK

final class Round5Tests: XCTestCase {

    private static let mutation = #"{"query":"mutation { placeOrder { id } }"}"#
    private static let innocent = #"{"operationName":"cartItemsV2"}"#

    /// `inner` as the `operations` part of a raw multipart body, `levels` deep.
    private func nested(_ inner: String, levels: Int) -> String {
        var s = inner
        for _ in 0..<levels {
            s = "--b\r\nContent-Disposition: form-data; name=\"operations\"\r\n\r\n" + s
        }
        return s + "\r\n--b--"
    }

    // MARK: item 2: body checks never crash and never recurse deeply

    func testAnOperationsFieldNestedPastEightLevelsIsBlocked() {
        XCTAssertFalse(Allowlist.bodyBlocked(nested(Round5Tests.innocent, levels: Allowlist.bodyMaxDepth)))
        XCTAssertTrue(Allowlist.bodyBlocked(nested(Round5Tests.innocent, levels: Allowlist.bodyMaxDepth + 1)))
        XCTAssertTrue(Allowlist.bodyBlocked(nested(Round5Tests.mutation, levels: 3)))
        // Far deeper ends at once instead of recursing on.
        XCTAssertTrue(Allowlist.bodyBlocked(nested(Round5Tests.innocent, levels: 2000)))
    }

    func testABodyOverOneMegabyteIsBlockedUnread() {
        let big = String(repeating: "a", count: Allowlist.bodyMaxText + 1)
        XCTAssertTrue(Allowlist.bodyBlocked(big))
        XCTAssertFalse(Allowlist.bodyBlocked(String(repeating: "a", count: Allowlist.bodyMaxText)))
        // The byte order mark is dropped before the length is taken.
        XCTAssertFalse(Allowlist.bodyBlocked("\u{FEFF}" + String(repeating: "a", count: Allowlist.bodyMaxText)))
    }

    func testTheGuardCarriesTheSameCaps() {
        XCTAssertTrue(MealioScripts.guardScript.contains(
            "  var MAX_DEPTH = \(Allowlist.bodyMaxDepth), MAX_TEXT = \(Allowlist.bodyMaxText);\n"))
    }

    // MARK: item 3: page messages are parsed with a depth limit of 512

    func testAMessageNestedFarPast512LevelsIsReadWithItsDeepPartEmpty() throws {
        let n = 100_000
        let text = #"{"type":"DEEP","a":"# + String(repeating: "[", count: n) + String(repeating: "]", count: n) + "}"
        let msg = try XCTUnwrap(parseMessage(text))
        XCTAssertEqual(msg["type"], "DEEP")
        var depth = 0
        var v = msg["a"]
        while let a = v?.arrayValue {
            depth += 1
            v = a.first
        }
        // The message object is level 1; containers past level 512 are kept empty.
        XCTAssertEqual(depth, 512)
        // Not JSON is still not a message, however deep.
        XCTAssertNil(parseMessage(String(repeating: "[", count: n)))
    }

    func testAWideArrayIsReadInLinearTime() throws {
        let n = 200_000
        let text = "[" + Array(repeating: "1", count: n).joined(separator: ",") + "]"
        let start = Date()
        let v = try XCTUnwrap(StrictJSON.parse(text))
        XCTAssertEqual(v.arrayValue?.count, n)
        let o = try XCTUnwrap(StrictJSON.parse("{" + (0..<50_000).map { "\"k\($0)\":\($0)" }.joined(separator: ",") + "}"))
        XCTAssertEqual(o.objectValue?.count, 50_000)
        // A copy per append took minutes here; in place it is well under this.
        XCTAssertLessThan(Date().timeIntervalSince(start), 20)
    }

    // MARK: item 4: ICU patterns read text as JS does

    func testOperationNameAcceptsJSWhitespaceBetweenItsParts() {
        // \v and U+FEFF are JS \s; ICU's \s needs them added.
        XCTAssertTrue(Allowlist.bodyBlocked("x \"operationName\"\u{0B}:\u{FEFF}\"PlaceOrder\""))
        XCTAssertTrue(Allowlist.bodyBlocked("x \"operationName\"\u{FEFF}: \"PlaceOrder\""))
    }

    func testAStringEscapeOfAnyCharacterButALineEndIsStripped() throws {
        // JS `\\.` takes \ followed by \v, \f or U+0085 as one escape, so the
        // string ends at the next quote and the second mutation is inside it.
        for c in ["\u{0B}", "\u{0C}", "\u{85}"] {
            let q = "mutation { ok } \"\\\(c) mutation { placeOrder }\""
            let body = try XCTUnwrap(String(data: try JSONEncoder().encode(["query": q]), encoding: .utf8))
            XCTAssertFalse(Allowlist.bodyBlocked(body), "escape of U+\(String(c.unicodeScalars.first!.value, radix: 16))")
        }
    }

    func testAMultipartNameEndsAtJSWhitespace() {
        for ws in ["\u{0B}", "\u{FEFF}"] {
            let body = "--b\r\nContent-Disposition: form-data; name=operations\(ws)\r\n\r\n" + Round5Tests.mutation + "\r\n--b--"
            XCTAssertTrue(Allowlist.bodyBlocked(body))
        }
    }

    // MARK: item 6: the testing kit's loader is strict at every level

    func testTheFakeScriptLoaderRefusesUnknownFieldsAndWrongTypesNamingTheField() {
        func refusal(_ json: String) -> String? {
            do {
                _ = try FakeMealio(json: json)
                return nil
            } catch let e as MealioError {
                return e.message
            } catch {
                return "\(error)"
            }
        }
        XCTAssertNil(refusal(#"{"store":"heb","warm":{},"items":[{"key":"k","quantity":2,"options":[{"id":"p","name":"P","unitPrice":1.5}]}]}"#))
        XCTAssertNil(refusal(#"{"warm":null,"signIn":null,"errors":{"search":{"code":"network","status":503}}}"#))
        XCTAssertEqual(refusal(#"{"stor":"heb"}"#), "The fake Mealio script: script.stor is not a known field")
        XCTAssertEqual(refusal(#"{"items":[{"key":"k","options":[{"id":"p","name":"P","colour":"red"}]}]}"#),
                       "The fake Mealio script: script.items[0].options[0].colour is not a known field")
        XCTAssertEqual(refusal(#"{"items":[{"key":"k","quantity":1.5}]}"#),
                       "The fake Mealio script: script.items[0].quantity must be a whole number")
        XCTAssertEqual(refusal(#"{"items":[{"quantity":1}]}"#), "The fake Mealio script: script.items[0].key is required")
        XCTAssertEqual(refusal(#"{"warm":{"signedIn":"yes"}}"#),
                       "The fake Mealio script: script.warm.signedIn must be true, false or null")
        XCTAssertEqual(refusal(#"{"signIn":"maybe"}"#),
                       "The fake Mealio script: script.signIn must be one of signed_in, cancelled, timeout, not \"maybe\"")
        XCTAssertEqual(refusal(#"{"errors":{"checkout":"x"}}"#), "The fake Mealio script: script.errors.checkout is not a known field")
        XCTAssertEqual(refusal(#"{"store":"heb"} x"#), "The fake Mealio script is not JSON")
        XCTAssertEqual(refusal("[]"), "The fake Mealio script must be a JSON object")
    }

    // MARK: the shared round 5 vectors (round5.test.ts)

    func testTheLimitsAreTheProtocols() throws {
        XCTAssertEqual(Allowlist.bodyMaxDepth, 8)
        XCTAssertEqual(Allowlist.bodyMaxText, 1_048_576)
        XCTAssertEqual(messageDepth, 512)
        let limits = try XCTUnwrap(try Fixtures.vectors()["bodyLimits"]?.arrayValue)
        XCTAssertEqual(Set(limits.compactMap { $0["rule"]?.stringValue }), ["depth", "size"])
    }

    func testBodyBlockedFollowsEveryBodyLimitsVectorQuicklyAndWithoutDeepRecursion() throws {
        let limits = try XCTUnwrap(try Fixtures.vectors()["bodyLimits"]?.arrayValue)
        for v in limits {
            let fill = try XCTUnwrap(v["fill"]?.stringValue)
            let times = try XCTUnwrap(v["times"]?.intValue)
            let suffix = try XCTUnwrap(v["suffix"]?.stringValue)
            let body = try XCTUnwrap(v["prefix"]?.stringValue) + String(repeating: fill, count: times) + suffix
            let what = "\(v["rule"]?.stringValue ?? "?") \(times)x \(fill) \(suffix.prefix(30))"
            let start = Date()
            XCTAssertEqual(Allowlist.bodyBlocked(body), try XCTUnwrap(v["blocked"]?.boolValue), what)
            // TS allows 2 s; a debug build on CI gets more.
            XCTAssertLessThan(Date().timeIntervalSince(start), 10, what)
        }
    }

    /// Nesting depth of a parsed value, without recursion (an empty container is one level).
    private func depthOf(_ v: JSONValue) -> Int {
        var most = 0
        var stack: [(JSONValue, Int)] = [(v, 1)]
        while let top = stack.popLast() {
            let (x, d) = top
            switch x {
            case .array(let a):
                most = max(most, d)
                for c in a { stack.append((c, d + 1)) }
            case .object(let o):
                most = max(most, d)
                for c in o.values { stack.append((c, d + 1)) }
            default:
                continue
            }
        }
        return most
    }

    func testParseMessageKeepsATooDeepContainerEmptyAndTheMessageStaysUsable() throws {
        let deep = try XCTUnwrap(try Fixtures.vectors()["deepMessages"]?.arrayValue)
        XCTAssertFalse(deep.isEmpty)
        for v in deep {
            let open = try XCTUnwrap(v["open"]?.stringValue)
            let close = try XCTUnwrap(v["close"]?.stringValue)
            let times = try XCTUnwrap(v["times"]?.intValue)
            let raw = try XCTUnwrap(v["prefix"]?.stringValue) + String(repeating: open, count: times)
                + String(repeating: close, count: times) + (try XCTUnwrap(v["suffix"]?.stringValue))
            let what = "\(open)x\(times)"
            let msg = try XCTUnwrap(parseMessage(raw), what)
            XCTAssertEqual(depthOf(.object(msg)), try XCTUnwrap(v["depth"]?.intValue), what)
            XCTAssertEqual(msg["keep"], v["keep"], what)
            // What the runner does with it next: match it, and send it to the server.
            XCTAssertTrue(matches(msg, Matcher(type: "X", eq: ["keep": 1])), what)
            XCTAssertNoThrow(try JSONEncoder().encode(JSONValue.object(msg)), what)
        }
    }

    func testIsJSONParseForAnythingNotTooDeepStringsWithBracketsInThemIncluded() {
        XCTAssertEqual(JSONValue.parse(#"{"a":"[[{{\"]]"}"#, keep: messageDepth), ["a": "[[{{\"]]"])
        XCTAssertEqual(JSONValue.parse(#"[1,{"b":[2,"}"]}]"#, keep: messageDepth), [1, ["b": [2, "}"]]])
        for bad in ["{", "[1,", #"{"a":}"#, "[" + String(repeating: "[", count: 600) + String(repeating: "]", count: 599)] {
            XCTAssertNil(JSONValue.parse(bad, keep: messageDepth), bad)
        }
        // Not an object.
        XCTAssertNil(parseMessage("[" + String(repeating: "[", count: 600) + String(repeating: "]", count: 600) + "]"))
    }

    // MARK: which guard copy a host gets

    func testGuardArmScriptIsGuardScriptThenTheArmCall() {
        XCTAssertEqual(MealioScripts.guardArm, "window.__mealioArm(); true;")
        XCTAssertEqual(MealioScripts.guardArmScript, MealioScripts.guardScript + "\n" + MealioScripts.guardArm)
    }

    @MainActor
    func testPageScriptGetsTheArmingCopyShowLoginGetsTheDocumentStartCopyAndTheArmingCopy() async throws {
        let host = FakeHost()
        let runner = Runner(host: host, allowlist: Allowlist(), keys: TestSigner.keys)
        let check: JSONValue = ["script": "true;", "intervalMs": 3000]
        let payload = TestSigner.payload(seq: 1, instructions: [
            ["op": "page_script", "id": "i1", "script": "true;", "until": [], "timeoutMs": 1000],
            ["op": "show_login", "id": "i2", "url": "https://www.heb.com/login", "title": "Sign in", "check": check,
             "doneWhen": [], "timeoutMs": 1000],
        ])
        _ = try await runner.run(TestSigner.envelope(payload), job: "job_test", lastSeq: 0)
        XCTAssertEqual(host.lastScriptGuard, MealioScripts.guardArmScript)
        XCTAssertEqual(host.lastLogin?.guardScript, MealioScripts.guardScript)
        XCTAssertEqual(host.lastLogin?.armGuardScript, MealioScripts.guardArmScript)
    }

    func testTheDocumentStartUserScriptIsTheUnarmedCopy() {
        XCTAssertFalse(MealioScripts.guardScript.contains(MealioScripts.guardArm))
    }
}
