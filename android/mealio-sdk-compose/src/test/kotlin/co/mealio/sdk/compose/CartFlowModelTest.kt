package co.mealio.sdk.compose

import co.mealio.sdk.AddResult
import co.mealio.sdk.CancelToken
import co.mealio.sdk.CartSession
import co.mealio.sdk.Envelope
import co.mealio.sdk.FetchRequest
import co.mealio.sdk.FetchResponse
import co.mealio.sdk.Host
import co.mealio.sdk.HttpResponse
import co.mealio.sdk.HttpTransport
import co.mealio.sdk.LoginOutcome
import co.mealio.sdk.LoginRequest
import co.mealio.sdk.LoginResult
import co.mealio.sdk.Matcher
import co.mealio.sdk.MealioClient
import co.mealio.sdk.MealioConfig
import co.mealio.sdk.MealioEvent
import co.mealio.sdk.MealioUser
import co.mealio.sdk.PageLoad
import co.mealio.sdk.Recipe
import co.mealio.sdk.RecipeIngredient
import co.mealio.sdk.ScriptRun
import co.mealio.sdk.StepListener
import co.mealio.sdk.StoreInfo
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters
import org.bouncycastle.crypto.signers.Ed25519Signer
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

// The drop-in's flow, outside composition. Mirrors the flow tests in
// packages/react-native/test/flow.test.tsx where they apply, plus Android's
// activity recreation (the audit's finding 1).
@OptIn(ExperimentalCoroutinesApi::class)
class CartFlowModelTest {

    // ── a signed fake server ────────────────────────────────────────

    private object Signer {
        private val priv = Ed25519PrivateKeyParameters(ByteArray(32) { 7 }, 0)
        val keys = mapOf("ktest" to Base64.getEncoder().encodeToString(priv.generatePublicKey().encoded))

        fun envelope(job: String, seq: Int, instructions: List<JSONObject>): JSONObject {
            val payload = JSONObject().put("v", 1).put("kind", "instructions").put("job", job).put("seq", seq)
                .put("exp", 4102444800L).put("store", "heb").put("instructions", JSONArray(instructions)).toString()
            val s = Ed25519Signer()
            s.init(true, priv)
            val b = payload.toByteArray(Charsets.UTF_8)
            s.update(b, 0, b.size)
            return JSONObject().put("payload", payload).put("sig", Base64.getEncoder().encodeToString(s.generateSignature())).put("kid", "ktest")
        }
    }

    private fun done(result: JSONObject) = JSONObject().put("op", "done").put("id", "d").put("result", result)
    private fun open(id: String = "o") = JSONObject().put("op", "page_open").put("id", id).put("url", "https://www.heb.com/robots.txt").put("timeoutMs", 1000)
    private val login = JSONObject().put("op", "show_login").put("id", "l").put("url", "https://www.heb.com/login")
        .put("title", "Sign in").put("doneWhen", JSONArray()).put("timeoutMs", 1000)

    private fun cart(store: String = "heb", picked: String = "p1") = JSONObject().put("cartId", "c").put("store", store)
        .put("ready", JSONArray()).put("needsChoice", JSONArray()).put("unavailable", JSONArray())
        .put("items", JSONArray()
            .put(item("milk", picked))
            .put(item("eggs", "e1")))

    private fun item(key: String, selected: String) = JSONObject().put("key", key).put("ingredient", key).put("quantity", 1)
        .put("status", "remembered").put("selectedId", selected).put("remembered", JSONObject.NULL)
        .put("options", JSONArray()
            .put(JSONObject().put("id", "p1").put("name", "Milk").put("unitPrice", 3))
            .put(JSONObject().put("id", "p2").put("name", "Oat milk").put("unitPrice", 4))
            .put(JSONObject().put("id", "e1").put("name", "Eggs").put("unitPrice", 2)))

    private val added = JSONObject().put("cartId", "c").put("store", "heb")
        .put("added", JSONArray().put(JSONObject().put("key", "milk").put("productId", "p1").put("name", "Milk").put("quantity", 1)))
        .put("skipped", JSONArray()).put("failed", JSONArray())

    private class FakeLogin : FlowLogin {
        var activeNow = false
        override val active: Boolean get() = activeNow
        var cancels = 0
        var attached = 0
        var detached = 0
        override fun cancel() { cancels += 1; activeNow = false }
        override fun goBack(): Boolean = false
        override fun attachSheet(): () -> Unit { attached += 1; return { detached += 1 } }
    }

