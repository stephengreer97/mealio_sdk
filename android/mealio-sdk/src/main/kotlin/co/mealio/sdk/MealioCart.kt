package co.mealio.sdk

import android.content.Context
import android.content.pm.ApplicationInfo
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * The partner-facing entry point.
 *
 * ```
 * MealioCart.configure(context, "pk_live_...", sessionTokenProvider = { myServer.mealioSessionToken() })
 * // Compose: MealioCartButton(recipe, store = "heb") runs the whole flow.
 * // Several meals in one cart: MealioCartButton(recipes = listOf(tacos, pasta)).
 * // Or by hand:
 * val session = MealioCart.prepareCart("heb", recipe, zip = "78701")
 * session.select(item.key, session.options(item.key).first().id)
 * val result = session.addToCart()
 * ```
 */
object MealioCart {
    const val SDK_VERSION = "0.5.0"

    private class State(val client: MealioClient, val host: WebViewHost, val sessions: StoreSessions)

    @Volatile private var state: State? = null

    /** For work that outlives a screen, like the store sign-out after a user change. */
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    private val userState = MutableStateFlow(MealioUser())

    /** Who [setUser] says is signed in. The drop-in watches it. */
    val user: StateFlow<MealioUser> = userState.asStateFlow()

    /**
     * Called when a MealioCartButton or MealioStoreSettings is used while
     * [setUser] says nobody is signed in, and the composable has no
     * onSignInRequired of its own. Send the user to your sign-in. With neither,
     * the button is disabled.
     */
    @Volatile var onSignInRequired: (() -> Unit)? = null

