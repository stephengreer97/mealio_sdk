package co.mealio.sdk

import kotlinx.coroutines.runBlocking
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
