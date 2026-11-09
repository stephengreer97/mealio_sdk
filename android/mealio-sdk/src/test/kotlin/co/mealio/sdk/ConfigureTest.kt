package co.mealio.sdk

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

// 0.6 round 3: configure() again cancels the old client's jobs, and every
// client it makes shares one job queue (as Flutter does), so the new
// client's jobs never land on the page in the middle of the old one's add.
@OptIn(ExperimentalCoroutinesApi::class)
class ConfigureTest {
    @After fun tearDown() {
        MealioCart.uninstall()
        Dispatchers.resetMain()
    }

    private class Memory : SessionStore {
        var epoch = 0
        override fun epoch() = epoch
        override fun bumpEpoch() = ++epoch
        override suspend fun clearStore(hosts: StoreHosts) = Unit
        override suspend fun clearAll() = Unit
    }

    private val cart = JSONObject().put("cartId", "c").put("store", "heb")
        .put("items", JSONArray()).put("ready", JSONArray()).put("needsChoice", JSONArray()).put("unavailable", JSONArray())

    @Test
    fun configureAgainCancelsTheOldJobsAndQueuesBehindItsAdd() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        val gate = CompletableDeferred<Unit>()
        val sent = mutableListOf<String>()
        var jobs = 0
        fun transport(name: String) = FakeTransport { path, _, _ ->
            sent += "$name $path"
            jobs += 1
            val job = "job$jobs"
            val ins = if (path.endsWith("/add")) listOf(pageOpen("o", "https://www.heb.com/robots.txt"), doneOp("d", JSONObject().put("added", JSONArray())))
            else listOf(doneOp("d", cart))
            ok(JSONObject().put("job", job).put("envelope", TestSigner.instructions(1, ins, job = job).toJson()))
        }
        val oldHost = FakeHost(onOpen = { gate.await(); PageLoad(true, it) })
        val released = mutableListOf<String>()
        fun config() = MealioConfig("pk", { "tok" }, baseUrl = "https://mealio.test", keys = Vectors.keys)
        val a = MealioCart.install(oldHost, Memory(), { released += "old" }) { q -> MealioClient(config(), oldHost, transport("A"), q) }
        val adding = async { a.addToCart("c", emptyList()) }
        runCurrent()
        val waiting = async { try { a.prepareCart(null, listOf(Recipe("r", listOf(RecipeIngredient("milk")))), null, CancelToken()); null } catch (e: MealioException) { e.code } }
        runCurrent()
        val newHost = FakeHost()
        MealioCart.install(newHost, Memory(), { released += "new" }) { q -> MealioClient(config(), newHost, transport("B"), q) }
        val fresh = async { MealioCart.prepareCart(null, Recipe("r", listOf(RecipeIngredient("milk")))) }
        runCurrent()
        assertEquals("the old client's waiting prepare is cancelled", "cancelled", waiting.await())
        assertEquals("the new client waits for the old add", listOf("A /api/v1/sdk/carts/c/add"), sent)
        assertTrue(released.isEmpty())
        gate.complete(Unit)
        adding.await()
        fresh.await()
        runCurrent()
        assertEquals(listOf("A /api/v1/sdk/carts/c/add", "B /api/v1/sdk/carts"), sent)
        assertEquals("the old page is let go after its add", listOf("old"), released)
    }

    @Test
    fun theTestKitIsNotPartOfTheSdkArtifact() {
        // 0.6 round 4: FakeMealio and its test key live in co.mealio:mealio-sdk-testing,
        // a testImplementation dependency, so a release app cannot carry them.
        for (name in listOf("co.mealio.sdk.testing.FakeMealio", "co.mealio.sdk.testing.FakeMealioKt", "co.mealio.sdk.testing.FakeScript")) {
            try {
                Class.forName(name)
                org.junit.Assert.fail("$name is in mealio-sdk")
            } catch (e: ClassNotFoundException) {
                // expected
            }
        }
    }
}
