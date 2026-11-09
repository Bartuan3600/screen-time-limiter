"""Optionale Restzeit-Anzeige (nur LESEN).

Liest die kleine Datei %ProgramData%\\ScreenTimeLimiter\\public\\status.json, die der Enforcer (SYSTEM)
schreibt, und zeigt die verbleibende Zeit des aktuellen Windows-Kontos. Diese Anzeige kann nichts
aendern, nichts sperren und nichts entsperren. Sie darf geschlossen werden: Die Sperre laeuft
unabhaengig davon. Es wird nichts ueberwacht oder gesendet."""
import json
import os
from datetime import datetime, timezone

STALE_AFTER_S = 60


def status_path():
    base = os.environ.get("PROGRAMDATA") or r"C:\ProgramData"
    return os.path.join(base, "ScreenTimeLimiter", "public", "status.json")


def load_status(path=None):
    try:
        with open(path or status_path(), "r", encoding="utf-8-sig") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def fmt_seconds(sec):
    if sec is None:
        return "unbegrenzt"
    sec = max(0, int(sec))
    return "%d:%02d:%02d" % (sec // 3600, sec % 3600 // 60, sec % 60)


def parse_utc(s):
    s = s.strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    # PowerShell 'o' liefert 7 Nachkommastellen; Python 3.9 kann nur 6
    if "." in s:
        head, rest = s.split(".", 1)
        frac = "".join(ch for ch in rest if ch.isdigit())[:6]
        tail = rest[len("".join(ch for ch in rest if ch.isdigit())):]
        s = head + "." + frac + tail
    dt = datetime.fromisoformat(s)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def describe(status, user, now=None):
    """-> (grosser_text, kleiner_text)"""
    now = now or datetime.now(timezone.utc)
    if not status:
        return "--:--:--", "Kein Status gefunden (Dienst nicht aktiv?)."
    try:
        age = (now - parse_utc(status["updated_utc"])).total_seconds()
    except (KeyError, ValueError):
        age = float("inf")
    mine = None
    for u in status.get("users", []):
        if str(u.get("name", "")).lower() == user.lower():
            mine = u
    if mine is None:
        return "--:--:--", "Für dieses Konto gilt kein Limit."
    big = fmt_seconds(mine.get("remaining_seconds"))
    lim = mine.get("limit_minutes")
    day = mine.get("day") or "Heute"
    if mine.get("mode") == "blocked" and not lim:
        small = "%s: keine Bildschirmzeit" % day
    elif lim is None:
        small = "%s: unbegrenzt" % day
    else:
        small = "%s: Limit %d Min." % (day, lim)
    if mine.get("window"):
        small += " · erlaubt %s" % mine["window"]
    if mine.get("lock_reason"):
        small += "\n" + mine["lock_reason"]
    if age > STALE_AFTER_S:
        small += "\nAchtung: Der Zähl-Dienst meldet sich nicht (Stand veraltet)."
    return big, small


def main():
    import tkinter as tk
    from tkinter import ttk

    user = os.environ.get("USERNAME") or os.environ.get("USER") or ""
    root = tk.Tk()
    root.title("Bildschirmzeit")
    root.geometry("300x150")
    root.resizable(False, False)
    f = ttk.Frame(root, padding=12)
    f.pack(fill="both", expand=True)
    ttk.Label(f, text="Verbleibende Zeit heute", font=("Segoe UI", 10)).pack()
    big = ttk.Label(f, text="--:--:--", font=("Segoe UI", 26, "bold"))
    big.pack(pady=2)
    small = ttk.Label(f, text="", font=("Segoe UI", 9), justify="center")
    small.pack()
    ttk.Label(f, text="Nur Anzeige. Ändern können nur die Eltern.", font=("Segoe UI", 8),
              foreground="#666").pack(side="bottom")

    def refresh():
        b, s = describe(load_status(), user)
        big.config(text=b)
        small.config(text=s)
        root.after(5000, refresh)

    refresh()
    root.mainloop()


if __name__ == "__main__":
    main()