    /** Everything one flow test needs. */
    private inner class Harness(val test: TestScope) {
        val sent = mutableListOf<String>()
        val bodies = mutableListOf<JSONObject>()
        val opened = mutableListOf<String>()
        var openGate: CompletableDeferred<Unit>? = null
        var signIns = 0
        var answer: (path: String, body: JSONObject) -> HttpResponse = { p, _ -> start(p, done(cart())) }
        var storesAnswer: () -> List<StoreInfo> = { listOf(StoreInfo("heb", "H-E-B", "device")) }
        var storeCalls = 0
        private var jobs = 0

        fun start(path: String, vararg ins: JSONObject): HttpResponse {
            jobs += 1
            val job = "job$jobs"
            return HttpResponse(200, JSONObject().put("job", job).put("envelope", Signer.envelope(job, 1, ins.toList())).toString())
        }

        val host = object : Host {
            override suspend fun openPage(store: String, url: String, timeoutMs: Long): PageLoad {
                opened += url
                openGate?.await()
                return PageLoad(true, url)
            }
            override suspend fun runScript(store: String, guard: String, script: String, until: List<Matcher>, timeoutMs: Long) = ScriptRun(emptyList(), false)
            override suspend fun showLogin(request: LoginRequest): LoginResult { signIns += 1; return LoginResult(LoginOutcome.SIGNED_IN, emptyList()) }
            override suspend fun fetch(store: String, request: FetchRequest, timeoutMs: Long, maxBytes: Int) = FetchResponse(true, 200, body = "")
        }
        val transport = object : HttpTransport {
            override suspend fun post(url: String, headers: Map<String, String>, body: String): HttpResponse {
                val path = url.removePrefix("https://mealio.test").removePrefix("/api/v1/sdk")
                sent += path
                bodies += JSONObject(body)
                return answer(path, JSONObject(body))
            }
        }
        val client = MealioClient(MealioConfig("pk", { "tok" }, baseUrl = "https://mealio.test", keys = Signer.keys), host, transport)
        var prepareThrows: Throwable? = null
        val backend = object : FlowBackend {
            override suspend fun prepareCart(store: String?, recipes: List<Recipe>, cancel: CancelToken, onStep: StepListener): CartSession {
                prepareThrows?.let { throw it }
                return client.prepareCart(store, recipes, null, cancel, onStep)
            }
            override suspend fun stores(): List<StoreInfo> { storeCalls += 1; return storesAnswer() }
        }
        val login = FakeLogin()
        val events = mutableListOf<MealioEvent>()
        val closed = mutableListOf<AddResult?>()
        val addedResults = mutableListOf<AddResult>()
        val errors = mutableListOf<Exception>()
        val ui = MealioUi(onEvent = { events += it })
        val dispatcher = StandardTestDispatcher(test.testScheduler)

        fun model(store: String? = "heb", user: MealioUser = MealioUser(), now: () -> MealioUser = { user }, flowLogin: FlowLogin = login) = CartFlowModel(
            listOf(Recipe("r", listOf(RecipeIngredient("milk")))), store, ui,
            FlowCallbacks({ closed += it }, { addedResults += it }, { errors += it }),
            backend, flowLogin, dispatcher, user, now,
        ).also { it.attach() }
    }

    // ── 0.6.1: a different store from the sign-in step ─────────────

    @Test
    fun aDifferentStoreFromSignInStopsTheCartAndShowsTheStores() = runTest {
        val h = Harness(this)
        h.storesAnswer = { listOf(StoreInfo("heb", "H-E-B", "device"), StoreInfo("aldi", "ALDI", "device")) }
        // The HEB cart waits on its page, as one waiting for a sign-in does.
        h.openGate = CompletableDeferred()
        h.answer = { p, b -> if (b.optString("store") == "aldi") h.start(p, done(cart("aldi"))) else h.start(p, open(), done(cart())) }
        val m = h.model(store = "heb")
        runCurrent()
        assertEquals(Phase.LOADING, m.phase)
        h.login.activeNow = true
        m.storeFromSignIn()
        assertEquals(1, h.login.cancels)
        assertEquals(Phase.STORES, m.phase)
        advanceUntilIdle()
        assertEquals(listOf("heb", "aldi"), m.stores?.map { it.id })
        m.pickStore("aldi")
        // The HEB page answers late: that cart was stopped and reports nothing.
        h.openGate!!.complete(Unit)
        advanceUntilIdle()
        assertEquals(Phase.LIST, m.phase)
        assertEquals("aldi", m.store)
        assertEquals(listOf("heb", "aldi"), h.bodies.filter { it.has("recipes") }.map { it.optString("store") })
        assertTrue(h.errors.isEmpty())
        m.close()
    }

