package co.mealio.sdk.compose

import android.graphics.BitmapFactory
import android.util.LruCache
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.net.HttpURLConnection
import java.net.URL

// A tiny product-image loader, so the drop-in pulls in no image library.
// https only, downsampled to thumbnail size, kept in a small memory cache.
// These requests carry no store cookies (HttpURLConnection has no cookie
// handler of ours).

private val cache = LruCache<String, ImageBitmap>(80)

private const val MAX_EDGE_PX = 320

@Composable
internal fun rememberProductImage(url: String?): ImageBitmap? {
    val img by produceState(initialValue = url?.let { cache.get(it) }, url) {
        if (url == null || value != null) return@produceState
        value = withContext(Dispatchers.IO) { load(url) }
    }
    return img
}

private fun load(url: String): ImageBitmap? {
    if (!url.startsWith("https://")) return null
    return try {
        val c = URL(url).openConnection() as HttpURLConnection
        try {
            c.connectTimeout = 10_000
            c.readTimeout = 15_000
            c.instanceFollowRedirects = true
            if (c.responseCode !in 200..299) return null
            val bytes = c.inputStream.use { it.readBytes() }
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            var sample = 1
            while (bounds.outWidth / (sample * 2) >= MAX_EDGE_PX && bounds.outHeight / (sample * 2) >= MAX_EDGE_PX) sample *= 2
            val bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })
                ?: return null
            bmp.asImageBitmap().also { cache.put(url, it) }
        } finally {
            c.disconnect()
        }
    } catch (e: Exception) {
        null
    }
}
