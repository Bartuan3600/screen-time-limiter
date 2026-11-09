"""Logik ohne GUI: Einstellungen, PIN-Hash, Zeitfenster, Restzeit.
Gespeichert wird NUR: Einstellungen + heute genutzte Sekunden. Sonst nichts."""
import hashlib
import hmac
import json
import os
import re
import secrets
import sys
import tempfile
from datetime import date, datetime, time as dtime, timedelta

APP_NAME = "ScreenTimeLimiter"
PBKDF2_ROUNDS = 200_000


def data_dir():
    base = os.environ.get("LOCALAPPDATA")
    if not base:  # nur fuer Tests auf Nicht-Windows
        base = os.path.join(os.path.expanduser("~"), ".local", "share")
    path = os.path.join(base, APP_NAME)
    os.makedirs(path, exist_ok=True)
    return path


def settings_path():
    return os.path.join(data_dir(), "settings.json")


def default_state(today=None):
    return {
        "pin_salt": "",
        "pin_hash": "",
        "daily_limit_minutes": 120,
        "window_enabled": False,
        "window_start": "16:00",
        "window_end": "20:00",
        "idle_pause_minutes": 5,   # 0 = Leerlauf nicht abziehen
        "date": (today or date.today()).isoformat(),
        "used_seconds": 0.0,
        "bonus_minutes": 0,        # heute vom Elternteil freigegeben
        "unlimited_today": False,  # "Heute freigeben"
        "blocked_today": False,    # "Heute sperren" (Eltern)
        "window_override": False,  # Zeitfenster heute ignorieren (nach Extra-Zeit)
    }


def load_state(path=None, today=None):
    path = path or settings_path()
    st = default_state(today)
    try:
        with open(path, "r", encoding="utf-8") as f:
            st.update(json.load(f))
    except (FileNotFoundError, ValueError, OSError):
        pass
    return roll_over(st, today)


def save_state(st, path=None):
    path = path or settings_path()
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(st, f, indent=2)
    os.replace(tmp, path)


def roll_over(st, today=None):
    """Um lokale Mitternacht: Tageswerte zuruecksetzen."""
    today_s = (today or date.today()).isoformat()
    if st.get("date") != today_s:
        st["date"] = today_s
        st["used_seconds"] = 0.0
        st["bonus_minutes"] = 0
        st["unlimited_today"] = False
        st["blocked_today"] = False
        st["window_override"] = False
    return st


# ---- PIN ----
PIN_RE = re.compile(r"[\x21-\x7e]{4,32}")


def valid_pin_format(pin):
    """PIN / Passwort: 4-32 sichtbare ASCII-Zeichen (Buchstaben, Ziffern, Sonderzeichen), keine Leerzeichen. Alte Ziffern-PINs bleiben gueltig."""
    return isinstance(pin, str) and PIN_RE.fullmatch(pin) is not None


def _hash(pin, salt_hex):
    return hashlib.pbkdf2_hmac("sha256", pin.encode(), bytes.fromhex(salt_hex),
                               PBKDF2_ROUNDS).hex()


def set_pin(st, pin):
    if not valid_pin_format(pin):
        raise ValueError("PIN / Passwort muss 4 bis 32 Zeichen haben (Buchstaben, Ziffern, Sonderzeichen, keine Leerzeichen).")
    st["pin_salt"] = secrets.token_hex(16)
    st["pin_hash"] = _hash(pin, st["pin_salt"])


def has_pin(st):
    return bool(st.get("pin_hash"))


def check_pin(st, pin):
    if not has_pin(st) or not isinstance(pin, str):
        return False
    return hmac.compare_digest(_hash(pin, st["pin_salt"]), st["pin_hash"])


# ---- Zeit / Wochenplan ----
# Konfiguration v3: st["days"] = Liste mit 7 Eintraegen (Montag..Sonntag), je
#   {"mode": "limit"|"blocked"|"unlimited", "limit_minutes": int,
#    "window_enabled": bool, "window_start": "HH:MM", "window_end": "HH:MM"}
# Fehlt "days" (alte Konfiguration mit einem Limit), gilt fuer jeden Tag das alte Limit/Fenster.
# Tageswerte (Entry): used_seconds, bonus_minutes, unlimited_today, blocked_today, window_override.
DAY_SHORT = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]
DAY_NAMES = ["Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag", "Sonntag"]
MODES = ("limit", "blocked", "unlimited")
LOOKAHEAD_MINUTES = 6   # so weit voraus wird das Ende des erlaubten Fensters gesucht (Warnungen)


def parse_hhmm(s):
    h, m = s.strip().split(":")
    h, m = int(h), int(m)
    if not (0 <= h < 24 and 0 <= m < 60):
        raise ValueError("Ungueltige Uhrzeit")
    return dtime(h, m)


def _mod(hhmm):
    t = parse_hhmm(hhmm)
    return t.hour * 60 + t.minute


