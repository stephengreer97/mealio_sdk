package co.mealio.sdk.compose

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import co.mealio.sdk.AddResult
import co.mealio.sdk.CancelReason
import co.mealio.sdk.CancelToken
import co.mealio.sdk.CartSession
import co.mealio.sdk.MealioCart
import co.mealio.sdk.MealioEvent
import co.mealio.sdk.MealioException
import co.mealio.sdk.MealioInlineLogin
import co.mealio.sdk.MealioSheetStep
import co.mealio.sdk.MealioUser
import co.mealio.sdk.Recipe
import co.mealio.sdk.Step
import co.mealio.sdk.StepListener
import co.mealio.sdk.StoreInfo
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

// The cart flow's state and its running job, kept outside composition so an
// activity recreation (rotation, a dark mode change) does not restart it. The
// sheet finds its model again by a saveable id (see FlowModels). After process
// death the id comes back with no model, and no new cart is started.

internal enum class Phase { LOADING, LIST, ADDING, DONE, ERROR, STORES, LOCATION }

internal data class FlowError(val code: String, val message: String)

/** What the flow asks of the SDK. MealioCart in the app, a fake in tests. */
internal interface FlowBackend {
    suspend fun prepareCart(store: String?, recipes: List<Recipe>, cancel: CancelToken, onStep: StepListener): CartSession
    suspend fun stores(): List<StoreInfo>
}

internal object MealioCartBackend : FlowBackend {
    override suspend fun prepareCart(store: String?, recipes: List<Recipe>, cancel: CancelToken, onStep: StepListener): CartSession =
        MealioCart.prepareCart(store, recipes, null, cancel, onStep)

    override suspend fun stores(): List<StoreInfo> = MealioCart.stores()
}

/** The store sign-in shown inside the sheet. MealioInlineLogin in the app. */
internal interface FlowLogin {
    val active: Boolean
    fun cancel()
    fun goBack(): Boolean
    /** The sheet is open and will show sign-ins itself. Returns how to detach. */
    fun attachSheet(): () -> Unit
}

internal object InlineFlowLogin : FlowLogin {
    override val active: Boolean get() = MealioInlineLogin.current.value != null
    override fun cancel() { MealioInlineLogin.current.value?.cancel() }
    override fun goBack(): Boolean = MealioInlineLogin.current.value?.goBack() == true
    override fun attachSheet(): () -> Unit = MealioInlineLogin.attachSheet()
}

/** The partner's callbacks. The latest composition's are the ones called. */
internal class FlowCallbacks(
    val onClose: (AddResult?) -> Unit,
    val onAdded: (AddResult) -> Unit,
    val onError: (Exception) -> Unit,
)

