package co.mealio.sdk.compose

import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import co.mealio.sdk.MealioCart
import co.mealio.sdk.StoreInfo
import co.mealio.sdk.StorePreferences
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch

// Change the user's store outside a cart: the same store list and the same zip
// and location screens as the cart sheet. Port of
// packages/react-native/src/MealioStoreSettings.tsx.

/**
 * The sheet where the user changes their store or zip. Put it on your settings
 * screen and open it by flipping `visible`:
 *
 * ```
 * var open by rememberSaveable { mutableStateOf(false) }
 * Button(onClick = { open = true }) { Text("Grocery store") }
 * MealioStoreSettings(visible = open, onClose = { open = false })
 * ```
 *
 * Requires MealioCart.configure(...) first.
 *
 * @param onClose called when the user closes the sheet. Set `visible` to false here.
 * @param onChange called each time the user's store changes.
 * @param onSignInRequired called instead of opening while [MealioCart.setUser]
 *   says nobody is signed in (else MealioCart.onSignInRequired). The sheet then
 *   closes at once.
 */
@Composable
fun MealioStoreSettings(
    visible: Boolean,
    onClose: () -> Unit,
    onChange: (StorePreferences) -> Unit = {},
    theme: MealioTheme = LocalMealioTheme.current,
    onSignInRequired: (() -> Unit)? = null,
) {
    if (!visible) return
    val user by MealioCart.user.collectAsState()
    if (!user.signedIn) {
        val signIn by rememberUpdatedState(onSignInRequired ?: MealioCart.onSignInRequired)
        val close by rememberUpdatedState(onClose)
        LaunchedEffect(Unit) {
            signIn?.invoke()
            close()
        }
        return
    }
    // Everything below lives only while the sheet is open, so each open starts fresh.
    SheetDialog(onDismiss = onClose) {
        SettingsSheet(theme, onClose, onChange)
    }
}

@Composable
private fun SettingsSheet(t: MealioTheme, onClose: () -> Unit, onChange: (StorePreferences) -> Unit) {
    val ui = LocalMealioUi.current
    val scope = rememberCoroutineScope()
    var stores by remember { mutableStateOf<List<StoreInfo>?>(null) }
    var prefs by remember { mutableStateOf<StorePreferences?>(null) }
    var picking by remember { mutableStateOf<StoreInfo?>(null) }
    var saving by remember { mutableStateOf<String?>(null) }
    var problem by remember { mutableStateOf<String?>(null) }
    val onChangeNow by rememberUpdatedState(onChange)

    LaunchedEffect(Unit) {
        try {
            val (list, current) = coroutineScope {
                val list = async { MealioCart.stores() }
                val current = async { MealioCart.storePreferences() }
                list.await() to current.await()
            }
            prefs = current
            stores = list
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            stores = emptyList()
            problem = e.message ?: ui.tr("couldNotLoadYourStores")
        }
    }

    fun changed(next: StorePreferences) {
        prefs = next
        onChangeNow(next)
    }

    fun choose(store: StoreInfo) {
        // A Kroger family store is a chain: the user still has to say which one.
        if (store.via == "kroger_api") {
            picking = store
            return
        }
        saving = store.id
        problem = null
        scope.launch {
            try {
                changed(MealioCart.setStore(store.id))
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                problem = e.message ?: ui.tr("couldNotSaveStore")
            } finally {
                saving = null
            }
        }
    }

    val chain = picking
    val saved = prefs
    val samePick = if (chain != null && saved?.defaultStore == chain.id) saved?.location else null
    val list = stores

    SheetFrame(t) {
        Header(t, null, if (chain != null) ui.tr("titleLocation", "store" to chain.name) else ui.tr("titleSettings"), onClose = onClose)
        when {
            chain != null -> LocationPicker(
                t, chain.id, chain.name,
                startZip = samePick?.zip,
                current = samePick?.id,
                onPicked = { location ->
                    changed(StorePreferences(chain.id, location))
                    picking = null
                },
                backLabel = ui.tr("backToStores"),
                onBack = { picking = null },
            )
            list == null -> Box(Modifier.fillMaxWidth().padding(20.dp), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(Modifier.size(28.dp), color = t.accent, strokeWidth = 2.5.dp)
            }
            else -> {
                Column(
                    Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).padding(start = 16.dp, end = 16.dp, bottom = 24.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    problem?.let { Text(it, style = t.ts(15)) }
                    for (st in list) {
                        key(st.id) {
                            val on = st.id == saved?.defaultStore
                            val location = saved?.location
                            val shape = RoundedCornerShape(t.radius)
                            Row(
                                Modifier
                                    .fillMaxWidth()
                                    .heightIn(min = 56.dp)
                                    .clip(shape)
                                    .border(if (on) 2.dp else 1.dp, if (on) t.accent else t.border, shape)
                                    .selectable(selected = on, enabled = saving == null, role = Role.RadioButton, onClick = { choose(st) })
                                    .padding(horizontal = 16.dp, vertical = 10.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(10.dp),
                            ) {
                                Column(Modifier.weight(1f)) {
                                    Text(st.name, style = t.ts(15, FontWeight.SemiBold, lineHeight = 20))
                                    if (on && location != null) {
                                        Text("${location.name}, ${location.address}", style = t.ts(12, color = t.muted, lineHeight = 17))
                                    }
                                }
                                if (saving == st.id) {
                                    CircularProgressIndicator(Modifier.size(20.dp), color = t.accent, strokeWidth = 2.dp)
                                } else if (on) {
                                    Text(ui.tr(if (location != null) "change" else "current"), style = t.ts(12, color = t.accent, lineHeight = 17))
                                }
                            }
                        }
                    }
                }
                TopRule(t)
                Column(Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 28.dp)) {
                    Cta(t, onClick = onClose) { Text(ui.tr("done"), style = t.ts(16, FontWeight.Bold, t.onAccent)) }
                }
            }
        }
    }
}
