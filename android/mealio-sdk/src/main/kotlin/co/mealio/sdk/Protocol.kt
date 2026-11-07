package co.mealio.sdk

import org.json.JSONArray
import org.json.JSONObject

// The relay protocol as Kotlin types. PROTOCOL.md is the spec and wins any
// disagreement. packages/core/src/protocol.ts is the reference these mirror.

const val PROTOCOL_VERSION = 1

/** Max instructions the SDK will accept in one envelope. */
const val MAX_INSTRUCTIONS = 64

/** Clock skew allowed when checking `exp`, in seconds. */
const val EXP_SKEW_SECONDS = 120L

/** Every op this SDK can run. Sent to the server with every job-starting call. */
val SUPPORTED_OPS: List<String> = listOf("page_open", "page_script", "show_login", "fetch", "done", "fail")

/** A signed instruction batch, exactly as the server sent it. */
data class Envelope(val payload: String, val sig: String, val kid: String) {
    fun toJson(): JSONObject = JSONObject().put("payload", payload).put("sig", sig).put("kid", kid)

    companion object {
        /**
         * Read an envelope from JSON. Returns null when `payload` or `sig` is not a
         * string (openEnvelope then refuses it as "shape"). A missing kid becomes ""
         * which no key matches, so it fails as "unknown_kid", as in the reference.
         */
        fun fromJson(v: Any?): Envelope? {
            val o = v as? JSONObject ?: return null
            val payload = o.opt("payload") as? String ?: return null
            val sig = o.opt("sig") as? String ?: return null
            val kid = o.opt("kid") as? String ?: ""
            return Envelope(payload, sig, kid)
        }
    }
}

/**
 * PROTOCOL.md "Matcher". `eq` and `ne` values are raw JSON values
 * (String, Number, Boolean, JSONObject.NULL, JSONObject, JSONArray).
 */
data class Matcher(
    val type: String,
    val eq: Map<String, Any?> = emptyMap(),
    val ne: Map<String, Any?> = emptyMap(),
) {
    companion object {
        fun fromJson(o: JSONObject): Matcher = Matcher(
            type = o.str("type") ?: "",
            eq = o.obj("eq")?.toValueMap() ?: emptyMap(),
            ne = o.obj("ne")?.toValueMap() ?: emptyMap(),
        )

        internal fun listFrom(a: JSONArray?): List<Matcher> = a?.objects()?.map { fromJson(it) } ?: emptyList()
    }
}

data class LoginCheck(val script: String, val intervalMs: Long)

data class FetchRequest(
    val method: String,
    val url: String,
    val headers: Map<String, String> = emptyMap(),
    val body: String? = null,
)

/** One instruction. Fields the server leaves out get the defaults noted. */
sealed class Instruction {
    abstract val id: String
    abstract val op: String

    data class PageOpen(override val id: String, val url: String, val timeoutMs: Long) : Instruction() {
        override val op get() = "page_open"
    }

    data class PageScript(
        override val id: String,
        val script: String,
        val until: List<Matcher>,
        val timeoutMs: Long,
    ) : Instruction() {
        override val op get() = "page_script"
    }

    data class ShowLogin(
        override val id: String,
        val url: String,
        val title: String,
        val check: LoginCheck?,
        val doneWhen: List<Matcher>,
        val doneWhenUrl: String?,
        val timeoutMs: Long,
    ) : Instruction() {
        override val op get() = "show_login"
    }

    data class Fetch(
        override val id: String,
        val request: FetchRequest,
        val timeoutMs: Long,
        val maxBytes: Int,
    ) : Instruction() {
        override val op get() = "fetch"
    }

    /** `result` is a raw JSON value. */
    data class Done(override val id: String, val result: Any?) : Instruction() {
        override val op get() = "done"
    }

    data class Fail(override val id: String, val code: String, val message: String) : Instruction() {
        override val op get() = "fail"
    }

