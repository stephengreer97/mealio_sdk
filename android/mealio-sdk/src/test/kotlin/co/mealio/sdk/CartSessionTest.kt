package co.mealio.sdk

import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

// Mirrors the "cart session" block of packages/core/test/core.test.ts, plus
// estimate() and stepOf().
class CartSessionTest {
    private fun product(id: String, name: String, unitPrice: Double? = null, estimated: Boolean = false, price: String? = null) =
        JSONObject().put("id", id).put("name", name).also { o ->
            unitPrice?.let { o.put("unitPrice", it) }
            if (estimated) o.put("estimated", true)
            price?.let { o.put("price", it) }
        }

    private fun item(key: String, status: String, options: List<JSONObject>, selectedId: String? = null, remembered: JSONObject? = null, quantity: Int = 1) =
        JSONObject().put("key", key).put("ingredient", key).put("quantity", quantity).put("status", status)
            .put("selectedId", selectedId ?: JSONObject.NULL)
            .put("remembered", remembered ?: JSONObject.NULL)
            .put("options", JSONArray(options))

    /** onion remembered (o1, "2 for $1.05"), garlic to choose, saffron unavailable. */
    private fun prepared(): JSONObject {
        val onion = product("o1", "Onion", unitPrice = 0.525, price = "2 for $1.05")
        return JSONObject().put("cartId", "c1").put("store", "heb").put("storeName", "H-E-B")
            .put("items", JSONArray()
                .put(item("onion", "remembered", listOf(onion, product("o2", "Red Onion", 1.25)), "o1", onion, quantity = 2)
                    .put("rememberedPreferenceId", "diced"))
                .put(item("garlic", "choose", listOf(product("g1", "Garlic", 0.5))))
                .put(item("saffron", "unavailable", emptyList()).put("reason", "no_results")))
            .put("ready", JSONArray()).put("needsChoice", JSONArray()).put("unavailable", JSONArray())
    }

    private fun session(json: JSONObject = prepared(), transport: FakeTransport = FakeTransport { _, _, _ -> error("no calls") }) =
        CartSession(MealioClient(MealioConfig("pk", { "tok" }, baseUrl = "https://mealio.test", keys = Vectors.keys), FakeHost(), transport), PreparedCart.fromJson(json))

    @Test
    fun parsesTheNewShape() {
        val cs = session()
        assertEquals("H-E-B", cs.storeName)
        assertEquals(listOf("onion", "garlic", "saffron"), cs.items.map { it.key })
        assertEquals(listOf(ItemStatus.REMEMBERED, ItemStatus.CHOOSE, ItemStatus.UNAVAILABLE), cs.items.map { it.status })
        assertEquals("Onion", cs.items[0].remembered!!.name)
        assertEquals(0.525, cs.items[0].options[0].unitPrice!!, 0.0)
        assertEquals("no_results", cs.items[2].reason)
        assertNull(cs.items[1].selectedId)
    }

    @Test
    fun rememberedItemsStartSelectedWithTheirPreference() {
        val cs = session()
        assertTrue(cs.isSelected("onion"))
        assertEquals("o1", cs.selectedId("onion"))
        assertEquals("diced", cs.selectedPreferenceId("onion"))
        assertEquals("Onion", cs.selected("onion")!!.name)
        assertFalse(cs.isSelected("garlic"))
        assertNull(cs.selected("garlic"))
        assertEquals(1, cs.selectedCount())
    }

    @Test
    fun deselectLeavesTheItemOutWithoutForgetting() {
        val cs = session()
        cs.select("garlic", "g1")
        cs.deselect("onion")
        assertEquals(
            listOf(
                Selection("onion", null, remember = false),
                Selection("garlic", "g1", quantity = 1, remember = true, preferenceId = null),
                Selection("saffron", null, remember = false),
            ),
            cs.selections(),
        )
        val wire = cs.selections()[0].toJson()
        assertTrue(wire.isNull("productId"))
        assertFalse(wire.getBoolean("remember"))
        assertFalse(wire.has("quantity"))
        // The remembered product is still on the item, so the user can tick it again.
        assertEquals("o1", cs.items[0].remembered!!.id)
        cs.select("onion", "o1", preferenceId = "diced")
        assertEquals(Selection("onion", "o1", 2, true, "diced"), cs.selections()[0])
    }

    @Test
    fun selectRefusesUnknownItemsAndProducts() {
        val cs = session()
        for ((k, p, want) in listOf(Triple("zzz", "g1", "unknown_item"), Triple("garlic", "nope", "unknown_product"))) {
            try {
                cs.select(k, p)
                fail("expected $want")
            } catch (e: MealioException) {
                assertEquals(want, e.code)
            }
        }
    }

