package co.mealio.sdk

import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import org.json.JSONTokener

// Small helpers over org.json. JSON values in this SDK are the org.json types:
// JSONObject, JSONArray, String, Number, Boolean and JSONObject.NULL.
//
// Two org.json habits these helpers avoid:
//  - optString() turns a JSON null into the text "null" (Android) and turns
//    numbers into strings. str() only returns real strings.
//  - The tokener is lenient (unquoted words, trailing text). parseJson() is
//    stricter so a broken payload fails as "json", like JSON.parse in the
//    TypeScript reference.

/** True for a JSON null (or a missing value). */
internal fun isJsonNull(v: Any?): Boolean = v == null || v == JSONObject.NULL

/** Parse JSON text. Throws JSONException when it is not valid JSON. */
internal fun parseJson(text: String): Any {
    val t = JSONTokener(text)
    val v = t.nextValue()
    // Anything after the value (other than whitespace) means the text is broken.
    if (t.nextClean() != 0.toChar()) throw JSONException("trailing text")
    // org.json reads an unquoted word as a string. JSON.parse does not.
    if (v is String && !text.trimStart().startsWith("\"")) throw JSONException("unquoted text")
    return v ?: JSONObject.NULL
}

internal fun JSONObject.str(key: String): String? = opt(key) as? String

internal fun JSONObject.num(key: String): Double? = (opt(key) as? Number)?.toDouble()

internal fun JSONObject.bool(key: String): Boolean? = opt(key) as? Boolean

internal fun JSONObject.obj(key: String): JSONObject? = opt(key) as? JSONObject

internal fun JSONObject.arr(key: String): JSONArray? = opt(key) as? JSONArray

internal fun JSONArray.objects(): List<JSONObject> {
    val out = ArrayList<JSONObject>(length())
    for (i in 0 until length()) (opt(i) as? JSONObject)?.let { out.add(it) }
    return out
}

internal fun JSONArray.strings(): List<String> {
    val out = ArrayList<String>(length())
    for (i in 0 until length()) (opt(i) as? String)?.let { out.add(it) }
    return out
}

/** A JSONObject as a map of its raw values (in the tokener's key order). */
internal fun JSONObject.toValueMap(): Map<String, Any?> {
    val out = LinkedHashMap<String, Any?>()
    val it = keys()
    while (it.hasNext()) {
        val k = it.next()
        out[k] = opt(k)
    }
    return out
}

/** Put a value, writing JSONObject.NULL for null. */
internal fun JSONObject.putNullable(key: String, v: Any?): JSONObject = put(key, v ?: JSONObject.NULL)

/** Put a value only when it is not null (JSON.stringify drops undefined). */
internal fun JSONObject.putIfNotNull(key: String, v: Any?): JSONObject {
    if (v != null) put(key, v)
    return this
}

/**
 * JSON equality with JavaScript `===` rules for scalars (all numbers are
 * doubles, so 1 equals 1.0) and structural equality for objects and arrays.
 *
 * The TypeScript reference compares objects with JSON.stringify, which also
 * cares about key order. org.json does not keep key order, so structural
 * equality is the closest faithful rule here.
 */
internal fun jsonEquals(a: Any?, b: Any?): Boolean {
    val an = isJsonNull(a)
    val bn = isJsonNull(b)
    if (an || bn) return an && bn
    if (a is Number && b is Number) return a.toDouble() == b.toDouble()
    if (a is String && b is String) return a == b
    if (a is Boolean && b is Boolean) return a == b
    if (a is JSONObject && b is JSONObject) {
        if (a.length() != b.length()) return false
        val it = a.keys()
        while (it.hasNext()) {
            val k = it.next()
            if (!b.has(k) || !jsonEquals(a.opt(k), b.opt(k))) return false
        }
        return true
    }
    if (a is JSONArray && b is JSONArray) {
        if (a.length() != b.length()) return false
        for (i in 0 until a.length()) if (!jsonEquals(a.opt(i), b.opt(i))) return false
        return true
    }
    return false
}

/**
 * JSON.parse's grammar exactly (RFC 8259: no comments, no single quotes, no
 * bare words, no trailing text, whitespace only space, tab, CR and LF), for
 * judging request bodies. Values are Map, List, String, Double, Boolean and
 * null; a repeated key keeps its last value, as JSON.parse does. org.json is
 * lenient, and a body it accepts but a server's JSON.parse would not must not
 * be read as JSON.
 */
