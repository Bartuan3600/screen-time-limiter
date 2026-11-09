package de.bartuan.eltern.relay

import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneOffset

val DAY_NAMES = listOf("Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag", "Sonntag")

data class DayRule(
    val mode: String,            // limit | blocked | unlimited
    val limitMinutes: Int,
    val windowEnabled: Boolean,
    val windowStart: String,     // HH:mm
    val windowEnd: String,
) {
    fun toJson(): Map<String, Any?> = linkedMapOf(
        "mode" to mode, "limit_minutes" to limitMinutes, "window_enabled" to windowEnabled,
        "window_start" to windowStart, "window_end" to windowEnd,
    )

    /** null = gültig, sonst Fehlertext (gleiche Regeln wie Test-StlDayRule am PC). */
    fun validate(dayName: String): String? {
        if (mode != "limit" && mode != "blocked" && mode != "unlimited") return "$dayName: unbekannter Modus."
        if (mode == "limit" && limitMinutes !in 1..1440) return "$dayName: Das Limit muss zwischen 1 Minute und 24 Stunden liegen."
        if (windowEnabled && mode != "blocked") {
            val s = minuteOfDay(windowStart)
            val e = minuteOfDay(windowEnd)
            if (s == null || e == null) return "$dayName: ungültige Uhrzeit im Zeitfenster."
            if (s == e) return "$dayName: Beginn und Ende des Zeitfensters dürfen nicht gleich sein."
        }
        return null
    }

    companion object {
        fun minuteOfDay(t: String): Int? {
            val m = Regex("^([01]?\\d|2[0-3]):([0-5]\\d)$").matchEntire(t.trim()) ?: return null
            return m.groupValues[1].toInt() * 60 + m.groupValues[2].toInt()
        }
        fun fromJson(o: JSONObject) = DayRule(
            mode = o.optString("mode", "limit"),
            limitMinutes = o.optInt("limit_minutes", 0),
            windowEnabled = o.optBoolean("window_enabled", false),
            windowStart = o.optString("window_start", "16:00"),
            windowEnd = o.optString("window_end", "20:00"),
        )
    }
}

data class UserStatus(
    val name: String,
    val session: String,         // active | locked | disconnected | none
    val usedSeconds: Int,
    val remainingSeconds: Int?,  // null = unbegrenzt
    val bonusMinutes: Int,
    val unlimitedToday: Boolean,
    val blockedToday: Boolean,
    val rule: String,
    val lockReason: String?,
)

data class CmdResult(val id: String, val ok: Boolean, val msg: String, val t: Instant?)

data class Status(
    val t: Instant,
    val day: String,
    val todayIndex: Int,
    val users: List<UserStatus>,
    val plan: List<DayRule>,
    val lastCmds: List<CmdResult>,
    val lockedUntil: Instant?,
)

object StatusParser {
    fun parseInstant(s: String?): Instant? {
        if (s.isNullOrBlank()) return null
        return try { Instant.parse(s) } catch (e: Exception) {
            try { OffsetDateTime.parse(s).toInstant() } catch (e2: Exception) {
                try { LocalDateTime.parse(s).toInstant(ZoneOffset.UTC) } catch (e3: Exception) { null }
            }
        }
    }

    private fun arr(o: JSONObject, name: String): List<JSONObject> {
        val v = o.opt(name)
        return when (v) {
            is JSONArray -> (0 until v.length()).mapNotNull { v.optJSONObject(it) }
            is JSONObject -> listOf(v)     // PowerShell 5.1 macht aus Ein-Element-Listen manchmal ein Objekt
            else -> emptyList()
        }
    }

    /** null, wenn kein gültiger Status (falsche Version / Zeit fehlt). */
    fun parse(json: String): Status? {
        return try {
            val o = JSONObject(json)
            val t = parseInstant(o.optString("t"))
            if (o.optInt("v", 0) != 1 || t == null) null else Status(
                t = t,
                day = o.optString("day"),
                todayIndex = o.optInt("today_index", 0).coerceIn(0, 6),
                users = arr(o, "users").map {
                    UserStatus(
                        name = it.optString("name"),
                        session = it.optString("session", "none"),
                        usedSeconds = it.optInt("used_seconds", 0),
                        remainingSeconds = if (it.isNull("remaining_seconds") || !it.has("remaining_seconds")) null else it.optInt("remaining_seconds"),
                        bonusMinutes = it.optInt("bonus_minutes", 0),
                        unlimitedToday = it.optBoolean("unlimited_today", false),
                        blockedToday = it.optBoolean("blocked_today", false),
                        rule = it.optString("rule"),
                        lockReason = if (it.isNull("lock_reason")) null else it.optString("lock_reason").ifBlank { null },
                    )
                },
                plan = arr(o, "plan").map { DayRule.fromJson(it) },
                lastCmds = arr(o, "last_cmds").map {
                    CmdResult(it.optString("id"), it.optBoolean("ok", false), it.optString("msg"), parseInstant(it.optString("t")))
                },
                lockedUntil = if (o.isNull("locked_until")) null else parseInstant(o.optString("locked_until")),
            )
        } catch (e: Exception) {
            null
        }
    }
}
