package co.mealio.sdk

import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.IOException

class ClientTest {
    private fun config(token: suspend () -> String = { "tok" }) = MealioConfig(
        publishableKey = "pk_test",
        sessionTokenProvider = token,
        baseUrl = "https://mealio.test/",
        keys = Vectors.keys,
    )

    private suspend fun code(block: suspend () -> Unit): String = try {
        block()
        fail("expected MealioException")
        ""
    } catch (e: MealioException) {
        e.code
    }

    @Test
    fun drivesAJobToDoneThroughStepCalls(): Unit = runBlocking {
        val c1 = Vectors.case("valid_two_instructions").getJSONObject("envelope")
        val c2 = Vectors.case("valid_unicode_done").getJSONObject("envelope")
        val transport = FakeTransport { path, _, body ->
            when {
                path.endsWith("/carts") -> ok(JSONObject().put("job", "job_test").put("envelope", c1))
                path.endsWith("/step") -> {
                    assertEquals(1, body.getInt("seq"))
                    assertEquals(2, body.getJSONArray("results").length())
                    ok(JSONObject().put("envelope", c2))
                }
                else -> error("unexpected $path")
            }
        }
        val client = MealioClient(config(), FakeHost(), transport)
        // The done result is not a PreparedCart here; the point is the loop.
        try {
            client.prepareCart("heb", Recipe("r1", emptyList()))
        } catch (e: MealioException) {
            // fine either way
        }
        // No hello round trip: the first call starts the job.
        assertEquals(listOf("/api/v1/sdk/carts", "/api/v1/sdk/jobs/job_test/step"), transport.seen)
    }

    @Test
    fun retriesOnceWithAFreshTokenOn401(): Unit = runBlocking {
        var tokens = 0
        var calls = 0
        val transport = FakeTransport { _, _, _ ->
            calls += 1
            if (calls == 1) HttpResponse(401, "{}") else ok(JSONObject().put("ok", true))
        }
        val client = MealioClient(config { "t${++tokens}" }, FakeHost(), transport)
        // The answer has no job; the point is the retry.
        try { client.addToCart("c1", emptyList()) } catch (e: MealioException) { }
        assertEquals(2, tokens)
        assertEquals("Bearer t2", transport.headers[1]["Authorization"])
    }

    @Test
    fun secondUnauthorizedIsSessionExpired(): Unit = runBlocking {
        val transport = FakeTransport { _, _, _ -> HttpResponse(401, "{}") }
        val client = MealioClient(config(), FakeHost(), transport)
        assertEquals("session_expired", code { client.addToCart("c1", emptyList()) })
        assertEquals(2, transport.seen.size)
    }

    @Test
    fun sendsTheProtocolHeadersAndWhoIsCallingInEveryJobBody(): Unit = runBlocking {
        val bodies = mutableListOf<JSONObject>()
        val transport = FakeTransport { _, _, body -> bodies.add(body); HttpResponse(503, "{}") }
        val client = MealioClient(config().let { MealioConfig(it.publishableKey, it.sessionTokenProvider, baseUrl = it.baseUrl, keys = it.keys, epochProvider = { 7 }, attestationProvider = { "att" }) }, FakeHost(), transport)
        code { client.prepareCart("heb", Recipe("r1", listOf(RecipeIngredient("milk")), title = "Tacos"), zip = "78701") }
        code { client.search("cart 1", "k1", "minced garlic") }
        code { client.addToCart("cart 1", listOf(Selection("k1", "p1", 1, true))) }
        assertEquals(listOf("/api/v1/sdk/carts", "/api/v1/sdk/carts/cart%201/search", "/api/v1/sdk/carts/cart%201/add"), transport.seen)

        val h = transport.headers[0]
        assertEquals("application/json", h["Content-Type"])
        assertEquals("Bearer tok", h["Authorization"])
        assertEquals("pk_test", h["X-Mealio-Publishable-Key"])
        assertEquals("android/${MealioCart.SDK_VERSION}", h["X-Mealio-SDK"])
        assertEquals("att", h["X-Mealio-Attestation"])

        for (b in bodies) {
            assertEquals(7, b.getInt("epoch"))
            val sdk = b.getJSONObject("sdk")
            assertEquals("android", sdk.getString("platform"))
            assertEquals(MealioCart.SDK_VERSION, sdk.getString("version"))
            assertEquals(SDK_CORE_VERSION, sdk.getString("core"))
            assertEquals(SUPPORTED_OPS, sdk.getJSONArray("ops").strings())
        }
        assertEquals("heb", bodies[0].getString("store"))
        assertEquals("78701", bodies[0].getString("zip"))
        assertEquals("Tacos", bodies[0].getJSONObject("recipe").getString("title"))
        assertEquals("k1", bodies[1].getString("key"))
        assertEquals("minced garlic", bodies[1].getString("query"))
        assertEquals("p1", bodies[2].getJSONArray("selections").getJSONObject(0).getString("productId"))
    }

