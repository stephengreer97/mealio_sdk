package co.mealio.sdk

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.withContext
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.yield
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

// 0.6: one job at a time, cancelling, users, bounded waits, and the cart fixes.
// Mirrors packages/core/test/jobs.test.ts; the test names follow its `it` lines.
@OptIn(ExperimentalCoroutinesApi::class)
class JobsTest {
    private val cartJson = JSONObject().put("cartId", "c").put("store", "heb")
        .put("items", JSONArray()).put("ready", JSONArray()).put("needsChoice", JSONArray()).put("unavailable", JSONArray())
    private val recipe = Recipe("r", listOf(RecipeIngredient("milk")))

    private fun open(id: String) = pageOpen(id, "https://www.heb.com/robots.txt")
    private val login = showLoginOp("l", "https://www.heb.com/login")

    /** A host whose every call can be replaced. */
    private open class Host0 : Host {
        val calls = mutableListOf<String>()
        override var pagesLost = 0
        open suspend fun open(url: String): PageLoad = PageLoad(ok = true, finalUrl = url)
        open suspend fun script(): ScriptRun = ScriptRun(emptyList(), timedOut = false)
        open suspend fun signIn(r: LoginRequest): LoginResult = LoginResult(LoginOutcome.SIGNED_IN, emptyList())
        override suspend fun openPage(store: String, url: String, timeoutMs: Long): PageLoad { calls += "open $url"; return open(url) }
        override suspend fun runScript(store: String, guard: String, script: String, until: List<Matcher>, timeoutMs: Long): ScriptRun { calls += "script"; return script() }
        override suspend fun showLogin(request: LoginRequest): LoginResult { calls += "login"; return signIn(request) }
        override suspend fun fetch(store: String, request: FetchRequest, timeoutMs: Long, maxBytes: Int) = FetchResponse(ok = true, status = 200, body = "")
        override suspend fun resetPage() { calls += "reset" }
    }

    private class Sent(val path: String, val body: JSONObject, val auth: String?)

    private inner class Setup(
        val host: Host0 = Host0(),
        token: suspend () -> String = { "tok" },
        queue: JobQueue = JobQueue(),
        val answer: suspend Setup.(path: String, body: JSONObject) -> HttpResponse,
    ) {
        val sent = mutableListOf<Sent>()
        private var jobs = 0
        val transport = object : HttpTransport {
            override suspend fun post(url: String, headers: Map<String, String>, body: String): HttpResponse {
                val path = url.removePrefix("https://mealio.test")
                val b = JSONObject(body)
                sent += Sent(path, b, headers["Authorization"])
                return answer(path, b)
            }
            override suspend fun get(url: String, headers: Map<String, String>): HttpResponse {
                val path = url.removePrefix("https://mealio.test")
                sent += Sent(path, JSONObject(), null)
                return answer(path, JSONObject())
            }
        }
        val client = MealioClient(MealioConfig("pk", token, baseUrl = "https://mealio.test", keys = Vectors.keys), host, transport, queue)

        fun start(vararg ins: JSONObject): HttpResponse {
            jobs += 1
            val job = "job$jobs"
            return ok(JSONObject().put("job", job).put("envelope", TestSigner.instructions(1, ins.toList(), job = job).toJson()))
        }

        fun step(job: String, vararg ins: JSONObject): HttpResponse =
            ok(JSONObject().put("envelope", TestSigner.instructions(2, ins.toList(), job = job).toJson()))

        fun paths() = sent.map { it.path.removePrefix("/api/v1/sdk") }
    }

    private suspend fun code(block: suspend () -> Unit): String = try {
        block()
        fail("expected MealioException")
        ""
    } catch (e: MealioException) {
        e.code
    }

    private fun jobOf(path: String) = path.split("/")[5]

    // ── one job at a time ──────────────────────────────────────────────

    @Test
    fun aSecondPrepareWaitsForTheFirstToEnd() = runTest {
        val gate = CompletableDeferred<Unit>()
        val order = mutableListOf<String>()
        val host = object : Host0() {
            override suspend fun open(url: String): PageLoad { order += "open"; gate.await(); order += "opened"; return PageLoad(true, url) }
        }
        val t = Setup(host) { p, _ -> if (p.endsWith("/carts")) start(open("o"), doneOp("d", cartJson)) else ok(JSONObject()) }
        val a = async { t.client.prepareCart(null, recipe) }
        val b = async { t.client.prepareCart(null, recipe) }
        runCurrent()
        assertEquals(listOf("open"), order)
        assertEquals(listOf("/carts"), t.paths())
        gate.complete(Unit)
        a.await(); b.await()
        assertEquals(listOf("open", "opened", "open", "opened"), order)
    }

    @Test
    fun aWarmUpAndASearchNeverOverlap() = runTest {
        // Android: warm and search hold the same lock as prepare and add.
        val gate = CompletableDeferred<Unit>()
        val order = mutableListOf<String>()
        val host = object : Host0() {
            override suspend fun open(url: String): PageLoad { order += "open $url"; gate.await(); order += "opened"; return PageLoad(true, url) }
        }
        val t = Setup(host) { p, _ ->
            when {
                p.endsWith("/warm") -> start(pageOpen("w", "https://www.heb.com/warm"), doneOp("d", JSONObject().put("store", "heb").put("signedIn", true)))
                p.endsWith("/search") -> start(pageOpen("s", "https://www.heb.com/search"), doneOp("d", JSONObject().put("key", "k").put("options", JSONArray())))
                else -> error("unexpected $p")
            }
        }
        val w = launch { t.client.warm() }
        runCurrent()
        val s = async { t.client.search("c", "k", "milk") }
        runCurrent()
        assertEquals(listOf("open https://www.heb.com/warm"), order)
        gate.complete(Unit)
        w.join(); s.await()
        assertEquals(listOf("open https://www.heb.com/warm", "opened", "open https://www.heb.com/search", "opened"), order)
    }