    @Test
    fun searchMergesOptionsWithoutRepeats(): Unit = runBlocking {
        var calls = 0
        val transport = FakeTransport { path, _, body ->
            assertEquals("/api/v1/sdk/carts/c1/search", path)
            assertEquals("garlic", body.getString("key"))
            calls += 1
            val opts = if (calls == 1) listOf(product("g9", "Minced Garlic Jar"), product("g1", "Garlic"))
            else listOf(product("g8", "Garlic Paste"), product("g9", "Minced Garlic Jar"))
            val result = JSONObject().put("key", "garlic").put("query", body.getString("query")).put("options", JSONArray(opts))
            val job = "job_s$calls"
            ok(JSONObject().put("job", job).put("envelope", TestSigner.instructions(1, listOf(doneOp("i1", result)), job = job).toJson()))
        }
        val cs = session(transport = transport)
        val steps = mutableListOf<Step>()
        val found = cs.search("garlic", "jar") { s, _ -> steps.add(s) }
        assertEquals(listOf("g9", "g1"), found.map { it.id })
        assertEquals(listOf("g1", "g9"), cs.options("garlic").map { it.id })
        cs.search("garlic", "paste")
        // Newest results first after the base options, nothing twice.
        assertEquals(listOf("g1", "g8", "g9"), cs.options("garlic").map { it.id })
        cs.select("garlic", "g9")
        assertEquals("g9", cs.selectedId("garlic"))
        assertEquals("Minced Garlic Jar", cs.selected("garlic")!!.name)
        // Search results belong to one item only.
        assertEquals(listOf("o1", "o2"), cs.options("onion").map { it.id })
        assertTrue(steps.isEmpty()) // the job finished in its first envelope, nothing ran
    }

    @Test
    fun estimateUsesServerUnitPricesTimesQuantity() {
        val cs = session()
        // onion: "2 for $1.05" -> unitPrice 0.525 x 2
        var e = cs.estimate()
        assertEquals(Estimate(total = 1.05, count = 1, estimated = false, unpriced = 0), e)
        cs.select("garlic", "g1")
        e = cs.estimate()
        assertEquals(1.55, e.total, 0.0)
        assertEquals(2, e.count)
        assertFalse(e.estimated)
        cs.select("onion", "o2") // 1.25 x 2
        assertEquals(3.0, cs.estimate().total, 0.0)
        cs.deselect("onion")
        cs.deselect("garlic")
        assertEquals(Estimate(0.0, 0, false, 0), cs.estimate())
    }

    @Test
    fun keepsAQuantityPerItemClampedToOneAndTheStoreCapInSelectionsAndTheTotal() {
        val p2 = prepared()
        val onionItem = p2.getJSONArray("items").getJSONObject(0)
        val capped = product("o1", "Onion", unitPrice = 1.5).put("maxQuantity", 3)
        onionItem.getJSONArray("options").put(0, capped)
        onionItem.put("remembered", capped)
        onionItem.put("quantity", 2)
        val cs = session(p2)
        assertEquals(2, cs.quantity("onion"))
        assertEquals(3, cs.setQuantity("onion", 9))
        assertEquals(1, cs.setQuantity("onion", 0))
        cs.setQuantity("onion", 3)
        val sel = cs.selections()[0]
        assertEquals("onion", sel.key)
        assertEquals("o1", sel.productId)
        assertEquals(3, sel.quantity)
        assertEquals(4.5, cs.estimate().total, 1e-9)
        cs.select("onion", "o2")
        assertEquals(99, cs.maxQuantity("onion"))
        assertEquals(3, cs.quantity("onion"))
        val p3 = prepared()
        p3.getJSONArray("items").getJSONObject(0).put("quantity", 0)
        assertEquals(1, session(p3).quantity("onion"))
    }

    @Test
    fun productParsesQuantityFieldsAndOldPayloadsStillParse() {
        val p = Product.fromJson(JSONObject().put("id", "f1").put("name", "Salmon").put("maxQuantity", 5)
            .put("soldByWeight", true).put("weightOptions", JSONArray().put(0.5).put(1).put(1.5)))
        assertEquals(5, p.maxQuantity)
        assertEquals(true, p.soldByWeight)
        assertEquals(listOf(0.5, 1.0, 1.5), p.weightOptions)
        val old = Product.fromJson(JSONObject().put("id", "x").put("name", "X"))
        assertNull(old.maxQuantity)
        assertNull(old.soldByWeight)
        assertNull(old.weightOptions)
    }

    @Test
    fun estimateIsFlaggedForWeightAndUnpricedItems() {
        val json = JSONObject().put("cartId", "c1").put("store", "heb")
            .put("items", JSONArray()
                .put(item("bananas", "remembered", listOf(product("b1", "Bananas", 0.3, estimated = true)), "b1", quantity = 3))
                .put(item("salt", "remembered", listOf(product("s1", "Salt")), "s1"))
                .put(item("pepper", "remembered", listOf(product("p1", "Pepper", 0.333)), "p1", quantity = 3)))
        val cs = session(json)
        val e = cs.estimate()
        // 0.9 + 0.999 = 1.899 -> 1.90
        assertEquals(1.9, e.total, 0.0)
        assertEquals(3, e.count)
        assertEquals(1, e.unpriced)
        assertTrue(e.estimated)
        cs.deselect("salt")
        val e2 = cs.estimate()
        assertEquals(0, e2.unpriced)
        assertTrue("sold by weight", e2.estimated)
        cs.deselect("bananas")
        assertFalse(cs.estimate().estimated)
        assertEquals(1.0, cs.estimate().total, 0.0)
    }

