package co.mealio.sdk

import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/**
 * MealioClient.warm(): the login check run before the tap, and the one-time
 * hint it hands the next prepare. Mirrors the TS "warm-up" tests in
 * packages/core/test/core.test.ts.
 */
class WarmTest {
    private val config = MealioConfig(
        publishableKey = "pk_test",
        sessionTokenProvider = { "tok" },
        baseUrl = "https://mealio.test/",
        keys = Vectors.keys,
    )
    private val recipe = Recipe("r1", emptyList())
    private val emptyCart = JSONObject().put("cartId", "c").put("store", "heb")
        .put("items", JSONArray()).put("ready", JSONArray()).put("needsChoice", JSONArray()).put("unavailable", JSONArray())

    private fun warmDone(signedIn: Any?) = JSONObject().put("job", "job_warm").put("envelope",
        TestSigner.instructions(1, listOf(doneOp("d1", JSONObject().put("store", "heb").put("signedIn", signedIn ?: JSONObject.NULL))), job = "job_warm").toJson())

    /** Serves /warm from `warm`, carts always done. Returns every carts body sent. */
    private fun setup(warm: () -> JSONObject): Pair<MealioClient, MutableList<JSONObject>> {
        val carts = mutableListOf<JSONObject>()
        val transport = FakeTransport { path, _, body ->
            when (path) {
                "/api/v1/sdk/warm" -> ok(warm())
                "/api/v1/sdk/carts" -> {
                    carts += body
                    ok(JSONObject().put("job", "job_cart").put("envelope", TestSigner.instructions(1, listOf(doneOp("d1", emptyCart)), job = "job_cart").toJson()))
                }
                else -> error("unexpected $path")
            }
        }
        return MealioClient(config, FakeHost(), transport) to carts
    }

    @Test
    fun handsASignedInWarmUpToTheNextPrepareOnce(): Unit = runBlocking {
        val (client, carts) = setup { warmDone(true) }
        client.warm()
        client.prepareCart(null, recipe)
        client.prepareCart(null, recipe)
        assertEquals("job_warm", carts[0].optString("warm"))
        assertFalse(carts[1].has("warm"))
    }

    @Test
    fun noHintWhenSignedOutOrNothingToWarm(): Unit = runBlocking {
        for (answer in listOf({ warmDone(false) }, { JSONObject().put("warm", JSONObject.NULL) })) {
            val (client, carts) = setup(answer)
            client.warm()
            client.prepareCart(null, recipe)
            assertFalse(carts[0].has("warm"))
        }
    }

    @Test
    fun noHintForAnotherStore(): Unit = runBlocking {
        val (client, carts) = setup { warmDone(true) }
        client.warm()
        client.prepareCart("walmart", recipe)
        assertFalse(carts[0].has("warm"))
    }

    @Test
    fun runsAtMostOnceEveryFewMinutesAndNeverThrows(): Unit = runBlocking {
        var calls = 0
        val (client, _) = setup { calls += 1; error("boom") }
        client.warm()
        client.warm()
        assertEquals(1, calls)
        client.clearWarm()
        client.warm()
        assertEquals(2, calls)
    }
}