    @Test
    fun aHostThatNeverAnswersEndsTheStepAtItsTimeoutPlusTheGrace() = runTest {
        val host = object : Host0() { override suspend fun script(): ScriptRun = awaitCancellation() }
        val script = pageScript("s", "X").put("timeoutMs", 100)
        val t = Setup(host) { p, b ->
            if (p.endsWith("/carts")) start(script)
            else step(jobOf(p), doneOp("d", JSONObject(cartJson.toString()).put("seen", b.getJSONArray("results"))))
        }
        t.client.prepareCart(null, recipe)
        assertEquals(100 + HOST_GRACE_MS, currentTime)
        val seen = t.sent.last().body.getJSONArray("results").getJSONObject(0)
        assertEquals("s", seen.getString("id"))
        assertTrue(seen.getBoolean("timedOut"))
        assertEquals(0, seen.getJSONArray("messages").length())
    }

    @Test
    fun afterAHungJobEndsAWarmUpRunsAgain() = runTest {
        val host = object : Host0() { override suspend fun open(url: String): PageLoad = awaitCancellation() }
        val t = Setup(host) { p, _ ->
            when {
                p.endsWith("/carts") -> start(open("o"))
                p.endsWith("/warm") -> ok(JSONObject().put("warm", JSONObject.NULL))
                else -> step(jobOf(p), doneOp("d", cartJson))
            }
        }
        t.client.prepareCart(null, recipe)
        t.client.warm()
        assertTrue("/warm" in t.paths())
    }

    // ── bounded requests ──────────────────────────────────────────────

    @Test
    fun aRequestWithNoAnswerFailsAsNetworkAfter30Seconds() = runTest {
        val t = Setup { _, _ -> awaitCancellation() }
        assertEquals("network", code { t.client.storePreferences() })
        assertEquals(REQUEST_TIMEOUT_MS, currentTime)
    }

    @Test
    fun a200ThatIsNotJsonIsAServerErrorNotACrash() = runTest {
        val t = Setup { _, _ -> HttpResponse(200, "<html>portal</html>") }
        assertEquals("server", code { t.client.prepareCart(null, recipe) })
        assertEquals("server", code { t.client.stores() })
    }

    @Test
    fun aFailedStoreListThrowsInsteadOfReadingAsNoStores() = runTest {
        val t = Setup { _, _ -> HttpResponse(503, JSONObject().put("error", JSONObject().put("code", "store_unavailable").put("message", "down")).toString()) }
        assertEquals("store_unavailable", code { t.client.stores() })
    }

    // ── session function ──────────────────────────────────────────────

    @Test
    fun aFailingOneRaisesSessionFailedWithItsMessage() = runTest {
        val t = Setup(token = { throw IllegalStateException("your server is down") }) { _, _ -> ok(JSONObject()) }
        try {
            t.client.storePreferences()
            fail("expected session_failed")
        } catch (e: MealioException) {
            assertEquals("session_failed", e.code)
            assertEquals("your server is down", e.message)
        }
    }

    @Test
    fun oneThatNeverAnswersRaisesSessionFailed() = runTest {
        val t = Setup(token = { awaitCancellation() }) { _, _ -> ok(JSONObject()) }
        assertEquals("session_failed", code { t.client.storePreferences() })
        assertEquals(REQUEST_TIMEOUT_MS, currentTime)
    }

    @Test
    fun aPartnersOwnTimeoutIsSessionFailedNotASilentEnd() = runTest {
        // withTimeout in the partner's function throws a CancellationException
        // while our call is still wanted. It must not end the job silently.
        val t = Setup(token = { withTimeout(10) { awaitCancellation() } }) { _, _ -> ok(JSONObject()) }
        assertEquals("session_failed", code { t.client.prepareCart(null, recipe) })
        val t2 = Setup(token = { throw CancellationException("gave up") }) { _, _ -> ok(JSONObject()) }
        assertEquals("session_failed", code { t2.client.storePreferences() })
        // The same from the transport is network.
        val t3 = Setup(token = { "tok" }) { _, _ -> throw CancellationException("socket closed") }
        assertEquals("network", code { t3.client.storePreferences() })
    }

    @Test
    fun cancellingTheCallerStillCancels() = runTest {
        val t = Setup(token = { awaitCancellation() }) { _, _ -> ok(JSONObject()) }
        var outcome = "running"
        val job = launch {
            try {
                t.client.storePreferences()
                outcome = "done"
            } catch (e: MealioException) {
                outcome = e.code
            } catch (e: CancellationException) {
                outcome = "cancelled"
                throw e
            }
        }
        runCurrent()
        job.cancel()
        job.join()
        assertEquals("cancelled", outcome)
    }

    // ── cancelling ──────────────────────────────────────────────────

