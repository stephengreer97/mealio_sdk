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
                path.endsWith("/hello") -> ok(JSONObject().put("ok", true))
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
        assertEquals(listOf("/api/v1/sdk/hello", "/api/v1/sdk/carts", "/api/v1/sdk/jobs/job_test/step"), transport.seen)
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
        client.hello()
        assertEquals(2, tokens)
        assertEquals("Bearer t2", transport.headers[1]["Authorization"])
    }

    @Test
    fun secondUnauthorizedIsSessionExpired(): Unit = runBlocking {
        val transport = FakeTransport { _, _, _ -> HttpResponse(401, "{}") }
        val client = MealioClient(config(), FakeHost(), transport)
        assertEquals("session_expired", code { client.hello() })
        assertEquals(2, transport.seen.size)
    }

    @Test
    fun sendsTheProtocolHeadersAndHello(): Unit = runBlocking {
        var hello: JSONObject? = null
        val transport = FakeTransport { _, _, body -> hello = body; ok(JSONObject().put("ok", true)) }
        val client = MealioClient(config().let { MealioConfig(it.publishableKey, it.sessionTokenProvider, baseUrl = it.baseUrl, keys = it.keys, epochProvider = { 7 }, attestationProvider = { "att" }) }, FakeHost(), transport)
        client.hello()
        val h = transport.headers[0]
        assertEquals("application/json", h["Content-Type"])
        assertEquals("Bearer tok", h["Authorization"])
        assertEquals("pk_test", h["X-Mealio-Publishable-Key"])
        assertEquals("android/${MealioCart.SDK_VERSION}", h["X-Mealio-SDK"])
        assertEquals("att", h["X-Mealio-Attestation"])
        val b = hello!!
        assertEquals(7, b.getInt("epoch"))
        assertEquals("android", b.getJSONObject("sdk").getString("platform"))
        assertEquals(SUPPORTED_OPS.size, b.getJSONObject("sdk").getJSONArray("ops").length())
        assertEquals(transport.seen, listOf("/api/v1/sdk/hello"))
    }

    @Test
    fun helloWidensTheAllowlistOnlyWhenSigned(): Unit = runBlocking {
        val payload = JSONObject().put("v", 1).put("kind", "allowlist").put("exp", 4102444800L)
            .put("stores", JSONObject().put("heb", JSONObject().put("hosts", JSONArray().put("api.heb.com").put("evil.io"))))
            .toString()
        val good = TestSigner.sign(payload)
        val client = MealioClient(config(), FakeHost(), FakeTransport { _, _, _ -> ok(JSONObject().put("ok", true).put("allowlist", good.toJson())) })
        client.hello()
        assertTrue("api.heb.com" in client.allowlist.hostsFor("heb")!!.hosts)
        assertFalse("evil.io" in client.allowlist.hostsFor("heb")!!.hosts)

        val forged = Envelope(payload.replace("api.heb.com", "www.heb.com"), good.sig, good.kid)
        val client2 = MealioClient(config(), FakeHost(), FakeTransport { _, _, _ -> ok(JSONObject().put("ok", true).put("allowlist", forged.toJson())) })
        client2.hello()
        assertEquals(listOf("heb.com"), client2.allowlist.hostsFor("heb")!!.hosts)
    }

    @Test
    fun mapsErrors(): Unit = runBlocking {
        val serverErr = FakeTransport { _, _, _ ->
            HttpResponse(503, JSONObject().put("error", JSONObject().put("code", "store_unavailable").put("message", "down")).toString())
        }
        assertEquals("store_unavailable", code { MealioClient(config(), FakeHost(), serverErr).hello() })
        assertEquals("server", code { MealioClient(config(), FakeHost(), FakeTransport { _, _, _ -> HttpResponse(500, "oops") }).hello() })
        assertEquals("network", code { MealioClient(config(), FakeHost(), FakeTransport { _, _, _ -> throw IOException("down") }).hello() })
        assertEquals("session_expired", code { MealioClient(config { throw RuntimeException("no") }, FakeHost(), serverErr).hello() })
    }

    private fun cartFlow(first: Envelope, onStep: (JSONObject) -> HttpResponse = { error("no step expected") }) =
        FakeTransport { path, _, body ->
            when {
                path.endsWith("/hello") -> ok(JSONObject().put("ok", true))
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
    fun cartSessionChoosesAndAdds(): Unit = runBlocking {
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
                path.endsWith("/hello") -> ok(JSONObject().put("ok", true))
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
        assertEquals(listOf("b", "c"), session.pending().map { it.key })
        assertEquals("p1", session.selectionFor("a")!!.productId)
        assertEquals("popular", session.needsChoice[0].options[0].badge)
        assertEquals("Sliced", session.needsChoice[0].options[0].preferences[0].label)
        assertEquals("no_results", session.unavailable[0].reason)

        assertEquals("unknown_product", code { session.choose("b", "nope") })
        assertEquals("unknown_item", code { session.choose("zzz", "p2") })
        session.choose("b", "p2", preferenceId = "sliced")
        session.skip("c")
        assertTrue(session.pending().isEmpty())

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
    }

    @Test
    fun encodesPathSegmentsLikeEncodeUriComponent() {
        assertEquals("a%20b%2Fc!'()*~", encodeUriComponent("a b/c!'()*~"))
    }
}