    @Test
    fun aDifferentStoreFromSignInDoesNothingWhileAdding() = runTest {
        val h = Harness(this)
        h.answer = { p, _ -> if (p.endsWith("/add")) h.start(p, open(), done(added)) else h.start(p, done(cart())) }
        val m = h.model()
        advanceUntilIdle()
        h.openGate = CompletableDeferred()
        m.add()
        runCurrent()
        h.login.activeNow = true
        m.storeFromSignIn()
        assertEquals(Phase.ADDING, m.phase)
        assertEquals(0, h.login.cancels)
        h.openGate!!.complete(Unit)
        advanceUntilIdle()
        assertEquals(Phase.DONE, m.phase)
        m.close()
    }

    // ── recreation (audit finding 1) ────────────────────────────────

    @Test
    fun aRotationMidAddKeepsTheAddAndDoneKeepsItsResult() = runTest {
        val h = Harness(this)
        h.answer = { p, _ -> if (p.endsWith("/add")) h.start(p, open(), done(added)) else h.start(p, done(cart())) }
        val m = FlowModels.obtain("rot", openedNow = true) { h.model() }!!
        advanceUntilIdle()
        assertEquals(Phase.LIST, m.phase)
        h.openGate = CompletableDeferred()
        m.add()
        runCurrent()
        // The activity is recreated: the composition goes, the model stays.
        m.detach()
        val again = FlowModels.obtain("rot", openedNow = false) { error("a new model would restart the flow") }
        assertSame(m, again)
        h.openGate!!.complete(Unit)
        // The new screen comes within a frame or two, well inside RECLAIM_MS.
        runCurrent()
        // Nothing is said to the partner while no screen shows it ...
        assertTrue(h.addedResults.isEmpty())
        assertEquals(Phase.DONE, m.phase)
        // ... and it is once the new screen attaches.
        m.attach()
        assertEquals(1, h.addedResults.size)
        assertNotNull(m.result)
        assertEquals(1, h.sent.count { it.endsWith("/add") })
        assertEquals(1, h.sent.count { it.endsWith("/carts") })
        m.close()
        assertSame(m.result, h.closed.single())
        assertNull(FlowModels.obtain("rot", openedNow = false) { error("closed") })
    }

    @Test
    fun aSignInInProgressSurvivesRecreation() = runTest {
        val h = Harness(this)
        val m = h.model()
        assertEquals(1, h.login.attached)
        // Recreation detaches the composition, not the sheet: the sign-in is not cancelled.
        m.detach()
        m.attach()
        assertEquals(0, h.login.detached)
        assertEquals(0, h.login.cancels)
        advanceUntilIdle()
        m.close()
        assertEquals(1, h.login.detached)
    }

    @Test
    fun afterProcessDeathNoNewCartStarts() = runTest {
        var made = 0
        // A saved id with no model: the process died. Nothing is created.
        assertNull(FlowModels.obtain("restored-${System.nanoTime()}", openedNow = false) { made += 1; Harness(this).model() })
        assertEquals(0, made)
    }

    @Test
    fun unmountingMidLoadReportsNothing() = runTest {
        val h = Harness(this)
        h.openGate = CompletableDeferred()
        h.answer = { p, _ -> h.start(p, open(), login, done(cart())) }
        val m = h.model()
        runCurrent()
        m.dispose()
        h.openGate!!.complete(Unit)
        advanceUntilIdle()
        assertEquals(0, h.signIns)
        assertTrue(h.closed.isEmpty() && h.errors.isEmpty() && h.addedResults.isEmpty())
        assertTrue(h.events.none { it is MealioEvent.ListShown || it is MealioEvent.SheetClosed })
    }

    // ── cancelling (audit finding 2) ────────────────────────────────

    @Test
    fun aPartnersCancellationExceptionShowsAnErrorNotASpinner() = runTest {
        val h = Harness(this)
        h.prepareThrows = CancellationException("partner timeout")
        val m = h.model()
        advanceUntilIdle()
        assertEquals(Phase.ERROR, m.phase)
        assertEquals(1, h.errors.size)
    }

