package de.bartuan.eltern.relay

import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

class HttpResult(val code: Int, val body: ByteArray) {
    val text: String get() = String(body, Charsets.UTF_8)
    val ok: Boolean get() = code in 200..299
}

/** Winzige HTTP-Abstraktion, damit der Relay-Ablauf ohne Netz getestet werden kann. */
fun interface Http {
    @Throws(IOException::class)
    fun request(method: String, url: String, headers: Map<String, String>, body: ByteArray?): HttpResult
}

object UrlConnectionHttp : Http {
    override fun request(method: String, url: String, headers: Map<String, String>, body: ByteArray?): HttpResult {
        require(url.startsWith("https://")) { "Nur https ist erlaubt." }
        val c = URL(url).openConnection() as HttpURLConnection
        try {
            c.requestMethod = method
            c.connectTimeout = 10_000
            c.readTimeout = 15_000
            c.useCaches = false
            headers.forEach { (k, v) -> c.setRequestProperty(k, v) }
            if (body != null) {
                c.doOutput = true
                c.setFixedLengthStreamingMode(body.size)
                c.outputStream.use { it.write(body) }
            }
            val code = c.responseCode
            val stream = if (code >= 400) c.errorStream else c.inputStream
            return HttpResult(code, stream?.use { it.readBytes() } ?: ByteArray(0))
        } finally {
            c.disconnect()
        }
    }
}
