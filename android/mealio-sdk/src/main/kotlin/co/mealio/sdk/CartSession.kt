package co.mealio.sdk

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.launch
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
private fun cents(n: Double): Double = wholeCents(n) / 100.0

/** Whole cents, so adding lines up stays exact. The list and done totals both sum these. */
private fun wholeCents(n: Double): Long = Math.floor(n * 100 + 0.5).roundToLong()

/**
 * What one added line cost, or null when its price is unknown. By weight:
 * price per lb times the pounds, else the package price once. Otherwise unit
 * price times quantity. `fallback` is the chosen Product, for servers whose
 * added entries carry no prices. Port of addedPrice in packages/core/src/client.ts.
 */
@JvmOverloads
fun addedPrice(a: AddedItem, fallback: Product? = null): LinePrice? =
    linePrice(a.quantity, a.weightLb, a.unitPrice, a.pricePerLb, a.estimated, fallback)

private fun linePrice(quantity: Int, weightLb: Double?, unitPrice: Double?, pricePerLb: Double?, estimated: Boolean?, fallback: Product?): LinePrice? {
    val perLb = pricePerLb ?: fallback?.pricePerLb
    val unit = unitPrice ?: fallback?.unitPrice
    val est = estimated ?: (fallback?.estimated ?: false)
    if (weightLb != null) {
        if (perLb != null) return LinePrice(cents(perLb * weightLb), true)
        if (unit != null) return LinePrice(cents(unit), true)
        return null
    }
    if (unit == null) return null
    return LinePrice(cents(unit * maxOf(1, quantity)), est)
}

