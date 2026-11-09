package co.mealio.sdk

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * 0.6 round 7, native blocking hosts: the store's hosts and its store-owned
 * sign-in hosts, never a shared identity provider. Reads
 * protocol/shared-identity-hosts.json from the repo (not a copy), so the list
 * here cannot drift from it.
 */
class SharedIdentityHostsTest {
    private val file: JSONObject by lazy {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (dir != null) {
            val f = File(dir, "protocol/shared-identity-hosts.json")
            if (f.isFile) return@lazy JSONObject(f.readText())
            dir = dir.parentFile
        }
        error("protocol/shared-identity-hosts.json not found")
    }

    @Test fun theListIsTheProtocolFile() {
        val a = file.getJSONArray("hosts")
        assertEquals((0 until a.length()).map { a.getString(it) }, SHARED_IDENTITY_HOSTS)
    }

    @Test fun excludedVectors() {
        val v = file.getJSONObject("vectors").getJSONArray("excluded").objects()
        assertTrue(v.size > 20)
        for (c in v) {
            val store = c.getString("store")
            val names = storeNames(Allowlist().hostsFor(store)!!)
            assertEquals("$store ${c.getString("host")}", c.getBoolean("excluded"), sharedIdentityHost(c.getString("host"), names))
        }
    }

    @Test fun blockHostsVectors() {
        for (c in file.getJSONObject("vectors").getJSONArray("blockHosts").objects()) {
            val store = c.getString("store")
            val al = Allowlist()
            c.optJSONObject("widen")?.let { w ->
                val auth = w.optJSONArray("authHosts")?.let { a -> (0 until a.length()).map { a.getString(it) } } ?: emptyList()
                val hosts = w.optJSONArray("hosts")?.let { a -> (0 until a.length()).map { a.getString(it) } } ?: emptyList()
                al.widen(AllowlistPayload(1, 4102444800.0, mapOf(store to StoreHostsPatch(hosts, auth))))
            }
            val want = c.getJSONArray("blockHosts").let { a -> (0 until a.length()).map { a.getString(it) } }
            assertEquals(store, want, blockHostsFor(al, store))
        }
    }

    /** Wired through: an armed block refuses checkout on store-owned sign-in hosts, never on a shared provider. */
    @Test fun armedBlockCoversStoreSignInHostsOnly() {
        val kroger = NetworkBlock().apply { arm(blockHostsFor(Allowlist(), "ralphs")) }
        assertTrue(kroger.blocks("https://www.kroger.com/checkout"))
        assertTrue(kroger.blocks("https://login.kroger.com/payment"))
        assertFalse(kroger.blocks("https://accounts.google.com/payment"))
        val safeway = NetworkBlock().apply { arm(blockHostsFor(Allowlist(), "safeway")) }
        assertTrue(safeway.blocks("https://www.safeway.com/checkout"))
        assertTrue(safeway.blocks("https://www.albertsons.com/abs/pub/checkout"))
        assertTrue(safeway.blocks("https://albertsons.okta.com/payment"))
        assertFalse(safeway.blocks("https://login.okta.com/payment"))
        assertFalse(safeway.blocks("https://kroger.okta.com/payment"))
        val wegmans = NetworkBlock().apply { arm(blockHostsFor(Allowlist(), "wegmans")) }
        assertTrue(wegmans.blocks("https://shop.wegmans.com/checkout"))
        assertFalse(wegmans.blocks("https://contoso.b2clogin.com/payment"))
        assertFalse(wegmans.blocks("https://login.microsoftonline.com/payment"))
    }
}
