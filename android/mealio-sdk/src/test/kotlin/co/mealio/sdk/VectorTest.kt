package co.mealio.sdk

import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

// Mirrors the "test vectors" block of packages/core/test/core.test.ts. Every
// case, allowlist case and matcher case in protocol/test-vectors.json must get
// the same answer here as in TypeScript.
class VectorTest {

    @Test
    fun testKeyIsTheVectorKey() {
        assertEquals(Vectors.json.getString("publicKey"), TestSigner.publicKeyB64)
    }

    @Test
    fun everyCase() {
        runBlocking {
            val cases = Vectors.cases()
            assertTrue(cases.isNotEmpty())
            for (c in cases) {
                val name = c.getString("name")
                val env = Envelope.fromJson(c.getJSONObject("envelope"))
                val job = c.getString("job")
                val lastSeq = c.getInt("lastSeq")
                val expect = c.getString("expect")
                val runner = Runner(FakeHost(), Allowlist(), Vectors.keys)
                if (expect == "ok") {
                    val out = runner.run(env, job, lastSeq)
                    val firstError = c.opt("firstResultError") as? String
                    if (firstError != null) {
                        assertEquals(name, firstError, out.results[0].error)
                    } else {
                        assertTrue(name, out.results.all { it.ok } || out.terminal != null)
                    }
                } else {
                    try {
                        runner.run(env, job, lastSeq)
                        fail("$name should have been refused with $expect")
                    } catch (e: EnvelopeException) {
                        assertEquals(name, expect, e.why)
                        assertEquals("bad_envelope", e.code)
                    }
                }
            }
        }
    }

    @Test
    fun allowlistCases() {
        val a = Allowlist()
        val cases = Vectors.json.getJSONArray("allowlist").objects()
        assertTrue(cases.isNotEmpty())
        for (c in cases) {
            val store = c.getString("store")
            val url = c.getString("url")
            val use = UrlUse.valueOf(c.getString("use").uppercase())
            assertEquals("$store $url $use", c.getBoolean("ok"), a.check(store, url, use).ok)
        }
    }

    @Test
    fun blockedBodyCases() {
        val cases = Vectors.json.getJSONArray("blockedBodies").objects()
        assertTrue(cases.isNotEmpty())
        for (c in cases) {
            val body = c.getString("body")
            assertEquals(body, c.getBoolean("blocked"), bodyBlocked(body))
        }
    }

    @Test
    fun jsonBodyCases() {
        // 0.6 round 4: StrictJson reads exactly what JSON.parse reads (depth, \\u hex digits, lone surrogates).
        val cases = Vectors.json.getJSONArray("jsonBodies").objects()
        assertTrue(cases.isNotEmpty())
        for (c in cases) {
            val body = c.getString("body")
            assertEquals("${c.optString("rule")}: ${body.take(80)}", c.getBoolean("blocked"), bodyBlocked(body))
        }
    }

    /** Runs [f] on a 1 MB stack, as a WebView callback or a worker may have. */
    private fun <T> onSmallStack(f: () -> T): T {
        var r: Result<T>? = null
        val t = Thread(null, { r = runCatching(f) }, "small", 1024L * 1024)
        t.start()
        t.join()
        return r!!.getOrThrow()
    }

    @Test
    fun bodyLimitCases() {
        // 0.6 round 5: operations nested past BODY_MAX_DEPTH are blocked; past BODY_MAX_TEXT, the plain text decides.
        val cases = Vectors.json.getJSONArray("bodyLimits").objects()
        assertTrue(cases.isNotEmpty())
        for (c in cases) {
            val body = c.getString("prefix") + c.getString("fill").repeat(c.getInt("times")) + c.getString("suffix")
            val label = "${c.getString("rule")} ${c.getString("fill").take(20)} x${c.getInt("times")} ${c.getString("suffix").take(40)}"
            assertEquals(label, c.getBoolean("blocked"), onSmallStack { bodyBlocked(body) })
        }
    }

    private fun depthOf(v: Any?): Int = when (v) {
        is JSONObject -> 1 + (v.keys().asSequence().maxOfOrNull { depthOf(v.opt(it)) } ?: 0)
        is JSONArray -> 1 + ((0 until v.length()).maxOfOrNull { depthOf(v.opt(it)) } ?: 0)
        else -> 0
    }

    @Test
    fun deepMessageCases() {
        // 0.6 round 5: a page message keeps containers to depth 512; deeper ones come back empty.
        val cases = Vectors.json.getJSONArray("deepMessages").objects()
        assertTrue(cases.isNotEmpty())
        for (c in cases) {
            val n = c.getInt("times")
            val raw = c.getString("prefix") + c.getString("open").repeat(n) + c.getString("close").repeat(n) + c.getString("suffix")
            val m = onSmallStack { parseMessage(raw) }
            val label = "${c.getString("open")} x$n"
            assertTrue(label, m != null)
            assertEquals(label, c.getInt("depth"), depthOf(m))
            assertEquals(label, c.getInt("keep"), m!!.getInt("keep"))
        }
    }

    @Test
    fun matcherCases() {
        val cases = Vectors.json.getJSONArray("matchers").objects()
        assertTrue(cases.isNotEmpty())
        for (c in cases) {
            val msg = c.getJSONObject("msg")
            val m = Matcher.fromJson(c.getJSONObject("m"))
            assertEquals("$msg vs ${c.getJSONObject("m")}", c.getBoolean("ok"), matches(msg, m))
        }
    }

    @Test
    fun doneCarriesUnicodeResultIntact() {
        runBlocking {
            val out = Runner(FakeHost(), Allowlist(), Vectors.keys).run(Vectors.envelope("valid_unicode_done"), "job_test", 1)
            val t = out.terminal as Terminal.Done
            val result = t.result as JSONObject
            assertEquals(1, result.length())
            assertEquals("café ✓", result.getString("hello"))
            assertTrue(out.results.isEmpty())
        }
    }

    @Test
    fun refusesTheProductionKeyForTestEnvelopes() {
        val env = Vectors.envelope(Vectors.cases()[0].getString("name"))
        val e = assertThrows(EnvelopeException::class.java) { openEnvelope(env) }
        assertEquals("unknown_kid", e.why)
        assertNotNull(KEYS["k1"])
    }
}