    companion object {
        // Defaults for a field the server leaves out. The server always sends
        // them; these only keep a malformed instruction from hanging forever.
        private const val DEFAULT_PAGE_TIMEOUT = 15_000L
        private const val DEFAULT_SCRIPT_TIMEOUT = 20_000L
        private const val DEFAULT_LOGIN_TIMEOUT = 600_000L
        private const val DEFAULT_FETCH_TIMEOUT = 12_000L
        private const val DEFAULT_MAX_BYTES = 400_000

        private fun JSONObject.ms(key: String, fallback: Long): Long =
            num(key)?.toLong()?.takeIf { it >= 0 } ?: fallback

        /** Build a typed instruction. `o` already passed checkInstructions. */
        internal fun fromJson(o: JSONObject): Instruction {
            val id = o.str("id") ?: ""
            return when (o.str("op")) {
                "page_open" -> PageOpen(id, o.str("url") ?: "", o.ms("timeoutMs", DEFAULT_PAGE_TIMEOUT))
                "page_script" -> PageScript(
                    id, o.str("script") ?: "", Matcher.listFrom(o.arr("until")),
                    o.ms("timeoutMs", DEFAULT_SCRIPT_TIMEOUT),
                )
                "show_login" -> {
                    val c = o.obj("check")
                    ShowLogin(
                        id = id,
                        url = o.str("url") ?: "",
                        title = o.str("title") ?: "",
                        check = c?.let { LoginCheck(it.str("script") ?: "", it.ms("intervalMs", 3_000L)) },
                        doneWhen = Matcher.listFrom(o.arr("doneWhen")),
                        doneWhenUrl = o.str("doneWhenUrl"),
                        timeoutMs = o.ms("timeoutMs", DEFAULT_LOGIN_TIMEOUT),
                    )
                }
                "fetch" -> {
                    val r = o.obj("request") ?: JSONObject()
                    val headers = LinkedHashMap<String, String>()
                    r.obj("headers")?.let { h -> h.keys().forEach { k -> (h.opt(k) as? String)?.let { headers[k] = it } } }
                    Fetch(
                        id = id,
                        request = FetchRequest(r.str("method") ?: "GET", r.str("url") ?: "", headers, r.str("body")),
                        timeoutMs = o.ms("timeoutMs", DEFAULT_FETCH_TIMEOUT),
                        maxBytes = o.num("maxBytes")?.toInt()?.takeIf { it >= 0 } ?: DEFAULT_MAX_BYTES,
                    )
                }
                "done" -> Done(id, if (o.has("result")) o.opt("result") else JSONObject.NULL)
                "fail" -> Fail(id, o.str("code") ?: "server", o.str("message") ?: "")
                else -> throw EnvelopeException("unsupported_op")
            }
        }
    }
}

data class InstructionsPayload(
    val v: Int,
    val job: String?,
    val seq: Int,
    val exp: Double,
    val store: String,
    val instructions: List<Instruction>,
)

data class StoreHostsPatch(val hosts: List<String> = emptyList(), val authHosts: List<String> = emptyList())

data class AllowlistPayload(val v: Int, val exp: Double, val stores: Map<String, StoreHostsPatch>) {
    companion object {
        /** Null when the payload is not `kind: "allowlist"`. */
        fun fromJson(p: JSONObject): AllowlistPayload? {
            if (p.str("kind") != "allowlist") return null
            val stores = LinkedHashMap<String, StoreHostsPatch>()
            p.obj("stores")?.let { s ->
                s.keys().forEach { k ->
                    val e = s.opt(k) as? JSONObject ?: return@forEach
                    stores[k] = StoreHostsPatch(e.arr("hosts")?.strings() ?: emptyList(), e.arr("authHosts")?.strings() ?: emptyList())
                }
            }
            return AllowlistPayload(p.num("v")?.toInt() ?: 0, p.num("exp") ?: 0.0, stores)
        }
    }
}

// ── results ────────────────────────────────────────────────────────────────
//
// Each result serialises like JSON.stringify of the TypeScript object: fields
// that are undefined there are left out here.

enum class LoginOutcome(val wire: String) {
    SIGNED_IN("signed_in"),
    CANCELLED("cancelled"),
    TIMEOUT("timeout"),
}

sealed class InstructionResult {
    abstract val id: String
    abstract val ok: Boolean
    abstract val ms: Long
    abstract val skipped: Boolean
    abstract val error: String?

    abstract fun toJson(): JSONObject

    protected fun base(): JSONObject {
        val o = JSONObject().put("id", id).put("ok", ok)
        return o
    }

