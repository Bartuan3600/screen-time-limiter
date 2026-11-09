package de.bartuan.eltern.relay

import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Format wie in PROTOCOL_RELAY.md (gleich wie beim Ausgaben-Scan-Protokoll):
 * AES-256-GCM, 12-Byte-IV (zufällig, pro Nachricht neu), 128-Bit-Tag hinten an den Chiffretext gehängt, kein AAD.
 * Umschlag: {"enc":"aes-256-gcm","iv":"<b64>","data":"<b64 chiffretext||tag>"}.
 * Schlüsselmaterial wird nie geloggt.
 */
object StlCrypto {
    const val ALG = "aes-256-gcm"
    private val random = SecureRandom()

    fun newIv(): ByteArray = ByteArray(12).also { random.nextBytes(it) }

    fun sha256(b: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(b)

    fun hex(b: ByteArray): String = b.joinToString("") { "%02x".format(it) }

    fun hmacHex(key: ByteArray, label: String): String {
        val m = Mac.getInstance("HmacSHA256")
        m.init(SecretKeySpec(key, "HmacSHA256"))
        return hex(m.doFinal(label.toByteArray(Charsets.UTF_8)))
    }

    fun seal(key: ByteArray, plaintext: String, iv: ByteArray = newIv()): String {
        require(key.size == 32 && iv.size == 12)
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, iv))
        val ct = c.doFinal(plaintext.toByteArray(Charsets.UTF_8))
        val b64 = Base64.getEncoder()
        return Json.write(linkedMapOf("enc" to ALG, "iv" to b64.encodeToString(iv), "data" to b64.encodeToString(ct)))
    }

    /** Klartext oder null (kein gültiger Umschlag, falscher Schlüssel, manipuliert). */
    fun open(key: ByteArray, envelope: String): String? = try {
        val o = org.json.JSONObject(envelope.trim())
        if (o.optString("enc") != ALG) null else {
            val d = Base64.getDecoder()
            val c = Cipher.getInstance("AES/GCM/NoPadding")
            c.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, d.decode(o.getString("iv"))))
            String(c.doFinal(d.decode(o.getString("data"))), Charsets.UTF_8)
        }
    } catch (e: Exception) {
        null
    }
}