def day_rule(st, when):
    """Regel fuer den Wochentag von `when` (date/datetime, lokale Zeit; Montag = 0)."""
    rule = {"mode": "limit", "limit_minutes": st["daily_limit_minutes"],
            "window_enabled": bool(st.get("window_enabled")),
            "window_start": st["window_start"], "window_end": st["window_end"]}
    days = st.get("days")
    idx = when.weekday()
    if isinstance(days, list) and len(days) == 7 and isinstance(days[idx], dict):
        d = days[idx]
        if d.get("mode") in MODES:
            rule["mode"] = d["mode"]
        for k in ("limit_minutes", "window_start", "window_end"):
            if d.get(k) is not None:
                rule[k] = d[k]
        if d.get("window_enabled") is not None:
            rule["window_enabled"] = bool(d["window_enabled"])
    return rule


def _own_window_ok(rule, t):
    if not rule["window_enabled"]:
        return True
    now = t.hour * 60 + t.minute
    s, e = _mod(rule["window_start"]), _mod(rule["window_end"])
    if s <= e:
        return s <= now < e
    return now >= s                      # Fenster ueber Mitternacht: abends ab Start ...


def _tail_ok(rule_prev, t):
    """... und nach Mitternacht bis zum Ende, wenn das Fenster des VORTAGS ueber Mitternacht ging."""
    if rule_prev["mode"] == "blocked" or not rule_prev["window_enabled"]:
        return False
    now = t.hour * 60 + t.minute
    s, e = _mod(rule_prev["window_start"]), _mod(rule_prev["window_end"])
    return s > e and now < e


def window_allowed_at(st, t, today):
    """Darf zur lokalen Zeit t genutzt werden (nur Wochenplan/Fenster, ohne Tageslimit)?
    Freigaben von heute (unlimited/blocked/window_override) gelten nur fuer den Kalendertag `today`."""
    if t.date() == today:
        if st.get("unlimited_today"):
            return True
        if st.get("blocked_today"):
            return False
        if st.get("window_override"):
            return True
    rule = day_rule(st, t)
    if rule["mode"] == "blocked":
        return False
    if _own_window_ok(rule, t):
        return True
    return _tail_ok(day_rule(st, t - timedelta(days=1)), t)


def in_window(st, now=None):
    now = now or datetime.now()
    return window_allowed_at(st, now, now.date())


def seconds_to_window_end(st, now=None):
    """Sekunden bis das erlaubte Fenster endet, bis zu LOOKAHEAD_MINUTES voraus (sonst inf)."""
    now = now or datetime.now()
    base = now.replace(second=0, microsecond=0)
    for k in range(1, LOOKAHEAD_MINUTES + 1):
        t = base + timedelta(minutes=k)
        if not window_allowed_at(st, t, now.date()):
            return (t - now).total_seconds()
    return float("inf")


def allowed_seconds(st, now=None):
    rule = day_rule(st, now or datetime.now())
    base = 0 if rule["mode"] == "blocked" else rule["limit_minutes"]
    return base * 60 + st.get("bonus_minutes", 0) * 60


def remaining_seconds(st, now=None):
    now = now or datetime.now()
    if st.get("unlimited_today"):
        return float("inf")
    if st.get("blocked_today"):
        return 0.0
    if day_rule(st, now)["mode"] == "unlimited":
        return float("inf")
    return max(0.0, allowed_seconds(st, now) - st["used_seconds"])


def lock_reason(st, now=None):
    """None = nutzbar, sonst Text fuer den Sperrbildschirm."""
    now = now or datetime.now()
    if st.get("unlimited_today"):
        return None
    if st.get("blocked_today"):
        return "Heute ist die Bildschirmzeit von den Eltern gesperrt."
    rule = day_rule(st, now)
    if rule["mode"] == "blocked" and not st.get("window_override"):
        return "Heute ist keine Bildschirmzeit erlaubt (gesperrt)."
    if not in_window(st, now):
        return "Außerhalb der erlaubten Zeit (%s–%s)." % (rule["window_start"], rule["window_end"])
    if remaining_seconds(st, now) <= 0:
        return "Das Tageslimit ist aufgebraucht."
    return None


def seconds_left(st, now=None):
    """Sekunden bis zur naechsten Sperre (Limit oder Fensterende), inf = keine in Sicht."""
    now = now or datetime.now()
    return min(remaining_seconds(st, now), seconds_to_window_end(st, now))


def preset(name):
    """Voreinstellungen fuer den Wochenplan. -> Liste mit 7 Tagesregeln."""
    def d(mode, limit, ws, we):
        return {"mode": mode, "limit_minutes": limit, "window_enabled": ws is not None,
                "window_start": ws or "16:00", "window_end": we or "20:00"}
    if name == "schule":
        return [d("limit", 60, "16:00", "19:00") for _ in range(5)] + [d("limit", 180, "10:00", "21:00") for _ in range(2)]
    if name == "gleich":
        return [d("limit", 120, None, None) for _ in range(7)]
    if name == "wochenende":
        return [d("blocked", 0, None, None) for _ in range(5)] + [d("limit", 180, "10:00", "21:00") for _ in range(2)]
    if name == "wochenende2h":
        return [d("blocked", 0, None, None) for _ in range(5)] + [d("limit", 120, None, None) for _ in range(2)]
    raise ValueError("Unbekannte Voreinstellung")


def fmt_seconds(sec):
    if sec == float("inf"):
        return "unbegrenzt"
    sec = int(sec)
    return "%d:%02d:%02d" % (sec // 3600, sec % 3600 // 60, sec % 60)