    @Test
    fun oneRecipeGoesAsRecipeAndSeveralAsRecipes(): Unit = runBlocking {
        val bodies = mutableListOf<JSONObject>()
        val client = MealioClient(config(), FakeHost(), FakeTransport { _, _, b -> bodies.add(b); HttpResponse(503, "{}") })
        val tacos = Recipe("r1", listOf(RecipeIngredient("onion")), title = "Tacos")
        val pasta = Recipe("r2", listOf(RecipeIngredient("onion"), RecipeIngredient("penne")), title = "Pasta")

        code { client.prepareCart("heb", tacos) }
        code { client.prepareCart("heb", listOf(tacos)) }
        code { client.prepareCart("heb", listOf(tacos, pasta), zip = "78701") }
        assertEquals(3, bodies.size)

        // One recipe, either overload: `recipe`, so an older server understands it.
        for (b in bodies.take(2)) {
            assertEquals("Tacos", b.getJSONObject("recipe").getString("title"))
            assertFalse(b.has("recipes"))
        }
        val several = bodies[2]
        assertFalse(several.has("recipe"))
        val sent = several.getJSONArray("recipes").objects()
        assertEquals(listOf("r1", "r2"), sent.map { it.getString("id") })
        assertEquals(2, sent[1].getJSONArray("ingredients").length())
        assertEquals("heb", several.getString("store"))
        assertEquals("78701", several.getString("zip"))
        assertEquals(SDK_CORE_VERSION, several.getJSONObject("sdk").getString("core"))
    }

    @Test
    fun recipeDetailsAreSentOnlyWhenSet(): Unit = runBlocking {
        val bodies = mutableListOf<JSONObject>()
        val client = MealioClient(config(), FakeHost(), FakeTransport { _, _, b -> bodies.add(b); HttpResponse(503, "{}") })
        val full = Recipe(
            "r1",
            listOf(RecipeIngredient("salt", pantry = true), RecipeIngredient("cilantro", optional = true)),
            servings = 4.0,
            makeServings = 6.0,
            photoUrl = "https://example.com/tacos.jpg",
        )

        code { client.prepareCart("heb", full) }
        code { client.prepareCart("heb", Recipe("r2", listOf(RecipeIngredient("onion")))) }

        val sent = bodies[0].getJSONObject("recipe")
        assertEquals(4.0, sent.getDouble("servings"), 0.0)
        assertEquals(6.0, sent.getDouble("makeServings"), 0.0)
        assertEquals("https://example.com/tacos.jpg", sent.getString("photoUrl"))
        val lines = sent.getJSONArray("ingredients").objects()
        assertTrue(lines[0].getBoolean("pantry"))
        assertFalse(lines[0].has("optional"))
        assertTrue(lines[1].getBoolean("optional"))
        assertFalse(lines[1].has("pantry"))

        val plain = bodies[1].getJSONObject("recipe")
        for (k in listOf("servings", "makeServings", "photoUrl")) assertFalse(k, plain.has(k))
        val line = plain.getJSONArray("ingredients").getJSONObject(0)
        for (k in listOf("pantry", "optional")) assertFalse(k, line.has(k))
    }