    @Test
    fun stopsAfterTheCurrentStepNoSignInNothingMoreSent() = runTest {
        val cancel = CancelToken()
        val host = object : Host0() { override suspend fun open(url: String): PageLoad { cancel.cancel(); return PageLoad(true, url) } }
        val t = Setup(host) { p, _ -> if (p.endsWith("/carts")) start(open("o"), login) else ok(JSONObject()) }
        assertEquals("cancelled", code { t.client.prepareCart(null, listOf(recipe), null, cancel) })
        assertEquals(listOf("/carts"), t.paths())
        assertFalse("login" in host.calls)
        // The queue is free again.
        t.client.warm()
    }

    @Test
    fun aCancelledJobWaitingInTheQueueNeverStarts() = runTest {
        val gate = CompletableDeferred<Unit>()
        val host = object : Host0() { override suspend fun open(url: String): PageLoad { gate.await(); return PageLoad(true, url) } }
        val t = Setup(host) { p, _ -> if (p.endsWith("/carts")) start(open("o"), doneOp("d", cartJson)) else ok(JSONObject()) }
        val a = async { t.client.prepareCart(null, recipe) }
        val cancel = CancelToken()
        val b = async { code { t.client.prepareCart(null, listOf(recipe), null, cancel) } }
        runCurrent()
        cancel.cancel()
        gate.complete(Unit)
        a.await()
        assertEquals("cancelled", b.await())
        assertEquals(listOf("/carts"), t.paths())
    }

    @Test
    fun aSignInOpenWhenItIsCancelledIsToldToClose() = runTest {
        val cancel = CancelToken()
        val host = object : Host0() {
            override suspend fun signIn(r: LoginRequest): LoginResult {
                val done = CompletableDeferred<LoginResult>()
                r.cancel?.onCancel { done.complete(LoginResult(LoginOutcome.CANCELLED, emptyList())) }
                return done.await()
            }
        }
        val t = Setup(host) { p, _ -> if (p.endsWith("/carts")) start(login) else ok(JSONObject()) }
        val p = async { code { t.client.prepareCart(null, listOf(recipe), null, cancel) } }
        runCurrent()
        assertEquals(listOf("login"), host.calls)
        cancel.cancel()
        assertEquals("cancelled", p.await())
    }

    // ── users ───────────────────────────────────────────────────────

    @Test
    fun whileNobodyIsSignedInNoSessionIsAskedForAndWarmDoesNothing() = runTest {
        var asked = 0
        val t = Setup(token = { asked += 1; "t" }) { _, _ -> ok(JSONObject().put("warm", JSONObject.NULL)) }
        t.client.setUser(null)
        t.client.warm()
        assertEquals("not_signed_in", code { t.client.prepareCart(null, recipe) })
        assertEquals(0, asked)
        assertTrue(t.sent.isEmpty())
    }

    @Test
    fun aNewUserCancelsAPrepareResetsTheSessionAndSaysToSignOutOfStores() = runTest {
        val tokens = ArrayDeque(listOf("alice", "bob"))
        val host = object : Host0() { override suspend fun open(url: String): PageLoad { delay(20); return PageLoad(true, url) } }
        val t = Setup(host, token = { tokens.removeFirst() }) { p, _ -> if (p.endsWith("/carts")) start(open("o"), doneOp("d", cartJson)) else ok(JSONObject()) }
        assertFalse(t.client.setUser("a"))
        val p = async { code { t.client.prepareCart(null, recipe) } }
        runCurrent()
        assertTrue(t.client.setUser("b"))
        assertEquals("cancelled", p.await())
        t.client.storePreferences()
        assertEquals(listOf("Bearer alice", "Bearer bob"), t.sent.map { it.auth })
        assertFalse(t.client.setUser("b"))
        assertTrue(t.client.setUser(null))
        assertFalse(t.client.setUser("c"))
    }

    @Test
    fun anAddRunsOnUnderTheSessionItStartedWith() = runTest {
        val tokens = ArrayDeque(listOf("alice", "bob"))
        val gate = CompletableDeferred<Unit>()
        val host = object : Host0() { override suspend fun open(url: String): PageLoad { gate.await(); return PageLoad(true, url) } }
        val t = Setup(host, token = { tokens.removeFirst() }) { p, _ ->
            if (p.endsWith("/add")) start(open("o")) else step(jobOf(p), doneOp("d", JSONObject().put("added", JSONArray())))
        }
        t.client.setUser("a")
        val p = async { t.client.addToCart("c", emptyList()) }
        runCurrent()
        t.client.setUser("b")
        gate.complete(Unit)
        p.await()
        assertEquals(listOf("Bearer alice", "Bearer alice"), t.sent.map { it.auth })
    }

    @Test
    fun aWarmUpThatEndsAfterAResetIsNotOfferedToTheNextPrepare() = runTest {
        val gate = CompletableDeferred<Unit>()
        val t = Setup { p, _ ->
            if (p.endsWith("/warm")) {
                gate.await()
                ok(JSONObject().put("job", "w").put("envelope", TestSigner.instructions(1, listOf(doneOp("d", JSONObject().put("store", "heb").put("signedIn", true))), job = "w").toJson()))
            } else start(doneOp("d", cartJson))
        }
        val w = launch { t.client.warm() }
        runCurrent()
        t.client.resetSession()
        gate.complete(Unit)
        w.join()
        t.client.prepareCart("heb", recipe)
        assertFalse(t.sent.first { it.path.endsWith("/carts") }.body.has("warm"))
    }