    @Test
    fun addToCartSendsEveryItem(): Unit = runBlocking {
        var sent: JSONArray? = null
        val transport = FakeTransport { path, _, body ->
            assertEquals("/api/v1/sdk/carts/c1/add", path)
            sent = body.getJSONArray("selections")
            val r = JSONObject().put("cartId", "c1").put("store", "heb").put("added", JSONArray()).put("skipped", JSONArray())
                .put("failed", JSONArray()).put("storeCartUrl", JSONObject.NULL)
            ok(JSONObject().put("job", "job_add").put("envelope", TestSigner.instructions(1, listOf(doneOp("i1", r)), job = "job_add").toJson()))
        }
        val cs = session(transport = transport)
        cs.deselect("onion")
        cs.addToCart()
        val keys = sent!!.objects().map { it.getString("key") }
        assertEquals(listOf("onion", "garlic", "saffron"), keys)
        assertTrue(sent!!.objects().all { it.isNull("productId") && !it.getBoolean("remember") })
    }

    @Test
    @Suppress("DEPRECATION")
    fun deprecatedAliasesStillWork() {
        val cs = session()
        assertEquals(listOf("garlic"), cs.pending().map { it.key })
        cs.choose("garlic", "g1")
        assertTrue(cs.pending().isEmpty())
        cs.skip("onion")
        assertEquals(listOf("onion"), cs.pending().map { it.key })
        assertEquals("g1", cs.selectionFor("garlic")!!.productId)
    }

    @Test
    fun stepOfReadsInstructionIds() {
        fun open(id: String) = Instruction.PageOpen(id, "https://www.heb.com/", 1000)
        val login = Instruction.ShowLogin("open-1", "https://www.heb.com/login", "Sign in", null, emptyList(), null, 1000)
        assertEquals(Step.SIGNING_IN, stepOf(login))
        assertEquals(Step.SEARCHING, stepOf(open("search-onion")))
        assertEquals(Step.ADDING, stepOf(open("add-1")))
        assertEquals(Step.CHECKING_SIGN_IN, stepOf(open("session-check")))
        assertEquals(Step.CHECKING_SIGN_IN, stepOf(open("resession-2")))
        assertEquals(Step.CONNECTING, stepOf(open("open-home")))
        assertEquals(Step.CONNECTING, stepOf(open("")))
        assertEquals("checking_sign_in", Step.CHECKING_SIGN_IN.wire)
    }

    @Test
    fun clientReportsStepsBeforeEachExecutedInstruction(): Unit = runBlocking {
        val prepared = prepared()
        val first = TestSigner.instructions(1, listOf(pageOpen("open-1", "https://www.heb.com/"), fetchOp("session-1", "https://www.heb.com/x")))
        val second = TestSigner.instructions(2, listOf(fetchOp("search-1", "https://www.heb.com/s"), doneOp("done", prepared)))
        val transport = FakeTransport { path, _, _ ->
            if (path.endsWith("/carts")) ok(JSONObject().put("job", "job_test").put("envelope", first.toJson()))
            else ok(JSONObject().put("envelope", second.toJson()))
        }
        val steps = mutableListOf<Pair<Step, String>>()
        val client = MealioClient(MealioConfig("pk", { "tok" }, baseUrl = "https://mealio.test", keys = Vectors.keys), FakeHost(), transport)
        val cs = client.prepareCart("heb", Recipe("r", emptyList())) { s, ins -> steps.add(s to ins.id) }
        assertEquals(listOf(Step.CONNECTING to "open-1", Step.CHECKING_SIGN_IN to "session-1", Step.SEARCHING to "search-1"), steps)
        assertEquals(3, cs.items.size)
    }

    @Test
    fun runnerOnStepSkipsSkippedInstructionsAndSurvivesAThrowingListener(): Unit = runBlocking {
        val env = TestSigner.instructions(1, listOf(pageOpen("a", "https://evil.example/"), pageOpen("b", "https://www.heb.com/")))
        val seen = mutableListOf<String>()
        val out = Runner(FakeHost(), Allowlist(), Vectors.keys).run(env, "job_test", 0) { ins ->
            seen.add(ins.id)
            throw IllegalStateException("listener bug")
        }
        assertEquals(listOf("a"), seen)
        assertEquals(2, out.results.size)
        assertTrue(out.results[1].skipped)
    }
}
