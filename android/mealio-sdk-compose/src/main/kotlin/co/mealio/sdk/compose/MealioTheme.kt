package co.mealio.sdk.compose

import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import java.util.Locale

/**
 * The drop-in's look. Partners match their brand with a handful of values;
 * everything else follows from them. Same values and defaults as the React
 * Native SDK's theme.ts.
 */
@Immutable
data class MealioTheme(
    /** Buttons, checkmarks, selected rings. */
    val accent: Color = Color(0xFF1F6B47),
    /** Text on the accent color. */
    val onAccent: Color = Color(0xFFFFFFFF),
    /** Sheet background. */
    val background: Color = Color(0xFFFFFFFF),
    /** Page behind cards, search box, thumbnails. */
    val surface: Color = Color(0xFFF2F1EE),
    val text: Color = Color(0xFF1B1B1A),
    /** Secondary text. Keep 4.5:1 against background. */
    val muted: Color = Color(0xFF5F5D58),
    val border: Color = Color(0xFFE4E2DD),
    /** Corner radius of cards and buttons. */
    val radius: Dp = 14.dp,
    /** Font family for every text, or null for the system font. */
    val fontFamily: FontFamily? = null,
    /** Out-of-stock warning colors. */
    val warnBackground: Color = Color(0xFFFFF4E5),
    val warnText: Color = Color(0xFF7A4A06),
) {
    companion object {
        val Default = MealioTheme()
    }
}

/** The theme MealioCartButton and MealioCartFlow use when none is passed. */
val LocalMealioTheme = staticCompositionLocalOf { MealioTheme.Default }

/** Set the Mealio drop-in's theme for everything inside `content`. */
@Composable
fun MealioThemeProvider(theme: MealioTheme, content: @Composable () -> Unit) {
    CompositionLocalProvider(LocalMealioTheme provides theme, content = content)
}

/** "$31.20" style money, two decimals. */
internal fun money(n: Double): String = "$" + String.format(Locale.US, "%.2f", n)