    @Test
    fun noRecipesOrTooManyFailBeforeAnyRequest(): Unit = runBlocking {
        var tokens = 0
        val transport = FakeTransport { _, _, _ -> error("no calls") }
        val client = MealioClient(config { tokens += 1; "tok" }, FakeHost(), transport)
        assertEquals("bad_recipe", code { client.prepareCart("heb", emptyList<Recipe>()) })
        val eleven = (1..MAX_RECIPES + 1).map { Recipe("r$it", listOf(RecipeIngredient("salt"))) }
        assertEquals("too_many_recipes", code { client.prepareCart("heb", eleven) })
        assertTrue(transport.seen.isEmpty())
        assertEquals(0, tokens)
    }

    @Test
    fun epochDefaultsToZero(): Unit = runBlocking {
        var body: JSONObject? = null
        val client = MealioClient(config(), FakeHost(), FakeTransport { _, _, b -> body = b; HttpResponse(503, "{}") })
        code { client.addToCart("c", emptyList()) }
        assertEquals(0, body!!.getInt("epoch"))
    }

    @Test
    fun widensTheAllowlistOnlyWhenSigned() {
        val payload = JSONObject().put("v", 1).put("kind", "allowlist").put("exp", 4102444800L)
            .put("stores", JSONObject().put("heb", JSONObject().put("hosts", JSONArray().put("api.heb.com").put("evil.io"))))
            .toString()
        val good = TestSigner.sign(payload)
        val client = MealioClient(config(), FakeHost(), FakeTransport { _, _, _ -> error("no calls") })
        client.widenAllowlist(good)
        assertTrue("api.heb.com" in client.allowlist.hostsFor("heb")!!.hosts)
        assertFalse("evil.io" in client.allowlist.hostsFor("heb")!!.hosts)

        val forged = Envelope(payload.replace("api.heb.com", "www.heb.com"), good.sig, good.kid)
        val client2 = MealioClient(config(), FakeHost(), FakeTransport { _, _, _ -> error("no calls") })
        client2.widenAllowlist(forged)
        assertEquals(listOf("heb.com"), client2.allowlist.hostsFor("heb")!!.hosts)
    }

    @Test
    fun mapsErrors(): Unit = runBlocking {
        val serverErr = FakeTransport { _, _, _ ->
            HttpResponse(503, JSONObject().put("error", JSONObject().put("code", "store_unavailable").put("message", "down")).toString())
        }
        val r = Recipe("r", emptyList())
        assertEquals("store_unavailable", code { MealioClient(config(), FakeHost(), serverErr).prepareCart("heb", r) })
        assertEquals("server", code { MealioClient(config(), FakeHost(), FakeTransport { _, _, _ -> HttpResponse(500, "oops") }).prepareCart("heb", r) })
        assertEquals("network", code { MealioClient(config(), FakeHost(), FakeTransport { _, _, _ -> throw IOException("down") }).prepareCart("heb", r) })
        assertEquals("session_expired", code { MealioClient(config { throw RuntimeException("no") }, FakeHost(), serverErr).prepareCart("heb", r) })
    }

    private fun cartFlow(first: Envelope, onStep: (JSONObject) -> HttpResponse = { error("no step expected") }) =
        FakeTransport { path, _, body ->
            when {
                path.endsWith("/carts") -> ok(JSONObject().put("job", "job_test").put("envelope", first.toJson()))
                path.endsWith("/step") -> onStep(body)
                else -> error("unexpected $path")
            }
        }

