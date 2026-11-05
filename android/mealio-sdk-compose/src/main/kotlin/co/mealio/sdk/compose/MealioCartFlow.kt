package co.mealio.sdk.compose

import android.view.ViewGroup
import android.view.WindowManager
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.MutableTransitionState
import androidx.compose.animation.fadeIn
import androidx.compose.animation.slideInVertically
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.union
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.window.DialogWindowProvider
import co.mealio.sdk.AddResult
import co.mealio.sdk.AddedItem
import co.mealio.sdk.CartItem
import co.mealio.sdk.CartSession
import co.mealio.sdk.InlineLogin
import co.mealio.sdk.ItemStatus
import co.mealio.sdk.MealioCart
import co.mealio.sdk.MealioException
import co.mealio.sdk.MealioInlineLogin
import co.mealio.sdk.Product
import co.mealio.sdk.Recipe
import co.mealio.sdk.Step
import co.mealio.sdk.StoreInfo
import co.mealio.sdk.forRecipes
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

// The drop-in: ONE sheet that runs the whole add-to-cart flow over the
// partner's app. Loading, store sign-in, the list, adding, done. Port of
// packages/react-native/src/MealioCartFlow.tsx.
//
// The list shows EVERY item, every time. Remembered products come back
// pre-selected. Unchecking an item leaves it out of this run only: its
// remembered choice stays for next time. There is no skip button.

private enum class Phase { LOADING, LIST, ADDING, DONE, ERROR, STORES }

private data class FlowError(val code: String, val message: String)

/**
 * The whole flow in one sheet. Requires MealioCart.configure(...) first.
 *
 * @param store store id from GET /api/v1/stores, e.g. "heb". Optional: without
 *   it the user's default store is used, and the sheet asks them to pick one
 *   the first time. The user can change store from the sheet either way.
 * @param zip 5-digit zip. Needed for Kroger family stores.
 * @param onClose called when the sheet closes. `result` is null when nothing was added.
 *   Set `visible` to false here.
 * @param onAdded called after the cart is filled, before the user taps Done.
 */
@Composable
fun MealioCartFlow(
    visible: Boolean,
    recipe: Recipe,
    store: String? = null,
    zip: String? = null,
    onClose: (AddResult?) -> Unit,
    onAdded: (AddResult) -> Unit = {},
    onError: (Exception) -> Unit = {},
    theme: MealioTheme = LocalMealioTheme.current,
) {
    val recipes = remember(recipe) { listOf(recipe) }
    MealioCartFlow(visible, recipes, store, zip, onClose, onAdded, onError, theme)
}

/**
 * The whole flow for several recipes in one cart (at most MAX_RECIPES).
 * Ingredients they share become one item, each item says which recipes it is
 * for, and a pick is remembered under every one of them. Otherwise the same as
 * the one-recipe MealioCartFlow.
 */
@Composable
fun MealioCartFlow(
    visible: Boolean,
    recipes: List<Recipe>,
    store: String? = null,
    zip: String? = null,
    onClose: (AddResult?) -> Unit,
    onAdded: (AddResult) -> Unit = {},
    onError: (Exception) -> Unit = {},
    theme: MealioTheme = LocalMealioTheme.current,
) {
    if (!visible) return
    // Everything below lives only while the sheet is open, so each open starts fresh.
    val backRef = remember { mutableStateOf<() -> Unit>({}) }
    Dialog(
        onDismissRequest = { backRef.value() },
        properties = DialogProperties(
            usePlatformDefaultWidth = false,
            decorFitsSystemWindows = false,
            dismissOnClickOutside = false,
        ),
    ) {
        val window = (LocalView.current.parent as? DialogWindowProvider)?.window
        SideEffect {
            window?.let {
                it.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
                it.setDimAmount(0f)
                @Suppress("DEPRECATION")
                it.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
            }
        }
        FlowSheet(theme, recipes, store, zip, onClose, onAdded, onError, backRef)
    }
}

