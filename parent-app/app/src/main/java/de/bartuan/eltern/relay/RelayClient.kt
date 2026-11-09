package de.bartuan.eltern.relay

import java.io.IOException
import java.security.SecureRandom

const val DEFAULT_SERVER = "https://ntfy.sh"
const val DEFAULT_DB = "https://textdb.dev/api/data"

sealed class Fetch {
    class Ok(val status: Status, val fetchedAtMs: Long) : Fetch()
    /** Der PC hat noch nichts veröffentlicht (Schlüssel leer / nicht vorhanden). */
    object NoData : Fetch()
    /** Es kam etwas an, das mit diesem Schlüssel nicht lesbar ist (falscher Code / PC neu gekoppelt). */
    object BadData : Fetch()
    class Unreachable(val reason: String) : Fetch()
}

sealed class SendResult {
    class Sent(val id: String) : SendResult()
    class Failed(val reason: String) : SendResult()
}

object Commands {
    private val rnd = SecureRandom()
    private const val ALPHA = "abcdefghijklmnopqrstuvwxyz0123456789"
    const val MAX_BYTES = 4096

    fun newId(nowMs: Long = System.currentTimeMillis()): String =
        "a" + java.lang.Long.toString(nowMs / 1000, 36) + (1..6).map { ALPHA[rnd.nextInt(ALPHA.length)] }.joinToString("")

    /** Befehls-Klartext; reset_used gibt es absichtlich nicht. */
    fun build(id: String, action: String, user: String?, minutes: Int?, pin: String?, days: List<DayRule>?): String {
        val m = linkedMapOf<String, Any?>("v" to 1, "id" to id, "action" to action)
        if (!user.isNullOrBlank()) m["user"] = user
        if (minutes != null) m["minutes"] = minutes
        if (pin != null) m["pin"] = pin
        if (days != null) m["days"] = days.map { it.toJson() }
        return Json.write(m)
    }
}

class RelayClient(
    private val pairing: Pairing,
    private val server: String = DEFAULT_SERVER,
    private val dbBase: String = DEFAULT_DB,
    private val http: Http = UrlConnectionHttp,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    fun fetchStatus(): Fetch {
        val now = clock()
        val url = "${dbBase.trimEnd('/')}/${pairing.dbKey}?t=$now"
        val r = try {
            http.request("GET", url, mapOf("Cache-Control" to "no-cache"), null)
        } catch (e: IOException) {
            return Fetch.Unreachable("Keine Internetverbindung")
        } catch (e: IllegalArgumentException) {
            return Fetch.Unreachable("Server-Adresse ungültig")
        }
        if (r.code == 404) return Fetch.NoData
        if (!r.ok) return Fetch.Unreachable("Server antwortet mit Fehler ${r.code}")
        val text = r.text.trim()
        if (text.isEmpty()) return Fetch.NoData
        val plain = StlCrypto.open(pairing.key, text) ?: return Fetch.BadData
        val st = StatusParser.parse(plain) ?: return Fetch.BadData
        return Fetch.Ok(st, now)
    }

    /** Verschlüsselt und sendet einen Befehl. Die Antwort des PCs steht später in last_cmds des Status. */
    fun send(action: String, user: String?, minutes: Int?, pin: String?, days: List<DayRule>?, id: String = Commands.newId(clock())): SendResult {
        val envelope = StlCrypto.seal(pairing.key, Commands.build(id, action, user, minutes, pin, days))
        if (envelope.toByteArray().size >= Commands.MAX_BYTES) return SendResult.Failed("Befehl zu groß")
        return try {
            val r = http.request("POST", "${server.trimEnd('/')}/${pairing.topic}",
                mapOf("Tags" to "stl-cmd", "Content-Type" to "text/plain"), envelope.toByteArray())
            if (r.ok) SendResult.Sent(id) else SendResult.Failed("Server antwortet mit Fehler ${r.code}")
        } catch (e: IOException) {
            SendResult.Failed("Keine Internetverbindung")
        } catch (e: IllegalArgumentException) {
            SendResult.Failed("Server-Adresse ungültig")
        }
    }
}
