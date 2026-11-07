package co.mealio.sdk

// What happens in the drop-in sheet, for a partner's analytics. Set `onEvent`
// once and every step arrives here. Nothing is sent to Mealio. Port of
// packages/core/src/events.ts.

/** One step of the sheet. [type] is the same name on every Mealio SDK, e.g. "sheet_opened". */
sealed class MealioEvent(val type: String) {
    data class SheetOpened(val recipes: Int) : MealioEvent("sheet_opened")
    data class StorePicked(val store: String) : MealioEvent("store_picked")
    data class LocationAsked(val store: String) : MealioEvent("location_asked")
    data class SigninShown(val store: String?) : MealioEvent("signin_shown")
    data class ListShown(val store: String, val items: Int) : MealioEvent("list_shown")
    data class ItemUnchecked(val key: String) : MealioEvent("item_unchecked")
    data class ItemChecked(val key: String) : MealioEvent("item_checked")
    data class AddStarted(val items: Int) : MealioEvent("add_started")
    data class CartAdded(val store: String, val added: Int, val failed: Int) : MealioEvent("cart_added")
    data class Error(val code: String, val step: MealioSheetStep) : MealioEvent("error")

    /** `step` is where they left, so a count per step shows where people drop off. */
    data class SheetClosed(val step: MealioSheetStep, val added: Int) : MealioEvent("sheet_closed")
}

enum class MealioSheetStep(val wire: String) {
    LOADING("loading"),
    STORES("stores"),
    LOCATION("location"),
    SIGNIN("signin"),
    LIST("list"),
    ADDING("adding"),
    DONE("done"),
    ERROR("error"),
}

typealias MealioEventListener = (MealioEvent) -> Unit

/**
 * A partner's listener never breaks the sheet. Throwable, not Exception: a
 * Kotlin `TODO()` left in a listener is an Error.
 */
fun safeListener(fn: MealioEventListener? = null): MealioEventListener = { event ->
    try {
        fn?.invoke(event)
    } catch (e: Throwable) {
        // Their code, their log.
    }
}
