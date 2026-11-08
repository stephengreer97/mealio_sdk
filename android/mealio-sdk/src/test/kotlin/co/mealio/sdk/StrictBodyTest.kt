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
}