/**
 * A prepared cart. Port of CartSession in packages/core/src/client.ts.
 *
 * Every item is shown every run. Remembered products start selected, except an
 * item with startUnchecked; the user can select another option, search for something else, or deselect an item to
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
    /** Per item, per product found with [search]: the query that first found it, for [restorePicks]. */
    private val foundBy = HashMap<String, HashMap<String, String>>()
    private var adding: CompletableDeferred<AddResult>? = null
    private val searches = LinkedHashSet<CancelToken>()

    init {
        for (it in items) {
            val id = it.selectedId ?: continue
            if (it.startUnchecked) continue
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

    /** What the server changed or ignored in what you sent. Empty from older servers. */
    val warnings: List<CartWarning> get() = cart.warnings

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

    /**
     * Packages to add for an item: the recipe's quantity (at least 1) until the
     * user changes it, never over the selected product's cap. What this returns
     * is what is sent.
     */
    @Synchronized
    fun quantity(key: String): Int = minOf(qty[key] ?: maxOf(1, find(key)?.quantity ?: 1), maxQuantity(key))

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

    /**
     * Take the user's picks from an earlier cart, after a failed add. Works by
     * item key, on the same store: what they unticked stays unticked, and a
     * product this cart offers comes back with its quantity, weight and
     * preference. A product no longer offered leaves the item as this cart set it.
     *
     * Mealio knows a searched product only on the cart it was found in, so a
     * pick the user made from [search] is never sent to this cart as it is.
     * The search that found the picked product (not just the item's last
     * one) runs again here instead (it counts toward the search cap), and the
     * same product is selected if it comes back. If it does not, or that
     * search fails, the item keeps this cart's own pick.
     *
     * It never throws (other than for a cancel of the calling coroutine): it
     * ends with whatever it could restore. `cancel` and [cancelSearches] stop
     * those searches; check `cancel.cancelled` afterwards to tell a cancel
     * from outside.
     */
    @JvmOverloads
    suspend fun restorePicks(from: CartSession, cancel: CancelToken = CancelToken(), onStep: StepListener? = null) {
        if (from === this || from.store != store) return
        // Read the old cart first, so the two locks are never held together.
        val old = synchronized(from) {
            items.associate {
                val productId = from.picks[it.key]?.productId
                it.key to Old(from.find(it.key) != null, productId, from.picks[it.key]?.preferenceId, from.qty[it.key], from.lb[it.key],
                    productId?.let { id -> from.foundBy[it.key]?.get(id) })
            }
        }
        val again = ArrayList<Pair<String, String>>()
        synchronized(this) {
            for (it in items) {
                val o = old[it.key] ?: continue
                if (!o.known) continue
                val productId = o.productId
                if (productId == null) { deselect(it.key); continue }
                if (restoreOne(it.key, o)) continue
                // Not offered here. Found with search there: that search again here.
                if (o.query != null) again.add(it.key to o.query)
            }
        }
        for ((key, query) in again) {
            if (cancel.cancelled) return
            try {
                search(key, query, cancel, onStep)
            } catch (e: Throwable) {
                rethrowIfCancelled(e)
                if (e is Error) throw e
                continue
            }
            synchronized(this) { restoreOne(key, old.getValue(key)) }
        }
    }

    private class Old(val known: Boolean, val productId: String?, val pref: String?, val qty: Int?, val lb: Double?, val query: String?)

    /** Select the old pick for `key` if this cart offers it. False (nothing changed) when it does not. */
    private fun restoreOne(key: String, o: Old): Boolean {
        val productId = o.productId ?: return false
        val product = options(key).firstOrNull { p -> p.id == productId } ?: return false
        select(key, productId, o.pref.takeIf { pref -> product.preferences.any { p -> p.id == pref } })
        o.qty?.let { n -> setQuantity(key, n) }
        o.lb?.let { w -> setWeight(key, w) }
        return true
    }

    /** True while a search runs. Keep Add disabled until it ends. */
    val searching: Boolean get() = synchronized(searches) { searches.isNotEmpty() }

    /** Stop every search of this cart. Closing the sheet does this, with reason [CancelReason.CLOSED]. */
    @JvmOverloads
    fun cancelSearches(reason: String = CancelReason.CANCELLED) {
        val list = synchronized(searches) { searches.toList() }
        for (c in list) c.cancel(reason)
    }

    /** Search the store for something else and add the results to this item's options. */
    @JvmOverloads
    suspend fun search(key: String, query: String, onStep: StepListener? = null): List<Product> =
        search(key, query, CancelToken(), onStep)

    /** As above, stopped by `cancel` or [cancelSearches]: it then fails with "cancelled". */
    suspend fun search(key: String, query: String, cancel: CancelToken, onStep: StepListener? = null): List<Product> {
        val stop = cancel
        synchronized(searches) { searches.add(stop) }
        try {
            val r = client.search(cart.cartId, key, query, stop, onStep)
            synchronized(this) {
                val prev = extra[key] ?: emptyList()
                val seen = prev.mapTo(HashSet()) { it.id }
                extra[key] = r.options.filter { it.id !in seen } + prev
                val by = foundBy.getOrPut(key) { HashMap() }
                for (p in r.options) by.putIfAbsent(p.id, query)
            }
            return r.options
        } finally {
            synchronized(searches) { searches.remove(stop) }
        }
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
        else Selection(it.key, p.productId, quantity = quantity(it.key), remember = true, preferenceId = p.preferenceId)
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
        var total = 0L
        var count = 0
        var unpriced = 0
        var estimated = false
        for (it in items) {
            val p = selected(it.key) ?: continue
            if (needsPreference(it.key)) continue
            count += 1
            // Priced line by line as the done screen will price it, so the two agree.
            val byWeight = p.soldByWeight == true
            val line = linePrice(quantity(it.key), if (byWeight) weight(it.key) else null, null, null, null, p)
            if (byWeight) estimated = true
            if (line == null) { unpriced += 1; continue }
            total += wholeCents(line.amount)
            if (line.estimated) estimated = true
        }
        return Estimate(if (unpriced > 0) null else total / 100.0, count, estimated || unpriced > 0, unpriced)
    }

    /**
     * The total of what the store took, for the finished-run screen. Same rule
     * as estimate(): `total` is null when any added item has no price. Prices
     * come from the added entries, else (an older server) from the product
     * selected in this session.
     */
    @Synchronized
    fun addedTotal(result: AddResult): Estimate {
        var total = 0L
        var unpriced = 0
        var estimated = false
        for (a in result.added) {
            val p = addedPrice(a, selected(a.key))
            if (p == null) { unpriced += 1; continue }
            total += wholeCents(p.amount)
            if (p.estimated) estimated = true
        }
        return Estimate(if (unpriced > 0) null else total / 100.0, result.added.size, estimated || unpriced > 0, unpriced)
    }

    /** One added line's price (see [addedPrice]), with this session's product as the fallback. */
    @Synchronized
    fun addedPrice(a: AddedItem): LinePrice? = co.mealio.sdk.addedPrice(a, selected(a.key))

    /** True while an add runs. */
    val isAdding: Boolean get() = synchronized(searches) { adding != null }

    /**
     * Fill the store cart with the current selections. A second call while one
     * is running waits for that same add instead of starting another.
     *
     * Once called the add runs to its end: it belongs to no caller, so a
     * caller cancelled while waiting stops waiting but not the add, and every
     * other caller still gets its result.
     */
    @JvmOverloads
    suspend fun addToCart(onStep: StepListener? = null): AddResult {
        val mine = CompletableDeferred<AddResult>()
        val running = synchronized(searches) { adding ?: run { adding = mine; null } }
        if (running != null) return running.await()
        val sel = selections()
        // The caller's dispatcher, without its Job: cancelling the caller does not reach the add.
        CoroutineScope(currentCoroutineContext().minusKey(Job)).launch(start = CoroutineStart.UNDISPATCHED) {
            val r = try {
                Result.success(client.addToCart(cart.cartId, sel, onStep))
            } catch (e: Throwable) {
                Result.failure(e)
            }
            // Not adding any more before anyone hears the result.
            synchronized(searches) { if (adding === mine) adding = null }
            r.fold({ mine.complete(it) }, { mine.completeExceptionally(it) })
        }
        return mine.await()
    }

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

/** [forRecipes] in the partner's words: the `forRecipes` and `and` strings. */
fun forRecipes(cart: CartSession, key: String, text: TextTools): String? {
    if (cart.recipes.size < 2) return null
    val names = cart.recipesFor(key).mapNotNull { it.title?.takeIf { t -> t.isNotEmpty() } }
    return if (names.isEmpty()) null else text.tr("forRecipes", "recipes" to listAnd(names, text.tr("and")))
}

/** "A", "A and B", "A, B and C". */
internal fun listAnd(xs: List<String>, and: String = "and"): String = when (xs.size) {
    0 -> ""
    1 -> xs[0]
    else -> xs.dropLast(1).joinToString(", ") + " " + and + " " + xs.last()
}
