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
 *
 * Like JSON.parse it has no nesting limit of its own: containers are kept on
 * a heap stack, not the call stack, so a body nested a few thousand deep is
 * read as JSON and judged as JSON. A `\u` escape takes ASCII hex digits only,
 * and a lone surrogate (escaped or raw) is kept as it is.
 *
 * With [parse]'s `keep`, a container nested deeper than `keep` (the top value
 * is depth 1) is still read for its grammar but never built: it comes back
 * empty. Messages from the page are read that way (PROTOCOL.md, depth 512).
 */
internal object StrictJson {
    /** What [parse] returns for text that is not JSON. */
    val INVALID = Any()

    private class Bad : RuntimeException(null, null, false, false)

    /** An open container past the depth limit: read, never filled. */
    private class Skipped(val isMap: Boolean)

    private val SKIP_MAP = Skipped(true)
    private val SKIP_LIST = Skipped(false)

    fun parse(text: String, keep: Int = Int.MAX_VALUE): Any? = try {
        P(if (keep == Int.MAX_VALUE) text else blankDeep(text, keep), keep).run()
    } catch (e: Bad) {
        INVALID
    }

    /**
     * packages/core/src/matcher.ts parseJson's first pass, exactly: every
     * container deeper than `keep` is replaced by an empty one of its own
     * kind, found by bracket and string matching alone. What is inside it is
     * never read for its grammar (mismatched brackets, `1,,` and all), so a
     * message TS accepts is accepted here too. The grammar check that follows
     * reads the rest.
     */
    internal fun blankDeep(text: String, keep: Int): String {
        var out: StringBuilder? = null
        var last = 0
        var depth = 0
        var inString = false
        var i = 0
        val n = text.length
        while (i < n) {
            val c = text[i]
            if (inString) {
                if (c == '\\') i++ else if (c == '"') inString = false
                i++
                continue
            }
            if (c == '"') { inString = true; i++; continue }
            if (c == '[' || c == '{') {
                depth++
                if (depth <= keep) { i++; continue }
                // Too deep: find where this container closes, and keep it empty.
                var d = 1
                var str = false
                var j = i + 1
                while (j < n && d > 0) {
                    val k = text[j]
                    if (str) {
                        if (k == '\\') j++ else if (k == '"') str = false
                    } else if (k == '"') str = true
                    else if (k == '[' || k == '{') d++
                    else if (k == ']' || k == '}') d--
                    j++
                }
                if (d > 0) break // never closes: not JSON, and the grammar check says so
                val sb = out ?: StringBuilder(n).also { out = it }
                sb.append(text, last, i).append(if (c == '[') "[]" else "{}")
                last = j
                i = j
                depth--
                continue
            }
            if (c == ']' || c == '}') depth--
            i++
        }
        val sb = out ?: return text
        return sb.append(text, last, n).toString()
    }

    private class P(val s: String, val keep: Int) {
        var i = 0

        fun isMap(c: Any) = c is LinkedHashMap<*, *> || (c is Skipped && c.isMap)

        fun ws() {
            while (i < s.length && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) i++
        }

        fun word(w: String, v: Any?): Any? {
            if (!s.startsWith(w, i)) throw Bad()
            i += w.length
            return v
        }

        /** At a key: the key, the colon, and the space before its value. */
        fun key(): String {
            if (i >= s.length || s[i] != '"') throw Bad()
            val k = str()
            ws()
            if (i >= s.length || s[i] != ':') throw Bad()
            i++
            ws()
            return k
        }

        fun run(): Any? {
            // Open containers, innermost last, and for an object the key its next value goes under.
            val open = ArrayList<Any>()
            val keys = ArrayList<String?>()
            ws()
            value@ while (true) {
                if (i >= s.length) throw Bad()
                var v: Any? = when (s[i]) {
                    '{' -> {
                        i++
                        ws()
                        if (i < s.length && s[i] == '}') { i++; LinkedHashMap<String, Any?>() } else {
                            open.add(if (open.size >= keep) SKIP_MAP else LinkedHashMap<String, Any?>())
                            keys.add(key())
                            continue@value
                        }
                    }
                    '[' -> {
                        i++
                        ws()
                        if (i < s.length && s[i] == ']') { i++; ArrayList<Any?>() } else {
                            open.add(if (open.size >= keep) SKIP_LIST else ArrayList<Any?>())
                            keys.add(null)
                            continue@value
                        }
                    }
                    '"' -> str()
                    't' -> word("true", true)
                    'f' -> word("false", false)
                    'n' -> word("null", null)
                    else -> num()
                }
                // A whole value: put it in its container, then close what ends here.
                while (true) {
                    if (open.isEmpty()) {
                        ws()
                        if (i != s.length) throw Bad()
                        return v
                    }
                    val top = open[open.size - 1]
                    @Suppress("UNCHECKED_CAST")
                    if (top is LinkedHashMap<*, *>) (top as MutableMap<String, Any?>)[keys[keys.size - 1]!!] = v
                    else if (top is ArrayList<*>) (top as MutableList<Any?>).add(v)
                    ws()
                    if (i >= s.length) throw Bad()
                    val c = s[i++]
                    if (c == ',') {
                        ws()
                        if (isMap(top)) keys[keys.size - 1] = key()
                        continue@value
                    }
                    if (c != (if (isMap(top)) '}' else ']')) throw Bad()
                    open.removeAt(open.size - 1)
                    keys.removeAt(keys.size - 1)
                    // The first container past the limit lands empty; those inside it are dropped with it.
                    v = if (top is Skipped) (if (top.isMap) LinkedHashMap<String, Any?>() else ArrayList<Any?>()) else top
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
                                    val d = hex(s[i + k])
                                    if (d < 0) throw Bad()
                                    n = n * 16 + d
                                }
                                i += 4
                                // A lone surrogate stays, as JSON.parse keeps it.
                                sb.append(n.toChar())
                            }
                            else -> throw Bad()
                        }
                    }
                    else -> sb.append(c)
                }
            }
        }

        /** ASCII hex only: Character.digit also takes fullwidth and other Unicode digits. */
        fun hex(c: Char): Int = when (c) {
            in '0'..'9' -> c - '0'
            in 'a'..'f' -> c - 'a' + 10
            in 'A'..'F' -> c - 'A' + 10
            else -> -1
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
