package de.bartuan.eltern.relay

/** Aus dem 32-Byte-Schlüssel abgeleitete Adressen (nur lokal berechnet, nie übertragen). */
class Pairing(val key: ByteArray) {
    init { require(key.size == 32) }
    val topic: String = "stl-" + StlCrypto.hmacHex(key, "stl-topic-v1").substring(0, 24)
    val dbKey: String = "stl-" + StlCrypto.hmacHex(key, "stl-status-v1").substring(0, 24)
    /** Erste 8 Hex-Zeichen von SHA-256(Schlüssel): nicht geheim, zum Vergleich mit dem PC. */
    val fingerprint: String = StlCrypto.hex(StlCrypto.sha256(key)).substring(0, 8)
    val code: String get() = PairingCode.format(key)
}

sealed class CodeResult {
    class Ok(val pairing: Pairing) : CodeResult()
    class Error(val message: String) : CodeResult()
}

/** STL1-XXXX-…(13 Gruppen)-PRÜF, Groß-/Kleinschreibung egal, Leerzeichen/Bindestriche beliebig. */
object PairingCode {
    const val PREFIX = "STL1"

    private fun check(key: ByteArray): String = Base32.encode(StlCrypto.sha256(key).copyOfRange(0, 4)).substring(0, 4)

    fun format(key: ByteArray): String =
        PREFIX + "-" + Base32.encode(key).chunked(4).joinToString("-") + "-" + check(key)

    fun parse(input: String): CodeResult {
        val c = input.uppercase().filter { it.isLetterOrDigit() }
        if (!c.startsWith(PREFIX)) return CodeResult.Error("Der Code muss mit STL1 beginnen.")
        val body = c.substring(PREFIX.length)
        if (body.length != 56) return CodeResult.Error("Der Code ist unvollständig oder zu lang (erwartet: 56 Zeichen nach STL1).")
        val key = Base32.decode(body.substring(0, 52)) ?: return CodeResult.Error("Der Code enthält ein ungültiges Zeichen (erlaubt: A–Z und 2–7).")
        if (key.size != 32) return CodeResult.Error("Der Code ist ungültig.")
        if (body.substring(52) != check(key)) return CodeResult.Error("Tippfehler im Code (Prüfsumme stimmt nicht). Bitte noch einmal vergleichen.")
        return CodeResult.Ok(Pairing(key))
    }
}
