package co.mealio.sdk.compose

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import co.mealio.sdk.AddResult
import co.mealio.sdk.MealioCart
import co.mealio.sdk.Recipe

/** The button's look: [SOLID] (the default), [OUTLINE], [COMPACT] for a recipe card, or [ICON], a round cart button. */
enum class MealioButtonVariant { SOLID, OUTLINE, COMPACT, ICON }

/**
 * The one-composable integration: a themed button that runs the whole
 * add-to-cart flow in one sheet over your app.
 *
 * ```
 * MealioCartButton(recipe = recipe, store = "heb")
 * // Several meals in one cart:
 * MealioCartButton(recipes = listOf(tacos, pasta), store = "heb")
 * ```
 *
 * @param store store id, e.g. "heb". Optional: without it the user's default
 *   store is used, or they pick one in the sheet.
 * @param zip 5-digit zip, if you know it. Fills the zip box when a Kroger family
 *   store asks the user which store they shop at.
 * @param label defaults to the `addToCart` string, or `addToCartShort` on a compact button.
 * @param onClose called when the sheet closes; `result` is null when nothing was added.
 * @param variant how the button looks.
 * @param button draw your own button. It keeps the whole flow and the warm-up:
 *   call `onClick` when it is tapped.
 * @param doneMessage a line of your own on the done screen.
 * @param doneAction a button of your own on the done screen. Tapping it closes the sheet.
 * @param onSignInRequired called on tap while [MealioCart.setUser] says nobody is
 *   signed in. Send the user to your sign-in. Without it (or
 *   MealioCart.onSignInRequired) the button is disabled then.
 */
@Composable
fun MealioCartButton(
    recipe: Recipe,
    store: String? = null,
    zip: String? = null,
    label: String? = null,
    onAdded: (AddResult) -> Unit = {},
    onClose: (AddResult?) -> Unit = {},
    onError: (Exception) -> Unit = {},
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    theme: MealioTheme = LocalMealioTheme.current,
    variant: MealioButtonVariant = MealioButtonVariant.SOLID,
    button: (@Composable (onClick: () -> Unit, enabled: Boolean, label: String) -> Unit)? = null,
    doneMessage: String? = null,
    doneAction: MealioDoneAction? = null,
    onSignInRequired: (() -> Unit)? = null,
) {
    val recipes = remember(recipe) { listOf(recipe) }
    MealioCartButton(recipes, store, zip, label, onAdded, onClose, onError, modifier, enabled, theme, variant, button, doneMessage, doneAction, onSignInRequired)
}

/** The button for several recipes in one cart, at most MAX_RECIPES. */
@Composable
fun MealioCartButton(
    recipes: List<Recipe>,
    store: String? = null,
    zip: String? = null,
    label: String? = null,
    onAdded: (AddResult) -> Unit = {},
    onClose: (AddResult?) -> Unit = {},
    onError: (Exception) -> Unit = {},
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    theme: MealioTheme = LocalMealioTheme.current,
    variant: MealioButtonVariant = MealioButtonVariant.SOLID,
    button: (@Composable (onClick: () -> Unit, enabled: Boolean, label: String) -> Unit)? = null,
    doneMessage: String? = null,
    doneAction: MealioDoneAction? = null,
    onSignInRequired: (() -> Unit)? = null,
) {
    val ui = LocalMealioUi.current
    var open by rememberSaveable { mutableStateOf(false) }
    val user by MealioCart.user.collectAsState()
    val tap = buttonTap(user.signedIn, enabled, onSignInRequired ?: MealioCart.onSignInRequired)
    val on = tap != ButtonTap.OFF
    // WARM THE LOGIN CHECK while the user reads the recipe. Only for a known
    // user with a store on file: the server answers "nothing to warm"
    // otherwise. The client runs it at most once every few minutes. Also when
    // the button turns on, or a new user signs in.
    LaunchedEffect(store, on, user) {
        if (on && user.signedIn) MealioCart.warm(store)
    }
    val text = label?.takeIf { it.isNotEmpty() }
        ?: ui.tr(if (variant == MealioButtonVariant.COMPACT) "addToCartShort" else "addToCart")
    val signIn by rememberUpdatedState(onSignInRequired ?: MealioCart.onSignInRequired)
    val onClick: () -> Unit = {
        // Read at tap time: the user may have changed since the last draw.
        when (buttonTap(MealioCart.user.value.signedIn, enabled, signIn)) {
            ButtonTap.OPEN -> open = true
            ButtonTap.SIGN_IN -> signIn?.invoke()
            ButtonTap.OFF -> Unit
        }
    }
    if (button != null) {
        button(onClick, on, text)
    } else {
        DrawnButton(theme, variant, text, on, onClick, modifier)
    }
    MealioCartFlow(
        visible = open,
        recipes = recipes,
        store = store,
        zip = zip,
        onAdded = onAdded,
        onError = onError,
        onClose = { r -> open = false; onClose(r) },
        theme = theme,
        doneMessage = doneMessage,
        doneAction = doneAction,
    )
}

