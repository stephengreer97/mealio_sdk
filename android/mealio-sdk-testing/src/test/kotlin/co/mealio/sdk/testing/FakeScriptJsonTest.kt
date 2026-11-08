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
}