    @Test
    fun failAndBadEnvelopesBecomeMealioErrors(): Unit = runBlocking {
        val fail = TestSigner.instructions(1, listOf(failOp("i1", "login_cancelled", "closed")))
        assertEquals("login_cancelled", code { MealioClient(config(), FakeHost(), cartFlow(fail)).prepareCart("heb", Recipe("r", emptyList())) })

        val wrongJob = TestSigner.instructions(1, listOf(doneOp("i1", null)), job = "job_other")
        assertEquals("bad_envelope", code { MealioClient(config(), FakeHost(), cartFlow(wrongJob)).prepareCart("heb", Recipe("r", emptyList())) })

        val unknownOp = TestSigner.instructions(1, listOf(JSONObject().put("op", "tap").put("id", "i1")))
        assertEquals("unsupported", code { MealioClient(config(), FakeHost(), cartFlow(unknownOp)).prepareCart("heb", Recipe("r", emptyList())) })

        // seq must climb by exactly one across step calls.
        val first = TestSigner.instructions(1, listOf(pageOpen("i1", "https://www.heb.com/")))
        val replay = TestSigner.instructions(1, listOf(doneOp("i2", null)))
        assertEquals("bad_envelope", code {
            MealioClient(config(), FakeHost(), cartFlow(first) { ok(JSONObject().put("envelope", replay.toJson())) })
                .prepareCart("heb", Recipe("r", emptyList()))
        })
    }

    @Test
    @Suppress("DEPRECATION")
    fun legacyServerShapeStillWorksThroughTheOldApi(): Unit = runBlocking {
        val prepared = JSONObject()
            .put("cartId", "cart 1")
            .put("store", "heb")
            .put("ready", JSONArray().put(
                JSONObject().put("key", "a").put("ingredient", "milk").put("quantity", 1)
                    .put("chosen", JSONObject().put("id", "p1").put("name", "Milk")),
            ))
            .put("needsChoice", JSONArray().put(
                JSONObject().put("key", "b").put("ingredient", "ham").put("quantity", 2)
                    .put("options", JSONArray()
                        .put(JSONObject().put("id", "p2").put("name", "Ham").put("badge", "popular")
                            .put("preferences", JSONArray().put(JSONObject().put("id", "sliced").put("label", "Sliced"))))
                        .put(JSONObject().put("id", "p3").put("name", "Other ham"))),
            ).put(JSONObject().put("key", "c").put("ingredient", "salt").put("quantity", 1).put("options", JSONArray())))
            .put("unavailable", JSONArray().put(JSONObject().put("key", "d").put("ingredient", "saffron").put("quantity", 1).put("reason", "no_results")))
        val addResult = JSONObject().put("cartId", "cart 1").put("store", "heb")
            .put("added", JSONArray().put(JSONObject().put("key", "a").put("productId", "p1").put("name", "Milk").put("quantity", 1)))
            .put("skipped", JSONArray().put(JSONObject().put("key", "c").put("reason", "user")))
            .put("failed", JSONArray())
            .put("storeCartUrl", "https://www.heb.com/cart")

        var addBody: JSONObject? = null
        var job = 0
        val transport = FakeTransport { path, _, body ->
            when {
                path == "/api/v1/sdk/carts" -> ok(JSONObject().put("job", "job_test").put("envelope", TestSigner.instructions(1, listOf(doneOp("i1", prepared))).toJson()))
                path == "/api/v1/sdk/carts/cart%201/add" -> {
                    addBody = body
                    job += 1
                    ok(JSONObject().put("job", "job_add").put("envelope", TestSigner.instructions(1, listOf(doneOp("i1", addResult)), job = "job_add").toJson()))
                }
                else -> error("unexpected $path")
            }
        }
        val session = MealioClient(config(), FakeHost(), transport).prepareCart("heb", Recipe("r1", listOf(RecipeIngredient("milk"))), zip = "78701")
        assertEquals("cart 1", session.cartId)
        assertEquals(listOf("a", "b", "c", "d"), session.items.map { it.key })
        assertEquals(ItemStatus.REMEMBERED, session.items[0].status)
        assertEquals(ItemStatus.UNAVAILABLE, session.items[3].status)
        assertEquals(listOf("b", "c"), session.pending().map { it.key })
        assertEquals("p1", session.selectionFor("a")!!.productId)
        assertEquals("popular", session.needsChoice[0].options[0].badge)
        assertEquals("Sliced", session.needsChoice[0].options[0].preferences[0].label)
        assertEquals("no_results", session.unavailable[0].reason)

        assertEquals("unknown_product", code { session.choose("b", "nope") })
        assertEquals("unknown_item", code { session.choose("zzz", "p2") })
        session.choose("b", "p2", preferenceId = "sliced")
        session.skip("c")
        // skip() is deselect() now: the item is simply not selected this run.
        assertEquals(listOf("c"), session.pending().map { it.key })

        val result = session.addToCart()
        assertEquals(1, job)
        assertEquals("https://www.heb.com/cart", result.storeCartUrl)
        assertEquals("Milk", result.added[0].name)
        assertEquals("c", result.skipped[0].key)

        val sel = addBody!!.getJSONArray("selections").objects().associateBy { it.getString("key") }
        assertEquals("p1", sel["a"]!!.getString("productId"))
        assertEquals(2, sel["b"]!!.getInt("quantity"))
        assertEquals("sliced", sel["b"]!!.getString("preferenceId"))
        assertTrue(sel["b"]!!.getBoolean("remember"))
        assertTrue(sel["c"]!!.isNull("productId"))
        assertFalse(sel["c"]!!.getBoolean("remember"))
        // Every item is sent, the unavailable one too.
        assertTrue(sel["d"]!!.isNull("productId"))
    }

