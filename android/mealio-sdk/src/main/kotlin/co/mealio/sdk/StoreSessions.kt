package co.mealio.sdk

import android.content.Context
import android.webkit.CookieManager
import android.webkit.WebStorage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlin.coroutines.resume

// The user's store logins live in CookieManager and WebStorage. Signing out
// clears them and bumps a device "epoch" that hello sends, so the server knows
// any session it remembers for this device is gone too.

internal class StoreSessions(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun epoch(): Int = prefs.getInt(KEY_EPOCH, 0)

    @Synchronized
    fun bumpEpoch(): Int {
        val next = epoch() + 1
        prefs.edit().putInt(KEY_EPOCH, next).apply()
        return next
    }

    /**
     * Remove cookies and web storage for a store's hosts and auth hosts.
     *
     * CookieManager has no "remove cookies for this domain" call, so each cookie
     * it reports for the host (and its www. subdomain) is overwritten with an
     * expired copy, as a host-only cookie and as a domain cookie.
     * VERIFY: cookies set with a Path other than "/" or on other subdomains are
     * not reachable this way; signOutOfAllStores clears everything.
     */
    suspend fun clearStore(hosts: StoreHosts) = withContext(Dispatchers.Main) {
        val cm = CookieManager.getInstance()
        val storage = WebStorage.getInstance()
        for (host in (hosts.hosts + hosts.authHosts).distinct()) {
            val names = if (host.startsWith("www.")) listOf(host) else listOf(host, "www.$host")
            for (h in names) {
                val url = "https://$h/"
                val jar = cm.getCookie(url)
                if (!jar.isNullOrEmpty()) {
                    for (pair in jar.split(';')) {
                        val name = pair.substringBefore('=').trim()
                        if (name.isEmpty()) continue
                        val dead = "$name=; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Path=/; Secure"
                        cm.setCookie(url, dead)
                        cm.setCookie(url, "$dead; Domain=$host")
                        if (h != host) cm.setCookie(url, "$dead; Domain=$h")
                    }
                }
                storage.deleteOrigin("https://$h")
            }
        }
        cm.flush()
    }

    /**
     * Remove every cookie and all web storage in this app's WebViews. This is
     * process-wide: it also signs the user out of any other WebView in the app.
     */
    suspend fun clearAll() = withContext(Dispatchers.Main) {
        val cm = CookieManager.getInstance()
        suspendCancellableCoroutine<Unit> { cont ->
            cm.removeAllCookies { if (cont.isActive) cont.resume(Unit) }
        }
        WebStorage.getInstance().deleteAllData()
        cm.flush()
    }

    companion object {
        private const val PREFS = "co.mealio.sdk"
        private const val KEY_EPOCH = "store_epoch"
    }
}