    @Test
    fun runExclusiveWaitsForAnAddToEnd() = runTest {
        val gate = CompletableDeferred<Unit>()
        val order = mutableListOf<String>()
        val host = object : Host0() { override suspend fun open(url: String): PageLoad { order += "add"; gate.await(); return PageLoad(true, url) } }
        val t = Setup(host) { p, _ -> if (p.endsWith("/add")) start(open("o"), doneOp("d", JSONObject().put("added", JSONArray()))) else ok(JSONObject()) }
        val add = async { t.client.addToCart("c", emptyList()) }
        runCurrent()
        val clear = async { t.client.runExclusive { order += "clear" } }
        runCurrent()
        assertEquals(listOf("add"), order)
        gate.complete(Unit)
        add.await(); clear.await()
        assertEquals(listOf("add", "clear"), order)
    }

    // ── the hidden page ─────────────────────────────────────────────

    @Test
    fun aWarmUpLeftOnALostPageIsNotOffered() = runTest {
        // A WebView swapped after a renderer crash loads nothing new, so
        // pageOpens alone would still match. Host.pagesLost voids the warm-up.
        val host = Host0()
        val warmStart = { tag: String ->
            ok(JSONObject().put("job", tag).put("envelope", TestSigner.instructions(1, listOf(doneOp("d", JSONObject().put("store", "heb").put("signedIn", true))), job = tag).toJson()))
        }
        val t = Setup(host) { p, _ -> if (p.endsWith("/warm")) warmStart("w") else start(doneOp("d", cartJson)) }
        t.client.warm()
        host.pagesLost += 1
        t.client.prepareCart("heb", recipe)
        assertFalse(t.sent.first { it.path.endsWith("/carts") }.body.has("warm"))
        // Without a loss it is offered.
        t.client.clearWarm()
        t.client.warm()
        t.client.prepareCart("heb", recipe)
        assertEquals("w", t.sent.last { it.path.endsWith("/carts") }.body.optString("warm"))
    }

    // ── cart session ────────────────────────────────────────────────

    private fun prod(id: String = "p", extra: (JSONObject) -> Unit = {}) = JSONObject().put("id", id).put("name", "P").also(extra)
    private fun item(key: String = "k", selectedId: String = "p", options: List<JSONObject>, quantity: Int = 1, extra: (JSONObject) -> Unit = {}) =
        JSONObject().put("key", key).put("ingredient", "x").put("quantity", quantity).put("status", "remembered")
            .put("selectedId", selectedId).put("remembered", JSONObject.NULL).put("options", JSONArray(options)).also(extra)
    private fun session(items: List<JSONObject>, store: String = "heb", client: MealioClient = Setup { _, _ -> error("no calls") }.client, cartId: String = "c") =
        CartSession(client, PreparedCart.fromJson(JSONObject().put("cartId", cartId).put("store", store).put("items", JSONArray(items))
            .put("ready", JSONArray()).put("needsChoice", JSONArray()).put("unavailable", JSONArray())))

    @Test
    fun showsTheQuantityItSendsUnderTheCapAlsoAfterSwitchingProduct() {
        val c = session(listOf(item(quantity = 8, options = listOf(prod { it.put("unitPrice", 2).put("maxQuantity", 5) }))))
        assertEquals(5, c.quantity("k"))
        assertEquals(5, c.selections()[0].quantity)
        val d = session(listOf(item(selectedId = "a", options = listOf(prod("a") { it.put("unitPrice", 2) }, prod("b") { it.put("unitPrice", 2).put("maxQuantity", 3) }))))
        d.setQuantity("k", 10)
        d.select("k", "b")
        assertEquals(3, d.quantity("k"))
        assertEquals(3, d.selections()[0].quantity)
        assertEquals(2, d.setQuantity("k", d.quantity("k") - 1))
    }

    @Test
    fun theListTotalAndTheDoneTotalAgreeToTheCent() {
        fun lb(key: String) = item(key, options = listOf(prod { it.put("soldByWeight", true).put("pricePerLb", 3.33) })) { it.put("weightLb", 0.25) }
        val c = session(listOf(lb("a"), lb("b")))
        val added = listOf("a", "b").map { AddedItem(it, "p", "P", 1, weightLb = 0.25, pricePerLb = 3.33) }
        assertEquals(1.66, c.estimate().total!!, 0.0)
        assertEquals(1.66, c.addedTotal(AddResult("c", "heb", added, emptyList(), emptyList(), null)).total!!, 0.0)
    }

    @Test
    fun aSecondAddWhileOneRunsReturnsTheSamePromise() = runTest {
        val gate = CompletableDeferred<Unit>()
        val host = object : Host0() { override suspend fun open(url: String): PageLoad { gate.await(); return PageLoad(true, url) } }
        val t = Setup(host) { p, _ -> if (p.endsWith("/add")) start(open("o"), doneOp("d", JSONObject().put("added", JSONArray()))) else ok(JSONObject()) }
        val c = session(emptyList(), client = t.client)
        val a = async { c.addToCart() }
        runCurrent()
        assertTrue(c.isAdding)
        val b = async { c.addToCart() }
        runCurrent()
        gate.complete(Unit)
        assertSame(a.await(), b.await())
        assertEquals(1, t.paths().count { it.endsWith("/add") })
        assertFalse(c.isAdding)
    }

