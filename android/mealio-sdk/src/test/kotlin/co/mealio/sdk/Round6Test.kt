package co.mealio.sdk

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

/** 0.6 round 6, items 3 and 4. */
class Round6Test {
    // ── 3. The multipart scan is linear ──

    private fun timed(label: String, body: String, boundMs: Long = 1500) {
        val t0 = System.nanoTime()
        bodyBlocked(body)
        val ms = (System.nanoTime() - t0) / 1_000_000
        assertTrue("$label: ${body.length} chars took $ms ms", ms < boundMs)
    }

    @Test fun multipartScanIsLinear() {
        bodyBlocked("name=query\n".repeat(1000)) // warm up the JIT
        // Each of these took seconds to minutes when every `name=` line started a scan to the end.
        timed("name lines", "name=query\n".repeat(90000))
        timed("name lines, CRLF", "name=query\r\n".repeat(80000))
        timed("names and headers", "name=query\n" + "name=query\nX\n".repeat(75000))
        timed("lone CRs", "name=query\r".repeat(90000))
        timed("names on one line", "name=query".repeat(100000))
        timed("dashes", "--B\r\nname=query\r\n\r\n" + "\n-".repeat(400000))
        timed("form operations", "operations=" + "%25".repeat(300000))
    }

    /** protocol/test-vectors.json multipartScan: judged right, and fast. */
    @Test fun multipartScanVectors() {
        val cases = Vectors.json.getJSONArray("multipartScan").objects()
        assertTrue(cases.isNotEmpty())
        bodyBlocked("name=query\n".repeat(1000)) // warm up the JIT
        for (c in cases) {
            val body = c.getString("prefix") + c.getString("fill").repeat(c.getInt("times")) + c.getString("suffix")
            val label = "${JSONObject.quote(c.getString("fill"))} x ${c.getInt("times")}"
            val t0 = System.nanoTime()
            assertEquals(label, c.getBoolean("blocked"), bodyBlocked(body))
            val ms = (System.nanoTime() - t0) / 1_000_000
            assertTrue("$label took $ms ms", ms < 1500)
        }
    }

    /** JS MULTIPART_FIELD, with Java's end-of-input `\z` for JS `$` (no m flag). ASCII bodies only. */
    private val reference = Regex("name=[\"']?(operationName|query|operations)(?=[\"';\\s]|\\z)[^\\r\\n]*\\r?\\n(?:[^\\r\\n]+\\r?\\n)*\\r?\\n([\\s\\S]*?)(?=\\r?\\n--|\\z)")

    @Test fun multipartScanMatchesThePattern() {
        val atoms = listOf("name=", "name=", "query", "operations", "operationName", "\"", "'", ";", " ", "\r", "\n", "\n", "\r\n", "--", "x", "{}", "mutation placeOrder{a}")
        val rnd = Random(6)
        var withFields = 0
        repeat(40000) {
            val s = buildString { repeat(rnd.nextInt(1, 20)) { append(atoms[rnd.nextInt(atoms.size)]) } }
            val want = reference.findAll(s).map { it.groupValues[1] to it.groupValues[2] }.toList()
            if (want.isNotEmpty()) withFields++
            assertEquals(JSONObject.quote(s), want, multipartFields(s))
        }
        println("multipart pattern cases with fields: $withFields")
        assertTrue(withFields > 100)
    }

    // ── 4. Parity with TS parseJson / parseMessage ──

    @Test fun infinityKeepsTheMessage() {
        val m = parseMessage("{\"type\":\"done\",\"x\":1e400,\"y\":[-1e400],\"n\":2}")
        assertNotNull(m)
        assertTrue(isJsonNull(m!!.opt("x")))
        assertTrue(isJsonNull(m.getJSONArray("y").opt(0)))
        assertEquals(2, m.getInt("n"))
        assertTrue(matches(m, Matcher("done", mapOf("n" to 2))))
        // JSON.stringify writes it as null: so do we.
        assertEquals("[null]", m.getJSONArray("y").toString())
    }

    @Test fun tooDeepContainersAreBlankedByBracketMatching() {
        // Past depth 512 the content is not read for its grammar, as TS parseJson.
        val deepBad = "{\"type\":\"done\",\"a\":" + "[".repeat(513) + "1,,}" + "]".repeat(512) + "}"
        assertEquals("done", parseMessage(deepBad)?.getString("type"))
        val deepMix = "{\"type\":\"done\",\"a\":" + "[".repeat(512) + "{]" + "]".repeat(512) + "}"
        assertEquals("done", parseMessage(deepMix)?.getString("type"))
        // A string inside the skipped part may hold brackets.
        assertEquals("[[[[]]]]", toJson(StrictJson.parse("[[[[\"]\\\"\"]]]]", 3)))
        // Grammar above the limit still counts; an unclosed deep part is not JSON.
        assertSame(StrictJson.INVALID, StrictJson.parse("[[[[1,,]]],]", 3))
        assertSame(StrictJson.INVALID, StrictJson.parse("[[[[1]]]", 3))
        // No limit: full grammar, as JSON.parse.
        assertSame(StrictJson.INVALID, StrictJson.parse("[[[[1,,]]]]"))
    }

    private fun toJson(v: Any?): String = when (v) {
        is List<*> -> v.joinToString(",", "[", "]") { toJson(it) }
        else -> v.toString()
    }

    private fun shape(v: Any?): String = when (v) {
        null -> "null"
        is Map<*, *> -> v.entries.joinToString(",", "{", "}") { JSONObject.quote(it.key as String) + ":" + shape(it.value) }
        is List<*> -> v.joinToString(",", "[", "]") { shape(it) }
        is Number -> "#"
        is String -> JSONObject.quote(v).replace("\\/", "/").map { c -> if (Character.isSurrogate(c)) String.format("\\u%04x", c.code) else c.toString() }.joinToString("")
        else -> v.toString()
    }

    /** json-depth-fuzz.json: node's JSON.parse and TS parseJson(s, 3) on random text (tools/gen-json-depth-fuzz.cjs). */
    @Test fun depthLimitFuzzParityWithTs() {
        val a = JSONArray(readResource("json-depth-fuzz.json"))
        var onlyPastLimit = 0
        for (i in 0 until a.length()) {
            val o = a.getJSONObject(i)
            val s = o.getString("s")
            assertEquals("full ${JSONObject.quote(s)}", o.getString("full"), if (StrictJson.parse(s) === StrictJson.INVALID) "bad" else "ok")
            val l = StrictJson.parse(s, 3)
            val want = if (o.isNull("lim")) null else o.getString("lim")
            assertEquals("limit 3 ${JSONObject.quote(s)}", want, if (l === StrictJson.INVALID) null else shape(l))
            if (want != null && o.getString("full") == "bad") onlyPastLimit++
        }
        assertTrue(onlyPastLimit > 0)
        assertFalse(a.length() < 1000)
    }
}
