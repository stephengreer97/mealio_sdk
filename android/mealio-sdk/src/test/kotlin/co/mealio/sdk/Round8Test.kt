package co.mealio.sdk

import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException

/**
 * 0.6 round 8, native blocking timing: blocking is on from a job's first
 * script until the job ends, however it ends, and only state-changing
 * requests and documents are ever refused.
 */
class Round8Test {
    private fun config() = MealioConfig(
        publishableKey = "pk_test",
        sessionTokenProvider = { "tok" },
        baseUrl = "https://mealio.test/",
        keys = Vectors.keys,
    )

    private fun start(vararg ops: JSONObject) =
        ok(JSONObject().put("job", "job_test").put("envelope", TestSigner.instructions(1, ops.toList()).toJson()))

    private suspend fun ending(host: FakeHost, transport: FakeTransport, cancel: CancelToken = CancelToken()): String? = try {
        MealioClient(config(), host, transport).prepareCart("heb", listOf(Recipe("r1", emptyList())), null, cancel)
        null
    } catch (e: MealioException) {
        e.code
    }

    @Test fun theHostHearsEveryJobEnd(): Unit = runBlocking {
        // Failed by the server.
        val failed = FakeHost()
        ending(failed, FakeTransport { _, _, _ -> start(pageScript("s", "X"), failOp("f", "store_down", "down")) })
        assertEquals(1, failed.jobsEnded)

        // Done (whatever the result reads as).
        val done = FakeHost()
        ending(done, FakeTransport { _, _, _ -> start(pageScript("s", "X"), doneOp("d", null)) })
        assertEquals(1, done.jobsEnded)

        // The step call fails on the network.
        val lost = FakeHost()
        assertEquals("network", ending(lost, FakeTransport { p, _, _ -> if (p.endsWith("/carts")) start(pageScript("s", "X")) else throw IOException("down") }))
        assertEquals(1, lost.jobsEnded)

        // Cancelled mid-job.
        val cancel = CancelToken()
        val cancelled = FakeHost(onOpen = { u -> cancel.cancel(); PageLoad(ok = true, finalUrl = u) })
        assertEquals("cancelled", ending(cancelled, FakeTransport { _, _, _ -> start(pageOpen("o", "https://www.heb.com/"), pageScript("s", "X")) }, cancel))
        assertEquals(1, cancelled.jobsEnded)
    }

    @Test fun onlyStateChangingMethodsAndDocumentsAreRefused() {
        val b = NetworkBlock().apply { arm(blockHostsFor(Allowlist(), "heb")) }
        for (m in listOf("POST", "PUT", "PATCH", "DELETE", "post")) assertTrue(m, b.blocksRequest("https://www.heb.com/checkout", m, document = false))
        for (m in listOf("GET", "HEAD", "OPTIONS", null)) assertFalse("$m", b.blocksRequest("https://www.heb.com/checkout", m, document = false))
        // A document, any method.
        assertTrue(b.blocksRequest("https://www.heb.com/checkout", "GET", document = true))
        // Never an ordinary path, never another host.
        assertFalse(b.blocksRequest("https://www.heb.com/api/cart/add", "POST", document = false))
        assertFalse(b.blocksRequest("https://js.stripe.com/v3/payment", "POST", document = true))
        b.disarm()
        assertFalse(b.blocksRequest("https://www.heb.com/checkout", "POST", document = true))
    }

    @Test fun aSubframeDocumentIsToldByItsAcceptHeader() {
        assertTrue(isDocumentRequest(true, null))
        assertTrue(isDocumentRequest(false, mapOf("Accept" to "text/html,application/xhtml+xml,*/*;q=0.8")))
        assertTrue(isDocumentRequest(false, mapOf("accept" to "application/xhtml+xml")))
        assertFalse(isDocumentRequest(false, null))
        assertFalse(isDocumentRequest(false, mapOf("Accept" to "*/*")))
        assertFalse(isDocumentRequest(false, mapOf("Accept" to "image/webp,*/*")))
        assertFalse(isDocumentRequest(false, mapOf("Accept" to "text/css,*/*;q=0.1")))
        assertFalse(isDocumentRequest(false, mapOf("Accept" to "application/json, text/html")))
    }

