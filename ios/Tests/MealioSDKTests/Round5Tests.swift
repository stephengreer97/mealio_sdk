// 0.6 round 5: body checks that never recurse deeply, page messages with a
// depth limit, ICU patterns that read text as JS does, and the testing kit's
// strict script loader. Mirrors packages/core/test/round5.test.ts where the
// two meet.

import XCTest
@testable import MealioSDK

final class Round5Tests: XCTestCase {

    private static let mutation = #"{"query":"mutation { placeOrder { id } }"}"#
    private static let innocent = #"{"operationName":"cartItemsV2"}"#

    /// `inner` as a form-encoded `operations` field, `levels` deep.
    private func nested(_ inner: String, levels: Int) -> String {
        String(repeating: "operations=", count: levels) + inner
    }

    /// The same, inside one raw multipart `operations` part (one more level).
    /// Raw multipart parts cannot nest in each other: a part's value ends at
    /// the first line starting `--`, which is the next part's boundary.
    private func multipart(_ inner: String, levels: Int) -> String {
        "--b\r\nContent-Disposition: form-data; name=\"operations\"\r\n\r\n" + nested(inner, levels: levels - 1) + "\r\n--b--"
    }

    // MARK: item 2: body checks never crash and never recurse deeply

    func testAnOperationsFieldNestedPastEightLevelsIsBlocked() {
        let wraps: [(String, Int) -> String] = [self.nested(_:levels:), self.multipart(_:levels:)]
        for wrap in wraps {
            XCTAssertFalse(Allowlist.bodyBlocked(wrap(Round5Tests.innocent, Allowlist.bodyMaxDepth)))
            XCTAssertTrue(Allowlist.bodyBlocked(wrap(Round5Tests.innocent, Allowlist.bodyMaxDepth + 1)))
            XCTAssertTrue(Allowlist.bodyBlocked(wrap(Round5Tests.mutation, 3)))
            // Far deeper ends at once instead of recursing on.
            XCTAssertTrue(Allowlist.bodyBlocked(wrap(Round5Tests.innocent, 2000)))
        }
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
            XCTAssertNoThrow(try JSONValue.object(msg).jsonData(), what)
            // Inside a step body it is four levels deeper still, and is sent whole.
            let step = StepRequest(seq: 1, results: [InstructionResult(id: "i1", ok: true, ms: 5, messages: [msg])])
            let sent = try JSONWriter().data(step.jsonNode)
            let back = try XCTUnwrap(JSONValue.parse(sent), what)
            let echoed = try XCTUnwrap(back["results"]?.arrayValue?.first?["messages"]?.arrayValue?.first, what)
            XCTAssertEqual(echoed, .object(msg), what)
        }
    }

    // MARK: JSONWriter writes what JSONEncoder writes, at any depth

    private func encoder(sorted: Bool, slashes: Bool) -> JSONEncoder {
        let e = JSONEncoder()
        var f: JSONEncoder.OutputFormatting = []
        if sorted { f.insert(.sortedKeys) }
        if !slashes { f.insert(.withoutEscapingSlashes) }
        e.outputFormatting = f
        return e
    }

    private static let ordinary: [JSONValue] = {
        var list: [JSONValue] = [
            .null, true, false, 0, 1, -1, 42, .int(Int.max), .int(Int.min), .int(9_007_199_254_740_993),
            0.5, -0.5, 1.5, 0.1, 0.2, .double(1.0 / 3.0), 100.0, -100.0, 1e15, 1e16, 1e17, 1e21, 1e22, 1.5e300, 1e-5, 1e-7, 5e-324,
            .double(-0.0), .double(0.0), .double(Double.greatestFiniteMagnitude), .double(-Double.leastNormalMagnitude),
            .double(123456789.125), .double(9_007_199_254_740_993.0),
            "", "plain", "quote \" backslash \\ slash / end", "</script>", "http://a.b/c?d=e&f",
            "tab\tnew\nret\rback\u{08}feed\u{0C}", "nul \u{00} one \u{01} us \u{1F} del \u{7F}", "\u{0B}\u{0E}\u{10}\u{1A}",
            "caf\u{E9} \u{4E2D}\u{6587} \u{1F600} \u{2028}\u{2029} \u{FEFF} \u{200B}", "e\u{301}",
        ]
        for c in 0..<0x20 { list.append(.string(String(Character(Unicode.Scalar(UInt8(c)))))) }
        list.append([])
        list.append([:])
        list.append([1, 2.5, "x", nil, true, [], [:], [[["deep"]]]])
        list.append(["a": 1, "b": [1, 2, ["c": "d/e"]], "c": ["x": nil, "y": [:], "z": []], "d": -0.0, "e": "\u{1F600}"])
        list.append(["k": ["k": ["k": ["k": ["k": "v"]]]]])
        list.append(["b": 1, "a": 2, "B": 3, "A": 4, "a1": 5, "a10": 6, "a2": 7, "_": 8, "z": 9, "": 11])
        list.append(["type": "X", "items": [["id": "p1", "price": 3.99, "qty": 2], ["id": "p/2", "price": 0.5, "qty": 1]]])
        return list
    }()

    func testJSONWriterMatchesJSONEncoderOnOrdinaryValues() throws {
        for v in Round5Tests.ordinary {
            for sorted in [true, false] {
                for slashes in [true, false] {
                    // Unsorted, only an object of one key has a single order.
                    if !sorted, case .object(let o) = v, o.count > 1 { continue }
                    let want = try encoder(sorted: sorted, slashes: slashes).encode(v)
                    let got = try JSONWriter(sortedKeys: sorted, escapeSlashes: slashes).data(v)
                    XCTAssertEqual(String(decoding: got, as: UTF8.self), String(decoding: want, as: UTF8.self),
                                   "sorted \(sorted) slashes \(slashes)")
                }
            }
        }
        // The default is the client's: unsorted, slashes left alone.
        XCTAssertEqual(try JSONValue.string("a/b").jsonData(), Data(#""a/b""#.utf8))
    }

    func testJSONWriterRefusesWhatJSONEncoderRefuses() {
        for d in [Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertThrowsError(try JSONEncoder().encode(JSONValue.double(d)))
            XCTAssertThrowsError(try JSONValue.double(d).jsonData())
            XCTAssertThrowsError(try JSONValue.array([["x": .double(d)]]).jsonData())
        }
    }

    func testAStepBodyIsWrittenAsJSONEncoderWritesIt() throws {
        let full = InstructionResult(id: "i1", ok: false, ms: 12, skipped: false, error: "bad / thing", finalUrl: "https://x.test/a",
                                     messages: [["type": "A", "n": 1.25], ["type": "B", "list": [1, "two", nil]]],
                                     timedOut: true, outcome: .signedIn, status: 200, headers: ["content-type": "text/html", "x-a": "1"],
                                     body: "{\"a\":\"\u{01}\"}", truncated: true)
        let bare = InstructionResult(id: "i2", ok: true, ms: 0)
        let step = StepRequest(seq: 7, results: [full, bare])
        for slashes in [true, false] {
            let want = try encoder(sorted: true, slashes: slashes).encode(step)
            let got = try JSONWriter(sortedKeys: true, escapeSlashes: slashes).data(step.jsonNode)
            XCTAssertEqual(String(decoding: got, as: UTF8.self), String(decoding: want, as: UTF8.self))
        }
        // Unsorted, the fields come in declared order and nil ones are left out.
        XCTAssertEqual(String(decoding: try JSONWriter().data(StepRequest(seq: 2, results: [bare]).jsonNode), as: UTF8.self),
                       #"{"seq":2,"results":[{"id":"i2","ok":true,"ms":0}]}"#)
    }

    func testAMessage513DeepInsideAStepBodyIsWritten() throws {
        let n = 512
        let raw = #"{"type":"X","a":"# + String(repeating: "[", count: n) + String(repeating: "]", count: n) + #","keep":1}"#
        let msg = try XCTUnwrap(parseMessage(raw))
        XCTAssertEqual(depthOf(.object(msg)), 513)
        // Foundation's writer stops at 512, which is why the SDK has its own.
        XCTAssertThrowsError(try JSONEncoder().encode(StepRequest(seq: 1, results: [InstructionResult(id: "i", ok: true, ms: 1, messages: [msg])])))
        let step = StepRequest(seq: 1, results: [InstructionResult(id: "i", ok: true, ms: 1, messages: [msg])])
        let text = String(decoding: try JSONWriter().data(step.jsonNode), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix(#"{"seq":1,"results":[{"id":"i","ok":true,"ms":1,"messages":[{"#), text.prefix(80).description)
        let back = try XCTUnwrap(JSONValue.parse(text))
        XCTAssertEqual(depthOf(back), 517)
        // Far deeper still writes, without recursion. (Kept to a depth whose
        // release, which is recursive, fits the test thread's stack.)
        var deep: JSONValue = "end"
        for _ in 0..<5_000 { deep = .array([deep]) }
        let big = try deep.jsonData()
        XCTAssertEqual(big.count, 5_000 * 2 + 5)
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
