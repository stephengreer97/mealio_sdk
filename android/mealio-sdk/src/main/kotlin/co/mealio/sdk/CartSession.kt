package co.mealio.sdk

import kotlin.math.abs
import kotlin.math.roundToLong

/** The weight step (lb) for a sold-by-weight item whose store lists no weights. */
const val WEIGHT_STEP: Double = 0.25

/** The most a selection may ask for, in lb. The server refuses more. */
const val MAX_WEIGHT_LB: Double = 20.0

/** The lightest and heaviest weight (lb) the user can pick for an item. */
data class WeightRange(val min: Double, val max: Double)

private fun nearestIndex(opts: List<Double>, v: Double): Int {
    var best = 0
    opts.forEachIndexed { i, o -> if (abs(o - v) < abs(opts[best] - v) - 1e-9) best = i }
    return best
}

/** A total, for "Estimated total about $12.40". */
data class Estimate(
    /**
     * Unit price times quantity over the counted items, and price per lb times
     * the weight for a sold-by-weight item, to the cent. Null when any counted
     * item has no price (`unpriced` > 0): no partial totals, show no number
     * then ("Prices at checkout").
     */
    val total: Double?,
    /** Counted items. */
    val count: Int,
    /** True when any counted item is sold by weight or has no price: show it as "about". */
    val estimated: Boolean,
    /** Counted items with no price. Above 0 means `total` is null. */
    val unpriced: Int,
)

/** One added line's price. */
data class LinePrice(val amount: Double, val estimated: Boolean)

/** Math.round(n * 100) / 100 in the reference (half rounds up). */
private fun cents(n: Double): Double = Math.floor(n * 100 + 0.5).roundToLong() / 100.0

/**
 * What one added line cost, or null when its price is unknown. By weight:
 * price per lb times the pounds, else the package price once. Otherwise unit
 * price times quantity. `fallback` is the chosen Product, for servers whose
 * added entries carry no prices. Port of addedPrice in packages/core/src/client.ts.
 */