    /**
     * Set up the SDK once, e.g. in Application.onCreate. Calling it again
     * replaces the previous setup.
     *
     * @param publishableKey the partner app's publishable key.
     * @param sessionTokenProvider returns an SDK session token from YOUR server
     *   (which calls POST /api/v1/sessions with its secret key). Called again
     *   when the token expires.
     * @param baseUrl override for testing.
     * @param attestationProvider optional Play Integrity token, when attestation is on.
     */
    @JvmOverloads
    fun configure(
        context: Context,
        publishableKey: String,
        sessionTokenProvider: suspend () -> String,
        baseUrl: String = DEFAULT_BASE_URL,
        attestationProvider: (suspend () -> String?)? = null,
    ) {
        val app = context.applicationContext
        val sessions = StoreSessions(app)
        val host = WebViewHost(app)
        val config = MealioConfig(
            publishableKey = publishableKey,
            sessionTokenProvider = sessionTokenProvider,
            platform = "android",
            sdkVersion = SDK_VERSION,
            baseUrl = baseUrl,
            attestationProvider = attestationProvider,
            epochProvider = { sessions.epoch() },
            debug = (app.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0,
        )
        val old = state
        val client = MealioClient(config, host)
        // Carry the user over to the new client.
        val u = userState.value
        if (u.tracked) client.setUser(u.id)
        // The hidden page and fetch redirects are checked against the same
        // allowlist the runner uses, widenings included.
        host.allowlist = client.allowlist
        state = State(client, host, sessions)
        old?.host?.destroy()
    }

    val isConfigured: Boolean get() = state != null

    /** The underlying client, for apps that want to call it directly. */
    val client: MealioClient get() = current().client

    /**
     * Start a cart for `recipe` at `store`. Shows the store's sign-in when the
     * user is not signed in (inside an open MealioCartFlow sheet, else in its
     * own screen), then searches every ingredient. `store` null uses the
     * user's default store; with none yet it fails with "store_required".
     * A Kroger family store the user has not chosen a location for fails with
     * "location_required", before any sign-in. Pass `zip` to use the nearest
     * store instead of asking them. Throws MealioException.
     */
    @JvmOverloads
    suspend fun prepareCart(store: String?, recipe: Recipe, zip: String? = null, onStep: StepListener? = null): CartSession =
        current().client.prepareCart(store, recipe, zip, onStep)

    /**
     * Start one cart from several recipes (at most [MAX_RECIPES]). Ingredients
     * they share become one item; [CartSession.recipesFor] says which recipes
     * each item is for. Throws MealioException ("bad_recipe" for none,
     * "too_many_recipes" for more than MAX_RECIPES).
     */
    @JvmOverloads
    suspend fun prepareCart(store: String?, recipes: List<Recipe>, zip: String? = null, onStep: StepListener? = null): CartSession =
        current().client.prepareCart(store, recipes, zip, onStep)

    /**
     * As above, stopped by `cancel`: it stops after the current step, sends
     * nothing more, never shows sign-in, and fails with "cancelled".
     */
    suspend fun prepareCart(store: String?, recipes: List<Recipe>, zip: String?, cancel: CancelToken, onStep: StepListener? = null): CartSession =
        current().client.prepareCart(store, recipes, zip, cancel, onStep)

    /** Stores the SDK supports right now (GET /api/v1/stores). */
    suspend fun stores(): List<StoreInfo> = current().client.stores()

    /** A Kroger family chain's stores near a zip, for your own store screen. */
    suspend fun storeLocations(store: String, zip: String): List<StoreLocation> =
        current().client.storeLocations(store, zip)

    /** The user's default store, and their exact store if it is in the Kroger family. */
    suspend fun storePreferences(): StorePreferences = current().client.storePreferences()

    /** Make a store the user's default. Kroger family stores need `locationId` the first time. */
    @JvmOverloads
    suspend fun setStore(store: String, locationId: String? = null): StorePreferences =
        current().client.setStore(store, locationId)

    /**
     * Run the login check for the user's store ahead of time, so the next cart
     * starts at search. MealioCartButton does this when it appears; call it
     * yourself if you start carts another way. Never shows sign-in, never
     * throws, and does nothing before [configure].
     */
    @JvmOverloads
    suspend fun warm(store: String? = null) {
        state?.client?.warm(store)
    }

    /**
     * The signed-in user changed. Forget the session, so the next call asks your
     * server for a new one. Signing out of the stores does this too.
     */
    fun resetSession() {
        state?.client?.resetSession()
    }

    /**
     * Tell the SDK who is signed in to your app: their id, or null for nobody.
     * Call it at start-up and whenever that changes. On a change it stops any
     * cart still loading, starts a new Mealio session, and when the old value
     * was a user, signs out of the stores on this device (that never throws,
     * and an add under way finishes first). While null, warm does nothing, no
     * session is asked for, and MealioCartButton calls [onSignInRequired].
     * Calling it with the same id again does nothing.
     */
    fun setUser(id: String?) {
        userState.value = MealioUser(tracked = true, id = id)
        val s = state ?: return
        if (s.client.setUser(id)) queueExclusive(scope, s.client) { clearAllStores(s) }
    }

    /** Stop every cart still loading and every search. An add runs on. */
    fun cancelJobs() {
        state?.client?.cancelJobs()
    }

    /** Sign the user out of one store on this device. */
    suspend fun signOutOfStore(store: String) {
        val s = current()
        s.client.cancelJobs()
        s.client.resetSession()
        // Queued, so an add under way finishes first and the next cart waits for this.
        s.client.runExclusive {
            val hosts = s.client.allowlist.hostsFor(store) ?: STORES[store]
            if (hosts != null) s.sessions.clearStore(hosts)
            s.host.reset()
            s.sessions.bumpEpoch()
        }
    }

    /**
     * Sign the user out of every store on this device. Note that this clears
     * ALL cookies and web storage of the app's WebViews (CookieManager is
     * process-wide), not only the stores'.
     */
    suspend fun signOutOfAllStores() {
        val s = current()
        s.client.cancelJobs()
        s.client.resetSession()
        s.client.runExclusive { clearAllStores(s) }
    }

    /**
     * Run `block` in the client's job queue from non-suspending code. Undispatched,
     * so it takes its place in the queue before this returns: a cart started
     * after this call (the next user's, after setUser) runs after it, never
     * before. A failure is dropped: a failed store sign-out never blocks a user change.
     */
    internal fun queueExclusive(scope: CoroutineScope, client: MealioClient, block: suspend () -> Unit) {
        scope.launch(start = CoroutineStart.UNDISPATCHED) {
            try {
                client.runExclusive(block)
            } catch (e: Throwable) {
                // See above.
            }
        }
    }

    private suspend fun clearAllStores(s: State) {
        s.sessions.clearAll()
        s.host.reset()
        s.sessions.bumpEpoch()
    }

    private fun current(): State =
        state ?: throw IllegalStateException("Call MealioCart.configure(context, publishableKey, sessionTokenProvider) first")
}

/**
 * Who [MealioCart.setUser] says is signed in. `tracked` is false until it is
 * first called: then users are not tracked and every call may ask for a session.
 */
data class MealioUser(val tracked: Boolean = false, val id: String? = null) {
    /** False only when setUser(null) said nobody is signed in. */
    val signedIn: Boolean get() = !tracked || id != null
}