internal enum class ButtonTap { OPEN, SIGN_IN, OFF }

/** What a tap does: open the sheet, ask the app to sign the user in, or nothing (disabled). */
internal fun buttonTap(signedIn: Boolean, enabled: Boolean, onSignInRequired: (() -> Unit)?): ButtonTap = when {
    !enabled -> ButtonTap.OFF
    signedIn -> ButtonTap.OPEN
    onSignInRequired != null -> ButtonTap.SIGN_IN
    else -> ButtonTap.OFF
}

@Composable
private fun DrawnButton(t: MealioTheme, variant: MealioButtonVariant, label: String, enabled: Boolean, onClick: () -> Unit, modifier: Modifier) {
    val shape = if (variant == MealioButtonVariant.ICON) CircleShape else RoundedCornerShape(t.radius)
    val outline = variant == MealioButtonVariant.OUTLINE
    val size = when (variant) {
        MealioButtonVariant.COMPACT -> Modifier.heightIn(min = 36.dp)
        MealioButtonVariant.ICON -> Modifier.size(48.dp)
        else -> Modifier.heightIn(min = 52.dp)
    }
    val sidePadding = when (variant) {
        MealioButtonVariant.COMPACT -> 12.dp
        MealioButtonVariant.ICON -> 0.dp
        else -> 20.dp
    }
    Box(
        modifier
            .then(size)
            .alpha(if (enabled) 1f else 0.5f)
            .clip(shape)
            .then(if (outline) Modifier.border(2.dp, t.accent, shape) else Modifier.background(t.accent))
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .then(if (variant == MealioButtonVariant.ICON) Modifier.semantics { contentDescription = label } else Modifier)
            .padding(horizontal = sidePadding),
        contentAlignment = Alignment.Center,
    ) {
        if (variant == MealioButtonVariant.ICON) {
            CartIcon(t.onAccent, Modifier.size(24.dp))
        } else {
            Text(
                label,
                style = t.ts(if (variant == MealioButtonVariant.COMPACT) 14 else 16, FontWeight.Bold, if (outline) t.accent else t.onAccent),
            )
        }
    }
}

/** A drawn cart, so the module needs no icon library. */
@Composable
private fun CartIcon(color: Color, modifier: Modifier = Modifier) {
    Canvas(modifier) {
        val s = size.minDimension
        val basket = Path().apply {
            moveTo(s * 0.06f, s * 0.14f)
            lineTo(s * 0.20f, s * 0.14f)
            lineTo(s * 0.34f, s * 0.66f)
            lineTo(s * 0.82f, s * 0.66f)
            lineTo(s * 0.92f, s * 0.30f)
            lineTo(s * 0.25f, s * 0.30f)
        }
        drawPath(basket, color, style = Stroke(width = s * 0.09f, cap = StrokeCap.Round, join = StrokeJoin.Round))
        drawCircle(color, radius = s * 0.075f, center = Offset(s * 0.40f, s * 0.85f))
        drawCircle(color, radius = s * 0.075f, center = Offset(s * 0.76f, s * 0.85f))
    }
}