    @Test
    fun knowsWhenASearchRunsAndCancelsIt() = runTest {
        val host = object : Host0() { override suspend fun open(url: String): PageLoad = awaitCancellation() }
        val t = Setup(host) { p, _ -> if (p.endsWith("/search")) start(open("o"), open("o2")) else error("no step: cancelled") }
        val c = session(listOf(item(options = listOf(prod()))), client = t.client)
        val p = async { code { c.search("k", "milk") } }
        runCurrent()
        assertTrue(c.searching)
        c.cancelSearches()
        assertEquals("cancelled", p.await())
        assertFalse(c.searching)
        assertEquals(1, host.calls.size)
    }

    @Test
    fun restoresPicksFromAFailedAddWhereTheProductIsStillOffered() = runTest {
        val opts = listOf(prod("p1") { it.put("maxQuantity", 9).put("preferences", JSONArray().put(JSONObject().put("id", "sl").put("label", "Sliced"))) }, prod("p2"))
        val old = session(listOf(item("a", "p1", opts), item("b", "p1", opts), item("c", "gone", listOf(prod("gone")))))
        old.select("a", "p2")
        old.setQuantity("a", 4)
        old.deselect("b")
        old.select("c", "gone")
        val fresh = session(listOf(item("a", "p1", opts), item("b", "p1", opts), item("c", "new", listOf(prod("new")))))
        fresh.restorePicks(old)
        assertEquals(listOf<Any?>("p2", 4, false, "new"), listOf(fresh.selectedId("a"), fresh.quantity("a"), fresh.isSelected("b"), fresh.selectedId("c")))
        val elsewhere = session(listOf(item("a", "p1", opts)), store = "walmart")
        elsewhere.restorePicks(old)
        assertEquals("p1", elsewhere.selectedId("a"))
    }

    @Test
    fun exposesServerWarningsAndNoneFromOlderServers() {
        val c = CartSession(Setup { _, _ -> error("no") }.client, PreparedCart.fromJson(JSONObject(cartJson.toString())
            .put("warnings", JSONArray().put(JSONObject().put("code", "lines_dropped").put("message", "Two lines were empty.")))))
        assertEquals(listOf(CartWarning("lines_dropped", "Two lines were empty.")), c.warnings)
        assertEquals(emptyList<CartWarning>(), session(emptyList()).warnings)
    }

    // ── blocked mutations ───────────────────────────────────────────

    @Test
    fun namesEveryFieldOfAMutationAndNothingOfAQuery() {
        assertEquals(
            listOf("Go", "placeOrder"),
            mutationNames("mutation Go(\$a: ID!) { x: placeOrder(id: \$a, note: \"checkout\") { ... on Err { message } } } # payment"),
        )
        assertEquals(emptyList<String>(), mutationNames("query Q { paymentMethods { id } }"))
    }

    @Test
    fun judgesAMutationByItsNameAndRootFieldsOnly() {
        assertEquals(listOf("AddToCart", "addItemsToCart"), mutationNames("mutation AddToCart { addItemsToCart { cart { items { maxPurchaseQuantity } } } }"))
        assertEquals(listOf("placeOrder", "checkout"), mutationNames("mutation { a: placeOrder { id } ... on Mutation { ...F } } fragment F on Mutation { checkout { id } }"))
    }

    @Test
    fun aLongStringInABodyIsReadWithoutOverflowing() {
        val long = "a\\\"".repeat(50_000)
        assertFalse(bodyBlocked("""{"query":"mutation Add { addItem(note: \"$long\") { id } }"}"""))
        assertTrue(bodyBlocked("mutation Go { note(x: \"$long\") placeOrder { id } }"))
    }

    // ── 0.6 round 2 ─────────────────────────────────────────────────

    @Test
    fun aUserChangeWhileAPrepareWaitsForItsTokenEndsItAsCancelledAndSendsNothing() = runTest {
        for (next in listOf<String?>("b", null)) {
            val gate = CompletableDeferred<Unit>()
            var asked = 0
            val t = Setup(token = { asked += 1; gate.await(); "tok$asked" }) { _, _ -> start(doneOp("d", cartJson)) }
            t.client.setUser("a")
            val p = async { code { t.client.prepareCart(null, recipe) } }
            runCurrent()
            t.client.setUser(next)
            gate.complete(Unit)
            assertEquals("next=$next", "cancelled", p.await())
            assertEquals("never asks for the next user's token", 1, asked)
            assertTrue(t.sent.isEmpty())
        }
    }

    @Test
    fun anAddKeepsTheTokenItWasCalledWithThroughTheWaitInTheQueue() = runTest {
        var who = "alice"
        val t = Setup(token = { who }) { p, _ -> if (p.endsWith("/add")) start(doneOp("d", JSONObject().put("added", JSONArray()))) else ok(JSONObject()) }
        t.client.setUser("a")
        t.client.storePreferences()
        val gate = CompletableDeferred<Unit>()
        val held = async { t.client.runExclusive { gate.await() } }
        runCurrent()
        val add = async { t.client.addToCart("c", emptyList()) }
        runCurrent()
        who = "bob"
        t.client.setUser("b")
        gate.complete(Unit)
        held.await(); add.await()
        assertEquals("Bearer alice", t.sent.last { it.path.endsWith("/add") }.auth)
    }

