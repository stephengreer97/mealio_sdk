package co.mealio.sdk.compose

import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.painter.Painter
import co.mealio.sdk.AddResult
import co.mealio.sdk.MealioEventListener
import co.mealio.sdk.TextTools
import co.mealio.sdk.safeListener

/** How tall the sheet is. */
sealed class MealioSheetHeight {
    /** A tall sheet that leaves the top of your app showing. */
    data object Auto : MealioSheetHeight()

    /** Fills the screen, with square top corners. */
    data object Full : MealioSheetHeight()

    /** A share of the screen. Clamped to 0.5..1 when drawn. */
    data class Fraction(val value: Float) : MealioSheetHeight()
}

/**
 * How the sheet looks and behaves.
 *
 * @param showTotal show the list total and the done screen prices. Options keep their own prices.
 * @param height [MealioSheetHeight.Auto], [MealioSheetHeight.Full] or a [MealioSheetHeight.Fraction].
 * @param logo your logo, shown at the top of the sheet.
 */
@Immutable
data class MealioSheetOptions(
    val showTotal: Boolean = true,
    val height: MealioSheetHeight = MealioSheetHeight.Auto,
    val logo: Painter? = null,
)

/**
 * A button of your own on the done screen, like "Back to meal plan". It becomes
 * the main button and Done turns quiet. Tapping it closes the sheet, then calls
 * `onClick`.
 */
data class MealioDoneAction(val label: String, val onClick: (AddResult) -> Unit)

/** The drop-in's words and prices, resolved once by [MealioThemeProvider]. */
@Immutable
class MealioUi internal constructor(
    strings: Map<String, String> = emptyMap(),
    private val formatMoney: ((Double) -> String)? = null,
    val sheet: MealioSheetOptions = MealioSheetOptions(),
    onEvent: MealioEventListener? = null,
) : TextTools(strings) {
    /** Reports a step to the partner's listener. Never throws. */
    internal val emit: MealioEventListener = safeListener(onEvent)

    /** A price as the partner wants it read. Defaults to "$12.50". */
    fun money(amount: Double): String = formatMoney?.invoke(amount) ?: defaultMoney(amount)

    /** True when the partner set formatMoney, so prices are built from numbers, not the store's text. */
    val customMoney: Boolean get() = formatMoney != null
}

/** The words, prices and sheet options the drop-in uses. Set by [MealioThemeProvider]. */
val LocalMealioUi = staticCompositionLocalOf { MealioUi() }
