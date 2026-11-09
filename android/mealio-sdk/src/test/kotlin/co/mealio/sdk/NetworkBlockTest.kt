package co.mealio.sdk

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** 0.6 round 6, item 1: the decision behind native network blocking. */
class NetworkBlockTest {
    @Test fun blockedPathsOnAnyHostAreRefused() {
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
            "https://pay.thirdparty.example/wallet/frame",
            "http://www.heb.com/billing",
            "wss://www.heb.com/checkout/socket",
            "https://user:pw@www.heb.com/checkout",
        )) assertTrue(u, requestBlocked(u))
    }

    @Test fun otherRequestsPass() {
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

    /** Every allowlist vector the SDK refuses for its path is refused on the wire too. */
    @Test fun agreesWithTheAllowlistVectors() {
        var n = 0
        for (c in Vectors.json.getJSONArray("allowlist").objects()) {
            val url = c.getString("url")
            val use = UrlUse.values().first { it.name.equals(c.getString("use"), ignoreCase = true) }
            if (Allowlist().check(c.getString("store"), url, use).reason == "blocked_path") {
                n++
                assertTrue(url, requestBlocked(url))
            }
        }
        assertTrue("vectors with a blocked path", n > 0)
    }

    @Test fun serviceWorkerRequestsAreJudgedOnStoreDomainsOnly() {
        assertTrue(serviceWorkerRequestBlocked("https://www.heb.com/checkout"))
        assertTrue(serviceWorkerRequestBlocked("https://api.heb.com/graphql/payment"))
        assertFalse(serviceWorkerRequestBlocked("https://www.heb.com/search"))
        // The service worker client is process-wide: the app's own pages are left alone.
        assertFalse(serviceWorkerRequestBlocked("https://partner.example/checkout"))
        assertEquals(true, serviceWorkerRequestBlocked("https://www.heb.com:x@evil/checkout"))
    }
}
