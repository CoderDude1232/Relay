package app.relaymsg.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import java.net.HttpURLConnection
import java.net.URL
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * A one-line preview of a link in a message.
 *
 * **The fetch is not automatic.** Loading a preview means this device asking
 * the linked server for a page — which tells that server, and anyone watching,
 * that the link was received and roughly when. In a messenger that is a
 * meaningful leak, so previews load only when the user taps to load one.
 *
 * Only the page title is read, from the first kilobytes of HTML. No images, no
 * sub-resources, no scripts: a title is the useful part and everything else
 * multiplies both the traffic and the disclosure.
 */
object LinkPreview {

    /** Per-process, so a title survives scrolling without refetching. */
    private val cache = object : LinkedHashMap<String, String>(0, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, String>) = size > 200
    }

    private val urlPattern = Regex("""https?://[^\s<>"]+""")

    /** The first link in a message, if there is one. */
    fun firstUrl(body: String): String? = urlPattern.find(body)?.value

    fun cached(url: String): String? = synchronized(cache) { cache[url] }

    suspend fun title(url: String): String? {
        cached(url)?.let { return it }
        val fetched = withContext(Dispatchers.IO) { fetchTitle(url) } ?: return null
        synchronized(cache) { cache[url] = fetched }
        return fetched
    }

    private fun fetchTitle(url: String): String? = runCatching {
        val connection = (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            instanceFollowRedirects = true
            connectTimeout = 6_000
            readTimeout = 6_000
            // A generic agent: the app's own would announce Relay to every site
            // anyone ever links to.
            setRequestProperty("User-Agent", "Mozilla/5.0")
            setRequestProperty("Accept", "text/html")
        }
        connection.use {
            if (it.responseCode !in 200..299) return null
            // A title lives in <head>; reading the whole page would be
            // unbounded for the sake of one tag.
            val head = ByteArray(HEAD_BYTES)
            val read = it.inputStream.read(head)
            if (read <= 0) return null
            val html = String(head, 0, read, Charsets.UTF_8)
            Regex("""<title[^>]*>(.*?)</title>""", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL))
                .find(html)
                ?.groupValues
                ?.get(1)
                ?.replace(Regex("""\s+"""), " ")
                ?.trim()
                ?.take(140)
                ?.takeIf { title -> title.isNotEmpty() }
        }
    }.getOrNull()

    private const val HEAD_BYTES = 32 * 1024

    private inline fun <T> HttpURLConnection.use(block: (HttpURLConnection) -> T): T =
        try {
            block(this)
        } finally {
            disconnect()
        }
}

/**
 * The preview card under a message.
 *
 * Shows the host immediately — that costs nothing and is what most people
 * actually want to check — and fetches the title only when asked.
 */
@Composable
fun LinkPreviewCard(url: String, onBlack: Boolean) {
    val context = LocalContext.current
    var title by remember(url) { mutableStateOf(LinkPreview.cached(url)) }
    var loading by remember(url) { mutableStateOf(false) }
    val ink = if (onBlack) Color.White else MaterialTheme.colorScheme.onSurface

    LaunchedEffect(loading) {
        if (loading) {
            title = LinkPreview.title(url)
            loading = false
        }
    }

    Column(
        Modifier
            .fillMaxWidth()
            .padding(top = 6.dp)
            .background(ink.copy(alpha = 0.10f), RoundedCornerShape(10.dp))
            .clickable {
                if (title == null) {
                    loading = true
                } else {
                    runCatching {
                        context.startActivity(
                            android.content.Intent(
                                android.content.Intent.ACTION_VIEW,
                                android.net.Uri.parse(url),
                            ),
                        )
                    }
                }
            }
            .padding(horizontal = 10.dp, vertical = 8.dp),
    ) {
        Text(
            text = title ?: runCatching { URL(url).host }.getOrNull() ?: url,
            style = MaterialTheme.typography.bodyMedium,
            color = ink,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            text = when {
                loading -> "Loading…"
                // Said outright, because the trade is not obvious: loading a
                // preview tells that site the link reached you.
                title == null -> "Tap to load preview"
                else -> "Tap to open"
            },
            style = MaterialTheme.typography.labelSmall,
            color = ink.copy(alpha = 0.7f),
        )
    }
}
