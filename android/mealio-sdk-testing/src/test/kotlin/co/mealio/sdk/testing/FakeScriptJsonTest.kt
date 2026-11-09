package co.mealio.sdk.testing

import co.mealio.sdk.LoginOutcome
import co.mealio.sdk.MealioException
import co.mealio.sdk.Recipe
import co.mealio.sdk.RecipeIngredient
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

// 0.6 round 4: one script format. The JSON TypeScript's createFakeMealio and
// Swift's FakeMealio(json:) take, with the same field names.
class FakeScriptJsonTest {
    private val recipe = Recipe("r", listOf(RecipeIngredient("milk"), RecipeIngredient("salt")))

    @Test
    fun readsEveryFieldByItsTypeScriptName() {
        val s = FakeScript.fromJson("""
            {"store": "walmart", "storeName": "Walmart",
             "items": [{"key": "milk", "ingredient": "whole milk", "quantity": 2, "options": [{"id": "m1", "name": "Milk", "unitPrice": 3}],
                        "remembered": "m1", "rememberedPreferenceId": "pf", "rememberedUnavailable": true, "startUnchecked": true,
                        "weightLb": 1.5, "recipes": [{"id": "r", "title": "Tacos", "quantity": 2}], "unavailable": "not_found"}],
             "recipes": [{"id": "r", "title": null}], "warnings": [{"code": "servings_ignored", "message": "m"}],
             "search": {"Oat Milk": [{"id": "o1", "name": "Oat"}]}, "add": {"fail": {"code": "store_error", "status": 502}},
             "signIn": "cancelled", "errors": {"search": "network", "session": {"code": "nope", "message": "down"}},
             "stores": [{"id": "walmart", "name": "Walmart", "via": "device"}],
             "preferences": {"defaultStore": "walmart", "location": null},
             "locations": [{"id": "l1", "name": "Main", "address": "1 Main St", "zip": "78701"}],
             "warm": {"signedIn": false}}
        """.trimIndent())
        assertEquals("walmart" to "Walmart", s.store to s.storeName)
        val i = s.items.single()
        assertEquals(listOf("milk", "whole milk", 2, "m1", "pf", true, true, 1.5, "Tacos", "not_found"),
            listOf(i.key, i.ingredient, i.quantity, i.remembered, i.rememberedPreferenceId, i.rememberedUnavailable, i.startUnchecked, i.weightLb, i.recipes!!.single().title, i.unavailable))
        assertEquals(3.0, i.options.single().unitPrice!!, 0.0)
        assertNull(s.recipes!!.single().title)
        assertEquals("servings_ignored", s.warnings.single().code)
        assertEquals("o1", s.search.getValue("Oat Milk").single().id)
        assertEquals(FakeError("store_error", null, 502), s.addFail)
        assertEquals(LoginOutcome.CANCELLED, s.signIn)
        assertEquals(mapOf(FakeKind.SEARCH to FakeError("network"), FakeKind.SESSION to FakeError("nope", "down")), s.errors)
        assertEquals("device", s.stores!!.single().via)
        assertEquals("walmart", s.preferences!!.defaultStore)
        assertEquals("78701", s.locations.single().zip)
        assertEquals(false, s.warmSignedIn)
        // warm: null is "nothing to warm"; absent is signed in.
        assertNull(FakeScript.fromJson("""{"warm": null}""").warmSignedIn)
        assertEquals(true, FakeScript.fromJson("{}").warmSignedIn)
    }

    @Test
    fun aLoadedScriptRunsTheRealClient() = runTest {
        val fake = FakeMealio.fromJson("""
            {"items": [{"key": "milk", "options": [{"id": "m1", "name": "Milk", "unitPrice": 3}], "remembered": "m1"},
                       {"key": "salt", "options": [{"id": "s1", "name": "Salt", "unitPrice": 1}]}],
             "search": {"sea salt": [{"id": "s2", "name": "Sea salt", "unitPrice": 2}]}}
        """)
        val cart = fake.client().prepareCart("heb", recipe)
        assertEquals("m1", cart.selectedId("milk"))
        cart.search("salt", "Sea Salt")
        cart.select("salt", "s2")
        assertEquals(listOf("m1", "s2"), cart.addToCart().added.map { it.productId })
        fake.script.addFail = FakeError("store_error")
        assertEquals("store_error", (runCatching { cart.addToCart() }.exceptionOrNull() as MealioException).code)
    }

