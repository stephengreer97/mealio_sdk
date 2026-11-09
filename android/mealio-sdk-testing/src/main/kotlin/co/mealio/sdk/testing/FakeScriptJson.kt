package co.mealio.sdk.testing

import co.mealio.sdk.CartRecipe
import co.mealio.sdk.CartWarning
import co.mealio.sdk.ItemRecipe
import co.mealio.sdk.LoginOutcome
import co.mealio.sdk.Product
import co.mealio.sdk.StoreInfo
import co.mealio.sdk.StoreLocation
import co.mealio.sdk.StorePreferences
import org.json.JSONArray
import org.json.JSONObject

// The one script format every kit reads: the JSON form of TypeScript's
// FakeScript (createFakeMealio), with its field names. Swift's
// FakeMealio(json:) and Dart's loader take the same text, and
// protocol/fake-script.json is a script all of them run.
//
//   {"store": "heb", "items": [{"key": "milk", "options": [{"id": "m1", "name": "Milk", "unitPrice": 3}], "remembered": "m1"}],
//    "search": {"oat milk": [{"id": "m2", "name": "Oat milk"}]}, "add": {"fail": "store_error"},
//    "signIn": "signed_in", "errors": {"search": {"code": "network", "status": 503}}, "warm": {"signedIn": false}}
//
// The function forms of `search` and `add` have no JSON form: set
// FakeScript.searchWith / FakeScript.add after loading.

/**
 * A script from its JSON text (TypeScript FakeScript field names). Throws
 * IllegalArgumentException when it is not one: text that JSON.parse would
 * refuse (trailing text included), an unknown field or a value of the wrong
 * type at any level. The message names the field. Read as JSON.parse reads
 * it: a repeated key keeps its last value.
 */
fun fakeScriptFromJson(json: String): FakeScript {
    val root = strictJsonParse(json)
    val o = root as? JSONObject ?: throw IllegalArgumentException("The fake Mealio script must be a JSON object")
    return fakeScriptFromJson(o)
}

/** As above, from a parsed object. */
fun fakeScriptFromJson(o: JSONObject): FakeScript {
    checkScript(o)
    val s = FakeScript()
    s.store = o.string("store")
    s.storeName = o.string("storeName")
    s.items = o.objects("items").map { fakeItemFromJson(it) }
    if (o.has("recipes")) s.recipes = o.objects("recipes").map { CartRecipe.fromJson(it) }
    s.warnings = o.objects("warnings").mapNotNull { CartWarning.fromJson(it) }
    (o.opt("search") as? JSONObject)?.let { m ->
        val out = LinkedHashMap<String, List<Product>>()
        for (q in m.keys()) out[q] = m.objects(q).map { Product.fromJson(it) }
        s.search = out
    }
    (o.opt("add") as? JSONObject)?.opt("fail")?.let { s.addFail = fakeErrorFromJson(it) }
    s.signIn = when (val w = o.opt("signIn")) {
        null, JSONObject.NULL -> null
        is String -> LoginOutcome.values().firstOrNull { it.wire == w } ?: throw IllegalArgumentException("signIn: unknown outcome $w")
        else -> throw IllegalArgumentException("signIn must be a string")
    }
    (o.opt("errors") as? JSONObject)?.let { m ->
        val out = LinkedHashMap<FakeKind, FakeError>()
        for (k in m.keys()) out[ERROR_KINDS.getValue(k)] = fakeErrorFromJson(m.opt(k))
        s.errors = out
    }
    if (o.has("stores")) s.stores = o.objects("stores").map { StoreInfo.fromJson(it) }
    (o.opt("preferences") as? JSONObject)?.let { s.preferences = StorePreferences.fromJson(it) }
    s.locations = o.objects("locations").map { StoreLocation.fromJson(it) }
    // Absent: signed in. null: nothing to warm. {"signedIn": b}: b, and {} is signed in (TS: warm?.signedIn ?? true).
    if (o.has("warm")) s.warmSignedIn = (o.opt("warm") as? JSONObject)?.let { it.opt("signedIn") as? Boolean ?: true }
    return s
}

