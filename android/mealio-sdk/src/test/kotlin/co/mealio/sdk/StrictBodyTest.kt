package co.mealio.sdk

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

// 0.6 round 3: bodyBlocked reads JSON exactly as JSON.parse does. org.json
// accepts text JSON.parse refuses (single quotes, bare words, comments), and
// reading such a body as JSON hid the mutation in it.
class StrictBodyTest {
    @Test fun singleQuotedArrayIsJudgedAsADocument() = assertTrue(bodyBlocked("['mutation {checkout}']"))
    @Test fun bareWordsAreJudgedAsADocument() = assertTrue(bodyBlocked("[mutation,{\"x\":checkout}]"))
    @Test fun aCommentTailIsJudgedAsADocument() = assertTrue(bodyBlocked("{\"a\":1}/* mutation{checkout} */"))

    @Test
    fun parsesWhatJsonParseParsesAndNothingElse() {
        val good = listOf("{}", "[]", "1", "-0.5e+3", "\"a\\u0041\"", " [true,false,null] ", "{\"a\":{\"b\":[1,\"x\"]}}")
        for (g in good) assertFalse(g, StrictJson.parse(g) === StrictJson.INVALID)
        val bad = listOf("", "{a:1}", "['x']", "[1,]", "{\"a\":1,}", "01", "1.", ".5", "+1", "NaN", "\"\t\"",
            "[1]/**/", "[1] x", "\u00a0[]", "\uFEFF[]", "\"\\x41\"", "tru", "{\"a\" 1}")
        for (b in bad) assertSame(b, StrictJson.INVALID, StrictJson.parse(b))
        // A repeated key keeps its last value, as in JSON.parse.
        assertEquals("checkout", (StrictJson.parse("{\"operationName\":\"x\",\"operationName\":\"checkout\"}") as Map<*, *>)["operationName"])
        assertTrue(bodyBlocked("{\"operationName\":\"x\",\"operationName\":\"\\u0063heckout\"}"))
    }

    // ── 0.6 round 4: exactly what JSON.parse accepts ────────────────────

    @Test
    fun deepNestingIsJsonAsInJsonParse() {
        val deep = "[".repeat(1001) + "]".repeat(1001)
        val body = "[$deep,{\"query\":\"mutation placeOrder{x}\"}]"
        assertFalse(StrictJson.parse(body) === StrictJson.INVALID)
        assertTrue(bodyBlocked(body))
        // Far past any call stack.
        val huge = "[".repeat(200_000) + "]".repeat(200_000)
        assertFalse(StrictJson.parse(huge) === StrictJson.INVALID)
        val hugeObj = "{\"a\":".repeat(100_000) + "1" + "}".repeat(100_000)
        assertFalse(StrictJson.parse(hugeObj) === StrictJson.INVALID)
        assertSame(StrictJson.INVALID, StrictJson.parse("[".repeat(5000) + "]".repeat(4999)))
    }

    @Test
    fun aUnicodeEscapeTakesAsciiHexDigitsOnly() {
        // Fullwidth zeros: JSON.parse refuses this, so the body is judged as text.
        val fw = "{\"x\":\"\\u\uFF10\uFF10\uFF14\uFF11\",\"y\":\"&query=mutation%20placeOrder%7Bx%7D\"}"
        assertSame(StrictJson.INVALID, StrictJson.parse(fw))
        assertTrue(bodyBlocked(fw))
        assertSame(StrictJson.INVALID, StrictJson.parse("\"\\u\u0661\u0660\u0660\u0660\""))
        assertEquals("Aa", StrictJson.parse("\"\\u0041\\u0061\""))
    }

    @Test
    fun loneSurrogatesAreKeptAsJsonParseKeepsThem() {
        assertEquals("\uD800", StrictJson.parse("\"\\uD800\""))
        assertEquals("\uDC00x", StrictJson.parse("\"\\udc00x\""))
        assertEquals("\uD800", StrictJson.parse("\"\uD800\""))
        assertTrue(bodyBlocked("{\"a\":\"\\uD800\",\"operationName\":\"checkout\"}"))
    }

    @Test
    fun aMultipartFieldNameMayBeBareOrSingleQuoted() {
        val q = "mutation { placeOrder { id } }"
        for (name in listOf("query", "'query'", "\"query\"", "query\u00a0", "query;"))
            assertTrue(name, bodyBlocked("--b\r\nContent-Disposition: form-data; name=$name\r\n\r\n$q\r\n--b--"))
    }
}
