// Runner semantics with a fake Host, using envelopes signed by the test key.

import XCTest
@testable import MealioSDK

final class RunnerTests: XCTestCase {

    private func pageOpen(_ id: String, _ url: String) -> JSONValue {
        ["op": "page_open", "id": .string(id), "url": .string(url), "timeoutMs": 1000]
    }

    private func fetch(_ id: String, _ url: String = "https://www.heb.com/api/search") -> JSONValue {
        ["op": "fetch", "id": .string(id), "request": ["method": "GET", "url": .string(url)], "timeoutMs": 1000, "maxBytes": 1000]
    }

    @MainActor
    private func refusal(_ payload: String, job: String? = "job_test", lastSeq: Int = 0) async -> String? {
        let runner = Runner(host: FakeHost(), allowlist: Allowlist(), keys: TestSigner.keys)
        do {
            _ = try await runner.run(TestSigner.envelope(payload), job: job, lastSeq: lastSeq)
            return nil
        } catch let e as EnvelopeError {
            return e.why
        } catch {
            return "other: \(error)"
        }
    }

    // Same as the TS "skips the rest of an envelope after a failure" test.
    @MainActor
    func testSkipsTheRestOfAnEnvelopeAfterAFailure() async throws {
        let v = try Fixtures.vectors()
        let c = try XCTUnwrap(v["cases"]?.arrayValue?.first { $0["name"]?.stringValue == "blocked_url_runs_but_refuses" })
        let host = FakeHost()
        let out = try await Runner(host: host, allowlist: Allowlist(), keys: try Fixtures.keys(v))
            .run(Envelope(json: c["envelope"]), job: "job_test", lastSeq: 0)
        XCTAssertEqual(out.results.count, 1)
        XCTAssertEqual(host.calls, [])
    }

    @MainActor
    func testSkippedResultsKeepTheirShape() async throws {
        let payload = TestSigner.payload(seq: 1, instructions: [
            pageOpen("i1", "https://www.heb.com/checkout/review"),
            pageOpen("i2", "https://www.heb.com/robots.txt"),
            ["op": "page_script", "id": "i3", "script": "true;", "until": [], "timeoutMs": 1000],
            ["op": "show_login", "id": "i4", "url": "https://www.heb.com/login", "title": "Sign in", "doneWhen": [], "timeoutMs": 1000],
        ])
        let host = FakeHost()
        let out = try await Runner(host: host, allowlist: Allowlist(), keys: TestSigner.keys)
            .run(TestSigner.envelope(payload), job: "job_test", lastSeq: 0)
        XCTAssertEqual(host.calls, [])
        XCTAssertEqual(out.results.map(\.id), ["i1", "i2", "i3", "i4"])
        XCTAssertEqual(out.results[0].error, "blocked")
        XCTAssertNil(out.results[0].skipped)
        XCTAssertEqual(out.results[1].skipped, true)
        XCTAssertNil(out.results[1].messages)
        XCTAssertEqual(out.results[2].skipped, true)
        XCTAssertEqual(out.results[2].messages, [])
        XCTAssertEqual(out.results[2].timedOut, false)
        XCTAssertEqual(out.results[3].outcome, .cancelled)
        XCTAssertEqual(out.results[3].messages, [])
    }

    @MainActor
    func testRunsInOrderAndStopsAtDone() async throws {
        let payload = TestSigner.payload(seq: 1, instructions: [
            pageOpen("i1", "https://www.heb.com/robots.txt"),
            fetch("i2"),
            ["op": "done", "id": "i3", "result": ["n": 1]],
            pageOpen("i4", "https://www.heb.com/never"),
        ])
        let host = FakeHost()
        let out = try await Runner(host: host, allowlist: Allowlist(), keys: TestSigner.keys)
            .run(TestSigner.envelope(payload), job: "job_test", lastSeq: 0)
        XCTAssertEqual(host.calls, ["open https://www.heb.com/robots.txt", "fetch"])
        XCTAssertEqual(out.results.count, 2)
        XCTAssertEqual(out.results[1].status, 200)
        XCTAssertEqual(out.terminal, .done(["n": 1]))
    }

    @MainActor
    func testFailIsTerminal() async throws {
        let payload = TestSigner.payload(seq: 1, instructions: [
            ["op": "fail", "id": "i1", "code": "store_unavailable", "message": "H-E-B is not answering right now."],
        ])
        let out = try await Runner(host: FakeHost(), allowlist: Allowlist(), keys: TestSigner.keys)
            .run(TestSigner.envelope(payload), job: "job_test", lastSeq: 0)
        XCTAssertEqual(out.terminal, .fail(code: "store_unavailable", message: "H-E-B is not answering right now."))
    }

    @MainActor
    func testFetchRateCapIs120PerMinutePerStore() async throws {
        let host = FakeHost()
        let runner = Runner(host: host, allowlist: Allowlist(), keys: TestSigner.keys)
        let first = TestSigner.payload(seq: 1, instructions: (0..<64).map { fetch("a\($0)") })
        let second = TestSigner.payload(seq: 2, instructions: (0..<64).map { fetch("b\($0)") })

        let out1 = try await runner.run(TestSigner.envelope(first), job: "job_test", lastSeq: 0)
        XCTAssertTrue(out1.results.allSatisfy { $0.ok })

        let out2 = try await runner.run(TestSigner.envelope(second), job: "job_test", lastSeq: 1)
        XCTAssertTrue(out2.results[0..<56].allSatisfy { $0.ok })
        XCTAssertEqual(out2.results[56].error, "rate")
        XCTAssertEqual(out2.results[57].skipped, true)
        XCTAssertEqual(host.calls.filter { $0 == "fetch" }.count, FETCH_PER_MINUTE)
    }