    @Test
    fun storesIsAPublicGetWithNoSession(): Unit = runBlocking {
        var tokens = 0
        val list = JSONObject().put("stores", JSONArray()
            .put(JSONObject().put("id", "heb").put("name", "H-E-B").put("via", "device"))
            .put(JSONObject().put("id", "kroger").put("name", "Kroger").put("via", "kroger_api")))
        val transport = FakeTransport(onGet = { HttpResponse(200, list.toString()) }) { _, _, _ -> error("no POST") }
        val client = MealioClient(config { tokens += 1; "tok" }, FakeHost(), transport)
        assertEquals(listOf(StoreInfo("heb", "H-E-B", "device"), StoreInfo("kroger", "Kroger", "kroger_api")), client.stores())
        assertEquals(listOf("GET /api/v1/stores"), transport.seen)
        assertEquals(0, tokens)
        assertFalse(transport.headers[0].containsKey("Authorization"))

        val odd = MealioClient(config(), FakeHost(), FakeTransport(onGet = { HttpResponse(200, "{}") }) { _, _, _ -> error("no POST") })
        assertTrue(odd.stores().isEmpty())
        val down = MealioClient(config(), FakeHost(), FakeTransport(onGet = { throw IOException("down") }) { _, _, _ -> error("no POST") })
        assertEquals("network", code { down.stores() })
        val html = MealioClient(config(), FakeHost(), FakeTransport(onGet = { HttpResponse(502, "<html>") }) { _, _, _ -> error("no POST") })
        assertEquals("network", code { html.stores() })
    }

    @Test
    fun storeIsOptionalAndStoreRequiredSurfaces(): Unit = runBlocking {
        var body: JSONObject? = null
        val fail = TestSigner.instructions(1, listOf(failOp("i1", "store_required", "Pick a store")))
        val transport = FakeTransport { _, _, b -> body = b; ok(JSONObject().put("job", "job_test").put("envelope", fail.toJson())) }
        val client = MealioClient(config(), FakeHost(), transport)
        assertEquals("store_required", code { client.prepareCart(null, Recipe("r", emptyList())) })
        assertTrue(body!!.has("store"))
        assertTrue(body!!.isNull("store"))
    }

    private val oak = JSONObject().put("id", "k2").put("name", "Kroger Oak")
        .put("address", "3 Oak St, Dallas, TX 75202").put("zip", "75202")
    private val oakLocation = StoreLocation("k2", "Kroger Oak", "3 Oak St, Dallas, TX 75202", "75202")