    @Test
    fun a401AfterTheUserChangedFailsTheAddAsSessionExpired() = runTest {
        var who = "alice"
        var asked = 0
        val gate = CompletableDeferred<Unit>()
        val host = object : Host0() { override suspend fun open(url: String): PageLoad { gate.await(); return PageLoad(true, url) } }
        val t = Setup(host, token = { asked += 1; who }) { p, _ -> if (p.endsWith("/add")) start(open("o")) else HttpResponse(401, "{}") }
        t.client.setUser("a")
        val add = async { code { t.client.addToCart("c", emptyList()) } }
        runCurrent()
        who = "bob"
        t.client.setUser("b")
        gate.complete(Unit)
        assertEquals("session_expired", add.await())
        assertEquals(1, asked)
        assertEquals(listOf("Bearer alice", "Bearer alice"), t.sent.map { it.auth })
    }

    @Test
    fun a401ForTheSameUserRenewsTheAddsTokenForTheRestOfIt() = runTest {
        val tokens = ArrayDeque(listOf("t1", "t2"))
        var steps = 0
        lateinit var t: Setup
        t = Setup(token = { tokens.removeFirst() }) { p, _ ->
            when {
                p.endsWith("/add") -> start(open("o"))
                // The t1 session has expired on the server.
                t.sent.last().auth == "Bearer t1" -> HttpResponse(401, "{}")
                else -> { steps += 1; if (steps == 1) step(jobOf(p), open("o2")) else ok(JSONObject().put("envelope", TestSigner.instructions(3, listOf(doneOp("d", JSONObject().put("added", JSONArray()))), job = jobOf(p)).toJson())) }
            }
        }
        t.client.addToCart("c", emptyList())
        assertEquals(listOf("Bearer t1", "Bearer t1", "Bearer t2", "Bearer t2"), t.sent.map { it.auth })
    }

    @Test
    fun runExclusiveReportsItsDeadlineButHoldsTheQueueUntilTheWorkEnds() = runTest {
        val order = mutableListOf<String>()
        val t = Setup { _, _ -> ok(JSONObject()) }
        val slow = async {
            code {
                t.client.runExclusive {
                    try { delay(60_000) } finally { kotlinx.coroutines.withContext(kotlinx.coroutines.NonCancellable) { delay(10_000) }; order += "slow ended" }
                }
            }
        }
        runCurrent()
        val next = async { t.client.runExclusive { order += "next" } }
        testScheduler.advanceTimeBy(30_001)
        runCurrent()
        assertTrue("the caller hears of the deadline at 30 seconds", slow.isCompleted)
        assertEquals("network", slow.await())
        assertEquals(emptyList<String>(), order)
        advanceUntilIdle()
        next.await()
        assertEquals(listOf("slow ended", "next"), order)
    }

