package de.bartuan.eltern.relay

/**
 * Eltern-PIN / Passwort: 4–32 Zeichen, druckbares ASCII ohne Leerzeichen (Buchstaben, Ziffern, Sonderzeichen), Groß-/Kleinschreibung zählt.
 * Gilt identisch auf dem PC (StlCommon.ps1: Test-StlPinFormat). Alte 4–8-stellige Ziffern-PINs bleiben gültig.
 * Bewusst kein Unicode (Umlaute, Leerzeichen): verschiedene Normalisierung auf Handy und PC würde sonst zu „falsch“ führen.
 */
object PinPolicy {
    const val MIN = 4
    const val MAX = 32
    private fun allowed(c: Char) = c.code in 0x21..0x7E
    fun isValid(pin: String): Boolean = pin.length in MIN..MAX && pin.all(::allowed)
    /** Für die Eingabe: unerlaubte Zeichen (Leerzeichen, Umlaute, Emojis …) verwerfen, auf MAX kürzen. */
    fun sanitize(input: String): String = input.filter(::allowed).take(MAX)
}
