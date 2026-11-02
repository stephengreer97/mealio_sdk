package co.mealio.sdk.compose

import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import co.mealio.sdk.AddResult
import co.mealio.sdk.CartSession
import co.mealio.sdk.MealioException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

// 0.1 entry points, kept for apps that prepare the cart themselves. They now
// show the same list as MealioCartFlow. New code: MealioCartButton.

/** A bottom sheet with the list for a cart you prepared yourself. */
@Deprecated("Use MealioCartButton or MealioCartFlow, which run the whole flow in one sheet.")
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MealioCartSheet(
    session: CartSession,
    onDismiss: () -> Unit,
    onAdded: (AddResult) -> Unit,
    modifier: Modifier = Modifier,
    onError: (MealioException) -> Unit = {},
) {
    val t = LocalMealioTheme.current
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        modifier = modifier,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = t.background,
    ) {
        @Suppress("DEPRECATION")
        MealioCartContent(session, onAdded, Modifier.fillMaxHeight(0.9f), onError)
    }
}

/** The list for a cart you prepared yourself, without a sheet. */
@Deprecated("Use MealioCartList, or MealioCartFlow for the whole flow.")
@Composable
fun MealioCartContent(
    session: CartSession,
    onAdded: (AddResult) -> Unit,
    modifier: Modifier = Modifier,
    onError: (MealioException) -> Unit = {},
) {
    val scope = rememberCoroutineScope()
    var busy by remember(session) { mutableStateOf(false) }
    MealioCartList(
        cart = session,
        storeName = session.storeName ?: storeLabel(session.store),
        busy = busy,
        modifier = modifier,
        onAdd = {
            busy = true
            scope.launch {
                try {
                    onAdded(session.addToCart())
                } catch (e: CancellationException) {
                    throw e
                } catch (e: MealioException) {
                    onError(e)
                } finally {
                    busy = false
                }
            }
        },
    )
}
