package de.bartuan.eltern

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import de.bartuan.eltern.relay.DEFAULT_DB
import de.bartuan.eltern.relay.DEFAULT_SERVER
import de.bartuan.eltern.relay.Pairing
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Einstellungen nur lokal (SharedPreferences, nicht im Android-Backup: allowBackup=false).
 * Der Kopplungsschlüssel wird nie angezeigt oder geloggt. Eine PIN wird NUR gespeichert, wenn die Eltern es ausdrücklich wollen
 * (Keystore-AES-Schlüssel, nicht auslesbar für andere Apps).
 */
class AppSettings(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences("eltern_settings", Context.MODE_PRIVATE)

    fun pairing(): Pairing? {
        val b = prefs.getString("key_b64", null) ?: return null
        val key = runCatching { Base64.decode(b, Base64.NO_WRAP) }.getOrNull() ?: return null
        return if (key.size == 32) Pairing(key) else null
    }

    fun savePairing(p: Pairing) { prefs.edit().putString("key_b64", Base64.encodeToString(p.key, Base64.NO_WRAP)).apply() }

    /** „Kopplung entfernen“: Schlüssel, gespeicherte PIN, Server-Overrides weg. */
    fun clearAll() {
        PinVault.clear(prefs)
        prefs.edit().clear().apply()
    }

    var server: String
        get() = prefs.getString("server", null) ?: DEFAULT_SERVER
        set(v) { prefs.edit().putString("server", v).apply() }
    var db: String
        get() = prefs.getString("db", null) ?: DEFAULT_DB
        set(v) { prefs.edit().putString("db", v).apply() }
    var notifyLimit: Boolean
        get() = prefs.getBoolean("notify_limit", false)
        set(v) { prefs.edit().putBoolean("notify_limit", v).apply() }

    val hasSavedPin: Boolean get() = prefs.contains("pin_enc")
    fun savedPin(): String? = PinVault.load(prefs)
    fun savePin(pin: String): Boolean = PinVault.save(prefs, pin)
    fun clearPin() = PinVault.clear(prefs)
}

object PinVault {
    private const val ALIAS = "eltern_pin_v1"
    private const val PROVIDER = "AndroidKeyStore"

    private fun key(create: Boolean): SecretKey? {
        val ks = KeyStore.getInstance(PROVIDER).apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        if (!create) return null
        val g = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, PROVIDER)
        g.init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256).build())
        return g.generateKey()
    }

    fun save(prefs: android.content.SharedPreferences, pin: String): Boolean = try {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, key(true))
        val ct = c.doFinal(pin.toByteArray(Charsets.UTF_8))
        prefs.edit().putString("pin_enc", Base64.encodeToString(c.iv, Base64.NO_WRAP) + ":" + Base64.encodeToString(ct, Base64.NO_WRAP)).apply()
        true
    } catch (e: Exception) { false }

    fun load(prefs: android.content.SharedPreferences): String? {
        return try {
            val parts = (prefs.getString("pin_enc", null) ?: return null).split(":")
            val c = Cipher.getInstance("AES/GCM/NoPadding")
            c.init(Cipher.DECRYPT_MODE, key(false) ?: return null, GCMParameterSpec(128, Base64.decode(parts[0], Base64.NO_WRAP)))
            String(c.doFinal(Base64.decode(parts[1], Base64.NO_WRAP)), Charsets.UTF_8)
        } catch (e: Exception) { null }
    }

    fun clear(prefs: android.content.SharedPreferences) {
        prefs.edit().remove("pin_enc").apply()
        runCatching { KeyStore.getInstance(PROVIDER).apply { load(null) }.deleteEntry(ALIAS) }
    }
}
