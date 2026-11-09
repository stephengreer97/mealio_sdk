package co.mealio.sdk

import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

// PROTOCOL.md "Matcher". Port of packages/core/src/matcher.ts.

/** The deepest container a message from the page builds. Deeper ones come back empty. */
internal const val MESSAGE_DEPTH = 512

/**
 * Parse one posted message, as JSON.parse reads it. Anything that is not a
 * JSON object is dropped (null). A container nested deeper than
 * [MESSAGE_DEPTH] is kept empty, never built: org.json's tokener recursed once
 * per level, so a page could post a message deep enough to overflow the stack.
 */
fun parseMessage(raw: String?): JSONObject? {
    if (raw == null) return null
    val v = StrictJson.parse(raw, MESSAGE_DEPTH)
    if (v !is Map<*, *>) return null
    return try {
        toOrgJson(v) as JSONObject
    } catch (e: JSONException) {
        null
    }
}

/** A StrictJson value as org.json values. Recursion is bounded by the depth limit. */
private fun toOrgJson(v: Any?): Any = when (v) {
    null -> JSONObject.NULL
    is Map<*, *> -> JSONObject().also { o -> for ((k, x) in v) o.put(k as String, toOrgJson(x)) }
    is List<*> -> JSONArray().also { a -> for (x in v) a.put(toOrgJson(x)) }
    // A number JSON.parse reads as Infinity (1e400) cannot go into org.json. The
    // message is kept, as TS and Dart keep it, with the value as null: what
    // JSON.stringify sends the server for it. (Unlike TS, a matcher comparing
    // that field to null at the top level sees it as equal.)
    is Double -> if (v.isInfinite()) JSONObject.NULL
    // A whole number reads back as Int or Long, as org.json's tokener gave it.
    else if (v == Math.rint(v) && !v.isInfinite() && Math.abs(v) < 9.007199254740992E15 && !(v == 0.0 && 1.0 / v < 0)) {
        val l = v.toLong()
        if (l in Int.MIN_VALUE..Int.MAX_VALUE) l.toInt() else l
    } else v
    else -> v
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