    protected fun JSONObject.finish(): JSONObject {
        putIfNotNull("error", error)
        put("ms", ms)
        if (skipped) put("skipped", true)
        return this
    }

    data class PageOpenResult(
        override val id: String,
        override val ok: Boolean,
        val finalUrl: String? = null,
        override val error: String? = null,
        override val ms: Long,
        override val skipped: Boolean = false,
    ) : InstructionResult() {
        override fun toJson(): JSONObject = base().putIfNotNull("finalUrl", finalUrl).finish()
    }

    data class PageScriptResult(
        override val id: String,
        override val ok: Boolean,
        val messages: List<JSONObject>,
        val timedOut: Boolean,
        override val error: String? = null,
        override val ms: Long,
        override val skipped: Boolean = false,
    ) : InstructionResult() {
        override fun toJson(): JSONObject =
            base().put("messages", JSONArray(messages)).put("timedOut", timedOut).finish()
    }

    data class ShowLoginResult(
        override val id: String,
        override val ok: Boolean,
        val outcome: LoginOutcome,
        val messages: List<JSONObject>,
        override val error: String? = null,
        override val ms: Long,
        override val skipped: Boolean = false,
    ) : InstructionResult() {
        override fun toJson(): JSONObject =
            base().put("outcome", outcome.wire).put("messages", JSONArray(messages)).finish()
    }

    data class FetchResult(
        override val id: String,
        override val ok: Boolean,
        val status: Int? = null,
        val headers: Map<String, String>? = null,
        val body: String? = null,
        val truncated: Boolean? = null,
        override val error: String? = null,
        override val ms: Long,
        override val skipped: Boolean = false,
    ) : InstructionResult() {
        override fun toJson(): JSONObject {
            val o = base()
            o.putIfNotNull("status", status)
            headers?.let { h -> o.put("headers", JSONObject().also { j -> h.forEach { (k, v) -> j.put(k, v) } }) }
            o.putIfNotNull("body", body)
            o.putIfNotNull("truncated", truncated)
            return o.finish()
        }
    }
}

/** POST /api/v1/sdk/jobs/{job}/step body. */
data class StepRequest(val seq: Int, val results: List<InstructionResult>) {
    fun toJson(): JSONObject = JSONObject().put("seq", seq).put("results", JSONArray(results.map { it.toJson() }))
}

// ── what the server hands back from a finished job ─────────────────────────

data class ProductPreference(val id: String, val label: String)

data class Product(
    val id: String,
    val name: String,
    val price: String? = null,
    val imageUrl: String? = null,
    val size: String? = null,
    val outOfStock: Boolean = false,
    /** Why this option sits where it does: "picked_before", "popular" or "partner_pick". Ranking only. */
    val badge: String? = null,
    /** The words for the badge, when it has any: "Crowd favorite for Tacos". */
    val badgeLabel: String? = null,
    /** Variants the user must pick one of (H-E-B "sliced or shaved?"). Pass the id as preferenceId. */
    val preferences: List<ProductPreference> = emptyList(),
    /** One unit's price as a number, for an estimated total. The server works out "2 for $1.05" style deals. */
    val unitPrice: Double? = null,
    /** Sold by weight: the price is the store's estimate. */
    val estimated: Boolean = false,
    /** The store's per-order cap, when it states one. */
    val maxQuantity: Int? = null,
    /** Sold by weight (deli, fish counter). */
    val soldByWeight: Boolean? = null,
    /** Weights offered for a sold-by-weight item, in lb, ascending. Null when the store lists none. */
    val weightOptions: List<Double>? = null,
    /**
     * Price per lb for a sold-by-weight item priced by the pound. Null for a
     * weight item priced as a package, and on count items.
     */
    val pricePerLb: Double? = null,
) {
    companion object {
        fun fromJson(o: JSONObject): Product = Product(
            id = o.str("id") ?: "",
            name = o.str("name") ?: "",
            price = o.str("price"),
            imageUrl = o.str("imageUrl"),
            size = o.str("size"),
            outOfStock = o.bool("outOfStock") ?: false,
            badge = o.str("badge"),
            badgeLabel = o.str("badgeLabel"),
            preferences = o.arr("preferences")?.objects()?.map { ProductPreference(it.str("id") ?: "", it.str("label") ?: "") }
                ?: emptyList(),
            unitPrice = o.num("unitPrice")?.takeIf { it.isFinite() },
            estimated = o.bool("estimated") ?: false,
            maxQuantity = o.num("maxQuantity")?.takeIf { it.isFinite() }?.toInt(),
            soldByWeight = o.bool("soldByWeight"),
            weightOptions = o.arr("weightOptions")?.let { a ->
                (0 until a.length()).mapNotNull { i -> (a.opt(i) as? Number)?.toDouble()?.takeIf { it.isFinite() } }
            },
            pricePerLb = o.num("pricePerLb")?.takeIf { it.isFinite() },
        )
    }
}

