package de.bartuan.eltern

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import de.bartuan.eltern.relay.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

enum class Conn { Loading, Ok, NoData, BadData, Offline }

data class UiState(
    val paired: Boolean = false,
    val fingerprint: String = "",
    val conn: Conn = Conn.Loading,
    val connDetail: String = "",
    val status: Status? = null,
    val fetchedAtMs: Long = 0,
    val busy: Boolean = false,
    val message: String? = null,
    val pendingId: String? = null,
    val hasSavedPin: Boolean = false,
    val notifyLimit: Boolean = false,
    val server: String = DEFAULT_SERVER,
    val db: String = DEFAULT_DB,
)

class MainViewModel(app: Application) : AndroidViewModel(app) {
    private val settings = AppSettings(app)
    private var client: RelayClient? = null
    private val _ui = MutableStateFlow(UiState())
    val ui: StateFlow<UiState> = _ui.asStateFlow()
    private var fastUntilMs = 0L
    private var wakeNow = false
    private val watcher = LimitWatcher()

    init { reload() }

    private fun reload() {
        val p = settings.pairing()
        client = p?.let { RelayClient(it, settings.server, settings.db) }
        _ui.update {
            UiState(paired = p != null, fingerprint = p?.fingerprint ?: "", hasSavedPin = settings.hasSavedPin,
                notifyLimit = settings.notifyLimit, server = settings.server, db = settings.db)
        }
    }

    /** @return Fehlertext oder null bei Erfolg */
    fun pair(code: String): String? = when (val r = PairingCode.parse(code)) {
        is CodeResult.Error -> r.message
        is CodeResult.Ok -> { settings.savePairing(r.pairing); reload(); null }
    }

    fun unpair() { settings.clearAll(); reload() }

    fun setNotifyLimit(on: Boolean) { settings.notifyLimit = on; _ui.update { it.copy(notifyLimit = on) } }
    fun forgetPin() { settings.clearPin(); _ui.update { it.copy(hasSavedPin = false, message = "Gespeicherte PIN / Passwort gelöscht.") } }
    fun savedPin(): String? = settings.savedPin()
    fun savePin(pin: String) {
        val ok = settings.savePin(pin)
        _ui.update { it.copy(hasSavedPin = ok, message = if (ok) "PIN / Passwort sicher auf diesem Handy gespeichert." else "PIN / Passwort konnte nicht gespeichert werden.") }
    }

    fun saveServers(server: String, db: String): String? {
        if (!server.trim().startsWith("https://") || !db.trim().startsWith("https://")) return "Nur https-Adressen sind erlaubt."
        settings.server = server.trim().trimEnd('/'); settings.db = db.trim().trimEnd('/')
        reload(); return null
    }

    fun consumeMessage() { _ui.update { it.copy(message = null) } }

    /** Läuft, solange die App sichtbar ist: alle 15 s, nach einem Befehl alle 3 s bis zur Antwort. */
    suspend fun pollLoop() {
        while (true) {
            fetchOnce()
            var waited = 0L
            while (waited < (if (System.currentTimeMillis() < fastUntilMs) 3000L else 15000L) && !wakeNow) { delay(250); waited += 250 }
            wakeNow = false
        }
    }

    fun refreshNow() { wakeNow = true }

    /** Ein Aktualisierungsversuch; fordert den PC zusätzlich auf, sofort einen frischen Status zu schreiben. */
    fun refreshWithPing() {
        val c = client ?: return
        viewModelScope.launch {
            withContext(Dispatchers.IO) { c.send("refresh", null, null, null, null) }
            fastUntilMs = System.currentTimeMillis() + 20_000
            wakeNow = true
        }
    }

    private suspend fun fetchOnce() {
        val c = client ?: return
        val r = withContext(Dispatchers.IO) { c.fetchStatus() }
        _ui.update { s ->
            when (r) {
                is Fetch.Ok -> {
                    var msg = s.message
                    var pending = s.pendingId
                    val res = r.status.lastCmds.firstOrNull { it.id == pending }
                    if (res != null) {
                        msg = (if (res.ok) "✓ " else "✗ ") + res.msg
                        pending = null
                        fastUntilMs = 0
                        if (!res.ok && res.msg.startsWith("Falsche PIN") && settings.hasSavedPin) {
                            settings.clearPin()
                            msg += " Das gespeicherte PIN / Passwort wurde gelöscht."
                        }
                    }
                    s.copy(conn = Conn.Ok, connDetail = "", status = r.status, fetchedAtMs = r.fetchedAtMs, message = msg, pendingId = pending,
                        busy = pending != null, hasSavedPin = settings.hasSavedPin)
                }
                is Fetch.NoData -> s.copy(conn = Conn.NoData)
                is Fetch.BadData -> s.copy(conn = Conn.BadData)
                is Fetch.Unreachable -> s.copy(conn = Conn.Offline, connDetail = r.reason)
            }
        }
        // „Befehl gesendet, aber keine Antwort“ nach Ablauf der schnellen Phase
        val st = _ui.value
        if (st.pendingId != null && System.currentTimeMillis() > fastUntilMs) {
            _ui.update { it.copy(busy = false, pendingId = null,
                message = "Befehl gesendet, aber noch keine Antwort vom PC. Ist er an und online? Der Befehl gilt 10 Minuten.") }
        }
    }

    fun send(action: String, user: String?, minutes: Int?, pin: String?, days: List<DayRule>?) {
        val c = client ?: return
        _ui.update { it.copy(busy = true, message = null) }
        viewModelScope.launch {
            when (val r = withContext(Dispatchers.IO) { c.send(action, user, minutes, pin, days) }) {
                is SendResult.Sent -> {
                    fastUntilMs = System.currentTimeMillis() + 60_000
                    _ui.update { it.copy(pendingId = r.id, message = "Gesendet – warte auf den PC …") }
                    wakeNow = true
                }
                is SendResult.Failed -> _ui.update { it.copy(busy = false, message = "Nicht gesendet: ${r.reason}") }
            }
        }
    }

    /** Jede Sekunde vom Bildschirm aufgerufen: meldet (optional) den Moment, in dem das Limit erreicht wird. */
    fun tick(nowMs: Long) {
        val s = _ui.value
        val st = s.status ?: return
        val live = st.users.associate { it.name to (it.session to Logic.liveRemaining(it, st, s.fetchedAtMs, nowMs)) }
        val hits = watcher.check(live)
        if (s.notifyLimit) hits.forEach { Notifier.limitReached(getApplication(), it) }
    }
}
