package co.mealio.sdk.testing

import co.mealio.sdk.AddResult
import co.mealio.sdk.CartSession
import co.mealio.sdk.MealioClient
import co.mealio.sdk.MealioException
import co.mealio.sdk.Recipe
import co.mealio.sdk.RecipeIngredient
import kotlinx.coroutines.test.runTest
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File

// protocol/fake-script.json: one script every platform's kit loads with its
// fromJson loader and runs on a real client. Read from the repo, not copied,
// so a change to it reaches this test at once.
class FakeScriptFixtureTest {
    private fun fixture(): JSONObject {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (dir != null) {
            val f = File(dir, "protocol/fake-script.json")
            if (f.isFile) return JSONObject(f.readText())
            dir = dir.parentFile
        }
        error("protocol/fake-script.json not found above ${System.getProperty("user.dir")}")
    }

    private fun JSONArray.objs(): List<JSONObject> = (0 until length()).map { getJSONObject(it) }
    private fun JSONArray.strs(): List<String> = (0 until length()).map { getString(it) }

    @Test
    fun everyCaseRunsAsScripted() = runTest {
        val fx = fixture()
        val r = fx.getJSONObject("recipe")
        val recipe = Recipe(r.getString("id"), r.getJSONArray("ingredients").objs().map { RecipeIngredient(it.getString("name")) }, r.optString("title"))
        val cases = fx.getJSONArray("cases").objs()
        assertTrue(cases.isNotEmpty())
        for (c in cases) runCase(c.getString("name"), c, recipe)
    }

    private suspend fun runCase(name: String, c: JSONObject, recipe: Recipe) {
        val raw = c.getJSONObject("script")
        val fake = FakeMealio.fromJson(raw.toString())
        val client: MealioClient = fake.client()
        val carts = HashMap<String, CartSession>()
        for ((i, step) in c.getJSONArray("steps").objs().withIndex()) {
            val at = "$name step $i (${step.getString("do")})"
            val expect = step.opt("expect")
            val wantError = (expect as? JSONObject)?.optString("error")?.takeIf { it.isNotEmpty() }
            val cartName = step.optString("cart", "a")
            try {
                when (step.getString("do")) {
                    "prepare" -> {
                        val cart = client.prepareCart(null, recipe)
                        carts[cartName] = cart
                        if (expect is JSONObject) checkCart(at, cart, expect)
                    }
                    "search" -> {
                        val found = carts.getValue(cartName).search(step.getString("key"), step.getString("query"))
                        if (expect is JSONObject) assertEquals(at, expect.getJSONArray("options").strs(), found.map { it.id })
                    }
                    "select" -> {
                        val cart = carts.getValue(cartName)
                        cart.select(step.getString("key"), step.getString("productId"))
                        if (expect is JSONObject && expect.has("selectedId")) assertEquals(at, expect.getString("selectedId"), cart.selectedId(step.getString("key")))
                    }
                    "add" -> {
                        val cart = carts.getValue(cartName)
                        val res = cart.addToCart()
                        if (expect is JSONObject) checkAdd(at, cart, res, expect)
                    }
                    "restorePicks" -> {
                        val cart = carts.getValue(cartName)
                        cart.restorePicks(carts.getValue(step.getString("from")))
                        if (expect is JSONObject) checkCart(at, cart, expect)
                    }
                    "setScript" -> {
                        val set = step.getJSONObject("set")
                        for (k in set.keys()) if (set.isNull(k)) raw.remove(k) else raw.put(k, set.get(k))
                        fake.script = FakeScript.fromJson(raw.toString())
                    }
                    "requests" -> assertEquals(at, (expect as JSONArray).strs(), fake.requests.map { it.kind.name.lowercase() })
                    "searches" -> assertEquals(at, (expect as JSONArray).strs(),
                        fake.requests.filter { it.kind == FakeKind.SEARCH }.map { it.body!!.getString("query") })
                    else -> fail("$at: unknown step")
                }
                if (wantError != null) fail("$at: expected error $wantError")
            } catch (e: MealioException) {
                assertEquals(at, wantError, e.code)
            }
        }
    }

    private fun checkCart(at: String, cart: CartSession, e: JSONObject) {
        if (e.has("store")) assertEquals(at, e.getString("store"), cart.store)
        if (e.has("storeName")) assertEquals(at, e.getString("storeName"), cart.cart.storeName)
        if (e.has("recipes")) assertEquals(at, e.getJSONArray("recipes").objs().map { it.getString("id") to it.optString("title") },
            cart.recipes.map { it.id to it.title })
        val items = e.optJSONObject("items") ?: return
        for (key in items.keys()) {
            val want = items.getJSONObject(key)
            val item = cart.items.first { it.key == key }
            if (want.has("status")) assertEquals("$at $key", want.getString("status"), item.status.wire)
            if (want.has("selectedId")) assertEquals("$at $key", if (want.isNull("selectedId")) null else want.getString("selectedId"), cart.selectedId(key))
            if (want.has("quantity")) assertEquals("$at $key", want.getInt("quantity"), cart.quantity(key))
        }
    }

    private fun checkAdd(at: String, cart: CartSession, r: AddResult, e: JSONObject) {
        assertEquals(at, e.getJSONArray("added").strs(), r.added.map { it.key })
        assertEquals(at, e.getJSONArray("skipped").strs(), r.skipped.map { it.key })
        assertEquals(at, e.getJSONArray("failed").strs(), r.failed.map { it.key })
        if (e.has("addedTotal")) assertEquals(at, Math.round(e.getDouble("addedTotal") * 100), Math.round(cart.addedTotal(r).total!! * 100))
    }
}