internal class CartFlowModel(
    private val recipes: List<Recipe>,
    initialStore: String?,
    @Volatile var ui: MealioUi,
    @Volatile var callbacks: FlowCallbacks,
    private val backend: FlowBackend = MealioCartBackend,
    private val login: FlowLogin = InlineFlowLogin,
    dispatcher: CoroutineDispatcher = Dispatchers.Main.immediate,
    /** Who was signed in when the sheet opened. */
    private val openedFor: MealioUser = MealioCart.user.value,
    /** Who is signed in now. */
    private val userNow: () -> MealioUser = { MealioCart.user.value },
) {
    private val scope = CoroutineScope(SupervisorJob() + dispatcher)

    var phase by mutableStateOf(Phase.LOADING)
        private set
    var step by mutableStateOf(Step.CONNECTING)
        private set
    var cart by mutableStateOf<CartSession?>(null)
        private set
    var result by mutableStateOf<AddResult?>(null)
        private set
    var error by mutableStateOf<FlowError?>(null)
        private set
    var store by mutableStateOf(initialStore)
        private set
    var stores by mutableStateOf<List<StoreInfo>?>(null)
        private set
    var backTo by mutableStateOf(Phase.LIST)
        private set
    /** Bumped when the cart's picks change from here (restorePicks), so the list redraws. */
    var version by mutableIntStateOf(0)
        private set

    /** The cart of a failed add, so Try again keeps the user's picks. */
    var failedAdd by mutableStateOf<CartSession?>(null)
        private set

    /** Each start, close and dispose bumps it: a job that is not the latest reports nothing. */
    private var run = 0
    /** The prepare under way, so closing can stop it. */
    private var preparing: CancelToken? = null
    /** An add is running. It runs to its end: nothing closes the sheet meanwhile. */
    var adding by mutableStateOf(false)
        private set
    /** The store the partner passes, for Try again and a cart still loading. */
    private var propStore: String? = initialStore

    private var detachSheet: (() -> Unit)? = null
    private var attached = 0
    /** Ends this model when no screen takes it back after a recreation. */
    private var reclaim: Job? = null
    /**
     * No screen took this model back while an add ran. The add still reports
     * (straight to the partner's callbacks), then the model is disposed.
     */
    private var orphaned = false
    /** Prepares restarted in a row after a cancel the user did not ask for. */
    private var restarts = 0

    /**
     * The partner set `visible` to false. The sheet stays up while an add
     * runs; when it ends, its result is reported (onAdded or onError) and the
     * sheet closes with onClose.
     */
    var hidden = false
    private val queued = ArrayList<() -> Unit>()
    var finished by mutableStateOf(false)
        private set

    init {
        // From open to close, even while the activity is being recreated, a
        // sign-in shows in this sheet and is not cancelled for lack of one.
        detachSheet = login.attachSheet()
        ui.emit(MealioEvent.SheetOpened(recipes.size))
        start(initialStore)
    }

    /** A composition shows this model. */
    fun attach() {
        attached += 1
        reclaim?.cancel()
        reclaim = null
        val now = queued.toList()
        queued.clear()
        for (fn in now) fn()
    }

    /**
     * The composition went away for an activity recreation. The job runs on,
     * for the new screen to take back. When none does within [RECLAIM_MS]
     * (the new activity does not show the sheet again), the model is disposed,
     * so it and its sheet attachment do not live on.
     */
    fun detach() {
        attached = (attached - 1).coerceAtLeast(0)
        if (attached > 0 || finished) return
        reclaim?.cancel()
        reclaim = scope.launch {
            delay(RECLAIM_MS)
            if (attached > 0) return@launch
            // An add is never dropped: it reports when it ends, then this goes.
            if (adding) orphaned = true else dispose()
        }
    }

    /**
     * A partner callback now, or when a composition shows this again. Hidden
     * or orphaned, no composition will: now.
     */
    private fun deliver(fn: () -> Unit) {
        if (finished) return
        if (attached > 0 || hidden || orphaned) fn() else queued.add(fn)
    }

    fun stepNow(): MealioSheetStep = if (login.active) MealioSheetStep.SIGNIN else when (phase) {
        Phase.LOADING -> MealioSheetStep.LOADING
        Phase.LIST -> MealioSheetStep.LIST
        Phase.ADDING -> MealioSheetStep.ADDING
        Phase.DONE -> MealioSheetStep.DONE
        Phase.ERROR -> MealioSheetStep.ERROR
        Phase.STORES -> MealioSheetStep.STORES
        Phase.LOCATION -> MealioSheetStep.LOCATION
    }

    private fun fail(e: Exception, fallback: String, at: MealioSheetStep) {
        val code = (e as? MealioException)?.code ?: "error"
        error = FlowError(code, e.message ?: fallback)
        phase = Phase.ERROR
        ui.emit(MealioEvent.Error(code, at))
        deliver { callbacks.onError(e) }
    }

    fun openStores(from: Phase) {
        backTo = from
        phase = Phase.STORES
        // An empty list is a load that failed: try again each time.
        if (stores.isNullOrEmpty()) {
            stores = null
            scope.launch {
                stores = try {
                    backend.stores()
                } catch (e: Throwable) {
                    if (e is CancellationException && !currentCoroutineContext().isActive) throw e
                    emptyList()
                }
            }
        }
    }

    fun openLocation(from: Phase) {
        backTo = from
        phase = Phase.LOCATION
    }

    fun askLocation(storeId: String, from: Phase) {
        ui.emit(MealioEvent.LocationAsked(storeId))
        openLocation(from)
    }

    fun backToList() {
        if (cart != null) phase = Phase.LIST
    }

    fun pickStore(id: String) {
        ui.emit(MealioEvent.StorePicked(id))
        restarts = 0
        start(id)
    }

    /** Try again, with the store as it stands now. */
    fun retry() {
        restarts = 0
        start(store)
    }

    fun start(storeId: String?) {
        if (finished || adding) return
        val id = ++run
        preparing?.cancel()
        val cancel = CancelToken()
        preparing = cancel
        store = storeId
        phase = Phase.LOADING; step = Step.CONNECTING; cart = null; result = null; error = null
        scope.launch {
            try {
                val c = backend.prepareCart(storeId, recipes, cancel) { s, _ -> if (run == id) step = s }
                if (run != id) return@launch
                // A searched pick is searched for again on the new cart, under this prepare's cancel.
                failedAdd?.let {
                    c.restorePicks(it, cancel) { s, _ -> if (run == id) step = s }
                    if (run != id) return@launch
                    failedAdd = null
                    version += 1
                }
                restarts = 0
                store = c.store
                cart = c
                phase = Phase.LIST
                ui.emit(MealioEvent.ListShown(c.store, c.items.size))
            } catch (e: Throwable) {
                // Only a cancel of this scope ends quietly. A partner's own
                // CancellationException is an error like any other.
                if (e is CancellationException && !currentCoroutineContext().isActive) throw e
                if (e is Error) throw e
                // Stopped by close, a newer start or dispose: report nothing.
                if (run != id) return@launch
                val ex = e as? Exception ?: return@launch
                when ((ex as? MealioException)?.code) {
                    // Stopped by something other than closing (a store sign-out,
                    // cancelJobs, a user change): never an error. Load again
                    // while the sheet is open, or close quietly when what it
                    // showed was another user's.
                    "cancelled" -> when {
                        userNow() != openedFor || (ex as MealioException).reason == CancelReason.USER_CHANGED -> close()
                        // Cancelled again and again from outside: stop, and let the user try again.
                        restarts >= MAX_RESTARTS -> fail(ex, ui.tr("somethingWrongSentence"), MealioSheetStep.LOADING)
                        else -> { restarts += 1; start(storeId) }
                    }
                    "store_required", "store_not_allowed" -> {
                        store = null
                        openStores(Phase.ERROR)
                    }
                    // Which store the user shops at is theirs to say. With no store
                    // named there is nothing to look up, so they pick the chain first.
                    "location_required" -> if (storeId != null) {
                        store = storeId
                        askLocation(storeId, Phase.ERROR)
                    } else {
                        openStores(Phase.ERROR)
                    }
                    else -> fail(ex, ui.tr("somethingWrongSentence"), MealioSheetStep.LOADING)
                }
            }
        }
    }

    /** Add the picks to the store cart. A second tap while one runs does nothing. */
    fun add() {
        val c = cart ?: return
        if (finished || adding || phase != Phase.LIST || c.searching) return
        adding = true
        phase = Phase.ADDING
        ui.emit(MealioEvent.AddStarted(c.estimate().count))
        val id = run
        scope.launch {
            try {
                val r = c.addToCart()
                if (run != id) return@launch
                failedAdd = null
                result = r
                phase = Phase.DONE
                ui.emit(MealioEvent.CartAdded(r.store, r.added.size, r.failed.size))
                deliver { callbacks.onAdded(r) }
            } catch (e: Throwable) {
                if (e is CancellationException && !currentCoroutineContext().isActive) throw e
                if (e is Error) throw e
                if (run != id) return@launch
                failedAdd = c
                fail(e as? Exception ?: Exception(e), ui.tr("couldNotAdd"), MealioSheetStep.ADDING)
            } finally {
                adding = false
                if (run == id) userCheck?.let { checkUser(it) }
                // Hidden by the partner meanwhile: the result is out, now close.
                if (run == id && hidden && !finished) close()
                // No screen took it back: the result is out, now go.
                if (run == id && orphaned && !finished) dispose()
            }
        }
    }

    /** Stop what can be stopped. Nothing it was doing reports afterwards. */
    private fun stop() {
        run += 1
        preparing?.cancel(CancelReason.CLOSED)
        cart?.cancelSearches(CancelReason.CLOSED)
    }

    /**
     * Every way of closing lands here: X, back, Done. An add cannot be stopped,
     * so while one runs the sheet stays open, though a sign-in the add asked
     * for can still be dismissed. Returns true when the sheet closed.
     */
    fun close(): Boolean {
        if (finished) return false
        if (adding) {
            if (login.active) login.cancel()
            return false
        }
        stop()
        ui.emit(MealioEvent.SheetClosed(stepNow(), if (phase == Phase.DONE) result?.added?.size ?: 0 else 0))
        login.cancel()
        val r = if (phase == Phase.DONE) result else null
        val onClose = callbacks.onClose
        end()
        // Called even with no composition showing: closing is what ends this model.
        onClose(r)
        return true
    }

    /** Back: inside the store's sign-in pages first, then close the sheet. */
    fun back() {
        if (login.goBack()) return
        close()
    }

    /** The partner passes a different store. A cart still loading moves to it; Try again uses it. */
    fun propStoreChanged(next: String?) {
        if (next == propStore) return
        propStore = next
        if (finished) return
        if (phase == Phase.LOADING) start(next)
        else if (phase == Phase.ERROR) store = next
    }

    private var userCheck: MealioUser? = null

    /** The user changed: what is on screen was theirs. An add finishes first. */
    fun checkUser(now: MealioUser) {
        if (finished || now == openedFor) return
        if (adding) { userCheck = now; return }
        failedAdd = null
        close()
    }

    /**
     * The sheet left composition for good (not a recreation). Unmounting
     * cancels too, and reports nothing afterwards. An add under way still ends
     * by itself.
     */
    fun dispose() {
        if (finished) return
        stop()
        end()
    }

    private fun end() {
        finished = true
        queued.clear()
        detachSheet?.invoke()
        detachSheet = null
        FlowModels.remove(this)
        // A running add keeps the scope until it ends; nothing else is left.
        if (!adding) scope.cancel()
    }
}

/** How long a model waits for a recreated screen to show it again. */
internal const val RECLAIM_MS = 5_000L

/**
 * Restarts in a row after an outside cancel. One more cancel shows the error
 * screen with Try again; a good prepare or any user action starts the count over.
 */
private const val MAX_RESTARTS = 3

/**
 * Flow models by the sheet's saveable id. They live as long as the process, so
 * a recreated activity finds its sheet's job still running.
 */
internal object FlowModels {
    private val models = HashMap<String, CartFlowModel>()

    /**
     * The model for `id`. A sheet opened just now gets a new one from `create`.
     * A sheet restored with no model (the process died) gets null: no new cart
     * starts on its own.
     */
    @Synchronized
    fun obtain(id: String, openedNow: Boolean, create: () -> CartFlowModel): CartFlowModel? {
        models[id]?.let { return it }
        if (!openedNow) return null
        return create().also { if (!it.finished) models[id] = it }
    }

    @Synchronized
    fun remove(model: CartFlowModel) {
        models.entries.removeAll { it.value === model }
    }

    @Synchronized
    internal fun size(): Int = models.size
}
