package co.mealio.sdk

import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class RunnerTest {
    private val keys = Vectors.keys

    private fun refused(env: Envelope?, job: String? = "job_test", lastSeq: Int = 0): String = runBlocking {
        try {
            Runner(FakeHost(), Allowlist(), keys).run(env, job, lastSeq)
            fail("expected a refusal")
            ""
        } catch (e: EnvelopeException) {
            e.why
        }
    }

    @Test
    fun skipsTheRestOfAnEnvelopeAfterAFailure_vector(): Unit = runBlocking {
        val host = FakeHost()
        val out = Runner(host, Allowlist(), keys).run(Vectors.envelope("blocked_url_runs_but_refuses"), "job_test", 0)
        assertEquals(1, out.results.size)
        assertTrue(host.calls.isEmpty())
    }

    @Test
    fun marksEverythingAfterAFailureSkipped(): Unit = runBlocking {
        val host = FakeHost()
        val env = TestSigner.instructions(
            1,
            listOf(
                pageOpen("i1", "https://www.heb.com/checkout/review"),
                fetchOp("i2", "https://www.heb.com/graphql"),
                pageScript("i3", "HEB_SESSION"),
                showLoginOp("i4", "https://www.heb.com/my-account/login"),
                pageOpen("i5", "https://www.heb.com/"),
            ),
        )
        val out = Runner(host, Allowlist(), keys).run(env, "job_test", 0)
        assertEquals(listOf("i1", "i2", "i3", "i4", "i5"), out.results.map { it.id })
        assertEquals("blocked", out.results[0].error)
        assertFalse(out.results[0].skipped)
        assertTrue(out.results.drop(1).all { it.skipped && !it.ok })
        assertTrue(host.calls.isEmpty())

        // Wire shape matches the reference's skipped() results.
        val script = out.results[2].toJson()
        assertEquals(0, script.getJSONArray("messages").length())
        assertEquals(false, script.getBoolean("timedOut"))
        assertEquals(true, script.getBoolean("skipped"))
        val login = out.results[3].toJson()
        assertEquals("cancelled", login.getString("outcome"))
        val fetch = out.results[1].toJson()
        assertFalse(fetch.has("status"))
        assertEquals(0, fetch.getInt("ms"))
    }

    @Test
    fun runsInOrderAndStopsAtDone(): Unit = runBlocking {
        val host = FakeHost()
        val env = TestSigner.instructions(
            1,
            listOf(
                pageOpen("i1", "https://www.heb.com/robots.txt"),
                fetchOp("i2", "https://www.heb.com/graphql"),
                showLoginOp("i3", "https://www.heb.com/my-account/login"),
                doneOp("i4", JSONObject().put("x", 1)),
                pageOpen("i5", "https://www.heb.com/never"),
            ),
        )
        val out = Runner(host, Allowlist(), keys).run(env, "job_test", 0)
        assertEquals(listOf("open https://www.heb.com/robots.txt", "fetch", "login"), host.calls)
        assertEquals(3, out.results.size)
        assertTrue(out.results.all { it.ok })
        val done = out.terminal as Terminal.Done
        assertEquals(1, (done.result as JSONObject).getInt("x"))
    }

    @Test
    fun failIsTerminal(): Unit = runBlocking {
        val env = TestSigner.instructions(1, listOf(failOp("i1", "store_unavailable", "H-E-B is not answering right now.")))
        val out = Runner(FakeHost(), Allowlist(), keys).run(env, "job_test", 0)
        assertEquals(Terminal.Fail("store_unavailable", "H-E-B is not answering right now."), out.terminal)
    }

    @Test
    fun loginAllowlistIsPassedToTheHost(): Unit = runBlocking {
        var seen: LoginRequest? = null
        val host = object : Host by FakeHost() {
            override suspend fun showLogin(request: LoginRequest): LoginResult {
                seen = request
                return LoginResult(LoginOutcome.CANCELLED, emptyList())
            }
        }
        val env = TestSigner.instructions(1, listOf(showLoginOp("i1", "https://www.heb.com/my-account/login")))
        val out = Runner(host, Allowlist(), keys).run(env, "job_test", 0)
        val r = out.results[0] as InstructionResult.ShowLoginResult
        assertTrue(r.ok)
        assertEquals(LoginOutcome.CANCELLED, r.outcome)
        val req = seen!!
        assertEquals(GUARD_SCRIPT, req.guard)
        assertTrue(req.allowNavigation("https://accounts.google.com/o/oauth2"))
        assertTrue(req.allowNavigation("https://mealio.co/return"))
        assertFalse(req.allowNavigation("https://evil.example/"))
        assertFalse(req.allowNavigation("https://www.heb.com/checkout"))
    }

    @Test
    fun hostErrorsBecomeFailedResults(): Unit = runBlocking {
        val host = FakeHost(onFetch = { throw RuntimeException("boom") })
        val env = TestSigner.instructions(1, listOf(fetchOp("i1", "https://www.heb.com/graphql")))
        val out = Runner(host, Allowlist(), keys).run(env, "job_test", 0)
        assertEquals("no_response", out.results[0].error)
        assertFalse(out.results[0].ok)

        val host2 = FakeHost(onOpen = { throw RuntimeException("boom") })
        val env2 = TestSigner.instructions(1, listOf(pageOpen("i1", "https://www.heb.com/")))
        assertEquals("load_failed", Runner(host2, Allowlist(), keys).run(env2, "job_test", 0).results[0].error)
    }

    @Test
    fun capsFetchesAt120PerMinutePerStore(): Unit = runBlocking {
        var now = 1_000_000L
        val runner = Runner(FakeHost(), Allowlist(), keys) { now }
        fun batch(seq: Int, n: Int) = TestSigner.instructions(seq, (1..n).map { fetchOp("f$it", "https://www.heb.com/graphql") })

        assertTrue(runner.run(batch(1, 60), "job_test", 0).results.all { it.ok })
        assertTrue(runner.run(batch(2, 60), "job_test", 1).results.all { it.ok })
        val third = runner.run(batch(3, 2), "job_test", 2)
        assertEquals("rate", third.results[0].error)
        assertTrue(third.results[1].skipped)

        now += 60_001
        assertTrue(runner.run(batch(4, 1), "job_test", 3).results.all { it.ok })
    }

    @Test
    fun refusalReasons() {
        assertEquals("shape", refused(null))
        assertEquals("unknown_kid", refused(TestSigner.sign("{}", kid = "nope")))
        assertEquals("json", refused(TestSigner.sign("not json{")))
        assertEquals("json", refused(TestSigner.sign("{\"v\":1} trailing")))
        assertEquals("version", refused(TestSigner.sign("[1,2]")))
        assertEquals("version", refused(TestSigner.instructions(1, listOf(doneOp("i1", null)), v = 2)))
        assertEquals("expired", refused(TestSigner.instructions(1, listOf(doneOp("i1", null)), exp = 1000)))
        assertEquals("kind", refused(TestSigner.instructions(1, listOf(doneOp("i1", null)), kind = "allowlist")))
        assertEquals("job", refused(TestSigner.instructions(1, listOf(doneOp("i1", null)), job = "job_x")))
        assertEquals("seq", refused(TestSigner.instructions(2, listOf(doneOp("i1", null)))))
        assertEquals("empty", refused(TestSigner.instructions(1, emptyList())))
        assertEquals("too_many", refused(TestSigner.instructions(1, (1..65).map { doneOp("i$it", null) })))
        assertEquals(
            "unsupported_op",
            refused(TestSigner.instructions(1, listOf(JSONObject().put("op", "click").put("id", "i1")))),
        )
        assertEquals(
            "unsupported_op",
            refused(TestSigner.instructions(1, listOf(JSONObject().put("op", "done")))),
        )
        // Exactly 64 is fine.
        runBlocking {
            Runner(FakeHost(), Allowlist(), keys).run(TestSigner.instructions(1, (1..64).map { doneOp("i$it", null) }), "job_test", 0)
        }
    }

    @Test
    fun expiryAllows120SecondsOfSkew() {
        val exp = 2_000_000L
        val env = TestSigner.instructions(1, listOf(doneOp("i1", null)), exp = exp)
        openEnvelope(env, keys, nowMs = (exp + 119) * 1000)
        try {
            openEnvelope(env, keys, nowMs = (exp + 121) * 1000)
            fail("expected expired")
        } catch (e: EnvelopeException) {
            assertEquals("expired", e.why)
        }
    }

    @Test
    fun noJobMeansNoJobCheck(): Unit = runBlocking {
        val env = TestSigner.instructions(1, listOf(doneOp("i1", null)), job = "anything")
        assertTrue(Runner(FakeHost(), Allowlist(), keys).run(env, null, 0).terminal is Terminal.Done)
    }

    @Test
    fun resultJsonDropsMissingFields() {
        val o = InstructionResult.PageOpenResult("i1", ok = true, finalUrl = "https://x", ms = 5).toJson()
        assertEquals(setOf("id", "ok", "finalUrl", "ms"), o.keys().asSequence().toSet())
        val step = StepRequest(3, listOf(InstructionResult.FetchResult("i2", ok = true, status = 200, headers = mapOf("a" to "b"), body = "x", truncated = false, ms = 1))).toJson()
        assertEquals(3, step.getInt("seq"))
        val f = step.getJSONArray("results").getJSONObject(0)
        assertEquals(200, f.getInt("status"))
        assertEquals("b", f.getJSONObject("headers").getString("a"))
        assertFalse(f.has("error"))
    }

    @Test
    fun allowlistWidening() {
        val a = Allowlist()
        a.widen(
            AllowlistPayload(
                1, 0.0,
                mapOf(
                    "heb" to StoreHostsPatch(hosts = listOf("api.heb.com", "heb-cdn.net")),
                    "nope" to StoreHostsPatch(hosts = listOf("x.com")),
                ),
            ),
        )
        assertTrue(a.hostsFor("heb")!!.hosts.contains("api.heb.com"))
        assertFalse(a.hostsFor("heb")!!.hosts.contains("heb-cdn.net"))
        assertNull(a.hostsFor("nope"))
        assertFalse(a.check("heb", "https://www.heb.com/checkout", UrlUse.PAGE).ok)
    }

    @Test
    fun allowlistPayloadParses() {
        val p = JSONObject().put("v", 1).put("kind", "allowlist").put("exp", 1)
            .put("stores", JSONObject().put("heb", JSONObject().put("hosts", JSONArray().put("api.heb.com"))))
        val a = AllowlistPayload.fromJson(p)!!
        assertEquals(listOf("api.heb.com"), a.stores["heb"]!!.hosts)
        assertNull(AllowlistPayload.fromJson(JSONObject().put("kind", "instructions")))
    }

    @Test
    fun allowlistEdges() {
        val a = Allowlist()
        assertFalse(a.check("heb", "https://heb.com@evil.io/", UrlUse.PAGE).ok)
        assertTrue(a.check("heb", "https://www.heb.com:443/x", UrlUse.PAGE).ok)
        assertTrue(a.check("heb", "HTTPS://WWW.HEB.COM/x", UrlUse.PAGE).ok)
        assertFalse(a.check("heb", "https://www.heb.com/x?giftcard=1", UrlUse.FETCH).ok)
        assertFalse(a.check("heb", "https://www.heb.com/account/password", UrlUse.PAGE).ok)
        assertTrue(a.check("heb", "https://www.heb.com/x#checkout", UrlUse.PAGE).ok) // fragment is not checked
        assertFalse(a.check("heb", "not a url", UrlUse.PAGE).ok)
        assertTrue(a.check("safeway", "https://www.albertsons.com/login", UrlUse.LOGIN).ok)
        assertFalse(a.check("safeway", "https://www.albertsons.com/login", UrlUse.PAGE).ok)
        assertEquals("example.co.uk", registrableDomain("www.shop.example.co.uk"))
        assertEquals("heb.com", registrableDomain("WWW.HEB.COM"))
    }

    @Test
    fun matcherSemantics() {
        val msg = JSONObject().put("type", "T").put("n", 1).put("nul", JSONObject.NULL)
        assertTrue(matches(msg, Matcher("T", eq = mapOf("n" to 1.0))))
        assertFalse(matches(msg, Matcher("T", eq = mapOf("n" to "1"))))
        assertTrue(matches(msg, Matcher("T", eq = mapOf("nul" to JSONObject.NULL))))
        assertFalse(matches(msg, Matcher("T", eq = mapOf("missing" to JSONObject.NULL))))
        assertTrue(matches(msg, Matcher("T", ne = mapOf("missing" to true))))
        assertFalse(matches(JSONObject().put("type", 5), Matcher("5")))
        assertEquals(null, parseMessage("[1]"))
        assertEquals(null, parseMessage("nope"))
        assertEquals("A", parseMessage("{\"type\":\"A\"}")!!.getString("type"))
    }

    @Test
    fun base64Variants() {
        val std = base64ToBytes("+/8=")
        val url = base64ToBytes("-_8")
        assertEquals(listOf(0xfb, 0xff), std.map { it.toInt() and 0xff })
        assertEquals(std.toList(), url.toList())
    }

    // Mirrors "security: request bodies and the runner fetch op" in core.test.ts.
    private fun postFetch(id: String, body: String) = JSONObject().put("op", "fetch").put("id", id)
        .put("request", JSONObject().put("method", "POST").put("url", "https://www.heb.com/graphql").put("body", body))
        .put("timeoutMs", 1000).put("maxBytes", 1000)

    @Test
    fun refusesAFetchWhoseBodyNamesAnOrder(): Unit = runBlocking {
        val host = FakeHost()
        val runner = Runner(host, Allowlist(), keys)
        // A literal backslash-u escape in the JSON text: "place\u004frder" is placeOrder.
        val bad = runner.run(TestSigner.instructions(1, listOf(postFetch("f1", "{\"operationName\":\"place\\u004frder\"}"))), "job_test", 0)
        val r = bad.results[0] as InstructionResult.FetchResult
        assertFalse(r.ok)
        assertEquals("blocked", r.error)
        assertFalse(host.calls.contains("fetch"))
        val good = runner.run(TestSigner.instructions(2, listOf(postFetch("f2", "{\"operationName\":\"cartItemsV2\"}"))), "job_test", 1)
        assertTrue(good.results[0].ok)
        assertTrue(host.calls.contains("fetch"))
    }

    @Test
    fun refusesShowLoginWhenTheRunMayNotSignIn(): Unit = runBlocking {
        val host = FakeHost()
        val runner = Runner(host, Allowlist(), keys)
        val no = runner.run(TestSigner.instructions(1, listOf(showLoginOp("l1", "https://www.heb.com/login"))), "job_test", 0, allowLogin = false)
        val r = no.results[0] as InstructionResult.ShowLoginResult
        assertFalse(r.ok)
        assertEquals(LoginOutcome.CANCELLED, r.outcome)
        assertEquals("not_allowed", r.error)
        assertFalse(host.calls.contains("login"))
        val yes = runner.run(TestSigner.instructions(2, listOf(showLoginOp("l2", "https://www.heb.com/login"))), "job_test", 1)
        assertEquals(LoginOutcome.SIGNED_IN, (yes.results[0] as InstructionResult.ShowLoginResult).outcome)
    }

    @Test
    fun parsesOnlyPlainHostNames() {
        assertNull(parseUrl("https://www.heb.com:x@evil.com/"))
        assertNull(parseUrl("https://evil.com\\.heb.com/"))
        assertEquals(ParsedUrl("https", "www.heb.com", "/a?b=1"), parseUrl("https://www.heb.com:443/a?b=1#c"))
        assertEquals(ParsedUrl("https", "www.heb.com", "/"), parseUrl("https://www.heb.com"))
    }
}
