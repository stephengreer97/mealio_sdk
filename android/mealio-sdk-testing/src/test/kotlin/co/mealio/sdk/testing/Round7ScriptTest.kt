package co.mealio.sdk.testing

import co.mealio.sdk.ItemRecipe
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** 0.6 round 7, testing kits: quantities keep the value JSON.parse gives them, as in TypeScript and Dart. */
class Round7ScriptTest {
    private fun item(json: String) = fakeScriptFromJson("{\"items\":[$json]}").items.single()

    @Test fun quantitiesAreNotClampedToInt() {
        assertEquals(1.0E20, item("{\"key\":\"a\",\"quantity\":100000000000000000000}").quantity)
        // JSON.parse reads 9007199254740993 as 9007199254740992.
        assertEquals(9.007199254740992E15, item("{\"key\":\"a\",\"quantity\":9007199254740993}").quantity)
        assertEquals(4294967296L, item("{\"key\":\"a\",\"quantity\":4294967296}").quantity)
        assertEquals(-2, item("{\"key\":\"a\",\"quantity\":-2}").quantity)
        // Sent as JSON.stringify sends it.
        assertEquals("4294967296", fakeCartItem(FakeItem("a", quantity = 4294967296L)).get("quantity").toString())
        assertEquals(2L, fakeCartItem(FakeItem("a", quantity = 2.0)).get("quantity"))
        assertEquals(1.5, fakeCartItem(FakeItem("a", quantity = 1.5)).get("quantity"))
    }

    @Test fun aRecipeShareOfHalfStaysHalf() {
        val i = item("{\"key\":\"a\",\"recipes\":[{\"id\":\"r\",\"title\":null,\"quantity\":0.5}]}")
        assertEquals(0.5, i.recipes!!.single().quantity, 0.0)
        val wire = fakeCartItem(i).getJSONArray("recipes").getJSONObject(0)
        assertEquals(0.5, wire.get("quantity"))
        // And the client reads it back as 0.5.
        assertEquals(0.5, ItemRecipe.fromJson(wire).quantity, 0.0)
        assertEquals(ItemRecipe("r", null, 2), ItemRecipe.fromJson(JSONObject("{\"id\":\"r\",\"title\":null,\"quantity\":2}")))
    }

    @Test fun numbersBeyondDoubleAreAcceptedAsJsonParseAcceptsThem() {
        val i = item("{\"key\":\"a\",\"quantity\":1e400,\"weightLb\":-1e400,\"options\":[{\"id\":\"o\",\"name\":\"O\",\"unitPrice\":1e400,\"weightOptions\":[1e999,2]}]}")
        assertEquals(Double.POSITIVE_INFINITY, i.quantity)
        // Infinity goes on the wire as JSON.stringify sends it: null.
        assertTrue(fakeCartItem(i).isNull("quantity"))
        assertEquals(null, i.options.single().unitPrice)
        assertEquals(listOf(2.0), i.options.single().weightOptions)
        // A non-number is still refused.
        val e = runCatching { item("{\"key\":\"a\",\"quantity\":\"1e400\"}") }.exceptionOrNull()
        assertTrue(e?.message, e?.message?.contains("items[0].quantity") == true)
    }
}