    /** Every public JVM signature ItemRecipe had in 0.5.0 (a data class with `quantity: Int`), still there. */
    @Test fun itemRecipeKeepsThe050Signatures() {
        val c = ItemRecipe::class.java
        val s = String::class.java
        val i = Int::class.javaPrimitiveType!!
        val marker = Class.forName("kotlin.jvm.internal.DefaultConstructorMarker")
        c.getConstructor(s, s, i)
        c.getConstructor(s, s, i, i, marker) // ItemRecipe("r") compiled against 0.5.0
        assertEquals(i, c.getMethod("getQuantity").returnType)
        assertEquals(i, c.getMethod("component3").returnType)
        assertEquals(c, c.getMethod("copy", s, s, i).returnType)
        val copyDefault = c.getMethod("copy\$default", c, s, s, i, i, Any::class.java)
        assertTrue(java.lang.reflect.Modifier.isStatic(copyDefault.modifiers))
        assertEquals(s, c.getMethod("component1").returnType)
        assertEquals(s, c.getMethod("component2").returnType)
        c.getMethod("getId"); c.getMethod("getTitle")
        assertEquals(ItemRecipe::class.java, ItemRecipe.Companion::class.java.getMethod("fromJson", JSONObject::class.java).returnType)
    }

    @Test fun itemRecipeShare() {
        assertEquals(2.0, ItemRecipe("r", "T", 2).share, 0.0)
        assertEquals(1.0, ItemRecipe("r").share, 0.0)
        val half = ItemRecipe.fromJson(JSONObject("{\"id\":\"r\",\"title\":null,\"quantity\":0.5}"))
        // quantity as 0.5.0 read it (toInt), share as sent.
        assertEquals(0, half.quantity)
        assertEquals(0.5, half.share, 0.0)
        assertEquals(ItemRecipe("r", null, 0, 0.5), half)
        assertFalse(half == ItemRecipe("r", null, 0))
        assertEquals(half.hashCode(), ItemRecipe("r", null, 0, 0.5).hashCode())
        val (id, title, q, share) = half
        assertEquals(listOf<Any?>("r", null, 0, 0.5), listOf(id, title, q, share))
        // copy keeps the share unless the whole quantity changes.
        assertEquals(0.5, half.copy(title = "T").share, 0.0)
        assertEquals(3.0, half.copy(quantity = 3).share, 0.0)
        assertEquals(ItemRecipe("r", null, 0, 0.25), half.copy(share = 0.25))
        assertEquals(ItemRecipe("r", null, Int.MAX_VALUE, 3.0e9), ItemRecipe.fromJson(JSONObject("{\"id\":\"r\",\"quantity\":3000000000}")))
    }

    /** The TS guard's round 8 form rules, ported (the reference copy is generated from guard.ts). */
    @Test fun guardJudgesFormsInTheCapturePhaseAndOnlyPreventsTheDefault() {
        assertTrue(GUARD_SCRIPT.contains("addEL(t, 'submit', onSubmit, true)"))
        assertFalse(GUARD_SCRIPT.contains("onSubmit, false"))
        assertFalse(GUARD_SCRIPT.contains("stopImmediatePropagation"))
        assertFalse(GUARD_SCRIPT.contains("stopPropagation(") || GUARD_SCRIPT.contains("'stopPropagation'"))
        assertTrue(GUARD_SCRIPT.contains("attrOf(form, 'action') !== null"))
        assertTrue(GUARD_SCRIPT.contains("attrOf(submitter, 'formaction')"))
        assertTrue(GUARD_SCRIPT.contains("FE.prototype.requestSubmit = function (by)"))
    }
}
