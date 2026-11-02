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