    @Test
    fun aSignOutQueuedOnAUserChangeRunsBeforeTheNextUsersCart() = runTest {
        val log = mutableListOf<String>()
        val t = Setup { p, _ -> log += p; start(doneOp("d", cartJson)) }
        t.client.setUser("a")
        // MealioCart's scope is Main: its work runs a frame later.
        val main = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.test.StandardTestDispatcher(testScheduler))
        if (t.client.setUser("b")) MealioCart.queueExclusive(main, t.client) { log += "signout" }
        // The app starts b's cart right after setUser, on Main.immediate.
        launch(kotlinx.coroutines.test.UnconfinedTestDispatcher(testScheduler)) { t.client.prepareCart(null, recipe) }
        advanceUntilIdle()
        assertEquals(listOf("signout", "/api/v1/sdk/carts"), log)
    }

    @Test
    fun aCancelledCallerDoesNotStopTheAddAndAnotherCallerGetsItsResult() = runTest {
        val gate = CompletableDeferred<Unit>()
        val host = object : Host0() { override suspend fun open(url: String): PageLoad { gate.await(); return PageLoad(true, url) } }
        val t = Setup(host) { p, _ -> if (p.endsWith("/add")) start(open("o")) else step(jobOf(p), doneOp("d", JSONObject().put("added", JSONArray()))) }
        val c = session(emptyList(), client = t.client)
        val first = launch { c.addToCart() }
        runCurrent()
        val second = async { c.addToCart() }
        runCurrent()
        first.cancel()
        gate.complete(Unit)
        second.await()
        assertEquals(1, t.paths().count { it.endsWith("/add") })
        assertEquals(1, t.paths().count { it.endsWith("/step") })
        assertFalse(c.isAdding)
    }

    @Test
    fun aCancelledSoleCallerStillLetsTheAddFinish() = runTest {
        val gate = CompletableDeferred<Unit>()
        val host = object : Host0() { override suspend fun open(url: String): PageLoad { gate.await(); return PageLoad(true, url) } }
        val t = Setup(host) { p, _ -> if (p.endsWith("/add")) start(open("o")) else step(jobOf(p), doneOp("d", JSONObject().put("added", JSONArray()))) }
        val c = session(emptyList(), client = t.client)
        val first = launch { c.addToCart() }
        runCurrent()
        first.cancel()
        gate.complete(Unit)
        advanceUntilIdle()
        assertEquals(1, t.paths().count { it.endsWith("/step") })
        assertFalse(c.isAdding)
    }

    @Test
    fun restorePicksKeepsAProductTheUserFoundWithSearch() = runTest {
        val found = prod("found") { it.put("unitPrice", 5) }
        val t = Setup { p, _ -> if (p.endsWith("/search")) start(doneOp("d", JSONObject().put("key", "a").put("options", JSONArray().put(found)))) else error("no") }
        val opts = listOf(prod("p1"))
        val old = session(listOf(item("a", "p1", opts)), client = t.client)
        old.search("a", "oat milk")
        old.select("a", "found")
        old.setQuantity("a", 3)
        val fresh = session(listOf(item("a", "p1", opts)), client = t.client, cartId = "c2")
        fresh.restorePicks(old)
        assertEquals("found", fresh.selectedId("a"))
        assertEquals(3, fresh.quantity("a"))
        assertEquals(listOf("p1", "found"), fresh.options("a").map { it.id })
    }

    // ── 0.6 round 3 ────────────────────────────────────────────────────

    @Test
    fun restorePicksSearchesAgainOnTheNewCartInsteadOfSendingTheOldCartsProduct() = runTest {
        val found = prod("found") { it.put("unitPrice", 5) }
        val t = Setup { p, _ -> if (p.endsWith("/search")) start(doneOp("d", JSONObject().put("key", "a").put("options", JSONArray().put(found)))) else error("no") }
        val old = session(listOf(item("a", "p1", listOf(prod("p1"))), item("b", "p1", listOf(prod("p1")))), client = t.client, cartId = "c1")
        old.search("a", "oat milk")
        old.select("a", "found")
        old.setQuantity("a", 3)
        val fresh = session(listOf(item("a", "p1", listOf(prod("p1"))), item("b", "p1", listOf(prod("p1")))), client = t.client, cartId = "c2")
        fresh.restorePicks(old)
        // The search ran again on the new cart, with the same words, and only for the searched pick.
        assertEquals(listOf("/carts/c1/search", "/carts/c2/search"), t.paths())
        assertEquals("oat milk", t.sent.last().body.getString("query"))
        assertEquals(Selection("a", "found", quantity = 3, remember = true), fresh.selections().first())
    }

    @Test
    fun restorePicksKeepsTheNewCartsOwnPickWhenTheSearchedProductDoesNotComeBack() = runTest {
        var n = 0
        val t = Setup { p, _ ->
            n += 1
            val id = if (n == 1) "found" else "other"
            start(doneOp("d", JSONObject().put("key", "a").put("options", JSONArray().put(prod(id)))))
        }
        val old = session(listOf(item("a", "p1", listOf(prod("p1")))), client = t.client, cartId = "c1")
        old.search("a", "oat milk")
        old.select("a", "found")
        old.setQuantity("a", 3)
        val fresh = session(listOf(item("a", "p1", listOf(prod("p1")))), client = t.client, cartId = "c2")
        fresh.restorePicks(old)
        assertEquals("p1", fresh.selectedId("a"))
        assertEquals(1, fresh.quantity("a"))
        // Never a product the new cart was not offered.
        assertTrue(fresh.selections().none { it.productId == "found" })
        assertTrue(fresh.options("a").none { it.id == "found" })
    }

    @Test
    fun aJobCancelledWhileWaitingInTheQueueSettlesAtOnceAndLeavesIt() = runTest {
        val gate = CompletableDeferred<Unit>()
        val host = object : Host0() { override suspend fun open(url: String): PageLoad { gate.await(); return PageLoad(true, url) } }
        val t = Setup(host) { p, _ -> if (p.endsWith("/add")) start(open("o"), doneOp("d", JSONObject().put("added", JSONArray()))) else start(doneOp("d", cartJson)) }
        val adding = async { t.client.addToCart("c", emptyList()) }
        runCurrent()
        val cancel = CancelToken()
        val waiting = async { try { t.client.prepareCart(null, listOf(recipe), null, cancel); null } catch (e: MealioException) { e } }
        val after = async { t.client.prepareCart(null, recipe) }
        runCurrent()
        cancel.cancel()
        runCurrent()
        // Settled while the add still holds the queue.
        assertTrue(waiting.isCompleted)
        assertEquals("cancelled", waiting.await()!!.code)
        assertFalse(gate.isCompleted)
        gate.complete(Unit)
        adding.await()
        after.await()
        assertEquals(listOf("/carts/c/add", "/carts"), t.paths())
    }

    @Test
    fun runExclusiveLetsTheQueueGoAfterItsCapAndTheNextJobStartsFromABlankPage() = runTest {
        val t = Setup { _, _ -> start(doneOp("d", cartJson)) }
        val stuck = async {
            try {
                // Work that ignores its cancel and never ends.
                t.client.runExclusive { withContext(NonCancellable) { CompletableDeferred<Unit>().await() } }
                "ended"
            } catch (e: MealioException) {
                e.code
            }
        }
        runCurrent()
        val next = async { t.client.prepareCart(null, recipe) }
        advanceTimeBy(REQUEST_TIMEOUT_MS + 1)
        assertEquals("network", stuck.await())
        assertTrue("still held until the cap", t.paths().isEmpty())
        advanceTimeBy(EXCLUSIVE_CAP_MS - REQUEST_TIMEOUT_MS)
        next.await()
        assertEquals(listOf("/carts"), t.paths())
        assertEquals("the page is reset before the job", listOf("reset"), t.host.calls)
        // Only once.
        t.client.prepareCart(null, recipe)
        assertEquals(listOf("reset"), t.host.calls)
    }

    @Test
    fun eachStepOfAStoreSignOutIsBoundedAndTheRestStillRun() = runTest {
        val done = mutableListOf<String>()
        signOutSteps(
            { awaitCancellation() },
            { throw IllegalStateException("cookie store broke") },
            { done += "epoch at $currentTime" },
        )
        assertEquals(listOf("epoch at ${SIGN_OUT_STEP_MS}"), done)
        // A cancel stops them all.
        val j = launch { signOutSteps({ delay(1_000) }, { done += "after cancel" }) }
        runCurrent()
        j.cancel()
        advanceUntilIdle()
        assertEquals(listOf("epoch at ${SIGN_OUT_STEP_MS}"), done)
    }

    @Test
    fun aJobCancelledWhoseSessionFetchThenFailsReportsCancelled() = runTest {
        val gate = CompletableDeferred<String>()
        val t = Setup(token = { gate.await() }) { _, _ -> start(doneOp("d", cartJson)) }
        val p = async { try { t.client.prepareCart(null, listOf(recipe), null, CancelToken()); null } catch (e: MealioException) { e } }
        runCurrent()
        t.client.cancelJobs()
        gate.completeExceptionally(IllegalStateException("partner server down"))
        val e = p.await()!!
        assertEquals("cancelled", e.code)
        assertEquals(CancelReason.CANCELLED, e.reason)
        assertTrue(t.sent.isEmpty())
    }

    @Test
    fun aCancelledErrorSaysWhy() = runTest {
        var gate = CompletableDeferred<Unit>()
        val host = object : Host0() { override suspend fun open(url: String): PageLoad { gate.await(); return PageLoad(true, url) } }
        val t = Setup(host) { p, _ -> if (p.endsWith("/carts")) start(open("o"), doneOp("d", cartJson)) else start(doneOp("d", cartJson)) }
        suspend fun reasonOf(stop: (CancelToken) -> Unit): String? {
            val c = CancelToken()
            gate = CompletableDeferred()
            val p = async { try { t.client.prepareCart(null, listOf(recipe), null, c); null } catch (e: MealioException) { e } }
            runCurrent()
            stop(c)
            gate.complete(Unit)
            runCurrent()
            val e = p.await()
            assertEquals("cancelled", e?.code)
            return e?.reason
        }
        t.client.setUser("a")
        assertEquals(CancelReason.USER_CHANGED, reasonOf { t.client.setUser("b") })
        assertEquals(CancelReason.CANCELLED, reasonOf { t.client.cancelJobs() })
        assertEquals(CancelReason.CLOSED, reasonOf { it.cancel(CancelReason.CLOSED) })
        assertEquals(CancelReason.CANCELLED, reasonOf { it.cancel() })
        assertNull(MealioException("server", "x").reason)
    }

    @Test
    fun aResetSessionWhileTheTokenComesIsAnOutsideCancel() = runTest {
        val gate = CompletableDeferred<String>()
        var asks = 0
        val t = Setup(token = { asks += 1; if (asks == 1) gate.await() else "tok2" }) { _, _ -> start(doneOp("d", cartJson)) }
        val p = async { try { t.client.prepareCart(null, listOf(recipe), null, CancelToken()); null } catch (e: MealioException) { e } }
        runCurrent()
        t.client.resetSession()
        gate.complete("tok1")
        val e = p.await()!!
        assertEquals("cancelled", e.code)
        assertEquals(CancelReason.CANCELLED, e.reason)
        assertTrue(t.sent.isEmpty())
    }

    @Test
    fun javaCanImplementHostAndCodeBuiltAgainst05StillLinks() {
        // A Java Host implements only the abstract methods: the defaults must be real JVM defaults.
        assertTrue(Host::class.java.getMethod("getPagesLost").isDefault)
        assertTrue(HttpTransport::class.java.getMethod("get", String::class.java, Map::class.java, kotlin.coroutines.Continuation::class.java).isDefault)
        // 0.5's constructors, before LoginRequest.cancel and PreparedCart.warnings.
        val l = List::class.java
        LoginRequest::class.java.getConstructor(String::class.java, String::class.java, String::class.java, String::class.java,
            LoginCheck::class.java, l, String::class.java, Long::class.javaPrimitiveType, Function1::class.java)
        val c = PreparedCart::class.java
        val old = arrayOf(String::class.java, String::class.java, l, l, l, l, String::class.java, l, StoreLocation::class.java)
        c.getConstructor(*old)
        // What PreparedCart("c", "heb", ready, none, none) compiled against 0.5 calls.
        val item = CartItem.fromJson(item(options = listOf(prod())), null)
        val made = c.getDeclaredConstructor(*old, Int::class.javaPrimitiveType, kotlin.jvm.internal.DefaultConstructorMarker::class.java)
            .newInstance("c", "heb", listOf(item), emptyList<CartItem>(), emptyList<CartItem>(), null, null, null, null, 0x1E0, null) as PreparedCart
        assertEquals(listOf(item), made.items)
        assertEquals(emptyList<CartRecipe>(), made.recipes)
        assertEquals(emptyList<CartWarning>(), made.warnings)
        c.getMethod("copy", *old)
        c.getMethod("copy\$default", c, *old, Int::class.javaPrimitiveType, Any::class.java)
    }
}
