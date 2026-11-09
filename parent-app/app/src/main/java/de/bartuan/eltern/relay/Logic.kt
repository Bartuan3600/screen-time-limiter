package de.bartuan.eltern.relay

/** Reine Anzeige-Logik (ohne Android), damit sie als JVM-Test prüfbar ist. */
object Logic {
    /** Der PC meldet sich mindestens alle 90 s (bei Netzproblemen bis 5 Min.). Älter als das = nicht erreichbar. */
    const val STALE_SECONDS = 210L

    fun ageSeconds(status: Status, nowMs: Long): Long = ((nowMs - status.t.toEpochMilli()) / 1000).coerceAtLeast(0)

    fun isStale(status: Status, nowMs: Long): Boolean = ageSeconds(status, nowMs) > STALE_SECONDS

    /**
     * Restzeit „live“: bei laufender Sitzung zählt die App seit dem Status herunter (max. 2 Min. Rückrechnung gegen
     * Uhrenabweichungen), sonst gilt der gemeldete Wert. null = unbegrenzt. Veraltete Daten werden nicht weitergezählt.
     */
    fun liveRemaining(u: UserStatus, status: Status, fetchedAtMs: Long, nowMs: Long): Int? {
        val base = u.remainingSeconds ?: return null
        if (u.session != "active" || isStale(status, nowMs)) return base
        val sinceStatus = ((fetchedAtMs - status.t.toEpochMilli()) / 1000).coerceIn(0, 120) + ((nowMs - fetchedAtMs) / 1000).coerceAtLeast(0)
        return (base - sinceStatus).toInt().coerceAtLeast(0)
    }

    fun formatRemaining(sec: Int): String {
        val s = sec.coerceAtLeast(0)
        return if (s >= 3600) "%d:%02d h".format(s / 3600, (s % 3600) / 60) else "%d:%02d min".format(s / 60, s % 60)
    }

    fun formatMinutes(min: Int): String = when {
        min >= 60 && min % 60 == 0 -> "${min / 60} h"
        min >= 60 -> "${min / 60} h ${min % 60} min"
        else -> "$min min"
    }

    fun sessionText(session: String): String = when (session) {
        "active" -> "Angemeldet – Zeit läuft"
        "locked" -> "Bildschirm gesperrt"
        "disconnected" -> "Getrennt"
        else -> "Nicht angemeldet"
    }

    fun ageText(sec: Long): String = when {
        sec < 60 -> "gerade eben"
        sec < 3600 -> "vor ${sec / 60} Min."
        sec < 86400 -> "vor ${sec / 3600} Std."
        else -> "vor ${sec / 86400} Tagen"
    }

    /** Anteil der verbleibenden Zeit am Tag (0..1) für den Ring; unbegrenzt = 1. */
    fun ringFraction(u: UserStatus, liveRemaining: Int?): Float {
        if (liveRemaining == null) return 1f
        val total = u.usedSeconds + (u.remainingSeconds ?: 0)
        if (total <= 0) return 0f
        return (liveRemaining.toFloat() / total).coerceIn(0f, 1f)
    }
}

/** Merkt sich pro Konto, ob noch Zeit übrig war – meldet den Moment, in dem das Limit während einer laufenden Sitzung erreicht wird. */
class LimitWatcher {
    private val hadTime = HashMap<String, Boolean>()

    /** @param live Konto → (Sitzung, Restsekunden oder null) */
    fun check(live: Map<String, Pair<String, Int?>>): List<String> {
        val hit = ArrayList<String>()
        for ((name, v) in live) {
            val (session, rem) = v
            val positive = rem == null || rem > 0
            if (hadTime[name] == true && rem != null && rem <= 0 && session == "active") hit.add(name)
            hadTime[name] = positive
        }
        return hit
    }
}
