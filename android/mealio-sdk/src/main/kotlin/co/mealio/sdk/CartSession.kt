package co.mealio.sdk

/**
 * A prepared cart the app can show and edit before filling the store cart.
 * Port of CartSession in packages/core/src/client.ts.
 *
 * Items in `ready` with a `chosen` product start out selected (the user's
 * earlier pick for this recipe). Items in `needsChoice` wait for choose() or
 * skip(). Nothing here picks a product on its own.
 */
class CartSession internal constructor(
    private val client: MealioClient,
    val cart: PreparedCart,
) {
    private val picks = LinkedHashMap<String, Selection>()

    init {
        for (item in cart.ready) {
            val chosen = item.chosen ?: continue
            picks[item.key] = Selection(item.key, chosen.id, quantity = item.quantity, remember = true)
        }
    }

    val cartId: String get() = cart.cartId
    val store: String get() = cart.store
    val ready: List<CartItem> get() = cart.ready
    val needsChoice: List<CartItem> get() = cart.needsChoice
    val unavailable: List<CartItem> get() = cart.unavailable

    /** Items still waiting on the user. */
    @Synchronized
    fun pending(): List<CartItem> = cart.needsChoice.filter { it.key !in picks }

    /**
     * Pick `productId` for the item `key`. The product must be one the server
     * offered for that item. Throws MealioException "unknown_item" or
     * "unknown_product" otherwise.
     */
    @Synchronized
    @JvmOverloads
    fun choose(
        key: String,
        productId: String,
        quantity: Int? = null,
        remember: Boolean = true,
        preferenceId: String? = null,
    ) {
        val item = find(key) ?: throw MealioException("unknown_item", "No item $key")
        val known = (listOfNotNull(item.chosen) + item.options).any { it.id == productId }
        if (!known) throw MealioException("unknown_product", "Product $productId was not offered for $key")
        picks[key] = Selection(key, productId, quantity ?: item.quantity, remember, preferenceId)
    }

    /** Leave this ingredient out of the store cart. */
    @Synchronized
    fun skip(key: String) {
        picks[key] = Selection(key, null, remember = false)
    }

    /** The current selection for `key`, if any. */
    @Synchronized
    fun selectionFor(key: String): Selection? = picks[key]

    @Synchronized
    fun selections(): List<Selection> = picks.values.toList()

    /** Fill the store cart with the current selections. */
    suspend fun addToCart(): AddResult = client.addToCart(cart.cartId, selections())

    private fun find(key: String): CartItem? = (cart.ready + cart.needsChoice).firstOrNull { it.key == key }
}