    @Test
    fun stopsTheJobNothingMoreIsSentAndSignInNeverShows() = runTest {
        val h = Harness(this)
        h.openGate = CompletableDeferred()
        h.answer = { p, _ -> h.start(p, open(), login, done(cart())) }
        val m = h.model()
        runCurrent()
        assertTrue(m.close())
        h.openGate!!.complete(Unit)
        advanceUntilIdle()
        assertEquals(0, h.signIns)
        assertEquals(listOf("/carts"), h.sent)
        assertEquals(listOf<AddResult?>(null), h.closed)
        assertTrue(h.errors.isEmpty())
    }

    // ── no close while adding (audit finding 4) ─────────────────────

    @Test
    fun cannotBeClosedOnceTappedAndReportsTheAddWhenItEnds() = runTest {
        val h = Harness(this)
        h.answer = { p, _ -> if (p.endsWith("/add")) h.start(p, open(), done(added)) else h.start(p, done(cart())) }
        val m = h.model()
        advanceUntilIdle()
        h.openGate = CompletableDeferred()
        m.add()
        runCurrent()
        // X, back and the system back all land in close() or back().
        assertFalse(m.close())
        m.back()
        assertEquals(Phase.ADDING, m.phase)
        assertTrue(h.closed.isEmpty())
        // A sign-in the add asked for can still be dismissed.
        h.login.activeNow = true
        assertFalse(m.close())
        assertEquals(1 + 0, h.login.cancels)
        h.openGate!!.complete(Unit)
        advanceUntilIdle()
        assertEquals(Phase.DONE, m.phase)
        assertEquals(1, h.addedResults.size)
        assertTrue(m.close())
    }

    // ── double tap (audit finding 5) ────────────────────────────────

    @Test
    fun twoTapsBeforeARenderAddOnce() = runTest {
        val h = Harness(this)
        h.answer = { p, _ -> if (p.endsWith("/add")) h.start(p, done(added)) else h.start(p, done(cart())) }
        val m = h.model()
        advanceUntilIdle()
        m.add()
        m.add()
        advanceUntilIdle()
        assertEquals(1, h.sent.count { it.endsWith("/add") })
        assertEquals(1, h.events.count { it is MealioEvent.AddStarted })
    }

    // ── the rest of 0.6 ─────────────────────────────────────────────

    @Test
    fun aFailedAddSaysToCheckTheCartAndTryAgainKeepsThePicks() = runTest {
        val h = Harness(this)
        h.answer = { p, _ ->
            if (p.endsWith("/add")) HttpResponse(500, JSONObject().put("error", JSONObject().put("code", "store_unavailable").put("message", "down")).toString())
            else h.start(p, done(cart()))
        }
        val m = h.model()
        advanceUntilIdle()
        m.cart!!.select("milk", "p2")
        m.cart!!.deselect("eggs")
        m.add()
        advanceUntilIdle()
        assertEquals(Phase.ERROR, m.phase)
        assertNotNull(m.failedAdd)
        m.retry()
        advanceUntilIdle()
        assertEquals(Phase.LIST, m.phase)
        assertNull(m.failedAdd)
        assertEquals("p2", m.cart!!.selectedId("milk"))
        assertFalse(m.cart!!.isSelected("eggs"))
    }

    @Test
    fun addIsOffWhileASearchRuns() = runTest {
        val h = Harness(this)
        val m = h.model()
        advanceUntilIdle()
        h.openGate = CompletableDeferred()
        h.answer = { p, _ -> h.start(p, open(), done(JSONObject().put("key", "milk").put("options", JSONArray()))) }
        val c = m.cart!!
        val search = launch(h.dispatcher) { c.search("milk", "oat milk") }
        runCurrent()
        assertTrue(c.searching)
        m.add()
        assertEquals(Phase.LIST, m.phase)
        h.openGate!!.complete(Unit)
        search.join()
        assertFalse(c.searching)
    }

    @Test
    fun closingCancelsASearch() = runTest {
        val h = Harness(this)
        val m = h.model()
        advanceUntilIdle()
        h.openGate = CompletableDeferred()
        h.answer = { p, _ -> h.start(p, open(), open("o2"), done(JSONObject().put("key", "milk").put("options", JSONArray()))) }
        val c = m.cart!!
        var outcome = ""
        val job = launch(h.dispatcher) {
            outcome = try { c.search("milk", "oat"); "found" } catch (e: co.mealio.sdk.MealioException) { e.code }
        }
        runCurrent()
        m.close()
        h.openGate!!.complete(Unit)
        job.join()
        assertEquals("cancelled", outcome)
        assertEquals(1, h.opened.size)
    }

