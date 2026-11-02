package co.mealio.sdk

import kotlin.math.roundToLong

/** The selected items' total, for "Estimated total about $12.40". */
data class Estimate(
    /** Unit price times quantity over the selected items that have a unit price, to the cent. */
    val total: Double,
    /** Selected items. */
    val count: Int,
    /** True when any selected item is sold by weight or has no price: show it as "about". */
    val estimated: Boolean,
    /** Selected items with no unit price (left out of `total`). */
    val unpriced: Int,
)

/**
 * A prepared cart. Port of CartSession in packages/core/src/client.ts.
 *
 * Every item is shown every run. Remembered products start selected; the user
 * can select another option, search for something else, or deselect an item to
 * leave it out of THIS run (its remembered choice is kept for next time).
 * Nothing here picks a product on its own.
 */
class CartSession internal constructor(
    private val client: MealioClient,
    val cart: PreparedCart,
) {
    private data class Pick(val productId: String, val preferenceId: String?)

    private val picks = LinkedHashMap<String, Pick>()
    private val extra = HashMap<String, List<Product>>()
    private val qty = HashMap<String, Int>()

    init {
        for (it in items) {
            val id = it.selectedId ?: continue
            picks[it.key] = Pick(id, it.rememberedPreferenceId)
        }
    }

    val cartId: String get() = cart.cartId
    val store: String get() = cart.store
    /** Display name, e.g. "H-E-B", when the server sent one. */
    val storeName: String? get() = cart.storeName

    /** Every item in recipe order. */
    val items: List<CartItem> get() = cart.items

    @Deprecated("Use items") val ready: List<CartItem> get() = cart.ready
    @Deprecated("Use items") val needsChoice: List<CartItem> get() = cart.needsChoice
    @Deprecated("Use items") val unavailable: List<CartItem> get() = cart.unavailable

    /** Options for an item, including any found with search(), without repeats. */
    @Synchronized
    fun options(key: String): List<Product> {
        val it = find(key)
        val base = it?.options?.takeIf { o -> o.isNotEmpty() } ?: listOfNotNull(it?.chosen)
        val more = extra[key] ?: emptyList()
        val seen = base.mapTo(HashSet()) { p -> p.id }
        return base + more.filter { p -> p.id !in seen }
    }

    @Synchronized
    fun selectedId(key: String): String? = picks[key]?.productId

    /** Packages to add for an item: the recipe's quantity (at least 1) until the user changes it. */
    @Synchronized
    fun quantity(key: String): Int = qty[key] ?: maxOf(1, find(key)?.quantity ?: 1)

    /** The most the user can add: the selected product's store cap, else 99. */
    @Synchronized
    fun maxQuantity(key: String): Int {
        val cap = selected(key)?.maxQuantity
        return if (cap != null && cap > 0) minOf(99, cap) else 99
    }

    /** Set the quantity, clamped to 1 and the store's cap. Returns what was set. */
    @Synchronized
    fun setQuantity(key: String, n: Int): Int {
        val v = maxOf(1, minOf(maxQuantity(key), n))
        qty[key] = v
        return v
    }

    @Synchronized
    fun isSelected(key: String): Boolean = key in picks

    @Synchronized
    fun selectedCount(): Int = picks.size

    /** The preference chosen with the selected product, if any. */
    @Synchronized
    fun selectedPreferenceId(key: String): String? = picks[key]?.preferenceId

    /** The selected product for an item, from its options. */
    @Synchronized
    fun selected(key: String): Product? {
        val id = picks[key]?.productId ?: return null
        return options(key).firstOrNull { it.id == id }
    }

    /**
     * Select `productId` for the item `key`. The product must be one of
     * options(key). Throws MealioException "unknown_item" or "unknown_product".
     */
    @Synchronized
    @JvmOverloads
    fun select(key: String, productId: String, preferenceId: String? = null) {
        if (find(key) == null) throw MealioException("unknown_item", "No item $key")
        if (options(key).none { it.id == productId }) {
            throw MealioException("unknown_product", "Product $productId was not offered for $key")
        }
        picks[key] = Pick(productId, preferenceId)
    }

    /** Leave the item out of this run. Its remembered choice is kept on the server. */
    @Synchronized
    fun deselect(key: String) {
        picks.remove(key)
    }

    /** Search the store for something else and add the results to this item's options. */
    @JvmOverloads
    suspend fun search(key: String, query: String, onStep: StepListener? = null): List<Product> {
        val r = client.search(cart.cartId, key, query, onStep)
        synchronized(this) {
            val prev = extra[key] ?: emptyList()
            val seen = prev.mapTo(HashSet()) { it.id }
            extra[key] = r.options.filter { it.id !in seen } + prev
        }
        return r.options
    }

    /**
     * One selection for EVERY item: selected ones as {productId, quantity,
     * remember: true, preferenceId}, the rest as {productId: null, remember: false}.
     */
    @Synchronized
    fun selections(): List<Selection> = items.map { it ->
        val p = picks[it.key]
        if (p != null) Selection(it.key, p.productId, quantity = minOf(quantity(it.key), maxQuantity(it.key)), remember = true, preferenceId = p.preferenceId)
        else Selection(it.key, null, remember = false)
    }

    /**
     * Estimated total of the selected items: unit price times quantity.
     * `estimated` is true when any item is sold by weight or has no price.
     */
    @Synchronized
    fun estimate(): Estimate {
        var total = 0.0
        var count = 0
        var unpriced = 0
        var estimated = false
        for (it in items) {
            val p = selected(it.key) ?: continue
            count += 1
            val u = p.unitPrice
            if (u != null) total += u * minOf(quantity(it.key), maxQuantity(it.key)) else unpriced += 1
            if (p.estimated) estimated = true
        }
        // Math.round(total * 100) / 100 in the reference (half rounds up).
        val cents = Math.floor(total * 100 + 0.5).roundToLong()
        return Estimate(cents / 100.0, count, estimated || unpriced > 0, unpriced)
    }

    /** Fill the store cart with the current selections. */
    @JvmOverloads
    suspend fun addToCart(onStep: StepListener? = null): AddResult = client.addToCart(cart.cartId, selections(), onStep)

    // ── 0.1 API ──────────────────────────────────────────────────────────

    @Deprecated("Use select()", ReplaceWith("select(key, productId, preferenceId)"))
    @Synchronized
    @JvmOverloads
    fun choose(
        key: String,
        productId: String,
        @Suppress("UNUSED_PARAMETER") quantity: Int? = null,
        @Suppress("UNUSED_PARAMETER") remember: Boolean = true,
        preferenceId: String? = null,
    ) = select(key, productId, preferenceId)

    @Deprecated("Use deselect()", ReplaceWith("deselect(key)"))
    fun skip(key: String) = deselect(key)

    /** Items that can be added but have nothing selected. */
    @Deprecated("Every item is shown and decided by its checkbox; see isSelected()")
    @Synchronized
    fun pending(): List<CartItem> = items.filter { it.status != ItemStatus.UNAVAILABLE && it.key !in picks }

    @Deprecated("Use selectedId() / selections()")
    fun selectionFor(key: String): Selection? = selections().firstOrNull { it.key == key }

    private fun find(key: String): CartItem? = items.firstOrNull { it.key == key }
}
