package co.mealio.sdk

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
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
    }

    private class Sent(val path: String, val body: JSONObject, val auth: String?)

    private inner class Setup(
        val host: Host0 = Host0(),
        token: suspend () -> String = { "tok" },
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
        val client = MealioClient(MealioConfig("pk", token, baseUrl = "https://mealio.test", keys = Vectors.keys), host, transport)

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
    private fun session(items: List<JSONObject>, store: String = "heb", client: MealioClient = Setup { _, _ -> error("no calls") }.client) =
        CartSession(client, PreparedCart.fromJson(JSONObject().put("cartId", "c").put("store", store).put("items", JSONArray(items))
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
    fun restoresPicksFromAFailedAddWhereTheProductIsStillOffered() {
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
            listOf("Go", "x", "placeOrder", "message"),
            mutationNames("mutation Go(\$a: ID!) { x: placeOrder(id: \$a, note: \"checkout\") { ... on Err { message } } } # payment"),
        )
        assertEquals(emptyList<String>(), mutationNames("query Q { paymentMethods { id } }"))
    }

    @Test
    fun aLongStringInABodyIsReadWithoutOverflowing() {
        val long = "a\\\"".repeat(50_000)
        assertFalse(bodyBlocked("""{"query":"mutation Add { addItem(note: \"$long\") { id } }"}"""))
        assertTrue(bodyBlocked("mutation Go { note(x: \"$long\") placeOrder { id } }"))
    }
}