internal object StrictJson {
    /** What [parse] returns for text that is not JSON. */
    val INVALID = Any()

    private const val MAX_DEPTH = 1000

    private class Bad : RuntimeException(null, null, false, false)

    fun parse(text: String): Any? = try {
        val p = P(text)
        p.ws()
        val v = p.value(0)
        p.ws()
        if (p.i != text.length) INVALID else v
    } catch (e: Bad) {
        INVALID
    }

    private class P(val s: String) {
        var i = 0

        fun ws() {
            while (i < s.length && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) i++
        }

        fun value(depth: Int): Any? {
            if (depth > MAX_DEPTH || i >= s.length) throw Bad()
            return when (s[i]) {
                '{' -> obj(depth)
                '[' -> arr(depth)
                '"' -> str()
                't' -> word("true", true)
                'f' -> word("false", false)
                'n' -> word("null", null)
                else -> num()
            }
        }

        fun word(w: String, v: Any?): Any? {
            if (!s.startsWith(w, i)) throw Bad()
            i += w.length
            return v
        }

        fun obj(depth: Int): Map<String, Any?> {
            val out = LinkedHashMap<String, Any?>()
            i++
            ws()
            if (i < s.length && s[i] == '}') { i++; return out }
            while (true) {
                ws()
                if (i >= s.length || s[i] != '"') throw Bad()
                val k = str()
                ws()
                if (i >= s.length || s[i] != ':') throw Bad()
                i++
                ws()
                out[k] = value(depth + 1)
                ws()
                if (i >= s.length) throw Bad()
                when (s[i++]) {
                    ',' -> continue
                    '}' -> return out
                    else -> throw Bad()
                }
            }
        }

        fun arr(depth: Int): List<Any?> {
            val out = ArrayList<Any?>()
            i++
            ws()
            if (i < s.length && s[i] == ']') { i++; return out }
            while (true) {
                ws()
                out.add(value(depth + 1))
                ws()
                if (i >= s.length) throw Bad()
                when (s[i++]) {
                    ',' -> continue
                    ']' -> return out
                    else -> throw Bad()
                }
            }
        }

        fun str(): String {
            val sb = StringBuilder()
            i++
            while (true) {
                if (i >= s.length) throw Bad()
                val c = s[i++]
                when {
                    c == '"' -> return sb.toString()
                    c < ' ' -> throw Bad()
                    c == '\\' -> {
                        if (i >= s.length) throw Bad()
                        when (s[i++]) {
                            '"' -> sb.append('"')
                            '\\' -> sb.append('\\')
                            '/' -> sb.append('/')
                            'b' -> sb.append('\b')
                            'f' -> sb.append('\u000C')
                            'n' -> sb.append('\n')
                            'r' -> sb.append('\r')
                            't' -> sb.append('\t')
                            'u' -> {
                                if (i + 4 > s.length) throw Bad()
                                var n = 0
                                for (k in 0 until 4) {
                                    val d = Character.digit(s[i + k], 16)
                                    if (d < 0) throw Bad()
                                    n = n * 16 + d
                                }
                                i += 4
                                sb.append(n.toChar())
                            }
                            else -> throw Bad()
                        }
                    }
                    else -> sb.append(c)
                }
            }
        }

        fun num(): Double {
            val start = i
            if (i < s.length && s[i] == '-') i++
            if (i >= s.length) throw Bad()
            if (s[i] == '0') i++
            else if (s[i] in '1'..'9') while (i < s.length && s[i] in '0'..'9') i++
            else throw Bad()
            if (i < s.length && s[i] == '.') {
                i++
                if (i >= s.length || s[i] !in '0'..'9') throw Bad()
                while (i < s.length && s[i] in '0'..'9') i++
            }
            if (i < s.length && (s[i] == 'e' || s[i] == 'E')) {
                i++
                if (i < s.length && (s[i] == '+' || s[i] == '-')) i++
                if (i >= s.length || s[i] !in '0'..'9') throw Bad()
                while (i < s.length && s[i] in '0'..'9') i++
            }
            return s.substring(start, i).toDouble()
        }
    }
}
