package co.mealio.sdk

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

// protocol/strings.json is the source of DEFAULT_STRINGS. The test reads that
// file itself rather than a copy, so a copy cannot drift and hide a difference.
class StringsTest {

    /** Gradle runs unit tests from the module directory, but walking up does not depend on that. */
    private fun protocolStrings(): JSONObject {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (dir != null) {
            val file = File(dir, "protocol/strings.json")
            if (file.isFile) return JSONObject(file.readText())
            dir = dir.parentFile
        }
        error("protocol/strings.json not found above ${System.getProperty("user.dir")}")
    }

    @Test
    fun tableMatchesProtocolStrings() {
        val source = protocolStrings()
        val keys = source.keys().asSequence().toSet()
        assertEquals(keys, DEFAULT_STRINGS.keys)
        for (key in keys) assertEquals(key, source.getString(key), DEFAULT_STRINGS[key])
    }

    @Test
    fun fillsPlaceholders() {
        assertEquals("Your H-E-B list", TextTools().tr("titleList", "store" to "H-E-B"))
        assertEquals("2 of 5 selected", TextTools().tr("selectedCount", "count" to 2, "total" to 5))
    }

    @Test
    fun anUnknownPlaceholderStaysVisible() {
        assertEquals("Your {store} list", TextTools().tr("titleList"))
        assertEquals("Hi {nmae}", fillText("Hi {nmae}", mapOf("name" to "Sam")))
    }

    @Test
    fun aMoneyValueIsFilledInLiterally() {
        assertEquals("about \$12.50", TextTools().tr("aboutPrice", "price" to "\$12.50"))
    }

    @Test
    fun pluralPicksOneOrOther() {
        val text = TextTools()
        assertEquals("1 option", text.plural("options", 1))
        assertEquals("0 options", text.plural("options", 0))
        assertEquals("3 options", text.plural("options", 3))
        assertEquals("Add 1 item to ALDI", text.plural("addItems", 1, "store" to "ALDI"))
        assertEquals("Add 2 items to ALDI", text.plural("addItems", 2, "store" to "ALDI"))
    }

    @Test
    fun overridesLayOverTheDefaults() {
        val text = TextTools(mapOf("close" to "Cerrar", "options_other" to "{count} opciones"))
        assertEquals("Cerrar", text.tr("close"))
        assertEquals("4 opciones", text.plural("options", 4))
        assertEquals("1 option", text.plural("options", 1))
        assertEquals("Done", text.tr("done"))
    }
}
