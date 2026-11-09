package co.mealio.sdk.testing

import org.junit.Assert.assertEquals
import org.junit.Test

/** 0.6 round 6, item 4: scripts read as JSON.parse reads them, field types as TS FakeScript's. */
class Round6ScriptTest {
    @Test fun aRepeatedKeyKeepsItsLastValue() {
        val s = fakeScriptFromJson("{\"store\":\"heb\",\"store\":\"kroger\",\"items\":[{\"key\":\"a\",\"key\":\"b\"}]}")
        assertEquals("kroger", s.store)
        assertEquals("b", s.items.single().key)
    }

    @Test fun largeIntegersAreNotWrapped() {
        val s = fakeScriptFromJson("{\"items\":[{\"key\":\"a\",\"quantity\":3000000000}],\"add\":{\"fail\":{\"code\":\"x\",\"status\":4294967799}}}")
        assertEquals(Int.MAX_VALUE, s.items.single().quantity)
        assertEquals(Int.MAX_VALUE, s.addFail?.status)
    }

    @Test fun fractionalNumbersAreAcceptedWhereTsSaysNumber() {
        val s = fakeScriptFromJson(
            "{\"items\":[{\"key\":\"a\",\"quantity\":1.5,\"recipes\":[{\"id\":\"r\",\"title\":null,\"quantity\":0.5}]," +
                "\"options\":[{\"id\":\"p\",\"name\":\"P\",\"maxQuantity\":2.5}]}],\"errors\":{\"search\":{\"code\":\"n\",\"status\":503.5}}}",
        )
        assertEquals(1, s.items.single().quantity)
        assertEquals(503, s.errors[FakeKind.SEARCH]?.status)
        // Exponent forms and -0 too.
        assertEquals(2, fakeScriptFromJson("{\"items\":[{\"key\":\"a\",\"quantity\":2e0}]}").items.single().quantity)
        assertEquals(0, fakeScriptFromJson("{\"items\":[{\"key\":\"a\",\"quantity\":-0}]}").items.single().quantity)
    }
}