/** Where an item stands this run. */
enum class ItemStatus(val wire: String) {
    /** The user's remembered product, in stock, pre-selected. */
    REMEMBERED("remembered"),
    /** Nothing remembered yet: the user picks. */
    CHOOSE("choose"),
    /** The remembered product is out of stock or gone this time. */
    REMEMBERED_UNAVAILABLE("remembered_unavailable"),
    /** Nothing found; `reason` says why. */
    UNAVAILABLE("unavailable");

    companion object {
        fun fromWire(s: String?): ItemStatus? = values().firstOrNull { it.wire == s }
    }
}

/** A recipe that calls for a cart item, in a cart made from one or more recipes. */
data class ItemRecipe(
    val id: String,
    val title: String? = null,
    /** This recipe's share of the item's quantity. */
    val quantity: Int = 1,
) {
    companion object {
        fun fromJson(o: JSONObject): ItemRecipe =
            ItemRecipe(o.str("id") ?: "", o.str("title"), o.num("quantity")?.toInt() ?: 1)
    }
}

/** A recipe a cart was made from, as PreparedCart lists them. */
data class CartRecipe(val id: String, val title: String? = null) {
    companion object {
        fun fromJson(o: JSONObject): CartRecipe = CartRecipe(o.str("id") ?: "", o.str("title"))
    }
}

data class CartItem(
    val key: String,
    val ingredient: String,
    /** Packages to buy: every recipe's share added together. */
    val quantity: Int,
    /** @deprecated 0.1 shape: the remembered product when it is in stock. Use [remembered] and [selectedId]. */
    val chosen: Product? = null,
    /** Every option, best first. The remembered product leads when the store has it. */
    val options: List<Product> = emptyList(),
    /** Why nothing could be offered, e.g. "no_results", or why the remembered product is unavailable. */
    val reason: String? = null,
    val status: ItemStatus = ItemStatus.CHOOSE,
    /** Pre-selected product id for this run, or null. */
    val selectedId: String? = null,
    /** The user's remembered product, whatever its stock. */
    val remembered: Product? = null,
    val rememberedPreferenceId: String? = null,
    /** The recipe's own weight for this line, in lb, when it gave one in a weight unit. */
    val weightLb: Double? = null,
    /**
     * The recipes that call for this item. A cart from several recipes merges an
     * ingredient they share into one item, and a pick on it is remembered under
     * each of them. Empty from servers older than multi-recipe.
     */
    val recipes: List<ItemRecipe> = emptyList(),
) {
    companion object {
        fun fromJson(o: JSONObject): CartItem = fromJson(o, null)

        /**
         * `legacy` is the 0.1 grouping the item came from ("ready", "needsChoice",
         * "unavailable") when the server sent no `items`; it fills in `status`.
         */
        internal fun fromJson(o: JSONObject, legacy: String?): CartItem {
            val chosen = o.obj("chosen")?.let { Product.fromJson(it) }
            val remembered = o.obj("remembered")?.let { Product.fromJson(it) } ?: chosen
            var options = o.arr("options")?.objects()?.map { Product.fromJson(it) } ?: emptyList()
            if (chosen != null && options.none { it.id == chosen.id }) options = listOf(chosen) + options
            val status = ItemStatus.fromWire(o.str("status")) ?: when (legacy) {
                "ready" -> if (chosen != null) ItemStatus.REMEMBERED else ItemStatus.CHOOSE
                "unavailable" -> ItemStatus.UNAVAILABLE
                else -> ItemStatus.CHOOSE
            }
            val selectedId = if (o.has("selectedId")) o.str("selectedId")
            else if (status == ItemStatus.REMEMBERED) remembered?.id else null
            return CartItem(
                key = o.str("key") ?: "",
                ingredient = o.str("ingredient") ?: "",
                quantity = o.num("quantity")?.toInt() ?: 1,
                chosen = chosen,
                options = options,
                reason = o.str("reason"),
                status = status,
                selectedId = selectedId,
                remembered = remembered,
                rememberedPreferenceId = o.str("rememberedPreferenceId"),
                weightLb = o.num("weightLb")?.takeIf { it.isFinite() },
                recipes = o.arr("recipes")?.objects()?.map { ItemRecipe.fromJson(it) } ?: emptyList(),
            )
        }
    }
}