/** One script line, TypeScript FakeItem field names. */
fun fakeItemFromJson(o: JSONObject): FakeItem {
    checkItem(o, "item")
    val scriptQuantity = jsNumber(o.opt("quantity"))?.toDouble() ?: 1.0
    return FakeItem(
        key = o.string("key")!!,
        options = o.objects("options").map { Product.fromJson(it) },
        remembered = o.string("remembered"),
        ingredient = o.string("ingredient"),
        // TS `quantity?: number`: the value as JSON.parse reads it, kept in
        // quantityExact (1.5, 3000000000 and 1e400, which is Infinity, are not
        // truncated, clamped or refused). A whole Int is quantity too, so
        // FakeItem(quantity = 2) equals a script's 2. The cart sends it as
        // JSON.stringify would.
        quantity = scriptQuantity.let { if (wholeInt(it)) it.toInt() else 1 },
        quantityExact = scriptQuantity,
        rememberedPreferenceId = o.string("rememberedPreferenceId"),
        rememberedUnavailable = o.opt("rememberedUnavailable") == true,
        startUnchecked = o.opt("startUnchecked") == true,
        weightLb = (o.opt("weightLb") as? Number)?.toDouble(),
        recipes = if (o.has("recipes")) o.objects("recipes").map { ItemRecipe.fromJson(it) } else null,
        unavailable = o.string("unavailable"),
    )
}

/** A FakeError: a code string, or {"code", "message"?, "status"?}. */
fun fakeErrorFromJson(v: Any?): FakeError {
    checkError(v, "error")
    return when (v) {
        is String -> FakeError(v)
        else -> (v as JSONObject).let { FakeError(it.string("code")!!, it.string("message"), (it.opt("status") as? Number)?.toDouble()?.toInt()) }
    }
}

private fun JSONObject.string(k: String): String? = opt(k) as? String

/**
 * A number JSON.parse read past Double's range (1e400 is Infinity, -1e400
 * -Infinity). org.json refuses a non-finite Number in an object or array, so
 * the parser stores this instead; it is not a Number, so readers that want a
 * finite one skip it, as the server's JSON.stringify turns it into null.
 */
internal class JsNonFinite(val value: Double) {
    override fun toString() = if (value > 0) "Infinity" else "-Infinity"
}

/** A JSON number as a Kotlin one, its value kept: Int, Long or Double, or ±Infinity for [JsNonFinite]. */
internal fun jsNumber(v: Any?): Number? = when (v) {
    is JsNonFinite -> v.value
    is Number -> v
    else -> null
}

/** A Double that is exactly an Int (not -0.0, which JSON.parse keeps). */
private fun wholeInt(d: Double): Boolean =
    d == Math.rint(d) && d >= Int.MIN_VALUE && d <= Int.MAX_VALUE && (d != 0.0 || 1.0 / d > 0)

private fun isJsNumber(v: Any?) = v is Number || v is JsNonFinite

private fun JSONObject.objects(k: String): List<JSONObject> {
    val a = opt(k) as? JSONArray ?: return emptyList()
    return (0 until a.length()).mapNotNull { a.opt(it) as? JSONObject }
}

// ── Strict checks: the TypeScript types, field by field ─────────────────

private val ERROR_KINDS = mapOf(
    "prepare" to FakeKind.PREPARE, "search" to FakeKind.SEARCH, "add" to FakeKind.ADD, "warm" to FakeKind.WARM,
    "stores" to FakeKind.STORES, "preferences" to FakeKind.PREFERENCES, "locations" to FakeKind.LOCATIONS, "session" to FakeKind.SESSION,
)

private fun bad(path: String, what: String): Nothing = throw IllegalArgumentException("The fake Mealio script: $path $what")

/** A field's value against its type. `null` is only allowed where the TypeScript type says `| null`. */
private class Fields(val o: JSONObject, val path: String, known: Set<String>, required: Set<String> = emptySet()) {
    init {
        for (k in o.keys()) if (k !in known) bad("$path.$k", "is not a known field")
        for (k in required) if (!o.has(k)) bad("$path.$k", "is required")
    }

    fun at(k: String) = "$path.$k"
    fun has(k: String) = o.has(k)
    fun isNull(k: String) = o.opt(k) == JSONObject.NULL

    fun string(k: String, nullable: Boolean = false, oneOf: Set<String>? = null) {
        if (!has(k) || (nullable && isNull(k))) return
        val v = o.opt(k) as? String ?: bad(at(k), if (nullable) "must be a string or null" else "must be a string")
        if (oneOf != null && v !in oneOf) bad(at(k), "must be one of ${oneOf.joinToString()}, not \"$v\"")
    }

    /** TS `number`: any number, fractions included. */
    fun number(k: String, nullable: Boolean = false) {
        if (!has(k) || (nullable && isNull(k))) return
        if (!isJsNumber(o.opt(k))) bad(at(k), if (nullable) "must be a number or null" else "must be a number")
    }

    fun boolean(k: String, nullable: Boolean = false) {
        if (!has(k) || (nullable && isNull(k))) return
        o.opt(k) as? Boolean ?: bad(at(k), if (nullable) "must be true, false or null" else "must be true or false")
    }