@Composable
private fun FlowSheet(
    t: MealioTheme,
    recipes: List<Recipe>,
    initialStore: String?,
    zip: String?,
    onClose: (AddResult?) -> Unit,
    onAdded: (AddResult) -> Unit,
    onError: (Exception) -> Unit,
    backRef: androidx.compose.runtime.MutableState<() -> Unit>,
) {
    val scope = rememberCoroutineScope()
    var phase by remember { mutableStateOf(Phase.LOADING) }
    var step by remember { mutableStateOf(Step.CONNECTING) }
    var cart by remember { mutableStateOf<CartSession?>(null) }
    var result by remember { mutableStateOf<AddResult?>(null) }
    var error by remember { mutableStateOf<FlowError?>(null) }
    var job by remember { mutableStateOf<Job?>(null) }
    var store by remember { mutableStateOf(initialStore) }
    var stores by remember { mutableStateOf<List<StoreInfo>?>(null) }
    var backTo by remember { mutableStateOf(Phase.LIST) }
    val login by MealioInlineLogin.current.collectAsState()
    val onCloseNow by rememberUpdatedState(onClose)
    val onAddedNow by rememberUpdatedState(onAdded)
    val onErrorNow by rememberUpdatedState(onError)

    // While this sheet is open, a store sign-in renders inside it.
    DisposableEffect(Unit) {
        val detach = MealioInlineLogin.attachSheet()
        onDispose { detach() }
    }

    fun fail(e: Exception, fallback: String) {
        error = FlowError((e as? MealioException)?.code ?: "error", e.message ?: fallback)
        phase = Phase.ERROR
        onErrorNow(e)
    }

    fun openStores(from: Phase) {
        backTo = from
        phase = Phase.STORES
        if (stores == null) {
            scope.launch {
                stores = try {
                    MealioCart.stores()
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    emptyList()
                }
            }
        }
    }

    fun start(storeId: String?) {
        job?.cancel()
        phase = Phase.LOADING; step = Step.CONNECTING; cart = null; result = null; error = null
        job = scope.launch {
            try {
                val c = MealioCart.prepareCart(storeId, recipes, zip) { s, _ -> step = s }
                store = c.store
                cart = c
                phase = Phase.LIST
            } catch (e: CancellationException) {
                throw e
            } catch (e: MealioException) {
                if (e.code == "store_required") openStores(Phase.ERROR) else fail(e, "Something went wrong.")
            } catch (e: Exception) {
                fail(e, "Something went wrong.")
            }
        }
    }

    fun add() {
        val c = cart ?: return
        phase = Phase.ADDING
        job = scope.launch {
            try {
                val r = c.addToCart()
                result = r
                phase = Phase.DONE
                onAddedNow(r)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                fail(e, "Could not add to your cart.")
            }
        }
    }

    fun close() {
        job?.cancel()
        login?.cancel()
        onCloseNow(if (phase == Phase.DONE) result else null)
    }

    // Back: inside the store's sign-in pages first, then close the sheet.
    backRef.value = { if (login?.goBack() != true) close() }

    LaunchedEffect(Unit) { start(initialStore) }

    val storeName = cart?.storeName ?: store?.let { storeLabel(it) } ?: "your store"
    // The kicker over the title: the recipe's own title, or "3 meals".
    val kicker = if (recipes.size == 1) recipes[0].title else if (recipes.size > 1) "${recipes.size} meals" else null
    val lineCount = recipes.sumOf { it.ingredients.size }
    val shown = remember { MutableTransitionState(false).apply { targetState = true } }

    Box(
        Modifier
            .fillMaxSize()
            .background(Color(0x59000000))
            .statusBarsPadding(),
        contentAlignment = Alignment.BottomCenter,
    ) {
        AnimatedVisibility(visibleState = shown, enter = slideInVertically { it } + fadeIn()) {
            Column(
                Modifier
                    .fillMaxWidth()
                    .fillMaxHeight(0.94f)
                    .clip(RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp))
                    .background(t.background)
                    .windowInsetsPadding(WindowInsets.ime.union(WindowInsets.navigationBars)),
            ) {
                Box(
                    Modifier
                        .align(Alignment.CenterHorizontally)
                        .padding(top = 8.dp)
                        .size(width = 36.dp, height = 5.dp)
                        .clip(RoundedCornerShape(3.dp))
                        .background(t.border),
                )
                val l = login
                Header(t, kicker, l?.title ?: headerTitle(phase, storeName), onClose = ::close)
                val c = cart
                val r = result
                when {
                    l != null -> LoginPane(t, l, storeName)
                    phase == Phase.LOADING -> Loading(t, step, storeName, lineCount)
                    phase == Phase.STORES -> StorePicker(
                        t, stores, store,
                        onPick = { id -> store = id; start(id) },
                        onBack = if (c != null && backTo == Phase.LIST) ({ phase = Phase.LIST }) else null,
                    )
                    (phase == Phase.LIST || phase == Phase.ADDING) && c != null ->
                        MealioCartList(
                            c, storeName, busy = phase == Phase.ADDING, onAdd = ::add, theme = t, modifier = Modifier.weight(1f),
                            onChangeStore = { openStores(Phase.LIST) },
                        )
                    phase == Phase.DONE && r != null && c != null -> Done(t, c, r, storeName, onDone = ::close)
                    else -> ErrorView(t, error, onRetry = { start(store) }, onClose = ::close)
                }
            }
        }
    }
}

private fun headerTitle(phase: Phase, storeName: String): String = when (phase) {
    Phase.DONE -> if (storeName == "your store") "In your cart" else "In your $storeName cart"
    Phase.LOADING -> if (storeName == "your store") "Getting your cart ready" else "Getting your $storeName cart ready"
    Phase.ERROR -> "Something went wrong"
    Phase.STORES -> "Choose your store"
    else -> "Your $storeName list"
}

internal fun storeLabel(id: String): String {
    val known = mapOf("heb" to "H-E-B", "aldi" to "ALDI", "kroger" to "Kroger", "safeway" to "Safeway", "wegmans" to "Wegmans")
    return known[id] ?: Regex("\\b\\w").replace(id.replace('_', ' ')) { it.value.uppercase() }
}

// ── pieces ─────────────────────────────────────────────────────────────

internal fun MealioTheme.ts(
    size: Int,
    weight: FontWeight = FontWeight.Normal,
    color: Color = text,
    lineHeight: Int? = null,
    decoration: TextDecoration? = null,
    align: TextAlign = TextAlign.Unspecified,
) = TextStyle(
    fontSize = size.sp,
    fontWeight = weight,
    color = color,
    lineHeight = lineHeight?.sp ?: TextUnit.Unspecified,
    fontFamily = fontFamily,
    textDecoration = decoration,
    textAlign = align,
)

private fun Dp.minus2(): Dp = (this - 2.dp).coerceAtLeast(0.dp)

@Composable
private fun hairline(): Dp = with(LocalDensity.current) { 1.toDp() }

@Composable
private fun TopRule(t: MealioTheme, thickness: Dp = 1.dp) {
    Box(Modifier.fillMaxWidth().height(thickness).background(t.border))
}

