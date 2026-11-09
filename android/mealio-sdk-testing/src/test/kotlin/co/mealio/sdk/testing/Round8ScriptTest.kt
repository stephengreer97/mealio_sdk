package co.mealio.sdk.testing

import co.mealio.sdk.ItemRecipe
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/** 0.6 round 8, compatibility: FakeItem.quantity is an Int again; the exact number is quantityExact. */
class Round8ScriptTest {
    private fun item(json: String) = fakeScriptFromJson("{\"items\":[$json]}").items.single()

    @Test fun aScriptItemEqualsTheFakeItemWrittenByHand() {
        assertEquals(FakeItem("a", quantity = 2), item("{\"key\":\"a\",\"quantity\":2}"))
        assertEquals(FakeItem("a", quantity = 2), item("{\"key\":\"a\",\"quantity\":2.0}"))
        assertEquals(FakeItem("a"), item("{\"key\":\"a\"}"))
        assertEquals(FakeItem("a", quantityExact = 1.5), item("{\"key\":\"a\",\"quantity\":1.5}"))
        assertEquals(FakeItem("a", quantityExact = 3.0e9), item("{\"key\":\"a\",\"quantity\":3000000000}"))
        assertNotEquals(FakeItem("a", quantity = 3), item("{\"key\":\"a\",\"quantity\":2}"))
    }

    @Test fun recipeSharesKeepTheExactNumberAndTheWholeQuantity() {
        val r = item("{\"key\":\"a\",\"recipes\":[{\"id\":\"r\",\"title\":null,\"quantity\":0.5},{\"id\":\"s\",\"title\":\"S\",\"quantity\":2}]}").recipes!!
        assertEquals(ItemRecipe("r", null, 0, 0.5), r[0])
        assertEquals(0, r[0].quantity)
        assertEquals(ItemRecipe("s", "S", 2), r[1])
        assertEquals(2.0, r[1].share, 0.0)
        // A recipe the kit sends is read back the same.
        val wire = fakeCartItem(FakeItem("a", recipes = r)).getJSONArray("recipes")
        assertEquals(r, (0 until wire.length()).map { ItemRecipe.fromJson(wire.getJSONObject(it)) })
        assertEquals(0.5, wire.getJSONObject(0).get("quantity"))
        assertEquals(2L, (wire.getJSONObject(1).get("quantity") as Number).toLong())
        // fromJson without a quantity: 1, as 0.5.0.
        assertEquals(ItemRecipe("x"), ItemRecipe.fromJson(JSONObject("{\"id\":\"x\"}")))
    }
}