    @Test
    fun tryAgainUsesTheStoreThePartnerPassesNow() = runTest {
        val h = Harness(this)
        h.answer = { p, _ -> HttpResponse(503, JSONObject().put("error", JSONObject().put("code", "store_unavailable").put("message", "down")).toString()) }
        val m = h.model("heb")
        advanceUntilIdle()
        assertEquals(Phase.ERROR, m.phase)
        m.propStoreChanged("aldi")
        h.answer = { p, _ -> h.start(p, done(cart("aldi"))) }
        m.retry()
        advanceUntilIdle()
        assertEquals("aldi", h.bodies.last().getString("store"))
        assertEquals(Phase.LIST, m.phase)
    }

    @Test
    fun aStoreListThatFailedToLoadIsAskedForAgain() = runTest {
        val h = Harness(this)
        val m = h.model()
        advanceUntilIdle()
        h.storesAnswer = { throw co.mealio.sdk.MealioException("network", "down") }
        m.openStores(Phase.LIST)
        advanceUntilIdle()
        assertEquals(emptyList<StoreInfo>(), m.stores)
        m.backToList()
        h.storesAnswer = { listOf(StoreInfo("heb", "H-E-B", "device")) }
        m.openStores(Phase.LIST)
        advanceUntilIdle()
        assertEquals(2, h.storeCalls)
        assertEquals(1, m.stores!!.size)
    }

    @Test
    fun callsTheLatestOnAdded() = runTest {
        val h = Harness(this)
        h.answer = { p, _ -> if (p.endsWith("/add")) h.start(p, done(added)) else h.start(p, done(cart())) }
        val m = h.model()
        advanceUntilIdle()
        val latest = mutableListOf<AddResult>()
        m.callbacks = FlowCallbacks({}, { latest += it }, {})
        m.add()
        advanceUntilIdle()
        assertEquals(1, latest.size)
        assertTrue(h.addedResults.isEmpty())
    }

    @Test
    fun aNewUserClosesTheOpenSheetButAnAddFinishesFirst() = runTest {
        val h = Harness(this)
        h.answer = { p, _ -> if (p.endsWith("/add")) h.start(p, open(), done(added)) else h.start(p, done(cart())) }
        val m = h.model(user = MealioUser(true, "a"))
        advanceUntilIdle()
        h.openGate = CompletableDeferred()
        m.add()
        runCurrent()
        m.checkUser(MealioUser(true, "b"))
        assertTrue(h.closed.isEmpty())
        h.openGate!!.complete(Unit)
        advanceUntilIdle()
        assertEquals(1, h.closed.size)
        assertTrue(m.finished)
    }

    // ── the button ──────────────────────────────────────────────────

    @Test
    fun withNobodySignedInTheButtonAsksForSignInOrIsOffWithoutACallback() {
        assertEquals(ButtonTap.OPEN, buttonTap(signedIn = true, enabled = true, onSignInRequired = null))
        assertEquals(ButtonTap.SIGN_IN, buttonTap(signedIn = false, enabled = true, onSignInRequired = {}))
        assertEquals(ButtonTap.OFF, buttonTap(signedIn = false, enabled = true, onSignInRequired = null))
        assertEquals(ButtonTap.OFF, buttonTap(signedIn = true, enabled = false, onSignInRequired = {}))
    }

    // ── 0.6 round 2 ─────────────────────────────────────────────────

    @Test
    fun aPrepareCancelledFromOutsideLoadsAgainAndShowsNoError() = runTest {
        val h = Harness(this)
        h.openGate = CompletableDeferred()
        h.answer = { p, _ -> h.start(p, open(), done(cart())) }
        val m = h.model()
        runCurrent()
        // signOutOfStore / cancelJobs while the sheet is open.
        h.client.cancelJobs()
        h.openGate!!.complete(Unit)
        advanceUntilIdle()
        assertEquals(Phase.LIST, m.phase)
        assertTrue(h.errors.isEmpty())
        assertTrue(h.events.none { it is MealioEvent.Error })
        assertEquals(2, h.sent.count { it.endsWith("/carts") })
        assertFalse(m.finished)
    }

