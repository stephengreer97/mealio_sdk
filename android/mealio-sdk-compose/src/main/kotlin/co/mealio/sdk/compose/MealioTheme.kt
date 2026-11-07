package co.mealio.sdk.compose

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import co.mealio.sdk.MealioEventListener
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

        /** The default dark colors, DEFAULT_DARK_THEME in the React Native SDK. */
        val Dark = MealioTheme(
            accent = Color(0xFF5FBF8F),
            onAccent = Color(0xFF0E1A14),
            background = Color(0xFF1B1B1A),
            surface = Color(0xFF2A2A28),
            text = Color(0xFFF2F1EE),
            muted = Color(0xFFB4B2AC),
            border = Color(0xFF3A3A37),
            warnBackground = Color(0xFF3B2A10),
            warnText = Color(0xFFF5C27A),
        )
    }
}

/**
 * Your colors for dark mode, laid over [MealioTheme.Dark]. Null keeps the
 * default dark color. `radius` and `fontFamily` carry over from your light
 * theme unless you set them here.
 */
@Immutable
data class MealioDarkTheme(
    val accent: Color? = null,
    val onAccent: Color? = null,
    val background: Color? = null,
    val surface: Color? = null,
    val text: Color? = null,
    val muted: Color? = null,
    val border: Color? = null,
    val radius: Dp? = null,
    val fontFamily: FontFamily? = null,
    val warnBackground: Color? = null,
    val warnText: Color? = null,
)

/** Which colors the drop-in uses. [AUTO] follows the phone. */
enum class MealioColorScheme { LIGHT, DARK, AUTO }

/**
 * The colors in force. Dark mode lays the partner's dark values over
 * [MealioTheme.Dark], and takes the shared shape (radius, font) from `light`
 * unless `dark` says otherwise.
 */
internal fun resolveTheme(light: MealioTheme, dark: MealioDarkTheme?, scheme: MealioColorScheme, phoneIsDark: Boolean): MealioTheme {
    val isDark = scheme == MealioColorScheme.DARK || (scheme == MealioColorScheme.AUTO && phoneIsDark)
    if (!isDark) return light
    val base = MealioTheme.Dark
    return MealioTheme(
        accent = dark?.accent ?: base.accent,
        onAccent = dark?.onAccent ?: base.onAccent,
        background = dark?.background ?: base.background,
        surface = dark?.surface ?: base.surface,
        text = dark?.text ?: base.text,
        muted = dark?.muted ?: base.muted,
        border = dark?.border ?: base.border,
        radius = dark?.radius ?: light.radius,
        fontFamily = dark?.fontFamily ?: light.fontFamily,
        warnBackground = dark?.warnBackground ?: base.warnBackground,
        warnText = dark?.warnText ?: base.warnText,
    )
}

/** The theme MealioCartButton and MealioCartFlow use when none is passed. */
val LocalMealioTheme = staticCompositionLocalOf { MealioTheme.Default }

/** Set the Mealio drop-in's theme for everything inside `content`. */
@Composable
fun MealioThemeProvider(theme: MealioTheme, content: @Composable () -> Unit) {
    CompositionLocalProvider(LocalMealioTheme provides theme, content = content)
}

/**
 * Set the Mealio drop-in's look for everything inside `content`.
 *
 * ```
 * MealioThemeProvider(
 *     theme = MealioTheme(accent = Color(0xFF0A5BD3)),
 *     darkTheme = MealioDarkTheme(accent = Color(0xFF7FB2FF)),
 *     colorScheme = MealioColorScheme.AUTO,
 *     strings = mapOf("addToCart" to "Add to Kroger"),
 *     formatMoney = { "%.2f EUR".format(it) },
 *     sheet = MealioSheetOptions(showTotal = false),
 *     onEvent = { analytics.track(it.type) },
 * ) { AppContent() }
 * ```
 *
 * @param darkTheme colors for dark mode. Only used when `colorScheme` is DARK, or AUTO on a phone set to dark.
 * @param colorScheme [MealioColorScheme.AUTO] follows the phone. Defaults to LIGHT.
 * @param strings change or translate any word the drop-in shows. See [co.mealio.sdk.DEFAULT_STRINGS] for the keys.
 * @param formatMoney how prices read. Defaults to "$12.50". With it set, option prices are built from
 *   the numeric `unitPrice`, not the store's text.
 * @param sheet how the sheet looks and behaves.
 * @param onEvent every step of the sheet, for your analytics. Nothing is sent to Mealio.
 */
@Composable
fun MealioThemeProvider(
    theme: MealioTheme = MealioTheme.Default,
    darkTheme: MealioDarkTheme? = null,
    colorScheme: MealioColorScheme = MealioColorScheme.LIGHT,
    strings: Map<String, String> = emptyMap(),
    formatMoney: ((Double) -> String)? = null,
    sheet: MealioSheetOptions = MealioSheetOptions(),
    onEvent: MealioEventListener? = null,
    content: @Composable () -> Unit,
) {
    val phoneIsDark = isSystemInDarkTheme()
    val resolved = remember(theme, darkTheme, colorScheme, phoneIsDark) { resolveTheme(theme, darkTheme, colorScheme, phoneIsDark) }
    // Updated state, so an inline onEvent does not rebuild everything on each render.
    val onEventNow by rememberUpdatedState(onEvent)
    val ui = remember(strings, formatMoney, sheet) { MealioUi(strings, formatMoney, sheet, onEvent = { e -> onEventNow?.invoke(e) }) }
    CompositionLocalProvider(LocalMealioTheme provides resolved, LocalMealioUi provides ui, content = content)
}

/** "$31.20" style money, two decimals. Partners replace it with `formatMoney`. */
internal fun defaultMoney(n: Double): String = "$" + String.format(Locale.US, "%.2f", n)