    fun obj(k: String, nullable: Boolean = false, check: (JSONObject, String) -> Unit) {
        if (!has(k) || (nullable && isNull(k))) return
        check(o.opt(k) as? JSONObject ?: bad(at(k), if (nullable) "must be an object or null" else "must be an object"), at(k))
    }

    fun list(k: String, each: (Any?, String) -> Unit) {
        if (!has(k)) return
        val a = o.opt(k) as? JSONArray ?: bad(at(k), "must be an array")
        for (i in 0 until a.length()) each(a.opt(i), "${at(k)}[$i]")
    }

    fun objects(k: String, check: (JSONObject, String) -> Unit) = list(k) { v, p -> check(v as? JSONObject ?: bad(p, "must be an object"), p) }
}

private fun checkScript(o: JSONObject) {
    val f = Fields(o, "script", setOf("store", "storeName", "items", "recipes", "warnings", "search", "add", "signIn", "errors", "stores", "preferences", "locations", "warm"))
    f.string("store")
    f.string("storeName")
    f.objects("items", ::checkItem)
    f.objects("recipes") { r, p -> Fields(r, p, setOf("id", "title"), setOf("id", "title")).run { string("id"); string("title", nullable = true) } }
    f.objects("warnings") { w, p -> Fields(w, p, setOf("code", "message"), setOf("code", "message")).run { string("code"); string("message") } }
    f.obj("search") { m, p -> val g = Fields(m, p, m.keys().asSequence().toSet()); for (q in m.keys()) g.objects(q, ::checkProduct) }
    f.obj("add") { a, p -> Fields(a, p, setOf("fail"), setOf("fail")).run { checkError(a.opt("fail"), at("fail")) } }
    f.string("signIn", nullable = true, oneOf = setOf("signed_in", "cancelled", "timeout"))
    f.obj("errors") { m, p -> Fields(m, p, ERROR_KINDS.keys); for (k in m.keys()) checkError(m.opt(k), "$p.$k") }
    f.objects("stores") { s, p -> Fields(s, p, setOf("id", "name", "via"), setOf("id", "name", "via")).run { string("id"); string("name"); string("via", oneOf = setOf("device", "kroger_api")) } }
    f.obj("preferences") { s, p ->
        Fields(s, p, setOf("defaultStore", "location"), setOf("defaultStore", "location")).run { string("defaultStore", nullable = true); obj("location", nullable = true, ::checkLocation) }
    }
    f.objects("locations", ::checkLocation)
    f.obj("warm", nullable = true) { w, p -> Fields(w, p, setOf("signedIn")).boolean("signedIn", nullable = true) }
}

private fun checkItem(o: JSONObject, path: String) {
    val f = Fields(o, path, setOf("key", "ingredient", "quantity", "options", "remembered", "rememberedPreferenceId", "rememberedUnavailable",
        "startUnchecked", "weightLb", "recipes", "unavailable"), setOf("key"))
    f.string("key")
    f.string("ingredient")
    f.number("quantity")
    f.objects("options", ::checkProduct)
    f.string("remembered", nullable = true)
    f.string("rememberedPreferenceId", nullable = true)
    f.boolean("rememberedUnavailable")
    f.boolean("startUnchecked")
    f.number("weightLb")
    f.objects("recipes") { r, p ->
        Fields(r, p, setOf("id", "title", "quantity"), setOf("id", "title", "quantity")).run { string("id"); string("title", nullable = true); number("quantity") }
    }
    f.string("unavailable")
}

private fun checkProduct(o: JSONObject, path: String) {
    val f = Fields(o, path, setOf("id", "name", "price", "imageUrl", "size", "outOfStock", "badge", "badgeLabel", "preferences", "unitPrice",
        "estimated", "maxQuantity", "soldByWeight", "weightOptions", "pricePerLb"), setOf("id", "name"))
    f.string("id")
    f.string("name")
    f.string("price", nullable = true)
    f.string("imageUrl", nullable = true)
    f.string("size", nullable = true)
    f.boolean("outOfStock")
    f.string("badge", nullable = true, oneOf = setOf("picked_before", "popular", "partner_pick"))
    f.string("badgeLabel", nullable = true)
    f.objects("preferences") { p, at -> Fields(p, at, setOf("id", "label"), setOf("id", "label")).run { string("id"); string("label") } }
    f.number("unitPrice", nullable = true)
    f.boolean("estimated")
    f.number("maxQuantity", nullable = true)
    f.boolean("soldByWeight")
    f.list("weightOptions") { v, at -> if (!isJsNumber(v)) bad(at, "must be a number") }
    f.number("pricePerLb", nullable = true)
}