    @Test
    fun listsStoresNearAZip(): Unit = runBlocking {
        var body: JSONObject? = null
        val transport = FakeTransport { _, _, b -> body = b; ok(JSONObject().put("locations", JSONArray().put(oak))) }
        assertEquals(listOf(oakLocation), MealioClient(config(), FakeHost(), transport).storeLocations("kroger", "75202"))
        assertEquals(listOf("/api/v1/sdk/locations"), transport.seen)
        assertEquals(2, body!!.length())
        assertEquals("kroger", body!!.getString("store"))
        assertEquals("75202", body!!.getString("zip"))

        val none = MealioClient(config(), FakeHost(), FakeTransport { _, _, _ -> ok(JSONObject()) })
        assertTrue(none.storeLocations("kroger", "75202").isEmpty())
    }

    @Test
    fun readsAndSetsTheStore(): Unit = runBlocking {
        val bodies = mutableListOf<JSONObject>()
        val transport = FakeTransport { _, _, b ->
            bodies.add(b)
            ok(JSONObject().put("defaultStore", "kroger").put("location", oak))
        }
        val client = MealioClient(config(), FakeHost(), transport)
        assertEquals(StorePreferences("kroger", oakLocation), client.storePreferences())
        client.setStore("kroger", "k2")
        client.setStore("heb")
        assertEquals(List(3) { "/api/v1/sdk/preferences" }, transport.seen)
        assertEquals(0, bodies[0].length())
        assertEquals("k2", bodies[1].getString("locationId"))
        assertEquals("kroger", bodies[1].getString("store"))
        assertEquals("heb", bodies[2].getString("store"))
        assertFalse(bodies[2].has("locationId"))
    }

    @Test
    fun noDefaultStoreReadsAsNulls(): Unit = runBlocking {
        val transport = FakeTransport { _, _, _ -> ok(JSONObject().put("defaultStore", JSONObject.NULL).put("location", JSONObject.NULL)) }
        assertEquals(StorePreferences(null, null), MealioClient(config(), FakeHost(), transport).storePreferences())
    }

    @Test
    fun locationRequiredFailsBeforeAnySignIn(): Unit = runBlocking {
        val transport = FakeTransport { _, _, _ ->
            HttpResponse(409, JSONObject().put("error", JSONObject().put("code", "location_required").put("message", "Choose")).toString())
        }
        val host = FakeHost()
        val client = MealioClient(config(), host, transport)
        assertEquals("location_required", code { client.prepareCart("kroger", Recipe("r", listOf(RecipeIngredient("garlic")))) })
        assertEquals(listOf("/api/v1/sdk/carts"), transport.seen)
        assertTrue(host.calls.isEmpty())
    }

    @Test
    fun cartCarriesItsLocationWhenTheServerSendsOne() {
        val base = JSONObject().put("cartId", "c").put("store", "kroger")
        assertEquals(null, PreparedCart.fromJson(base).location)
        assertEquals(null, PreparedCart.fromJson(JSONObject(base.toString()).put("location", JSONObject.NULL)).location)
        assertEquals(oakLocation, PreparedCart.fromJson(JSONObject(base.toString()).put("location", oak)).location)
        val noZip = JSONObject(oak.toString()).put("zip", JSONObject.NULL)
        assertEquals(null, StoreLocation.fromJson(noZip).zip)
    }

    @Test
    fun addResultCarriesVerified() {
        val base = JSONObject().put("cartId", "c").put("store", "heb").put("added", JSONArray()).put("skipped", JSONArray())
            .put("failed", JSONArray().put(JSONObject().put("key", "k").put("productId", "p").put("name", "Milk").put("reason", "not_confirmed")))
            .put("storeCartUrl", JSONObject.NULL)
        assertEquals(null, AddResult.fromJson(base).verified)
        assertEquals(false, AddResult.fromJson(JSONObject(base.toString()).put("verified", false)).verified)
        assertEquals("not_confirmed", AddResult.fromJson(base).failed[0].reason)
    }

    @Test
    fun encodesPathSegmentsLikeEncodeUriComponent() {
        assertEquals("a%20b%2Fc!'()*~", encodeUriComponent("a b/c!'()*~"))
    }
}