    @MainActor
    func testShowLoginChecksTheAllowlistAndHandsTheHostANavigationCheck() async throws {
        let blocked = TestSigner.payload(seq: 1, instructions: [
            ["op": "show_login", "id": "i1", "url": "https://evil.io/login", "title": "x", "doneWhen": [], "timeoutMs": 1000],
        ])
        let host = FakeHost()
        let runner = Runner(host: host, allowlist: Allowlist(), keys: TestSigner.keys)
        let out1 = try await runner.run(TestSigner.envelope(blocked), job: "job_test", lastSeq: 0)
        XCTAssertEqual(out1.results[0].error, "blocked")
        XCTAssertEqual(out1.results[0].outcome, .cancelled)
        XCTAssertEqual(host.calls, [])

        let check: JSONValue = ["script": "true;", "intervalMs": 3000]
        let doneWhen: JSONValue = [["type": "HEB_SESSION", "eq": ["loggedIn": true]]]
        let login: JSONValue = [
            "op": "show_login", "id": "i2", "url": "https://www.heb.com/my-account/login", "title": "Sign in to H-E-B",
            "check": check, "doneWhen": doneWhen, "doneWhenUrl": .null, "timeoutMs": 600000,
        ]
        let ok = TestSigner.payload(seq: 2, instructions: [login])
        let out2 = try await runner.run(TestSigner.envelope(ok), job: "job_test", lastSeq: 1)
        XCTAssertEqual(out2.results[0].outcome, .signedIn)
        let request = try XCTUnwrap(host.lastLogin)
        XCTAssertEqual(request.title, "Sign in to H-E-B")
        XCTAssertEqual(request.check, LoginCheck(script: "true;", intervalMs: 3000))
        XCTAssertEqual(request.doneWhen, [Matcher(type: "HEB_SESSION", eq: ["loggedIn": true])])
        XCTAssertNil(request.doneWhenUrl)
        XCTAssertEqual(request.guardScript, MealioScripts.guardScript)
        XCTAssertTrue(request.allowNavigation("https://accounts.google.com/o/oauth2"))
        XCTAssertTrue(request.allowNavigation("https://www.heb.com/my-account"))
        XCTAssertFalse(request.allowNavigation("https://www.heb.com/checkout"))
        XCTAssertFalse(request.allowNavigation("https://evil.io/"))
    }

    // MARK: refusals not in the shared vectors, in verify.ts order

    @MainActor
    func testRefusalReasons() async {
        let one: [JSONValue] = [pageOpen("i1", "https://www.heb.com/")]
        var r = await refusal("not json at all")
        XCTAssertEqual(r, "json")
        r = await refusal(TestSigner.payload(seq: 1, instructions: one, exp: 1000, v: 2))
        XCTAssertEqual(r, "version")
        r = await refusal(TestSigner.payload(seq: 1, instructions: one, kind: "allowlist"))
        XCTAssertEqual(r, "kind")
        r = await refusal(TestSigner.payload(seq: 1, instructions: []))
        XCTAssertEqual(r, "empty")
        let many = Array(repeating: pageOpen("i", "https://www.heb.com/"), count: 65)
        r = await refusal(TestSigner.payload(seq: 1, instructions: many))
        XCTAssertEqual(r, "too_many")
        r = await refusal(TestSigner.payload(seq: 1, instructions: [["op": "explode", "id": "i1"]]))
        XCTAssertEqual(r, "unsupported_op")
        r = await refusal(TestSigner.payload(seq: 1, instructions: [["op": "page_open", "url": "https://www.heb.com/"]]))
        XCTAssertEqual(r, "unsupported_op")
        r = await refusal(TestSigner.payload(seq: 1, instructions: [["op": "page_open", "id": "i1"]]))
        XCTAssertEqual(r, "unsupported_op")
        // 64 is the limit, not over it.
        let done: JSONValue = ["op": "done", "id": "d", "result": .null]
        r = await refusal(TestSigner.payload(seq: 1, instructions: Array(repeating: done, count: 64)))
        XCTAssertNil(r)
        // No job given: the job check is skipped, as in the TS (`job && ...`).
        r = await refusal(TestSigner.payload(seq: 1, instructions: one, job: "anything"), job: nil)
        XCTAssertNil(r)
    }

    func testExpiryAllows120SecondsOfSkew() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let fresh = TestSigner.envelope(TestSigner.payload(seq: 1, instructions: [], exp: 1_000_000 - 120))
        let stale = TestSigner.envelope(TestSigner.payload(seq: 1, instructions: [], exp: 1_000_000 - 121))
        XCTAssertNoThrow(try openEnvelope(fresh, keys: TestSigner.keys, now: now))
        XCTAssertThrowsError(try openEnvelope(stale, keys: TestSigner.keys, now: now)) { error in
            XCTAssertEqual((error as? EnvelopeError)?.why, "expired")
        }
    }

    func testResultJSONHasTheProtocolShape() throws {
        let script = InstructionResult(id: "i2", ok: true, ms: 5, messages: [], timedOut: false)
        let open = InstructionResult(id: "i1", ok: true, ms: 3, finalUrl: "https://www.heb.com/")
        let s = try JSONValue(encoding: script)
        let o = try JSONValue(encoding: open)
        XCTAssertEqual(s, ["id": "i2", "ok": true, "ms": 5, "messages": [], "timedOut": false])
        XCTAssertEqual(o, ["id": "i1", "ok": true, "ms": 3, "finalUrl": "https://www.heb.com/"])
        let login = try JSONValue(encoding: InstructionResult(id: "i3", ok: true, ms: 1, messages: [], outcome: .signedIn))
        XCTAssertEqual(login["outcome"], .string("signed_in"))
    }
}
