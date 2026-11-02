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
        assertEquals(1.55, e.total!!, 0.0)
        assertEquals(2, e.count)
        assertFalse(e.estimated)
        cs.select("onion", "o2") // 1.25 x 2
        assertEquals(3.0, cs.estimate().total!!, 0.0)
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
        assertEquals(4.5, cs.estimate().total!!, 1e-9)
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
        // No partial totals: salt has no price, so there is no number.
        assertNull(e.total)
        assertEquals(3, e.count)
        assertEquals(1, e.unpriced)
        assertTrue(e.estimated)
        cs.deselect("salt")
        val e2 = cs.estimate()
        // 0.9 + 0.999 = 1.899 -> 1.90
        assertEquals(1.9, e2.total!!, 0.0)
        assertEquals(0, e2.unpriced)
        assertTrue("sold by weight", e2.estimated)
        cs.deselect("bananas")
        assertFalse(cs.estimate().estimated)
        assertEquals(1.0, cs.estimate().total!!, 0.0)
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

    // ── sold by weight (mirrors describe('sold by weight')) ──────────────

    private val turkey = """{"id":"t1","name":"Deli Turkey","soldByWeight":true,"estimated":true,"pricePerLb":10,"unitPrice":10,"weightOptions":[0.25,0.5,0.75,1,1.25]}"""
    private val salmon = """{"id":"s1","name":"Salmon","soldByWeight":true,"estimated":true,"pricePerLb":12,"unitPrice":12}"""
    private val brisket = """{"id":"b1","name":"Brisket, Avg. 4 lbs","soldByWeight":true,"estimated":true,"pricePerLb":null,"unitPrice":32}"""

    private fun weightCart(weightLb: Double? = null): CartSession {
        val w = if (weightLb != null) ""","weightLb":$weightLb""" else ""
        val json = JSONObject(
            """{"cartId":"c1","store":"heb","ready":[],"needsChoice":[],"unavailable":[],"items":[""" +
                """{"key":"turkey","ingredient":"deli turkey","quantity":1,"status":"remembered","selectedId":"t1","remembered":$turkey,"options":[$turkey,$salmon,$brisket]$w},""" +
                """{"key":"onion","ingredient":"onion","quantity":2,"status":"remembered","selectedId":"o1","remembered":null,"options":[{"id":"o1","name":"Onion","unitPrice":1}]}""" +
                "]}",
        )
        return session(json)
    }

    @Test
    fun weightStartsAtTheRecipeWeightElseTheFirstOptionElseAQuarter() {
        assertEquals(0.75, weightCart(0.75).weight("turkey"), 0.0)
        // A recipe weight the store does not sell becomes the nearest one it does.
        assertEquals(0.5, weightCart(0.6).weight("turkey"), 0.0)
        assertEquals(0.25, weightCart().weight("turkey"), 0.0)
        val cs = weightCart()
        cs.select("turkey", "s1")
        assertEquals(0.25, cs.weight("turkey"), 0.0)
        assertEquals(0.0, cs.weight("onion"), 0.0)
        assertTrue(cs.isWeight("turkey"))
        assertFalse(cs.isWeight("onion"))
    }

    @Test
    fun setWeightSnapsToTheOptionsAndClampsToTheirRange() {
        val cs = weightCart()
        assertEquals(0.75, cs.setWeight("turkey", 0.8), 0.0)
        assertEquals(1.25, cs.setWeight("turkey", 9.0), 0.0)
        assertEquals(0.25, cs.setWeight("turkey", 0.0), 0.0)
        assertEquals(WeightRange(0.25, 1.25), cs.weightRange("turkey"))
        assertEquals(0.25, cs.weight("turkey"), 0.0)
    }

    @Test
    fun withNoOptionsQuarterPoundStepsFromAQuarterTo20() {
        val cs = weightCart()
        cs.select("turkey", "s1")
        assertEquals(1.0, cs.setWeight("turkey", 1.1), 0.0)
        assertEquals(1.25, cs.setWeight("turkey", 1.13), 0.0)
        assertEquals(0.25, cs.setWeight("turkey", 0.01), 0.0)
        assertEquals(20.0, cs.setWeight("turkey", 99.0), 0.0)
        assertEquals(WeightRange(0.25, 20.0), cs.weightRange("turkey"))
        cs.setWeight("turkey", 1.0)
        assertEquals(1.25, cs.stepWeight("turkey", 1), 0.0)
        assertEquals(1.0, cs.stepWeight("turkey", -1), 0.0)
    }

    @Test
    fun stepWeightWalksTheOptionsAndStopsAtTheEnds() {
        val cs = weightCart()
        assertEquals(0.25, cs.stepWeight("turkey", -1), 0.0)
        assertEquals(0.5, cs.stepWeight("turkey", 1), 0.0)
        cs.setWeight("turkey", 1.25)
        assertEquals(1.25, cs.stepWeight("turkey", 1), 0.0)
        assertEquals(1.0, cs.stepWeight("turkey", -1), 0.0)
    }

    @Test
    fun switchingProductReSnapsTheWeightToTheNewProduct() {
        val cs = weightCart()
        cs.select("turkey", "s1")
        cs.setWeight("turkey", 3.0)
        cs.select("turkey", "t1")
        assertEquals(1.25, cs.weight("turkey"), 0.0)
    }

    @Test
    fun selectionsSendWeightLbForWeightItemsOnly() {
        val cs = weightCart(1.0)
        assertEquals(
            listOf(
                Selection("turkey", "t1", quantity = 1, remember = true, preferenceId = null, weightLb = 1.0),
                Selection("onion", "o1", quantity = 2, remember = true, preferenceId = null),
            ),
            cs.selections(),
        )
        val wire = cs.selections().map { it.toJson() }
        assertEquals(1.0, wire[0].getDouble("weightLb"), 0.0)
        assertFalse(wire[1].has("weightLb"))
    }

    @Test
    fun estimateIsPricePerLbTimesTheWeightAndMarkedEstimated() {
        val cs = weightCart()
        cs.setWeight("turkey", 1.25)
        val e = cs.estimate()
        assertEquals(14.5, e.total!!, 0.0)
        assertTrue(e.estimated)
        assertEquals(2, e.count)
        // A package-priced weight item counts its price once, whatever the weight.
        cs.select("turkey", "b1")
        cs.setWeight("turkey", 3.0)
        val e2 = cs.estimate()
        assertEquals(34.0, e2.total!!, 0.0)
        assertTrue(e2.estimated)
    }

    @Test
    fun parsesWeightFieldsAsOptional() {
        val cs = weightCart(1.0)
        assertEquals(1.0, cs.items[0].weightLb!!, 0.0)
        assertNull(cs.items[1].weightLb)
        assertEquals(10.0, cs.options("turkey")[0].pricePerLb!!, 0.0)
        assertNull(cs.options("turkey")[2].pricePerLb)
        assertNull(cs.options("onion")[0].pricePerLb)
        val r = AddResult.fromJson(
            JSONObject("""{"cartId":"c1","store":"heb","added":[{"key":"turkey","productId":"t1","name":"Deli Turkey","quantity":1,"weightLb":1.25},{"key":"onion","productId":"o1","name":"Onion","quantity":2}],"skipped":[],"failed":[],"storeCartUrl":null}"""),
        )
        assertEquals(1.25, r.added[0].weightLb!!, 0.0)
        assertNull(r.added[1].weightLb)
    }

    // ── preferences ──────────────────────────────────────────────────────

    @Test
    fun holdsAnItemBackFromTheAddAndTheTotalUntilItsPreferenceIsChosen() {
        val p4 = prepared()
        val prefs = JSONArray().put(JSONObject().put("id", "thin").put("label", "Thin")).put(JSONObject().put("id", "none").put("label", "No preference"))
        p4.getJSONArray("items").getJSONObject(1)
            .put("options", JSONArray().put(product("g1", "Deli Turkey", 6.0).put("preferences", prefs)))
        val cs = session(p4)
        cs.select("garlic", "g1")
        assertTrue(cs.needsPreference("garlic"))
        assertEquals(listOf("garlic"), cs.pendingPreferences())
        assertEquals(Selection("garlic", null, remember = false), cs.selections()[1])
        assertEquals(1, cs.estimate().count)
        cs.select("garlic", "g1", preferenceId = "thin")
        assertFalse(cs.needsPreference("garlic"))
        assertEquals("thin", cs.preferenceId("garlic"))
        val sel = cs.selections()[1]
        assertEquals("garlic", sel.key)
        assertEquals("g1", sel.productId)
        assertEquals("thin", sel.preferenceId)
        assertEquals(2, cs.estimate().count)
    }

    // ── no partial totals ────────────────────────────────────────────────
    // Mirrors describe('no partial totals') in packages/core/test/core.test.ts.

    private fun priced(onion: Map<String, Any?> = emptyMap(), turkey: Map<String, Any?> = emptyMap()): JSONObject {
        fun over(o: JSONObject, m: Map<String, Any?>) = o.also { m.forEach { (k, v) -> it.put(k, v ?: JSONObject.NULL) } }
        val o1 = over(JSONObject().put("id", "o1").put("name", "Onion").put("unitPrice", 1), onion)
        val t1 = over(JSONObject().put("id", "t1").put("name", "Deli Turkey").put("soldByWeight", true).put("estimated", true)
            .put("pricePerLb", 12).put("unitPrice", 12), turkey)
        val c1 = JSONObject().put("id", "c1").put("name", "Chipotle Peppers").put("unitPrice", JSONObject.NULL)
        return JSONObject().put("cartId", "c1").put("store", "heb")
            .put("ready", JSONArray()).put("needsChoice", JSONArray()).put("unavailable", JSONArray())
            .put("items", JSONArray()
                .put(JSONObject().put("key", "onion").put("ingredient", "onion").put("quantity", 2).put("status", "remembered")
                    .put("selectedId", "o1").put("remembered", JSONObject.NULL).put("options", JSONArray().put(o1)))
                .put(JSONObject().put("key", "turkey").put("ingredient", "deli turkey").put("quantity", 1).put("weightLb", 0.5)
                    .put("status", "remembered").put("selectedId", "t1").put("remembered", JSONObject.NULL).put("options", JSONArray().put(t1)))
                .put(JSONObject().put("key", "chipotle").put("ingredient", "chipotle in adobo").put("quantity", 1).put("status", "choose")
                    .put("selectedId", JSONObject.NULL).put("remembered", JSONObject.NULL).put("options", JSONArray().put(c1))))
    }

    private fun result(added: List<AddedItem>) = AddResult("c1", "heb", added, emptyList(), emptyList(), null, verified = true)

    @Test
    fun totalsWhenEverySelectedItemHasAPriceAndAWeightItemPricedPerLbCountsAsPriced() {
        assertEquals(Estimate(total = 8.0, count = 2, estimated = true, unpriced = 0), session(priced()).estimate())
    }

    @Test
    fun totalIsNullWhenEvenOneSelectedItemHasNoPrice() {
        val cs = session(priced())
        cs.select("chipotle", "c1")
        assertEquals(Estimate(total = null, count = 3, estimated = true, unpriced = 1), cs.estimate())
        // A weight item with neither a per-lb nor a package price is unpriced too.
        val w = session(priced(turkey = mapOf("pricePerLb" to null, "unitPrice" to null))).estimate()
        assertNull(w.total)
        assertEquals(1, w.unpriced)
        // Deselecting the unpriced item brings the number back.
        cs.deselect("chipotle")
        assertEquals(8.0, cs.estimate().total!!, 0.0)
    }

    @Test
    fun pricesAddedItemsFromTheirOwnFields() {
        // Unit times quantity, per lb times pounds, a package once.
        assertEquals(LinePrice(0.74, false), addedPrice(AddedItem("a", "1", "Onion", 2, unitPrice = 0.37)))
        assertEquals(LinePrice(13.63, true), addedPrice(AddedItem("b", "2", "Salmon", 1, weightLb = 1.25, pricePerLb = 10.9, unitPrice = 10.9, estimated = true)))
        assertEquals(LinePrice(32.0, true), addedPrice(AddedItem("c", "3", "Brisket", 1, weightLb = 4.0, unitPrice = 32.0, estimated = true)))
        assertNull(addedPrice(AddedItem("d", "4", "Chipotle", 1)))
    }

    @Test
    fun addedTotalReadsTheAddedEntriesFallsBackToTheSessionProductAndIsNullWhenAnyIsUnpriced() {
        val cs = session(priced())
        val full = result(listOf(
            AddedItem("onion", "o1", "Onion", 2, imageUrl = "https://img/o.jpg", ingredient = "2 onions", unitPrice = 1.25),
            AddedItem("turkey", "t1", "Deli Turkey", 1, weightLb = 0.5, pricePerLb = 12.0, estimated = true),
        ))
        assertEquals(Estimate(total = 8.5, count = 2, estimated = true, unpriced = 0), cs.addedTotal(full))
        // An older server: no prices on the entries, the selected products stand in.
        val old = result(listOf(AddedItem("onion", "o1", "Onion", 2), AddedItem("turkey", "t1", "Deli Turkey", 1, weightLb = 0.5)))
        assertEquals(Estimate(total = 8.0, count = 2, estimated = true, unpriced = 0), cs.addedTotal(old))
        cs.select("chipotle", "c1")
        assertEquals(
            Estimate(total = null, count = 3, estimated = true, unpriced = 1),
            cs.addedTotal(result(full.added + AddedItem("chipotle", "c1", "Chipotle Peppers", 1))),
        )
        assertEquals(LinePrice(2.5, false), cs.addedPrice(full.added[0]))
    }

    @Test
    fun parsesTheFinishedRunFieldsOnAddedItemsAsOptional() {
        val r = AddResult.fromJson(JSONObject("""{"cartId":"c1","store":"heb","added":[
            {"key":"onion","productId":"o1","name":"Onion","quantity":2,"imageUrl":"https://img/o.jpg","ingredient":"2 onions","unitPrice":1.25},
            {"key":"turkey","productId":"t1","name":"Deli Turkey","quantity":1,"weightLb":0.5,"pricePerLb":12,"estimated":true},
            {"key":"salt","productId":"s1","name":"Salt","quantity":1}],"skipped":[],"failed":[],"storeCartUrl":null,"verified":true}"""))
        assertEquals(AddedItem("onion", "o1", "Onion", 2, imageUrl = "https://img/o.jpg", ingredient = "2 onions", unitPrice = 1.25), r.added[0])
        assertEquals(AddedItem("turkey", "t1", "Deli Turkey", 1, weightLb = 0.5, pricePerLb = 12.0, estimated = true), r.added[1])
        assertEquals(AddedItem("salt", "s1", "Salt", 1), r.added[2])
    }
}