    @Test
    fun aPrepareCancelledByAUserChangeClosesQuietly() = runTest {
        val h = Harness(this)
        h.client.setUser("a")
        h.openGate = CompletableDeferred()
        h.answer = { p, _ -> h.start(p, open(), done(cart())) }
        var now = MealioUser(true, "a")
        val m = h.model(user = MealioUser(true, "a"), now = { now })
        runCurrent()
        // MealioCart.setUser("b"): the client side at once, the composable's checkUser a frame later.
        now = MealioUser(true, "b")
        h.client.setUser("b")
        h.openGate!!.complete(Unit)
        advanceUntilIdle()
        assertTrue(h.errors.isEmpty())
        assertTrue(h.events.none { it is MealioEvent.Error })
        assertEquals(listOf<AddResult?>(null), h.closed)
        assertTrue(m.finished)
        assertEquals(1, h.sent.count { it.endsWith("/carts") })
    }

    @Test
    fun aModelNoRecreatedScreenTakesBackIsDisposedAndLetsGoOfTheSheet() = runTest {
        val h = Harness(this)
        val before = FlowModels.size()
        val m = FlowModels.obtain("leak-${System.nanoTime()}", openedNow = true) { h.model(flowLogin = InlineFlowLogin) }!!
        advanceUntilIdle()
        assertTrue(co.mealio.sdk.MealioInlineLogin.hasSheet)
        // Rotation; the new activity never shows the sheet again.
        m.detach()
        testScheduler.advanceTimeBy(RECLAIM_MS - 1)
        runCurrent()
        assertFalse(m.finished)
        testScheduler.advanceTimeBy(2)
        runCurrent()
        assertTrue(m.finished)
        assertEquals(before, FlowModels.size())
        assertFalse(co.mealio.sdk.MealioInlineLogin.hasSheet)
        assertTrue(h.closed.isEmpty() && h.errors.isEmpty())
    }

    @Test
    fun aModelTakenBackInTimeIsKept() = runTest {
        val h = Harness(this)
        val m = h.model()
        advanceUntilIdle()
        m.detach()
        testScheduler.advanceTimeBy(RECLAIM_MS / 2)
        m.attach()
        advanceUntilIdle()
        assertFalse(m.finished)
        assertEquals(0, h.login.detached)
    }

    @Test
    fun hiddenByThePartnerDuringAnAddItFinishesAndReportsOnAddedAndOnClose() = runTest {
        val h = Harness(this)
        h.answer = { p, _ -> if (p.endsWith("/add")) h.start(p, open(), done(added)) else h.start(p, done(cart())) }
        val m = h.model()
        advanceUntilIdle()
        h.openGate = CompletableDeferred()
        m.add()
        runCurrent()
        m.hidden = true
        h.openGate!!.complete(Unit)
        advanceUntilIdle()
        assertEquals(1, h.addedResults.size)
        assertSame(h.addedResults.single(), h.closed.single())
        assertTrue(m.finished)
    }

    @Test
    fun hiddenDuringAnAddThatFailsReportsOnErrorThenOnClose() = runTest {
        val h = Harness(this)
        h.answer = { p, _ ->
            if (p.endsWith("/add")) HttpResponse(500, JSONObject().put("error", JSONObject().put("code", "store_unavailable").put("message", "down")).toString())
            else h.start(p, done(cart()))
        }
        val m = h.model()
        advanceUntilIdle()
        m.hidden = true
        m.add()
        advanceUntilIdle()
        assertEquals(1, h.errors.size)
        assertEquals(listOf<AddResult?>(null), h.closed)
        assertTrue(m.finished)
    }

    @Test
    fun tryAgainAfterAFailedAddKeepsAProductFoundWithSearch() = runTest {
        val h = Harness(this)
        h.answer = { p, _ ->
            when {
                p.endsWith("/add") -> HttpResponse(500, JSONObject().put("error", JSONObject().put("code", "store_unavailable").put("message", "down")).toString())
                p.endsWith("/search") -> h.start(p, done(JSONObject().put("key", "milk").put("options", JSONArray().put(JSONObject().put("id", "p9").put("name", "Goat milk").put("unitPrice", 6)))))
                else -> h.start(p, done(cart()))
            }
        }
        val m = h.model()
        advanceUntilIdle()
        m.cart!!.search("milk", "goat milk")
        m.cart!!.select("milk", "p9")
        m.cart!!.setQuantity("milk", 2)
        m.add()
        advanceUntilIdle()
        m.retry()
        advanceUntilIdle()
        assertEquals(Phase.LIST, m.phase)
        assertEquals("p9", m.cart!!.selectedId("milk"))
        assertEquals(2, m.cart!!.quantity("milk"))
    }

    // ── 0.6 round 3 ─────────────────────────────────────────────────

