package co.mealio.sdk

import org.json.JSONException
import org.json.JSONObject

// PROTOCOL.md "Matcher". Port of packages/core/src/matcher.ts.

/** Parse one posted message. Anything that is not a JSON object is dropped (null). */
fun parseMessage(raw: String?): JSONObject? {
    if (raw == null) return null
    return try {
        parseJson(raw) as? JSONObject
    } catch (e: JSONException) {
        null
    }
}

/** `a` is the message's value, `present` says whether the message has the field at all. */
private fun same(present: Boolean, a: Any?, b: Any?): Boolean {
    // A missing field is never equal to anything (so it is always "not equal").
    if (!present) return false
    return jsonEquals(a, b)
}

/**
 * A message matches when `msg.type` is the matcher's type, every `eq` field is
 * equal, and every `ne` field is not equal (a missing field counts as not equal).
 */
fun matches(msg: JSONObject, m: Matcher): Boolean {
    val type = msg.opt("type")
    if (type !is String || type != m.type) return false
    for ((k, v) in m.eq) if (!same(msg.has(k), msg.opt(k), v)) return false
    for ((k, v) in m.ne) if (same(msg.has(k), msg.opt(k), v)) return false
    return true
}

fun matchesAny(msg: JSONObject, list: List<Matcher>): Boolean = list.any { matches(msg, it) }
