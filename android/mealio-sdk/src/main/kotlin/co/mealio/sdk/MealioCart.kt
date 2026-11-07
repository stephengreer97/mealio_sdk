package co.mealio.sdk

import android.content.Context

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
    const val SDK_VERSION = "0.5.1"

    private class State(val client: MealioClient, val host: WebViewHost, val sessions: StoreSessions)

    @Volatile private var state: State? = null

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
        )
        val old = state
        val client = MealioClient(config, host)
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

    /** Sign the user out of one store on this device. */
    suspend fun signOutOfStore(store: String) {
        val s = current()
        s.client.resetSession()
        val hosts = s.client.allowlist.hostsFor(store) ?: STORES[store]
        if (hosts != null) s.sessions.clearStore(hosts)
        s.host.reset()
        s.sessions.bumpEpoch()
    }

    /**
     * Sign the user out of every store on this device. Note that this clears
     * ALL cookies and web storage of the app's WebViews (CookieManager is
     * process-wide), not only the stores'.
     */
    suspend fun signOutOfAllStores() {
        val s = current()
        s.client.resetSession()
        s.sessions.clearAll()
        s.host.reset()
        s.sessions.bumpEpoch()
    }

    private fun current(): State =
        state ?: throw IllegalStateException("Call MealioCart.configure(context, publishableKey, sessionTokenProvider) first")
}