private fun checkLocation(o: JSONObject, path: String) {
    Fields(o, path, setOf("id", "name", "address", "zip"), setOf("id", "name", "address", "zip")).run {
        string("id"); string("name"); string("address"); string("zip", nullable = true)
    }
}

private fun checkError(v: Any?, path: String) {
    if (v is String) return
    val o = v as? JSONObject ?: bad(path, "must be a code or {code, message?, status?}")
    Fields(o, path, setOf("code", "message", "status"), setOf("code")).run { string("code"); string("message"); number("status") }
}

/**
 * JSON.parse, building org.json values: its grammar exactly (org.json's
 * tokener takes single quotes, bare words, comments and text after the
 * value), a repeated key keeps its last value (the tokener throws), and a
 * number is read as JSON.parse reads it, a double: a whole one that fits an
 * Int or Long comes back as one (3000000000 is a Long, never wrapped), any
 * other as a Double.
 */
internal fun strictJsonParse(s: String): Any {
    var i = 0
    fun fail(what: String): Nothing = throw IllegalArgumentException("The fake Mealio script is not JSON: $what at offset $i")
    fun ws() { while (i < s.length && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) i++ }
    fun str(): String {
        val sb = StringBuilder()
        i++
        while (true) {
            if (i >= s.length) fail("unterminated string")
            val c = s[i++]
            if (c == '"') return sb.toString()
            if (c < ' ') fail("control character in a string")
            if (c != '\\') { sb.append(c); continue }
            if (i >= s.length) fail("unterminated string")
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
                    if (i + 4 > s.length || (0 until 4).any { s[i + it] !in "0123456789abcdefABCDEF" }) fail("bad \\u escape")
                    sb.append(s.substring(i, i + 4).toInt(16).toChar())
                    i += 4
                }
                else -> fail("bad escape")
            }
        }
    }
    fun digits() { if (i >= s.length || s[i] !in '0'..'9') fail("expected a digit"); while (i < s.length && s[i] in '0'..'9') i++ }
    fun number(): Any {
        val start = i
        if (s[i] == '-') i++
        if (i < s.length && s[i] == '0') i++ else digits()
        if (i < s.length && s[i] == '.') { i++; digits() }
        if (i < s.length && (s[i] == 'e' || s[i] == 'E')) { i++; if (i < s.length && (s[i] == '+' || s[i] == '-')) i++; digits() }
        val d = s.substring(start, i).toDouble()
        // JSON.parse reads 1e400 as Infinity; so does this.
        if (d.isInfinite()) return JsNonFinite(d)
        if (d != Math.rint(d) || Math.abs(d) >= 9.007199254740992E15 || (d == 0.0 && 1.0 / d < 0)) return d
        val l = d.toLong()
        return if (l in Int.MIN_VALUE..Int.MAX_VALUE) l.toInt() else l
    }
    fun value(depth: Int): Any {
        if (depth > 512) fail("nested too deep")
        ws()
        if (i >= s.length) fail("expected a value")
        return when (val c = s[i]) {
            '{' -> {
                val o = JSONObject()
                i++; ws()
                if (i < s.length && s[i] == '}') { i++; return o }
                while (true) {
                    ws()
                    if (i >= s.length || s[i] != '"') fail("expected a quoted key")
                    val k = str(); ws()
                    if (i >= s.length || s[i] != ':') fail("expected ':'")
                    i++
                    o.put(k, value(depth + 1)); ws()
                    if (i < s.length && s[i] == ',') { i++; continue }
                    if (i < s.length && s[i] == '}') { i++; return o }
                    fail("expected ',' or '}'")
                }
            }
            '[' -> {
                val a = JSONArray()
                i++; ws()
                if (i < s.length && s[i] == ']') { i++; return a }
                while (true) {
                    a.put(value(depth + 1)); ws()
                    if (i < s.length && s[i] == ',') { i++; continue }
                    if (i < s.length && s[i] == ']') { i++; return a }
                    fail("expected ',' or ']'")
                }
            }
            '"' -> str()
            't', 'f', 'n' -> {
                val w = when (c) { 't' -> "true"; 'f' -> "false"; else -> "null" }
                if (!s.startsWith(w, i)) fail("unexpected text")
                i += w.length
                when (c) { 't' -> true; 'f' -> false; else -> JSONObject.NULL }
            }
            '-', in '0'..'9' -> number()
            else -> fail("unexpected text")
        }
    }
    val v = value(0)
    ws()
    if (i != s.length) fail("trailing text")
    return v
}
