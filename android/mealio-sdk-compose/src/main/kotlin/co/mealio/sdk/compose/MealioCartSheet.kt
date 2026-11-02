package co.mealio.sdk.compose

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.selectable
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import co.mealio.sdk.AddResult
import co.mealio.sdk.CartItem
import co.mealio.sdk.CartSession
import co.mealio.sdk.MealioException
import co.mealio.sdk.Product
import kotlinx.coroutines.launch

/**
 * A drop-in bottom sheet for a prepared cart: what is ready, what needs the
 * user's pick (with H-E-B style preferences), what is unavailable, and an
 * Add to cart button. Nothing is picked for the user.
 *
 * ```
 * var session by remember { mutableStateOf<CartSession?>(null) }
 * session?.let { s ->
 *     MealioCartSheet(s, onDismiss = { session = null }, onAdded = { result -> session = null; open(result.storeCartUrl) })
 * }
 * ```
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MealioCartSheet(
    session: CartSession,
    onDismiss: () -> Unit,
    onAdded: (AddResult) -> Unit,
    modifier: Modifier = Modifier,
    onError: (MealioException) -> Unit = {},
) {
    ModalBottomSheet(onDismissRequest = onDismiss, modifier = modifier) {
        MealioCartContent(session = session, onAdded = onAdded, onError = onError)
    }
}

/** The sheet's content without the sheet, for apps that host it themselves. */
@Composable
fun MealioCartContent(
    session: CartSession,
    onAdded: (AddResult) -> Unit,
    modifier: Modifier = Modifier,
    onError: (MealioException) -> Unit = {},
) {
    val scope = rememberCoroutineScope()
    // UI mirror of the session's picks, so Compose redraws when they change.
    val product = remember(session) {
        mutableStateMapOf<String, String>().apply {
            session.needsChoice.forEach { item -> session.selectionFor(item.key)?.productId?.let { put(item.key, it) } }
        }
    }
    val preference = remember(session) { mutableStateMapOf<String, String>() }
    val skipped = remember(session) { mutableStateMapOf<String, Boolean>() }
    var busy by remember(session) { mutableStateOf(false) }
    var error by remember(session) { mutableStateOf<String?>(null) }

    fun productOf(item: CartItem, id: String?): Product? = item.options.firstOrNull { it.id == id } ?: item.chosen?.takeIf { it.id == id }

    val allDecided = session.needsChoice.all { item ->
        if (skipped[item.key] == true) return@all true
        val p = productOf(item, product[item.key]) ?: return@all false
        p.preferences.isEmpty() || preference[item.key] != null
    }

    LazyColumn(
        modifier = modifier.fillMaxWidth().padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        if (session.ready.isNotEmpty()) {
            item { SectionTitle("Ready") }
            items(session.ready, key = { "ready_" + it.key }) { item -> ReadyRow(item) }
        }

        if (session.needsChoice.isNotEmpty()) {
            item { SectionTitle("Pick a product") }
            items(session.needsChoice, key = { "choice_" + it.key }) { item ->
                ChoiceBlock(
                    item = item,
                    selectedProduct = product[item.key],
                    selectedPreference = preference[item.key],
                    isSkipped = skipped[item.key] == true,
                    onPick = { p ->
                        product[item.key] = p.id
                        preference.remove(item.key)
                        skipped.remove(item.key)
                        session.choose(item.key, p.id)
                    },
                    onPreference = { p, prefId ->
                        preference[item.key] = prefId
                        session.choose(item.key, p.id, preferenceId = prefId)
                    },
                    onSkip = {
                        skipped[item.key] = true
                        product.remove(item.key)
                        preference.remove(item.key)
                        session.skip(item.key)
                    },
                )
            }
        }

        if (session.unavailable.isNotEmpty()) {
            item { SectionTitle("Not available") }
            items(session.unavailable, key = { "na_" + it.key }) { item ->
                Text(
                    text = item.ingredient + (item.reason?.let { " (${reasonLabel(it)})" } ?: ""),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(vertical = 4.dp),
                )
            }
        }

        item {
            Column(Modifier.fillMaxWidth().padding(top = 12.dp, bottom = 24.dp)) {
                error?.let {
                    Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium)
                    Spacer(Modifier.height(8.dp))
                }
                Button(
                    onClick = {
                        busy = true
                        error = null
                        scope.launch {
                            try {
                                onAdded(session.addToCart())
                            } catch (e: MealioException) {
                                error = e.message ?: "Could not add to cart"
                                onError(e)
                            } finally {
                                busy = false
                            }
                        }
                    },
                    enabled = allDecided && !busy,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    if (busy) {
                        CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                    } else {
                        Text("Add to cart")
                    }
                }
            }
        }
    }
}

@Composable
private fun SectionTitle(text: String) {
    Column(Modifier.padding(top = 12.dp, bottom = 4.dp)) {
        Text(text, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        HorizontalDivider(Modifier.padding(top = 4.dp))
    }
}

@Composable
private fun ReadyRow(item: CartItem) {
    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(item.ingredient, style = MaterialTheme.typography.bodyLarge)
            item.chosen?.let {
                Text(
                    productLine(it),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        Text("x${item.quantity}", style = MaterialTheme.typography.bodyMedium)
    }
}

@Composable
private fun ChoiceBlock(
    item: CartItem,
    selectedProduct: String?,
    selectedPreference: String?,
    isSkipped: Boolean,
    onPick: (Product) -> Unit,
    onPreference: (Product, String) -> Unit,
    onSkip: () -> Unit,
) {
    Column(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                "${item.ingredient}  x${item.quantity}",
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = FontWeight.Medium,
                modifier = Modifier.weight(1f),
            )
            TextButton(onClick = onSkip, enabled = !isSkipped) { Text(if (isSkipped) "Skipped" else "Skip") }
        }
        if (item.options.isEmpty()) {
            Text("No options found", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        for (p in item.options) {
            val selected = p.id == selectedProduct
            Row(
                Modifier
                    .fillMaxWidth()
                    .selectable(selected = selected, enabled = !p.outOfStock, role = Role.RadioButton, onClick = { onPick(p) })
                    .padding(vertical = 2.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                RadioButton(selected = selected, onClick = null, enabled = !p.outOfStock)
                Column(Modifier.weight(1f).padding(start = 8.dp)) {
                    Text(p.name, style = MaterialTheme.typography.bodyMedium, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    val sub = listOfNotNull(p.size, p.price, badgeLabel(p.badge), if (p.outOfStock) "Out of stock" else null)
                    if (sub.isNotEmpty()) {
                        Text(sub.joinToString("  ·  "), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
            if (selected && p.preferences.isNotEmpty()) {
                Column(Modifier.padding(start = 40.dp)) {
                    Text("Choose one", style = MaterialTheme.typography.labelMedium)
                    for (pref in p.preferences) {
                        val on = pref.id == selectedPreference
                        Row(
                            Modifier
                                .fillMaxWidth()
                                .selectable(selected = on, role = Role.RadioButton, onClick = { onPreference(p, pref.id) }),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            RadioButton(selected = on, onClick = null)
                            Text(pref.label, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(start = 8.dp))
                        }
                    }
                }
            }
        }
    }
}

private fun productLine(p: Product): String = listOfNotNull(p.name, p.size, p.price).joinToString("  ·  ")

private fun badgeLabel(badge: String?): String? = when (badge) {
    "picked_before" -> "Picked before"
    "popular" -> "Popular"
    "partner_pick" -> "Recommended"
    else -> null
}

private fun reasonLabel(reason: String): String = when (reason) {
    "no_results" -> "no matches at this store"
    else -> reason.replace('_', ' ')
}
