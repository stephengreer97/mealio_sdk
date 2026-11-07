package co.mealio.sdk

import org.junit.Assert.assertEquals
import org.junit.Test

class EventsTest {
    private val opened = MealioEvent.SheetOpened(1)

    @Test
    fun passesEventsOn() {
        val got = mutableListOf<MealioEvent>()
        safeListener { got.add(it) }.invoke(opened)
        assertEquals(listOf<MealioEvent>(opened), got)
    }

    @Test
    fun survivesAListenerThatThrows() {
        safeListener { throw IllegalStateException("boom") }.invoke(opened)
    }

    @Test
    fun survivesAListenerThatThrowsAnError() {
        safeListener { throw NotImplementedError() }.invoke(opened)
    }

    @Test
    fun survivesNoListener() {
        safeListener().invoke(opened)
        safeListener(null).invoke(opened)
    }

    @Test
    fun keepsDeliveringAfterAThrow() {
        var calls = 0
        val emit = safeListener {
            calls += 1
            throw IllegalStateException("boom")
        }
        emit(opened)
        emit(opened)
        assertEquals(2, calls)
    }

    /** The names in packages/core/src/events.ts. Partners log these, so they cannot drift. */
    @Test
    fun eventNamesMatchTheOtherSdks() {
        val events = listOf(
            opened,
            MealioEvent.StorePicked("heb"),
            MealioEvent.LocationAsked("kroger"),
            MealioEvent.SigninShown(null),
            MealioEvent.ListShown("heb", 3),
            MealioEvent.ItemUnchecked("k"),
            MealioEvent.ItemChecked("k"),
            MealioEvent.AddStarted(3),
            MealioEvent.CartAdded("heb", 2, 1),
            MealioEvent.Error("blocked", MealioSheetStep.ADDING),
            MealioEvent.SheetClosed(MealioSheetStep.LIST, 0),
        )
        assertEquals(
            listOf(
                "sheet_opened", "store_picked", "location_asked", "signin_shown", "list_shown", "item_unchecked",
                "item_checked", "add_started", "cart_added", "error", "sheet_closed",
            ),
            events.map { it.type },
        )
    }

    @Test
    fun stepNamesMatchTheOtherSdks() {
        assertEquals(
            listOf("loading", "stores", "location", "signin", "list", "adding", "done", "error"),
            MealioSheetStep.values().map { it.wire },
        )
    }
}