    @Test
    fun hiddenMidAddThenRotatedWithNoScreenTakingItBackStillReportsTheAdd() = runTest {
        val h = Harness(this)
        h.answer = { p, _ -> if (p.endsWith("/add")) h.start(p, open(), done(added)) else h.start(p, done(cart())) }
        val m = FlowModels.obtain("hid-rot-${System.nanoTime()}", openedNow = true) { h.model() }!!
        advanceUntilIdle()
        h.openGate = CompletableDeferred()
        m.add()
        runCurrent()
        // The partner sets visible = false mid-add, then the activity is recreated
        // and the new one does not show the sheet: nothing attaches again.
        m.hidden = true
        m.detach()
        testScheduler.advanceTimeBy(RECLAIM_MS + 1)
        runCurrent()
        assertFalse("not disposed while adding", m.finished)
        h.openGate!!.complete(Unit)
        advanceUntilIdle()
        assertEquals(1, h.sent.count { it.endsWith("/add") })
        assertEquals(1, h.addedResults.size)
        assertSame(h.addedResults.single(), h.closed.single())
        assertTrue(m.finished)
    }

    @Test
    fun anAddLeftWithNoScreenReportsAndThenTheModelGoes() = runTest {
        val h = Harness(this)
        h.answer = { p, _ -> if (p.endsWith("/add")) h.start(p, open(), done(added)) else h.start(p, done(cart())) }
        val before = FlowModels.size()
        val m = FlowModels.obtain("orphan-${System.nanoTime()}", openedNow = true) { h.model() }!!
        advanceUntilIdle()
        h.openGate = CompletableDeferred()
        m.add()
        runCurrent()
        m.detach()
        testScheduler.advanceTimeBy(RECLAIM_MS + 1)
        runCurrent()
        assertFalse(m.finished)
        h.openGate!!.complete(Unit)
        advanceUntilIdle()
        assertEquals(1, h.addedResults.size)
        assertTrue(m.finished)
        assertEquals(before, FlowModels.size())
    }

    // ── 0.6 round 4 ─────────────────────────────────────────────────

    @Test
    fun anAddThatEndsInsideTheReclaimWindowWithNoScreenStillReportsOnAdded() = runTest {
        val h = Harness(this)
        h.answer = { p, _ -> if (p.endsWith("/add")) h.start(p, open(), done(added)) else h.start(p, done(cart())) }
        val before = FlowModels.size()
        val m = FlowModels.obtain("orphan-early-${System.nanoTime()}", openedNow = true) { h.model() }!!
        advanceUntilIdle()
        h.openGate = CompletableDeferred()
        m.add()
        runCurrent()
        // Recreated; the add ends a moment later, well inside RECLAIM_MS.
        m.detach()
        h.openGate!!.complete(Unit)
        runCurrent()
        assertEquals(Phase.DONE, m.phase)
        assertTrue("queued for a screen that may come back", h.addedResults.isEmpty())
        // No screen takes it back.
        testScheduler.advanceTimeBy(RECLAIM_MS + 1)
        runCurrent()
        assertEquals(1, h.addedResults.size)
        assertTrue(m.finished)
        assertEquals(before, FlowModels.size())
    }

    @Test
    fun anOutsideCancelDuringRestorePicksLoadsAgain() = runTest {
        val h = Harness(this)
        var searches = 0
        h.answer = { p, _ ->
            when {
                p.endsWith("/add") -> HttpResponse(500, JSONObject().put("error", JSONObject().put("code", "store_unavailable").put("message", "down")).toString())
                p.endsWith("/search") -> {
                    searches += 1
                    val r = done(JSONObject().put("key", "milk").put("options", JSONArray().put(JSONObject().put("id", "p9").put("name", "Goat milk").put("unitPrice", 6))))
                    // The first search on a new cart waits at the page.
                    if (searches == 2) h.start(p, open("s"), r) else h.start(p, r)
                }
                else -> h.start(p, done(cart()))
            }
        }
        val m = h.model()
        advanceUntilIdle()
        m.cart!!.search("milk", "goat milk")
        m.cart!!.select("milk", "p9")
        m.add()
        advanceUntilIdle()
        val first = m.cart
        h.openGate = CompletableDeferred()
        m.retry()
        runCurrent()
        assertEquals(2, searches)
        // A store sign-out, cancelJobs: not this sheet.
        val gate = h.openGate!!
        h.openGate = null
        h.client.cancelJobs()
        gate.complete(Unit)
        advanceUntilIdle()
        assertEquals(Phase.LIST, m.phase)
        assertTrue("loaded again", h.sent.count { it.endsWith("/carts") } == 3)
        assertEquals(3, searches)
        assertEquals("p9", m.cart!!.selectedId("milk"))
        assertTrue(m.cart !== first)
        // Only the failed add reported an error; the cancel did not.
        assertEquals(listOf("store_unavailable"), h.errors.map { (it as co.mealio.sdk.MealioException).code })
    }

