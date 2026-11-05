package co.mealio.sdk.compose

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import co.mealio.sdk.AddResult
import co.mealio.sdk.MealioCart
import co.mealio.sdk.Recipe

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
 * @param onClose called when the sheet closes; `result` is null when nothing was added.
 */
@Composable
fun MealioCartButton(
    recipe: Recipe,
    store: String? = null,
    zip: String? = null,
    label: String = "Add to my grocery cart",
    onAdded: (AddResult) -> Unit = {},
    onClose: (AddResult?) -> Unit = {},
    onError: (Exception) -> Unit = {},
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    theme: MealioTheme = LocalMealioTheme.current,
) {
    val recipes = remember(recipe) { listOf(recipe) }
    MealioCartButton(recipes, store, zip, label, onAdded, onClose, onError, modifier, enabled, theme)
}

/** The button for several recipes in one cart, at most MAX_RECIPES. */
@Composable
fun MealioCartButton(
    recipes: List<Recipe>,
    store: String? = null,
    zip: String? = null,
    label: String = "Add to my grocery cart",
    onAdded: (AddResult) -> Unit = {},
    onClose: (AddResult?) -> Unit = {},
    onError: (Exception) -> Unit = {},
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    theme: MealioTheme = LocalMealioTheme.current,
) {
    var open by rememberSaveable { mutableStateOf(false) }
    // WARM THE LOGIN CHECK while the user reads the recipe. Only for a known
    // user with a store on file: the server answers "nothing to warm"
    // otherwise. The client runs it at most once every few minutes.
    LaunchedEffect(store, enabled) {
        if (enabled) MealioCart.warm(store)
    }
    Box(
        modifier
            .heightIn(min = 52.dp)
            .alpha(if (enabled) 1f else 0.5f)
            .clip(RoundedCornerShape(theme.radius))
            .background(theme.accent)
            .clickable(enabled = enabled, role = Role.Button, onClick = { open = true })
            .padding(horizontal = 20.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(label, style = theme.ts(16, FontWeight.Bold, theme.onAccent))
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
    )
}