    @Test
    fun refusesWhatIsNotAScript() {
        for (bad in listOf("[]", "nope", """{"signIn": "maybe"}""", """{"errors": {"checkout": "x"}}""", """{"items": [{"options": []}]}""")) {
            assertTrue(bad, runCatching { FakeScript.fromJson(bad) }.exceptionOrNull() is IllegalArgumentException)
        }
    }

    // ── 0.6 round 5: strict at every level, as the TypeScript types ─────

    private fun refusal(json: String): String? = (runCatching { FakeScript.fromJson(json) }.exceptionOrNull() as? IllegalArgumentException)?.message

    @Test
    fun aWrongFieldDeepInTheScriptIsAnErrorNamingIt() {
        val cases = mapOf(
            """{"items": [{"key": "milk", "options": [{"id": "m1", "name": "Milk", "unitPrice": "3"}]}]}""" to "script.items[0].options[0].unitPrice",
            """{"items": [{"key": "milk", "options": [{"id": "m1", "name": "Milk", "colour": "red"}]}]}""" to "script.items[0].options[0].colour",
            """{"items": [{"key": "milk", "quantity": "2"}]}""" to "script.items[0].quantity",
            """{"items": [{"key": "milk", "recipes": [{"id": "r", "title": "T"}]}]}""" to "script.items[0].recipes[0].quantity",
            """{"items": [{"key": "milk", "extra": 1}]}""" to "script.items[0].extra",
            """{"items": [{"key": 7}]}""" to "script.items[0].key",
            """{"items": {"key": "milk"}}""" to "script.items",
            """{"search": {"oat": [{"id": "o", "name": 3}]}}""" to "script.search.oat[0].name",
            """{"search": {"oat": {"id": "o"}}}""" to "script.search.oat",
            """{"add": {"fail": "x", "retry": true}}""" to "script.add.retry",
            """{"add": {"fail": {"code": "x", "status": "502"}}}""" to "script.add.fail.status",
            """{"errors": {"search": {"message": "no code"}}}""" to "script.errors.search.code",
            """{"stores": [{"id": "heb", "name": "H-E-B", "via": "carrier pigeon"}]}""" to "script.stores[0].via",
            """{"preferences": {"defaultStore": "heb", "location": {"id": "l", "name": "n", "address": "a"}}}""" to "script.preferences.location.zip",
            """{"locations": [{"id": "l", "name": "n", "address": 1, "zip": null}]}""" to "script.locations[0].address",
            """{"warnings": [{"code": "c"}]}""" to "script.warnings[0].message",
            """{"warm": {"signedIn": "no"}}""" to "script.warm.signedIn",
            """{"warm": {"signedIn": true, "store": "heb"}}""" to "script.warm.store",
            """{"warm": true}""" to "script.warm",
            """{"store": 5}""" to "script.store",
            """{"stor": "heb"}""" to "script.stor",
        )
        for ((json, field) in cases) {
            val m = refusal(json)
            assertTrue("$json -> $m", m != null && m.contains(field))
        }
    }

    @Test
    fun trailingTextAndLenientJsonAreErrors() {
        for (bad in listOf("""{} x""", """{}{}""", """{"store": 'heb'}""", """{store: "heb"}""", """{"store": "heb",}""", """{"store": "heb"} // c""", """{"items": [1,]}""")) {
            assertTrue(bad, refusal(bad) != null)
        }
        assertEquals("heb", FakeScript.fromJson(" {\"store\": \"heb\"} \n").store)
    }

    @Test
    fun defaultsMatchTypeScript() {
        // TS: warm?.signedIn ?? true.
        assertEquals(true, FakeScript.fromJson("""{"warm": {}}""").warmSignedIn)
        assertEquals(true, FakeScript.fromJson("""{"warm": {"signedIn": null}}""").warmSignedIn)
        assertEquals(1, FakeScript.fromJson("""{"items": [{"key": "milk"}]}""").items.single().quantity)
        assertNull(FakeScript.fromJson("""{"signIn": null}""").signIn)
    }
}
