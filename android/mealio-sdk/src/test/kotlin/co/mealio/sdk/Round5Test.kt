package co.mealio.sdk

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

// 0.6 round 5: nothing a page or a server body holds can crash the reader.
class Round5Test {
    /** Runs [f] on a thread with a small stack, as a WebView callback or a worker may have. Returns what it returned or threw. */
    private fun <T> onSmallStack(f: () -> T): Result<T> {
        var r: Result<T>? = null
        val t = Thread(null, { r = runCatching(f) }, "small", 1024L * 1024)
        t.start()
        t.join()
        return r!!
    }

    private fun depthOf(v: Any?): Int = when (v) {
        is JSONObject -> 1 + (v.keys().asSequence().maxOfOrNull { depthOf(v.opt(it)) } ?: 0)
        is JSONArray -> 1 + ((0 until v.length()).maxOfOrNull { depthOf(v.opt(it)) } ?: 0)
        else -> 0
    }

    // ── 3. Messages from the page: depth limit 512 ───────────────────────

    @Test
    fun aMessageNestedFarPastTheLimitIsReadWithItsDeepPartsEmpty() {
        val n = 100_000
        val raw = "{\"type\":\"A\",\"x\":" + "[".repeat(n) + "]".repeat(n) + "}"
        val m = onSmallStack { parseMessage(raw) }.getOrThrow()!!
        assertEquals("A", m.getString("type"))
        // Containers to depth 512, then the one at 513 is there but empty.
        assertEquals(MESSAGE_DEPTH + 1, depthOf(m))
        // The same with objects, and bad grammar deep down is still not JSON.
        val objs = "{\"type\":\"B\",\"x\":" + "{\"a\":".repeat(n) + "1" + "}".repeat(n) + "}"
        assertEquals(MESSAGE_DEPTH + 1, depthOf(onSmallStack { parseMessage(objs) }.getOrThrow()))
        assertNull(onSmallStack { parseMessage("{\"type\":\"A\",\"x\":" + "[".repeat(n) + "]".repeat(n - 1) + "}}") }.getOrThrow())
    }

    @Test
    fun aMessageAtTheLimitKeepsEverything() {
        // The top object is depth 1: 511 arrays inside it reach 512 and hold the 7.
        val raw = "{\"type\":\"A\",\"x\":" + "[".repeat(511) + "7" + "]".repeat(511) + "}"
        var v: Any? = parseMessage(raw)!!.get("x")
        while (v is JSONArray) v = v.get(0)
        assertEquals(7, v)
        // One deeper and the innermost array comes back empty.
        val over = "{\"type\":\"A\",\"x\":" + "[".repeat(512) + "7" + "]".repeat(512) + "}"
        var w: Any? = parseMessage(over)!!.get("x")
        var last: JSONArray? = null
        while (w is JSONArray && w.length() > 0) { last = w; w = w.get(0) }
        assertEquals(0, (w as JSONArray).length())
        assertTrue(last != null)
    }

    @Test
    fun messagesReadAsJsonParseReadsThem() {
        assertNull(parseMessage("{\"type\":'A'}"))
        assertNull(parseMessage("{type:\"A\"}"))
        assertNull(parseMessage("{\"type\":\"A\"} x"))
        // 0.6 round 6: kept, as TS and Dart keep it (Infinity, sent as null).
        assertTrue(parseMessage("{\"type\":\"A\",\"n\":1e400}")!!.isNull("n"))
        val m = parseMessage("{\"type\":\"A\",\"n\":3,\"f\":1.5,\"big\":12345678901,\"z\":null,\"b\":true}")!!
        assertEquals(listOf<Any>(3, 1.5, 12345678901L, true), listOf(m.get("n"), m.get("f"), m.get("big"), m.get("b")))
        assertTrue(m.isNull("z"))
    }

    // ── 2. Request bodies: bounded depth, bounded size, no stack overflow ──

    @Test
    fun aMultipartPartWithThousandsOfHeaderLinesIsReadNotOverflowed() {
        fun part(doc: String) = "--B\r\nContent-Disposition: form-data; name=\"query\"\r\n" + "X: y\r\n".repeat(5000) + "\r\n" + doc + "\r\n--B--"
        assertEquals(false, onSmallStack { bodyBlocked(part("query{a}")) }.getOrThrow())
        assertEquals(true, onSmallStack { bodyBlocked(part("mutation{placeOrder{id}}")) }.getOrThrow())
    }

    @Test
    fun theMultipartScanFindsWhatThePatternFinds() {
        // MULTIPART_FIELD from packages/core/src/allowlist.ts, as java.util.regex runs it on short text.
        val re = Regex(
            "name=[\"']?(operationName|query|operations)(?=[\"';\\s\\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000\\ufeff]|\\z)" +
                "[^\\r\\n]*\\r?\\n(?:[^\\r\\n]+\\r?\\n)*\\r?\\n([\\s\\S]*?)(?=\\r?\\n--|\\z)",
        )
        val bits = listOf("name=", "\"", "'", "query", "operations", "operationName", "operationsX", ";", " ", "\r", "\n", "\r\n", "--", "a", "X: y", "\u2028")
        val rnd = java.util.Random(5)
        repeat(20000) {
            val sb = StringBuilder()
            repeat(rnd.nextInt(14)) { sb.append(bits[rnd.nextInt(bits.size)]) }
            val t = sb.toString()
            assertEquals(t, re.findAll(t).map { it.groupValues[1] to it.groupValues[2] }.toList(), multipartFields(t))
        }
    }

    @Test
    fun operationsNestedPastEightAreBlocked() {
        assertEquals(false, bodyBlocked("operations=".repeat(8) + "query{a}"))
        assertEquals(true, bodyBlocked("operations=".repeat(9) + "query{a}"))
        assertEquals(true, onSmallStack { bodyBlocked("operations=".repeat(20000) + "query{a}") }.getOrThrow())
    }

    @Test
    fun aBodyOverOneMegabyteIsBlockedUnread() {
        assertEquals(false, bodyBlocked("a".repeat(BODY_MAX_TEXT - 8) + "query{a}"))
        assertEquals(true, bodyBlocked("a".repeat(BODY_MAX_TEXT - 7) + "query{a}"))
        // The byte order mark is dropped before measuring.
        assertEquals(false, bodyBlocked("\uFEFF" + "a".repeat(BODY_MAX_TEXT)))
        assertEquals(true, bodyBlocked("\uFEFF" + "a".repeat(BODY_MAX_TEXT + 1)))
    }

    @Test
    fun aStackOverflowWhileJudgingIsABlock() {
        // A chain of fragment spreads deep enough to exhaust a small stack.
        val n = 30000
        val doc = StringBuilder("mutation{...f0}")
        for (k in 0 until n) doc.append(" fragment f").append(k).append(" on M{...f").append(k + 1).append('}')
        assertEquals(true, onSmallStack { bodyBlocked(doc.toString()) }.getOrThrow())
    }
}