data class PreparedCart(
    val cartId: String,
    val store: String,
    /** @deprecated 0.1 groupings derived from items. */
    val ready: List<CartItem>,
    val needsChoice: List<CartItem>,
    val unavailable: List<CartItem>,
    /** Every recipe line, in recipe order. Show them all. */
    val items: List<CartItem> = ready + needsChoice + unavailable,
    /** Display name, e.g. "H-E-B". */
    val storeName: String? = null,
    /** The recipes this cart was made from, in the order they were sent. Empty from older servers. */
    val recipes: List<CartRecipe> = emptyList(),
    /** The exact store, on a Kroger family cart. The user can change it. Null from older servers. */
    val location: StoreLocation? = null,
) {
    companion object {
        fun fromJson(o: JSONObject): PreparedCart {
            fun group(name: String) = o.arr(name)?.objects()?.map { CartItem.fromJson(it, name) } ?: emptyList()
            val ready = group("ready")
            val needsChoice = group("needsChoice")
            val unavailable = group("unavailable")
            // Older servers: rebuilt from the 0.1 groupings.
            val items = o.arr("items")?.objects()?.map { CartItem.fromJson(it, null) } ?: (ready + needsChoice + unavailable)
            return PreparedCart(
                cartId = o.str("cartId") ?: "",
                store = o.str("store") ?: "",
                ready = ready,
                needsChoice = needsChoice,
                unavailable = unavailable,
                items = items,
                storeName = o.str("storeName"),
                recipes = o.arr("recipes")?.objects()?.map { CartRecipe.fromJson(it) } ?: emptyList(),
                location = o.obj("location")?.let { StoreLocation.fromJson(it) },
            )
        }
    }
}

/** One physical store of a Kroger family chain. */
data class StoreLocation(
    val id: String,
    val name: String,
    /** "123 Main St, Dallas, TX 75201". */
    val address: String,
    val zip: String? = null,
) {
    companion object {
        fun fromJson(o: JSONObject): StoreLocation =
            StoreLocation(o.str("id") ?: "", o.str("name") ?: "", o.str("address") ?: "", o.str("zip"))
    }
}

/** The store carts use by default. `location` is set for a Kroger family store. */
data class StorePreferences(val defaultStore: String?, val location: StoreLocation?) {
    companion object {
        fun fromJson(o: JSONObject): StorePreferences =
            StorePreferences(o.str("defaultStore"), o.obj("location")?.let { StoreLocation.fromJson(it) })
    }
}

/** A store the SDK supports, from GET /api/v1/stores. */
data class StoreInfo(
    val id: String,
    /** Display name, e.g. "H-E-B". */
    val name: String,
    /** "device": runs on the phone with the user's store login. "kroger_api": through Kroger's API. */
    val via: String,
) {
    companion object {
        fun fromJson(o: JSONObject): StoreInfo = StoreInfo(o.str("id") ?: "", o.str("name") ?: o.str("id") ?: "", o.str("via") ?: "device")
    }
}

/** What a search job returns: more options for one item. */
data class SearchResult(val key: String, val query: String, val options: List<Product>) {
    companion object {
        fun fromJson(o: JSONObject): SearchResult = SearchResult(
            key = o.str("key") ?: "",
            query = o.str("query") ?: "",
            options = o.arr("options")?.objects()?.map { Product.fromJson(it) } ?: emptyList(),
        )
    }
}

/**
 * One line the store took. Everything after weightLb is for the finished-run
 * screen and comes from the product the user chose (the server does not
 * search again). Each is optional: present only when known, and absent from
 * servers older than the finished-run screen.
 */
