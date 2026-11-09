package co.mealio.sdk

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** 0.6 round 6, item 1 (revised in round 7): the decision behind native network blocking. */
class NetworkBlockTest {
    @Test fun blockedPathsAreRecognised() {
        for (u in listOf(
            "https://www.heb.com/checkout",
            "https://www.heb.com/Checkout/step2",
            "https://www.heb.com/%63heckout",
            "https://www.heb.com/%2563heckout",
            "https://www.heb.com/api?next=payment",
            "https://www.heb.com/place-order",
            "https://www.heb.com/cart/confirm",
            "https://www.heb.com/orders/submit",
            "https://www.heb.com/purchase?x=1",
            "https://www.heb.com/account/password",
            "https://www.heb.com/addresses/new",
            "https://www.heb.com/gift-card",
            "http://www.heb.com/billing",
            "wss://www.heb.com/checkout/socket",
            "https://user:pw@www.heb.com/checkout",
        )) assertTrue(u, requestBlocked(u))
    }

    @Test fun otherPathsPass() {
        for (u in listOf(
            null, "", "about:blank", "data:text/html,checkout", "blob:https://www.heb.com/checkout-uuid",
            "javascript:checkout()",
            "https://www.heb.com/",
            "https://www.heb.com",
            "https://www.heb.com/search?q=milk",
            "https://www.heb.com/help#checkout",
            "https://checkout.heb.com/",
            "https://www.heb.com/orders/submitted-list",
        )) assertFalse(u.toString(), requestBlocked(u))
    }

    /** Every allowlist vector the SDK refuses for its path is refused on the wire too, once armed for its store. */
    @Test fun agreesWithTheAllowlistVectors() {
        var n = 0
        for (c in Vectors.json.getJSONArray("allowlist").objects()) {
            val url = c.getString("url")
            val use = UrlUse.values().first { it.name.equals(c.getString("use"), ignoreCase = true) }
            if (Allowlist().check(c.getString("store"), url, use).reason == "blocked_path") {
                n++
                val b = NetworkBlock().apply { arm(blockHostsFor(Allowlist(), c.getString("store"))) }
                assertTrue(url, requestBlocked(url))
                assertTrue(url, b.blocks(url))
            }
        }
        assertTrue("vectors with a blocked path", n > 0)
    }

    @Test fun offUntilArmed() {
        val b = NetworkBlock()
        assertFalse(b.armed)
        // The store's own boot requests before Mealio's first script go through.
        assertFalse(b.blocks("https://www.heb.com/checkout"))
        assertFalse(b.blocks("https://api.heb.com/graphql/payment"))
        b.arm(blockHostsFor(Allowlist(), "heb"))
        assertTrue(b.armed)
        assertTrue(b.blocks("https://www.heb.com/checkout"))
        assertTrue(b.blocks("https://api.heb.com/graphql/payment"))
        assertTrue(b.blocks("https://heb.com/place-order"))
        assertFalse(b.blocks("https://www.heb.com/search?q=milk"))
        b.disarm()
        assertFalse(b.blocks("https://www.heb.com/checkout"))
    }

    @Test fun thirdPartyHostsAreNeverBlocked() {
        val b = NetworkBlock()
        for (armed in listOf(false, true)) {
            if (armed) b.arm(blockHostsFor(Allowlist(), "heb"))
            for (u in listOf(
                "https://js.stripe.com/v3/payment",
                "https://pay.thirdparty.example/wallet/frame",
                "https://www.google.com/recaptcha/payment",
                "https://notheb.com/checkout",
                "https://heb.com.evil.example/checkout",
                "https://www.heb.com:x@evil.example/checkout",
                "https://www.heb.com@evil.example/checkout",
            )) assertFalse("$u armed=$armed", b.blocks(u))
        }
    }

    @Test fun onlyTheCurrentStoresHosts() {
        val b = NetworkBlock().apply { arm(blockHostsFor(Allowlist(), "safeway")) }
        assertTrue(b.blocks("https://www.safeway.com/checkout"))
        // Sign-in hosts are not blocked: they are often shared providers.
        assertFalse(b.blocks("https://www.albertsons.com/payment"))
        // Another store's host is not this store's.
        assertFalse(b.blocks("https://www.heb.com/checkout"))
        // The store changes: arming again replaces the hosts.
        b.arm(blockHostsFor(Allowlist(), "heb"))
        assertFalse(b.blocks("https://www.safeway.com/checkout"))
        assertTrue(b.blocks("https://www.heb.com/checkout"))
    }

    @Test fun readsTheHostABrowserSendsTo() {
        assertEquals("www.heb.com", requestHost("https://WWW.HEB.COM./checkout"))
        assertEquals("www.heb.com", requestHost("https://www.heb.com:443/x"))
        assertEquals("evil.example", requestHost("https://www.heb.com:x@evil.example/checkout"))
        assertNull(requestHost("data:text/html,checkout"))
        assertNull(requestHost("about:blank"))
    }

    @Test fun signedWideningIsCovered() {
        val a = Allowlist()
        a.widen(AllowlistPayload(1, 0.0, mapOf("aldi" to StoreHostsPatch(hosts = listOf("shop.aldi.us")))))
        assertTrue(blockHostsFor(a, "aldi").contains("shop.aldi.us"))
        // A widened sign-in host is not a store host.
        a.widen(AllowlistPayload(1, 0.0, mapOf("aldi" to StoreHostsPatch(authHosts = listOf("aldi.instacart.com")))))
        assertFalse(blockHostsFor(a, "aldi").contains("aldi.instacart.com"))
        assertTrue(blockHostsFor(Allowlist(), "nope").isEmpty())
    }

    /** The runner hands the login page its allowlist's hosts, widenings included. */
    @Test fun runnerPassesTheStoreHostsToTheLoginPage(): Unit = kotlinx.coroutines.runBlocking {
        var login: LoginRequest? = null
        val host = object : Host by FakeHost() {
            override suspend fun showLogin(request: LoginRequest): LoginResult {
                login = request
                return LoginResult(LoginOutcome.SIGNED_IN, emptyList())
            }
        }
        val a = Allowlist()
        a.widen(AllowlistPayload(1, 0.0, mapOf("heb" to StoreHostsPatch(hosts = listOf("api.heb.com")))))
        val env = TestSigner.instructions(1, listOf(showLoginOp("l1", "https://www.heb.com/my-account/login")))
        Runner(host, a, Vectors.keys).run(env, "job_test", 0)
        assertEquals(listOf("heb.com", "api.heb.com"), login!!.blockHosts)
    }
}