@Composable
private fun Header(t: MealioTheme, recipeTitle: String?, title: String, onClose: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(start = 20.dp, end = 20.dp, top = 12.dp, bottom = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Column(Modifier.weight(1f)) {
            if (!recipeTitle.isNullOrEmpty()) {
                Text(recipeTitle, style = t.ts(13, FontWeight.Medium, t.muted), maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            Text(
                title,
                style = t.ts(22, FontWeight.Bold, lineHeight = 28),
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.semantics { heading() },
            )
        }
        Box(
            Modifier
                .size(44.dp)
                .clip(CircleShape)
                .background(t.surface)
                .clickable(role = Role.Button, onClickLabel = "Close", onClick = onClose)
                .semantics { contentDescription = "Close" },
            contentAlignment = Alignment.Center,
        ) {
            Text("✕", style = t.ts(16))
        }
    }
}

@Composable
private fun ColumnScope.LoginPane(t: MealioTheme, login: InlineLogin, storeName: String) {
    Text(
        "Sign in on $storeName's own page. Mealio never sees your password.",
        style = t.ts(13, color = t.muted),
        modifier = Modifier.padding(start = 20.dp, end = 20.dp, bottom = 8.dp),
    )
    TopRule(t, hairline())
    key(login) {
        AndroidView(
            factory = { ctx ->
                login.createWebView(ctx).also { (it.parent as? ViewGroup)?.removeView(it) }
            },
            onRelease = { login.releaseWebView() },
            modifier = Modifier.fillMaxWidth().weight(1f),
        )
    }
}

private class StepRow(val keys: Set<Step>, val label: (Int, String) -> String)

private val STEPS = listOf(
    StepRow(setOf(Step.CONNECTING, Step.CHECKING_SIGN_IN, Step.SIGNING_IN)) { _, store -> "Checking your $store sign-in" },
    StepRow(setOf(Step.SEARCHING)) { n, _ -> "Finding your $n ingredient${if (n == 1) "" else "s"}" },
)

@Composable
private fun Loading(t: MealioTheme, step: Step, storeName: String, count: Int) {
    val at = STEPS.indexOfFirst { step in it.keys }
    Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Checking prices and stock at $storeName.", style = t.ts(14, color = t.muted))
        Column(Modifier.padding(vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
            STEPS.forEachIndexed { i, x ->
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    when {
                        i < at -> Box(Modifier.size(24.dp).clip(CircleShape).background(t.accent), contentAlignment = Alignment.Center) {
                            Text("✓", style = t.ts(13, FontWeight.ExtraBold, t.onAccent))
                        }
                        i == at -> Box(Modifier.size(24.dp), contentAlignment = Alignment.Center) {
                            CircularProgressIndicator(Modifier.size(22.dp), color = t.accent, strokeWidth = 2.5.dp)
                        }
                        else -> Box(Modifier.size(24.dp).border(2.dp, t.border, CircleShape))
                    }
                    Text(
                        x.label(count, storeName),
                        style = t.ts(15, if (i == at) FontWeight.Bold else FontWeight.Normal, if (i > at) t.muted else t.text),
                    )
                }
            }
        }
        repeat(3) {
            Box(Modifier.fillMaxWidth().height(72.dp).clip(RoundedCornerShape(t.radius + 2.dp)).background(t.surface))
        }
    }
}

/**
 * The list screen on its own, for apps that host it in their own sheet: every
 * item with its checkbox, options, search, the estimated total and the Add
 * button. `onChange` is called after each selection change. With
 * `onChangeStore`, a tappable store chip sits above the list.
 */
@Composable
fun MealioCartList(
    cart: CartSession,
    storeName: String,
    busy: Boolean,
    onAdd: () -> Unit,
    modifier: Modifier = Modifier,
    onChange: () -> Unit = {},
    onChangeStore: (() -> Unit)? = null,
    theme: MealioTheme = LocalMealioTheme.current,
) {
    val t = theme
    // CartSession is not observable; this counter redraws after each change.
    var version by remember(cart) { mutableIntStateOf(0) }
    val bump = { version += 1; onChange() }
    var open by remember(cart) {
        mutableStateOf(cart.items.firstOrNull { it.status == ItemStatus.CHOOSE || it.status == ItemStatus.REMEMBERED_UNAVAILABLE }?.key)
    }
    @Suppress("UNUSED_EXPRESSION") version
    val est = cart.estimate()
    val selectable = cart.items.count { it.status != ItemStatus.UNAVAILABLE }

    Column(modifier.fillMaxWidth()) {
        Row(
            Modifier.fillMaxWidth().padding(start = 20.dp, end = 20.dp, bottom = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            if (onChangeStore != null) {
                val chipLabel = "Store: $storeName. Change store"
                Row(
                    Modifier
                        .heightIn(min = 36.dp)
                        .clip(RoundedCornerShape(18.dp))
                        .background(t.surface)
                        .clickable(enabled = !busy, role = Role.Button, onClick = onChangeStore)
                        .semantics(mergeDescendants = true) { contentDescription = chipLabel }
                        .padding(horizontal = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text(storeName, style = t.ts(13, FontWeight.SemiBold))
                    Text("Change", style = t.ts(13, FontWeight.SemiBold, t.accent))
                }
            }
            Text("${est.count} of $selectable selected", style = t.ts(14, color = t.muted))
        }
        // Said while any item has no saved product, which on a recipe's first
        // cart is every item: the run where nothing on screen shows it yet.
        if (cart.items.any { it.status == ItemStatus.CHOOSE }) {
            val shape = RoundedCornerShape(10.dp)
            Box(
                Modifier
                    .padding(start = 12.dp, end = 12.dp, bottom = 10.dp)
                    .fillMaxWidth()
                    .clip(shape)
                    .background(t.surface)
                    .border(1.dp, t.border, shape)
                    .padding(12.dp),
            ) {
                Text(
                    "Pick a product for each item and Mealio will remember your preferences.",
                    style = t.ts(13, FontWeight.Medium, t.text, lineHeight = 18),
                )
            }
        }
        Column(
            Modifier
                .weight(1f)
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(start = 16.dp, end = 16.dp, bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            for (it in cart.items) {
                key(it.key) {
                    ItemRow(
                        t, cart, it, storeName, version,
                        open = open == it.key,
                        onToggleOpen = { open = if (open == it.key) null else it.key },
                        onChange = bump,
                        disabled = busy,
                    )
                }
            }
        }
        TopRule(t)
        Column(
            Modifier.fillMaxWidth().background(t.background).padding(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 28.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            val pending = cart.pendingPreferences().size
            if (pending > 0) {
                Text(
                    (if (pending == 1) "1 checked item needs" else "$pending checked items need") + " an option chosen before adding.",
                    style = t.ts(12, color = t.warnText, lineHeight = 17),
                    modifier = Modifier.padding(bottom = 6.dp),
                )
            }
            // No partial totals: one unpriced item and there is no number to show.
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.Bottom) {
                val total = est.total
                Text(if (total != null && est.estimated) "Estimated total" else "Total", style = t.ts(14, color = t.muted))
                if (total != null) Text((if (est.estimated) "about " else "") + money(total), style = t.ts(18, FontWeight.Bold))
                else Text("Prices at checkout", style = t.ts(15, FontWeight.SemiBold, t.muted))
            }
            val off = busy || est.count == 0
            Cta(t, enabled = !off, onClick = onAdd, modifier = Modifier.alpha(if (off) 0.5f else 1f)) {
                if (busy) {
                    CircularProgressIndicator(Modifier.size(24.dp), color = t.onAccent, strokeWidth = 2.5.dp)
                } else {
                    Text(
                        if (est.count > 0) "Add ${est.count} item${if (est.count == 1) "" else "s"} to $storeName" else "Select items to add",
                        style = t.ts(16, FontWeight.Bold, t.onAccent),
                    )
                }
            }
        }
    }
}

@Composable
private fun Cta(
    t: MealioTheme,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    background: Color = t.accent,
    content: @Composable () -> Unit,
) {
    Box(
        modifier
            .fillMaxWidth()
            .heightIn(min = 52.dp)
            .clip(RoundedCornerShape(t.radius))
            .background(background)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(horizontal = 16.dp),
        contentAlignment = Alignment.Center,
    ) { content() }
}

@Composable
private fun StepButton(t: MealioTheme, symbol: String, label: String, enabled: Boolean, dim: Boolean, onClick: () -> Unit) {
    val shape = RoundedCornerShape(10.dp)
    Box(
        Modifier
            .size(44.dp)
            .alpha(if (dim) 0.4f else 1f)
            .clip(shape)
            .background(t.surface)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        Text(symbol, style = t.ts(20, FontWeight.SemiBold))
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ItemRow(
    t: MealioTheme,
    cart: CartSession,
    item: CartItem,
    storeName: String,
    @Suppress("UNUSED_PARAMETER") version: Int,
    open: Boolean,
    onToggleOpen: () -> Unit,
    onChange: () -> Unit,
    disabled: Boolean,
) {
    val scope = rememberCoroutineScope()
    var query by remember { mutableStateOf("") }
    var searching by remember { mutableStateOf(false) }
    var searchNote by remember { mutableStateOf<String?>(null) }
    val on = cart.isSelected(item.key)
    val picked = cart.selected(item.key)
    val options = cart.options(item.key)
    val shown = picked ?: (if (item.status == ItemStatus.REMEMBERED) item.remembered else null)
    val cardShape = RoundedCornerShape(t.radius + 2.dp)

    if (item.status == ItemStatus.UNAVAILABLE) {
        Column(Modifier.fillMaxWidth().clip(cardShape).background(t.background).border(1.dp, t.border, cardShape)) {
            Row(
                Modifier.padding(top = 10.dp, bottom = 10.dp, end = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Box(Modifier.size(48.dp), contentAlignment = Alignment.Center) {
                    Box(Modifier.size(24.dp).border(2.dp, t.border, RoundedCornerShape(7.dp)))
                }
                Column(Modifier.weight(1f)) {
                    Text(item.ingredient, style = t.ts(12, FontWeight.Medium, t.muted), maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text("Not found at $storeName", style = t.ts(14, color = t.muted))
                }
            }
        }
        return
    }

    fun toggle() {
        if (disabled) return
        if (on) cart.deselect(item.key)
        else if (item.status == ItemStatus.REMEMBERED && item.selectedId != null) {
            try {
                cart.select(item.key, item.selectedId!!, item.rememberedPreferenceId)
            } catch (e: MealioException) {
                if (!open) onToggleOpen()
                return
            }
        } else {
            if (!open) onToggleOpen()
            return
        }
        onChange()
    }

    fun pick(p: Product, preferenceId: String? = null) {
        if (disabled) return
        cart.select(item.key, p.id, preferenceId)
        onChange()
    }

    fun search() {
        val q = query.trim()
        if (q.length < 2 || searching) return
        searching = true
        searchNote = null
        scope.launch {
            try {
                val found = cart.search(item.key, q)
                searchNote = if (found.isEmpty()) "Nothing found for \"$q\"." else null
                query = ""
                onChange()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                searchNote = e.message ?: "Search failed. Try again."
            } finally {
                searching = false
            }
        }
    }

    val meta = when {
        picked != null -> listOfNotNull(
            priceText(picked).takeIf { it.isNotEmpty() },
            if (picked.id == item.remembered?.id) "Your usual" else null,
        ).joinToString(" · ")
        item.status == ItemStatus.REMEMBERED -> "Not adding this time"
        item.status == ItemStatus.REMEMBERED_UNAVAILABLE -> "Your usual is out of stock"
        else -> "${options.size} option${if (options.size == 1) "" else "s"}"
    }

    Column(
        Modifier.fillMaxWidth().clip(cardShape).background(t.background).border(1.dp, if (open) t.muted else t.border, cardShape),
    ) {
        Row(
            Modifier.padding(top = 10.dp, bottom = 10.dp, end = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            val label = (if (on) "Leave out " else "Add ") + item.ingredient
            Box(
                Modifier
                    .size(48.dp)
                    .toggleable(value = on, enabled = !disabled, role = Role.Checkbox, onValueChange = { toggle() })
                    .semantics { contentDescription = label },
                contentAlignment = Alignment.Center,
            ) {
                val box = RoundedCornerShape(7.dp)
                Box(
                    Modifier
                        .size(24.dp)
                        .clip(box)
                        .then(if (on) Modifier.background(t.accent) else Modifier.border(2.dp, t.muted, box)),
                    contentAlignment = Alignment.Center,
                ) {
                    if (on) Text("✓", style = t.ts(14, FontWeight.ExtraBold, t.onAccent))
                }
            }
            Thumb(t, shown ?: options.firstOrNull(), dim = !on)
            Column(
                Modifier
                    .weight(1f)
                    .clickable(role = Role.Button, onClickLabel = "Show the options", onClick = onToggleOpen),
            ) {
                Text(item.ingredient, style = t.ts(12, FontWeight.Medium, t.muted), maxLines = 1, overflow = TextOverflow.Ellipsis)
                forRecipes(cart, item.key)?.let {
                    Text(it, style = t.ts(11, color = t.muted), maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                Text(
                    shown?.name ?: "Choose a product",
                    style = t.ts(
                        15, FontWeight.SemiBold,
                        color = if (on) t.text else t.muted,
                        lineHeight = 20,
                        decoration = if (!on && shown != null) TextDecoration.LineThrough else null,
                    ),
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(meta, style = t.ts(12, color = t.muted, lineHeight = 17))
            }
            Box(
                Modifier
                    .heightIn(min = 44.dp)
                    .clickable(role = Role.Button, onClick = onToggleOpen)
                    .semantics { stateDescription = if (open) "Expanded" else "Collapsed" }
                    .padding(horizontal = 10.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    if (open) "Done" else if (on || item.status == ItemStatus.REMEMBERED) "Change" else "Choose",
                    style = t.ts(14, FontWeight.SemiBold, t.accent),
                )
            }
        }

        if (on && picked != null && cart.needsPreference(item.key)) {
            Text(
                "Choose one: " + listOr(picked.preferences.map { it.label }),
                style = t.ts(13, FontWeight.SemiBold, t.accent, lineHeight = 18),
                modifier = Modifier.padding(start = 12.dp, end = 12.dp, bottom = 8.dp).semantics { liveRegion = LiveRegionMode.Polite },
            )
        }

        if (on && picked != null) {
            // Sold by weight: the stepper is pounds, stepping through the store's
            // weights (else 0.25 lb). Otherwise a count, clamped to the store cap.
            val byWeight = picked.soldByWeight == true
            val range = if (byWeight) cart.weightRange(item.key) else null
            val lb = if (byWeight) cart.weight(item.key) else 0.0
            val n = cart.quantity(item.key)
            val atMin = if (range != null) lb <= range.min else n <= 1
            val atMax = if (range != null) lb >= range.max else n >= cart.maxQuantity(item.key)
            fun step(dir: Int) {
                if (byWeight) cart.stepWeight(item.key, dir) else cart.setQuantity(item.key, n + dir)
                onChange()
            }
            Row(
                Modifier.fillMaxWidth().padding(start = 58.dp, end = 12.dp, bottom = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text(if (byWeight) "Weight" else "Quantity", style = t.ts(12, color = t.muted, lineHeight = 17))
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    StepButton(t, "−", "Less ${item.ingredient}", enabled = !disabled && !atMin, dim = atMin) { step(-1) }
                    val value = if (byWeight) lbText(lb) else "$n"
                    val valueLabel = if (byWeight) "Weight ${lbText(lb)}" else "Quantity $n"
                    Text(
                        value,
                        style = t.ts(16, FontWeight.Bold),
                        textAlign = TextAlign.Center,
                        modifier = Modifier.widthIn(min = if (byWeight) 64.dp else 28.dp).semantics { contentDescription = valueLabel },
                    )
                    StepButton(t, "+", "More ${item.ingredient}", enabled = !disabled && !atMax, dim = atMax) { step(1) }
                }
            }
        }

        if (item.status == ItemStatus.REMEMBERED_UNAVAILABLE && !on) {
            val name = item.remembered?.let { ", ${it.name}," } ?: ""
            val why = if (item.reason == "not_found") "not available" else "out of stock"
            WarnBox(t, "Your usual$name is $why today. Pick another this time. It stays your usual.", Modifier.padding(start = 12.dp, end = 12.dp, bottom = 12.dp))
        }

        if (open) {
            TopRule(t)
            Column(Modifier.padding(vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(
                    Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp),
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    for (o in options) {
                        val sel = picked?.id == o.id
                        val usual = o.id == item.remembered?.id
                        val shape = RoundedCornerShape(t.radius)
                        Column(
                            Modifier
                                .width(136.dp)
                                .clip(shape)
                                .background(t.background)
                                .border(if (sel) 2.dp else 1.dp, if (sel) t.accent else t.border, shape)
                                .selectable(selected = sel, enabled = !disabled, role = Role.RadioButton, onClick = { pick(o) })
                                .padding(10.dp),
                            verticalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            Thumb(t, o, big = true)
                            Text(
                                o.name,
                                style = t.ts(13, FontWeight.Medium, if (o.outOfStock) t.muted else t.text, lineHeight = 17),
                                maxLines = 3,
                                overflow = TextOverflow.Ellipsis,
                            )
                            Text(
                                if (o.outOfStock) "Out of stock" else priceText(o),
                                style = t.ts(13, FontWeight.SemiBold),
                            )
                            if (usual) Text("Your usual", style = t.ts(11, FontWeight.Bold, t.accent))
                            else if (o.badge == "popular") Text("Popular", style = t.ts(11, FontWeight.Bold, t.muted))
                        }
                    }
                }
                val prefs = picked?.preferences ?: emptyList()
                if (picked != null && prefs.isNotEmpty()) {
                    val selPref = cart.preferenceId(item.key)
                    FlowRow(
                        Modifier.padding(horizontal = 12.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        for (p in prefs) {
                            val s = selPref == p.id
                            Box(
                                Modifier
                                    .heightIn(min = 36.dp)
                                    .clip(RoundedCornerShape(18.dp))
                                    .background(if (s) t.accent else t.surface)
                                    .selectable(selected = s, enabled = !disabled, role = Role.RadioButton, onClick = { pick(picked, p.id) })
                                    .padding(horizontal = 12.dp),
                                contentAlignment = Alignment.Center,
                            ) {
                                Text(p.label, style = t.ts(13, color = if (s) t.onAccent else t.text))
                            }
                        }
                    }
                }
                val hint = "Search $storeName for something else"
                Row(Modifier.padding(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    val shape = RoundedCornerShape(t.radius.minus2())
                    BasicTextField(
                        value = query,
                        onValueChange = { query = it },
                        enabled = !disabled,
                        singleLine = true,
                        textStyle = t.ts(14),
                        cursorBrush = SolidColor(t.accent),
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                        keyboardActions = KeyboardActions(onSearch = { search() }),
                        modifier = Modifier
                            .weight(1f)
                            .heightIn(min = 44.dp)
                            .semantics { contentDescription = hint },
                        decorationBox = { inner ->
                            Box(
                                Modifier.fillMaxWidth().heightIn(min = 44.dp).clip(shape).background(t.surface).padding(horizontal = 12.dp),
                                contentAlignment = Alignment.CenterStart,
                            ) {
                                if (query.isEmpty()) Text(hint, style = t.ts(14, color = t.muted), maxLines = 1, overflow = TextOverflow.Ellipsis)
                                inner()
                            }
                        },
                    )
                    Box(
                        Modifier
                            .heightIn(min = 44.dp)
                            .widthIn(min = 76.dp)
                            .clip(shape)
                            .background(t.text)
                            .clickable(enabled = !searching, role = Role.Button, onClick = { search() })
                            .padding(horizontal = 14.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        if (searching) CircularProgressIndicator(Modifier.size(20.dp), color = Color.White, strokeWidth = 2.dp)
                        else Text("Search", style = t.ts(14, FontWeight.SemiBold, Color.White))
                    }
                }
                searchNote?.let {
                    Text(it, style = t.ts(12, color = t.muted, lineHeight = 17), modifier = Modifier.padding(horizontal = 12.dp))
                }
            }
        }
    }
}

@Composable
private fun WarnBox(t: MealioTheme, text: String, modifier: Modifier = Modifier) {
    Box(modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).background(t.warnBackground).padding(12.dp)) {
        Text(text, style = t.ts(13, color = t.warnText, lineHeight = 18))
    }
}

@Composable
private fun Thumb(t: MealioTheme, product: Product?, dim: Boolean = false, big: Boolean = false) {
    val img = rememberProductImage(product?.imageUrl)
    val shape = RoundedCornerShape(10.dp)
    val size = if (big) Modifier.fillMaxWidth().height(72.dp) else Modifier.size(48.dp)
    Box(
        size.alpha(if (dim) 0.45f else 1f).clip(shape).background(if (product?.imageUrl != null) Color.White else t.surface),
        contentAlignment = Alignment.Center,
    ) {
        if (img != null) Image(img, contentDescription = null, contentScale = ContentScale.Fit, modifier = Modifier.fillMaxSize())
    }
}

/**
 * The finished run. What the store took, row by row (image, product, the
 * recipe line, amount, price), then what was left out. No total unless every
 * added item has a price. No open-cart button: the user's next step is the
 * store's own app or site, not ours.
 */
@Composable
private fun ColumnScope.Done(t: MealioTheme, cart: CartSession, result: AddResult, storeName: String, onDone: () -> Unit) {
    val n = result.added.size
    val sum = remember(result) { cart.addedTotal(result) }
    val left = remember(result) { leftOut(cart, result, storeName) }
    var open by remember(result) { mutableStateOf(result.failed.isNotEmpty()) }
    val total = sum.total
    val subtitle = listOfNotNull(
        if (total != null) (if (sum.estimated) "about " else "") + money(total) else "Prices at checkout",
        null,
    ).joinToString(" · ")
    val title = if (n > 0) "$n item${if (n == 1) "" else "s"} added" else "Nothing was added"
    val card = RoundedCornerShape(t.radius + 2.dp)

    Column(
        Modifier
            .weight(1f)
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(start = 20.dp, end = 20.dp, top = 8.dp, bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        val bannerLabel = if (n > 0) "$title, $subtitle" else "$title. Your cart did not change."
        Row(
            Modifier
                .fillMaxWidth()
                .clip(card)
                .background(if (n > 0) t.accent.copy(alpha = 0.10f) else t.warnBackground)
                .clearAndSetSemantics {
                    contentDescription = bannerLabel
                    liveRegion = LiveRegionMode.Polite
                }
                .padding(vertical = 14.dp, horizontal = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Box(
                Modifier.size(36.dp).clip(CircleShape).background(if (n > 0) t.accent else t.warnText),
                contentAlignment = Alignment.Center,
            ) {
                if (n > 0) CheckIcon(t.onAccent, Modifier.size(18.dp))
                else Text("!", style = t.ts(18, FontWeight.ExtraBold, t.onAccent))
            }
            Column(Modifier.weight(1f)) {
                Text(title, style = t.ts(15, FontWeight.Bold, if (n > 0) t.text else t.warnText))
                Text(
                    if (n > 0) subtitle else "Your cart did not change.",
                    style = t.ts(13, color = if (n > 0) t.text.copy(alpha = 0.85f) else t.warnText, lineHeight = 18),
                )
            }
        }

        if (n > 0) {
            Column(Modifier.fillMaxWidth().clip(card).background(t.background).border(1.dp, t.border, card)) {
                result.added.forEachIndexed { i, a -> key(a.key) { AddedRow(t, cart, a, first = i == 0) } }
            }
        }

        if (left.isNotEmpty()) {
            val names = left.joinToString(", ") { it.label }
            Column(Modifier.fillMaxWidth().clip(card).background(t.background).border(1.dp, t.border, card)) {
                Row(
                    Modifier
                        .fillMaxWidth()
                        .heightIn(min = 56.dp)
                        .clickable(role = Role.Button, onClick = { open = !open })
                        .semantics {
                            contentDescription = "Left out this time: $names"
                            stateDescription = if (open) "Expanded" else "Collapsed"
                        }
                        .padding(vertical = 10.dp, horizontal = 16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Column(Modifier.weight(1f)) {
                        Text("Left out this time", style = t.ts(14, FontWeight.SemiBold))
                        if (!open) {
                            Text(sentence(names), style = t.ts(12, color = t.muted, lineHeight = 17), maxLines = 2, overflow = TextOverflow.Ellipsis)
                        }
                    }
                    ChevronIcon(t.muted, up = open, modifier = Modifier.size(18.dp))
                }
                if (open) {
                    for (x in left) {
                        key(x.key) {
                            TopRule(t)
                            Column(
                                Modifier
                                    .fillMaxWidth()
                                    .clearAndSetSemantics { contentDescription = "${x.label}, ${x.why}" }
                                    .padding(vertical = 10.dp, horizontal = 16.dp),
                                verticalArrangement = Arrangement.spacedBy(2.dp),
                            ) {
                                Text(sentence(x.label), style = t.ts(14, FontWeight.Medium), maxLines = 2, overflow = TextOverflow.Ellipsis)
                                Text(x.why, style = t.ts(12, color = if (x.failed) t.warnText else t.muted, lineHeight = 17))
                            }
                        }
                    }
                }
            }
        }
    }
    Column(
        Modifier.fillMaxWidth().background(t.background).padding(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 28.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Cta(t, onClick = onDone) { Text("Done", style = t.ts(16, FontWeight.Bold, t.onAccent)) }
        Text(
            "Cart by Mealio",
            style = t.ts(12, color = t.muted, lineHeight = 17, align = TextAlign.Center),
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Composable
private fun AddedRow(t: MealioTheme, cart: CartSession, item: AddedItem, first: Boolean) {
    val product = cart.selected(item.key)
    val image = item.imageUrl?.takeIf { it.isNotEmpty() } ?: product?.imageUrl
    val line = item.ingredient?.takeIf { it.isNotEmpty() } ?: cart.items.firstOrNull { it.key == item.key }?.ingredient ?: ""
    val w = item.weightLb
    val amount = if (w != null) lbText(w) else "×${item.quantity}"
    val p = cart.addedPrice(item)
    val price = p?.let { (if (it.estimated) "about " else "") + money(it.amount) } ?: ""
    val spoken = listOfNotNull(
        item.name,
        if (line.isNotEmpty()) "for $line" else null,
        if (w != null) "${lbNumber(w)} pounds" else "quantity ${item.quantity}",
        price.takeIf { it.isNotEmpty() },
    ).joinToString(", ")
    Column(Modifier.fillMaxWidth()) {
        if (!first) TopRule(t)
        Row(
            Modifier
                .fillMaxWidth()
                .heightIn(min = 68.dp)
                .clearAndSetSemantics { contentDescription = spoken }
                .padding(vertical = 12.dp, horizontal = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            val img = rememberProductImage(image)
            Box(
                Modifier.size(44.dp).clip(RoundedCornerShape(10.dp)).background(if (img != null) Color.White else t.surface),
                contentAlignment = Alignment.Center,
            ) {
                if (img != null) Image(img, contentDescription = null, contentScale = ContentScale.Fit, modifier = Modifier.fillMaxSize())
                else Text(monogram(item.name), style = t.ts(13, FontWeight.Bold, t.muted))
            }
            Column(Modifier.weight(1f)) {
                Text(item.name, style = t.ts(14, FontWeight.SemiBold, lineHeight = 19), maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (line.isNotEmpty()) {
                    Text(line, style = t.ts(12, color = t.muted, lineHeight = 17), maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
            Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    amount,
                    style = t.ts(12, FontWeight.Bold),
                    modifier = Modifier.clip(RoundedCornerShape(999.dp)).background(t.surface).padding(vertical = 3.dp, horizontal = 8.dp),
                )
                if (price.isNotEmpty()) Text(price, style = t.ts(12, color = t.muted, lineHeight = 17))
            }
        }
    }
}

/** A drawn check mark, so the module needs no icon library. */
@Composable
private fun CheckIcon(color: Color, modifier: Modifier = Modifier) {
    Canvas(modifier) {
        val s = size.minDimension
        val path = Path().apply {
            moveTo(s * 0.18f, s * 0.53f)
            lineTo(s * 0.41f, s * 0.75f)
            lineTo(s * 0.84f, s * 0.28f)
        }
        drawPath(path, color, style = Stroke(width = s * 0.15f, cap = StrokeCap.Round, join = StrokeJoin.Round))
    }
}

/** A drawn chevron: down when collapsed, up when open. */
@Composable
private fun ChevronIcon(color: Color, up: Boolean, modifier: Modifier = Modifier) {
    Canvas(modifier) {
        val s = size.minDimension
        val (y1, y2) = if (up) s * 0.62f to s * 0.36f else s * 0.38f to s * 0.64f
        val path = Path().apply {
            moveTo(s * 0.22f, y1)
            lineTo(s * 0.5f, y2)
            lineTo(s * 0.78f, y1)
        }
        drawPath(path, color, style = Stroke(width = s * 0.11f, cap = StrokeCap.Round, join = StrokeJoin.Round))
    }
}

private class LeftOut(val key: String, val label: String, val why: String, val failed: Boolean)

/** Everything the store did not take this run: unchecked, skipped, or failed (with its reason). */
private fun leftOut(cart: CartSession, result: AddResult, storeName: String): List<LeftOut> {
    fun item(key: String) = cart.items.firstOrNull { it.key == key }
    val out = ArrayList<LeftOut>()
    for (f in result.failed) {
        out += LeftOut(f.key, item(f.key)?.ingredient?.takeIf { it.isNotEmpty() } ?: f.name, sentence("${f.name}: ${reasonText(f.reason)}"), true)
    }
    for (x in result.skipped) {
        val it = item(x.key)
        val why = when {
            it?.status == ItemStatus.UNAVAILABLE -> "Not found at $storeName"
            x.reason == "preference_required" -> "Needed an option chosen"
            x.reason == "deselected" -> "Unchecked this time"
            else -> "Not chosen"
        }
        out += LeftOut(x.key, it?.ingredient?.takeIf { s -> s.isNotEmpty() } ?: x.key, why, false)
    }
    return out
}

/** First letter up: "Corn tortillas, chipotle peppers". */
private fun sentence(x: String): String = if (x.isEmpty()) x else x[0].uppercaseChar() + x.substring(1)

/** Two letters for an image-less product tile: "Fresh Yellow Onion" -> "FY". */
internal fun monogram(name: String): String {
    val w = name.replace(Regex("[^A-Za-z0-9 ]+"), " ").trim().split(Regex("\\s+")).filter { it.isNotEmpty() }
    return ((w.getOrNull(0)?.take(1) ?: "") + (w.getOrNull(1)?.take(1) ?: "")).uppercase()
}

/** "0.75", "1": pounds without the unit. */
private fun lbNumber(lb: Double): String =
    java.math.BigDecimal(String.format(java.util.Locale.US, "%.2f", lb)).stripTrailingZeros().toPlainString()

/** "0.75 lb", "1 lb". */
internal fun lbText(lb: Double): String =
    java.math.BigDecimal(String.format(java.util.Locale.US, "%.2f", lb)).stripTrailingZeros().toPlainString() + " lb"

/** "A, B or C". */
internal fun listOr(xs: List<String>): String {
    if (xs.size <= 1) return xs.firstOrNull() ?: ""
    return xs.dropLast(1).joinToString(", ") + " or " + xs.last()
}

/** The price as a row shows it. Sold by the pound: "$9.99/lb est.". */
internal fun priceText(p: Product): String {
    val perLb = p.pricePerLb
    if (p.soldByWeight == true && perLb != null) return "${money(perLb)}/lb est."
    return ((p.price ?: "") + (if (p.estimated) " est." else "")).trim()
}

internal fun reasonText(r: String): String = when {
    r == "not_confirmed" -> "not confirmed in your cart"
    r == "weight_not_supported" -> "sold by weight, which this store cannot take here"
    Regex("stock").containsMatchIn(r) -> "out of stock"
    Regex("timeout|no_answer").containsMatchIn(r) -> "the store did not answer"
    else -> "the store refused it"
}

@Composable
private fun ColumnScope.StorePicker(
    t: MealioTheme,
    stores: List<StoreInfo>?,
    current: String?,
    onPick: (String) -> Unit,
    onBack: (() -> Unit)?,
) {
    if (stores == null) {
        Box(Modifier.fillMaxWidth().padding(20.dp), contentAlignment = Alignment.Center) {
            CircularProgressIndicator(Modifier.size(28.dp), color = t.accent, strokeWidth = 2.5.dp)
        }
        return
    }
    Column(
        Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).padding(start = 16.dp, end = 16.dp, bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        if (stores.isEmpty()) Text("Could not load stores. Close and try again.", style = t.ts(14, color = t.muted))
        for (st in stores) {
            val on = st.id == current
            val shape = RoundedCornerShape(t.radius)
            Row(
                Modifier
                    .fillMaxWidth()
                    .heightIn(min = 56.dp)
                    .clip(shape)
                    .border(if (on) 2.dp else 1.dp, if (on) t.accent else t.border, shape)
                    .selectable(selected = on, role = Role.RadioButton, onClick = { onPick(st.id) })
                    .padding(horizontal = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text(st.name, style = t.ts(15, FontWeight.SemiBold, lineHeight = 20), modifier = Modifier.weight(1f))
                if (on) Text("Current", style = t.ts(12, color = t.accent, lineHeight = 17))
            }
        }
    }
    if (onBack != null) {
        TopRule(t)
        Column(Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 28.dp)) {
            Cta(t, onClick = onBack, background = t.surface) { Text("Back to your list", style = t.ts(16, FontWeight.Bold, t.text)) }
        }
    }
}

@Composable
private fun ColumnScope.ErrorView(t: MealioTheme, error: FlowError?, onRetry: () -> Unit, onClose: () -> Unit) {
    val msg = if (error?.code == "login_cancelled") "Sign-in was closed before it finished." else error?.message ?: "Something went wrong."
    Column(Modifier.weight(1f).fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(msg, style = t.ts(15))
        Spacer(Modifier.weight(1f))
        Cta(t, onClick = onRetry) { Text("Try again", style = t.ts(16, FontWeight.Bold, t.onAccent)) }
        Cta(t, onClick = onClose, background = t.surface) { Text("Close", style = t.ts(16, FontWeight.Bold, t.text)) }
    }
}