@JvmOverloads
fun addedPrice(a: AddedItem, fallback: Product? = null): LinePrice? {
    val perLb = a.pricePerLb ?: fallback?.pricePerLb
    val unit = a.unitPrice ?: fallback?.unitPrice
    val est = a.estimated ?: (fallback?.estimated ?: false)
    val w = a.weightLb
    if (w != null) {
        if (perLb != null) return LinePrice(cents(perLb * w), true)
        if (unit != null) return LinePrice(cents(unit), true)
        return null
    }
    if (unit == null) return null
    return LinePrice(cents(unit * maxOf(1, a.quantity)), est)
}

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
    private val lb = HashMap<String, Double>()

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

    /** The recipes this cart was made from. Empty from older servers. */
    val recipes: List<CartRecipe> get() = cart.recipes

    /** The recipes that call for an item, for a "For Tacos and Pasta" line. Empty from older servers. */
    fun recipesFor(key: String): List<ItemRecipe> = find(key)?.recipes ?: emptyList()

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

    /** True when the selected product is sold by weight: use weight(), not quantity(). */
    @Synchronized
    fun isWeight(key: String): Boolean = selected(key)?.soldByWeight == true

    /**
     * The lightest and heaviest weight (lb) the user can pick for the selected
     * product: its first and last weightOption, else 0.25 to 20.
     */
    @Synchronized
    fun weightRange(key: String): WeightRange {
        val opts = weightOptions(key)
        if (opts.isEmpty()) return WeightRange(WEIGHT_STEP, MAX_WEIGHT_LB)
        return WeightRange(opts.first(), minOf(MAX_WEIGHT_LB, opts.last()))
    }

    /**
     * Pounds to add for a sold-by-weight item: the user's, else the recipe's own
     * weight, else the store's first weight option, else 0.25. Always a weight
     * the selected product can be bought in (see setWeight). 0 for count items.
     */
    @Synchronized
    fun weight(key: String): Double {
        if (!isWeight(key)) return 0.0
        lb[key]?.let { return snapWeight(key, it) }
        val recipe = find(key)?.weightLb
        if (recipe != null && recipe > 0) return snapWeight(key, recipe)
        return weightOptions(key).firstOrNull() ?: WEIGHT_STEP
    }

    /**
     * Set the weight in lb. Snapped to the nearest weightOption when the store
     * lists them, else to 0.25 lb steps, and clamped to weightRange. Returns
     * what was set.
     */
    @Synchronized
    fun setWeight(key: String, pounds: Double): Double {
        val v = snapWeight(key, if (pounds.isFinite()) pounds else 0.0)
        lb[key] = v
        return v
    }

    /** One step heavier (dir > 0) or lighter (dir < 0): the next weightOption, else 0.25 lb. Returns the new weight. */
    @Synchronized
    fun stepWeight(key: String, dir: Int): Double {
        val d = if (dir < 0) -1 else 1
        val cur = weight(key)
        val opts = weightOptions(key)
        if (opts.isEmpty()) return setWeight(key, cur + d * WEIGHT_STEP)
        val i = nearestIndex(opts, cur)
        return setWeight(key, opts[maxOf(0, minOf(opts.size - 1, i + d))])
    }

    private fun weightOptions(key: String): List<Double> =
        (selected(key)?.weightOptions ?: emptyList())
            .filter { it.isFinite() && it > 0 && it <= MAX_WEIGHT_LB }
            .distinct()
            .sorted()

    private fun snapWeight(key: String, pounds: Double): Double {
        val r = weightRange(key)
        val opts = weightOptions(key)
        val v = maxOf(r.min, minOf(r.max, pounds))
        if (opts.isNotEmpty()) return opts[nearestIndex(opts, v)]
        // Math.round(v / 0.25) * 0.25 in the reference (half rounds up).
        return maxOf(r.min, minOf(r.max, Math.floor(v / WEIGHT_STEP + 0.5) * WEIGHT_STEP))
    }

    @Synchronized
    fun isSelected(key: String): Boolean = key in picks

    /** The preference chosen for an item's product, or null. */
    @Synchronized
    fun preferenceId(key: String): String? = picks[key]?.preferenceId

    /**
     * True when the item is ticked but its product offers preferences (H-E-B
     * deli slicing, for example) and none is chosen. Such an item stays out of
     * the add and the total until one is, the same rule as the Mealio app: a
     * missing preference is a different request from "No preference".
     */
    @Synchronized
    fun needsPreference(key: String): Boolean {
        val p = picks[key] ?: return false
        val prefs = selected(key)?.preferences
        return !prefs.isNullOrEmpty() && p.preferenceId.isNullOrEmpty()
    }

    /** Keys of ticked items still waiting on a preference. */
    @Synchronized
    fun pendingPreferences(): List<String> = items.filter { needsPreference(it.key) }.map { it.key }

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
     * remember: true, preferenceId} (quantity 1 and weightLb for a sold-by-weight
     * product), the rest, and ticked items still waiting on a preference, as
     * {productId: null, remember: false}.
     */
    @Synchronized
    fun selections(): List<Selection> = items.map { it ->
        val p = picks[it.key]
        if (p == null || needsPreference(it.key)) Selection(it.key, null, remember = false)
        else if (isWeight(it.key)) Selection(it.key, p.productId, quantity = 1, remember = true, preferenceId = p.preferenceId, weightLb = weight(it.key))
        else Selection(it.key, p.productId, quantity = minOf(quantity(it.key), maxQuantity(it.key)), remember = true, preferenceId = p.preferenceId)
    }

    /**
     * Estimated total of the selected items: unit price times quantity, and for a
     * sold-by-weight item price per lb times the weight (one package price when
     * the store prices it as a package). Items waiting on a preference are left
     * out. `estimated` is true when any item is sold by weight or has no price.
     *
     * `total` is null when even one selected item has no price (`unpriced` > 0):
     * a total that leaves an item out is wrong, so show no number at all
     * ("Prices at checkout"). A weight item priced per lb counts as priced.
     */
    @Synchronized
    fun estimate(): Estimate {
        var total = 0.0
        var count = 0
        var unpriced = 0
        var estimated = false
        for (it in items) {
            val p = selected(it.key) ?: continue
            if (needsPreference(it.key)) continue
            count += 1
            if (p.soldByWeight == true) {
                estimated = true
                val perLb = p.pricePerLb
                if (perLb != null) total += perLb * weight(it.key)
                else if (p.unitPrice != null) total += p.unitPrice
                else unpriced += 1
                continue
            }
            val u = p.unitPrice
            if (u != null) total += u * minOf(quantity(it.key), maxQuantity(it.key)) else unpriced += 1
            if (p.estimated) estimated = true
        }
        return Estimate(if (unpriced > 0) null else cents(total), count, estimated || unpriced > 0, unpriced)
    }

    /**
     * The total of what the store took, for the finished-run screen. Same rule
     * as estimate(): `total` is null when any added item has no price. Prices
     * come from the added entries, else (an older server) from the product
     * selected in this session.
     */
    @Synchronized
    fun addedTotal(result: AddResult): Estimate {
        var total = 0.0
        var unpriced = 0
        var estimated = false
        for (a in result.added) {
            val p = addedPrice(a, selected(a.key))
            if (p == null) { unpriced += 1; continue }
            total += p.amount
            if (p.estimated) estimated = true
        }
        return Estimate(if (unpriced > 0) null else cents(total), result.added.size, estimated || unpriced > 0, unpriced)
    }

    /** One added line's price (see [addedPrice]), with this session's product as the fallback. */
    @Synchronized
    fun addedPrice(a: AddedItem): LinePrice? = co.mealio.sdk.addedPrice(a, selected(a.key))

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

/**
 * "For Tacos and Pasta": the line under an item on a cart made from more than
 * one recipe. Null on a one-recipe cart, and when none of the item's recipes
 * has a title. Untitled recipes are left out.
 */
fun forRecipes(cart: CartSession, key: String): String? =
    forRecipes(cart.recipes.size, cart.recipesFor(key))

/** [forRecipes] without a session: `recipeCount` is how many recipes the cart was made from. */
fun forRecipes(recipeCount: Int, itemRecipes: List<ItemRecipe>): String? {
    if (recipeCount < 2) return null
    val names = itemRecipes.mapNotNull { it.title?.takeIf { t -> t.isNotEmpty() } }
    return if (names.isEmpty()) null else "For " + listAnd(names)
}

/** "A", "A and B", "A, B and C". */
internal fun listAnd(xs: List<String>): String = when (xs.size) {
    0 -> ""
    1 -> xs[0]
    else -> xs.dropLast(1).joinToString(", ") + " and " + xs.last()
}
