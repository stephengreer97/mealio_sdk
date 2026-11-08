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
import org.json.JSONTokener

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

/** A script from its JSON text (TypeScript FakeScript field names). Throws IllegalArgumentException when it is not one. */
fun fakeScriptFromJson(json: String): FakeScript {
    val root = try {
        JSONTokener(json).nextValue()
    } catch (e: Exception) {
        throw IllegalArgumentException("The fake Mealio script is not JSON", e)
    }
    val o = root as? JSONObject ?: throw IllegalArgumentException("The fake Mealio script must be a JSON object")
    return fakeScriptFromJson(o)
}

/** As above, from a parsed object. */
fun fakeScriptFromJson(o: JSONObject): FakeScript {
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
        for (k in m.keys()) {
            val kind = FakeKind.values().firstOrNull { it.name.equals(k, ignoreCase = true) }
                ?: throw IllegalArgumentException("errors: unknown kind $k")
            out[kind] = fakeErrorFromJson(m.opt(k))
        }
        s.errors = out
    }
    if (o.has("stores")) s.stores = o.objects("stores").map { StoreInfo.fromJson(it) }
    (o.opt("preferences") as? JSONObject)?.let { s.preferences = StorePreferences.fromJson(it) }
    s.locations = o.objects("locations").map { StoreLocation.fromJson(it) }
    // Absent: signed in. null: nothing to warm. {"signedIn": b}: b.
    if (o.has("warm")) s.warmSignedIn = (o.opt("warm") as? JSONObject)?.let { it.opt("signedIn") as? Boolean ?: true }
    return s
}

/** One script line, TypeScript FakeItem field names. */
fun fakeItemFromJson(o: JSONObject): FakeItem = FakeItem(
    key = o.string("key") ?: throw IllegalArgumentException("items: a line has no key"),
    options = o.objects("options").map { Product.fromJson(it) },
    remembered = o.string("remembered"),
    ingredient = o.string("ingredient"),
    quantity = (o.opt("quantity") as? Number)?.toInt() ?: 1,
    rememberedPreferenceId = o.string("rememberedPreferenceId"),
    rememberedUnavailable = o.opt("rememberedUnavailable") == true,
    startUnchecked = o.opt("startUnchecked") == true,
    weightLb = (o.opt("weightLb") as? Number)?.toDouble(),
    recipes = if (o.has("recipes")) o.objects("recipes").map { ItemRecipe.fromJson(it) } else null,
    unavailable = o.string("unavailable"),
)

/** A FakeError: a code string, or {"code", "message"?, "status"?}. */
fun fakeErrorFromJson(v: Any?): FakeError = when (v) {
    is String -> FakeError(v)
    is JSONObject -> FakeError(
        v.string("code") ?: throw IllegalArgumentException("an error has no code"),
        v.string("message"),
        (v.opt("status") as? Number)?.toInt(),
    )
    else -> throw IllegalArgumentException("an error must be a code or an object")
}

private fun JSONObject.string(k: String): String? = opt(k) as? String

private fun JSONObject.objects(k: String): List<JSONObject> {
    val a = opt(k) as? JSONArray ?: return emptyList()
    return (0 until a.length()).mapNotNull { a.opt(it) as? JSONObject }
}