    /** A prepare that waits at the page, and a cancel from outside for each one. */
    private fun TestScope.cancelFromOutside(h: Harness) {
        runCurrent()
        val gate = h.openGate!!
        h.openGate = CompletableDeferred()
        h.client.cancelJobs()
        gate.complete(Unit)
        runCurrent()
    }

    @Test
    fun aFourthOutsideCancelInARowShowsTryAgainInsteadOfClosing() = runTest {
        val h = Harness(this)
        h.openGate = CompletableDeferred()
        h.answer = { p, _ -> h.start(p, open(), done(cart())) }
        val m = h.model()
        repeat(3) { cancelFromOutside(h) }
        assertEquals(Phase.LOADING, m.phase)
        cancelFromOutside(h)
        assertEquals(Phase.ERROR, m.phase)
        assertEquals("Something went wrong.", m.error!!.message)
        assertFalse(m.finished)
        assertTrue(h.closed.isEmpty())
        assertEquals(4, h.sent.count { it.endsWith("/carts") })
        // Try again starts the count over: three more outside cancels load again.
        m.retry()
        repeat(3) { cancelFromOutside(h) }
        assertEquals(Phase.LOADING, m.phase)
        h.openGate!!.complete(Unit)
        advanceUntilIdle()
        assertEquals(Phase.LIST, m.phase)
    }

    @Test
    fun pickingAStoreStartsTheRestartCountOver() = runTest {
        val h = Harness(this)
        h.openGate = CompletableDeferred()
        h.answer = { p, _ -> h.start(p, open(), done(cart())) }
        val m = h.model()
        repeat(3) { cancelFromOutside(h) }
        m.pickStore("heb")
        repeat(3) { cancelFromOutside(h) }
        assertEquals(Phase.LOADING, m.phase)
        cancelFromOutside(h)
        assertEquals(Phase.ERROR, m.phase)
    }

    @Test
    fun closingCancelsThePrepareWithReasonClosed() = runTest {
        val h = Harness(this)
        h.openGate = CompletableDeferred()
        h.answer = { p, _ -> h.start(p, open(), done(cart())) }
        var seen: CancelToken? = null
        val inner = h.backend
        val m = CartFlowModel(
            listOf(Recipe("r", listOf(RecipeIngredient("milk")))), "heb", h.ui, FlowCallbacks({}, {}, {}),
            object : FlowBackend by inner {
                override suspend fun prepareCart(store: String?, recipes: List<Recipe>, cancel: CancelToken, onStep: StepListener): CartSession {
                    seen = cancel
                    return inner.prepareCart(store, recipes, cancel, onStep)
                }
            },
            h.login, h.dispatcher, MealioUser(), { MealioUser() },
        ).also { it.attach() }
        runCurrent()
        m.close()
        assertEquals(co.mealio.sdk.CancelReason.CLOSED, seen!!.reason)
    }

    @Test
    fun tryAgainAfterAFailedAddSearchesAgainOnTheNewCart() = runTest {
        val h = Harness(this)
        var searches = 0
        h.answer = { p, _ ->
            when {
                p.endsWith("/add") -> HttpResponse(500, JSONObject().put("error", JSONObject().put("code", "store_unavailable").put("message", "down")).toString())
                p.endsWith("/search") -> {
                    searches += 1
                    // The new cart's search does not offer the goat milk.
                    val id = if (searches == 1) "p9" else "p8"
                    h.start(p, done(JSONObject().put("key", "milk").put("options", JSONArray().put(JSONObject().put("id", id).put("name", "Goat milk").put("unitPrice", 6)))))
                }
                else -> h.start(p, done(cart()))
            }
        }
        val m = h.model()
        advanceUntilIdle()
        m.cart!!.search("milk", "goat milk")
        m.cart!!.select("milk", "p9")
        m.add()
        advanceUntilIdle()
        m.retry()
        advanceUntilIdle()
        assertEquals(Phase.LIST, m.phase)
        assertEquals(2, searches)
        assertEquals("goat milk", h.bodies.last { it.has("query") }.getString("query"))
        assertEquals("p1", m.cart!!.selectedId("milk"))
    }
}