data class AddedItem(
    val key: String,
    val productId: String,
    val name: String,
    val quantity: Int,
    /** Set on an item added by weight: the pounds asked for. */
    val weightLb: Double? = null,
    /** The product's image, from the search that offered it. */
    val imageUrl: String? = null,
    /** The recipe line it was added for, as the partner wrote it. */
    val ingredient: String? = null,
    /** One unit's price. On a weight item priced as a package, the package price. */
    val unitPrice: Double? = null,
    /** Price per lb for a weight item priced by the pound. */
    val pricePerLb: Double? = null,
    /** The price is the store's estimate (weighed or "Avg." items). Null when the server did not say. */
    val estimated: Boolean? = null,
)
data class SkippedItem(val key: String, val reason: String)
data class FailedItem(val key: String, val productId: String, val name: String, val reason: String)

data class AddResult(
    val cartId: String,
    val store: String,
    val added: List<AddedItem>,
    val skipped: List<SkippedItem>,
    val failed: List<FailedItem>,
    /** Open this to let the user check out on the store's own site or app. */
    val storeCartUrl: String?,
    /**
     * True when a cart read after adding confirmed every added item. A failed
     * item with reason "not_confirmed" was sent but not found in the cart. Null
     * when the server did not say.
     */
    val verified: Boolean? = null,
) {
    companion object {
        fun fromJson(o: JSONObject): AddResult = AddResult(
            cartId = o.str("cartId") ?: "",
            store = o.str("store") ?: "",
            added = o.arr("added")?.objects()?.map {
                AddedItem(
                    it.str("key") ?: "", it.str("productId") ?: "", it.str("name") ?: "", it.num("quantity")?.toInt() ?: 1,
                    it.num("weightLb")?.takeIf { w -> w.isFinite() },
                    imageUrl = it.str("imageUrl"),
                    ingredient = it.str("ingredient"),
                    unitPrice = it.num("unitPrice")?.takeIf { w -> w.isFinite() },
                    pricePerLb = it.num("pricePerLb")?.takeIf { w -> w.isFinite() },
                    estimated = it.bool("estimated"),
                )
            } ?: emptyList(),
            skipped = o.arr("skipped")?.objects()?.map { SkippedItem(it.str("key") ?: "", it.str("reason") ?: "") }
                ?: emptyList(),
            failed = o.arr("failed")?.objects()?.map {
                FailedItem(it.str("key") ?: "", it.str("productId") ?: "", it.str("name") ?: "", it.str("reason") ?: "")
            } ?: emptyList(),
            storeCartUrl = o.str("storeCartUrl"),
            verified = o.bool("verified"),
        )
    }
}

/**
 * One decision the user made. `productId == null` leaves the item out of this
 * run and never forgets the remembered choice.
 */
data class Selection(
    val key: String,
    val productId: String?,
    val quantity: Int? = null,
    /** Save this product as the remembered choice. The server's default is true. */
    val remember: Boolean? = null,
    /** Required when the chosen Product has `preferences`. */
    val preferenceId: String? = null,
    /**
     * Pounds, for a Product with soldByWeight. Above 0 and at most 20. The
     * store writes it by weight where it can (H-E-B, Albertsons family);
     * elsewhere the item fails as weight_not_supported. Ignored for count items.
     */
    val weightLb: Double? = null,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("key", key)
        .putNullable("productId", productId)
        .putIfNotNull("quantity", quantity)
        .putIfNotNull("weightLb", weightLb)
        .putIfNotNull("remember", remember)
        .putIfNotNull("preferenceId", preferenceId)
}

data class RecipeIngredient(
    val name: String,
    /** Packages to buy. Defaults to 1 on the server. */
    val quantity: Int? = null,
    val amount: Double? = null,
    val unit: String? = null,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("name", name)
        .putIfNotNull("quantity", quantity)
        .putIfNotNull("amount", amount)
        .putIfNotNull("unit", unit)
}

data class Recipe(
    val id: String,
    val ingredients: List<RecipeIngredient>,
    val title: String? = null,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("id", id)
        .putIfNotNull("title", title)
        .put("ingredients", JSONArray(ingredients.map { it.toJson() }))
}

/** At most this many recipes in one prepareCart. */
const val MAX_RECIPES = 10
