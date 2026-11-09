"""Prueft die PowerShell-Logik (StlCommon.ps1/StlEnforce.ps1) gegen die Python-Referenz (standalone/core.py).
Braucht 'pwsh' (PowerShell 7). Ohne pwsh werden die Tests uebersprungen.
Aufruf (im Ordner screen-time-limiter):  python -m unittest discover -s tests -v
pwsh-Pfad ggf. per Umgebungsvariable PWSH angeben."""
import json
import os
import random
import shutil
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "standalone"))
import core  # noqa: E402

PWSH = os.environ.get("PWSH") or shutil.which("pwsh") or (
    None)
ENV = dict(os.environ, DOTNET_SYSTEM_GLOBALIZATION_INVARIANT="1")


@unittest.skipUnless(PWSH, "pwsh nicht installiert")
class PowerShellLogic(unittest.TestCase):
    @staticmethod
    def _rand_days(rnd):
        days = []
        for _ in range(7):
            ws = "%02d:%02d" % (rnd.randrange(24), rnd.choice([0, 15, 30, 59]))
            we = "%02d:%02d" % (rnd.randrange(24), rnd.choice([0, 15, 30, 59]))
            days.append(dict(mode=rnd.choice(["limit", "limit", "limit", "blocked", "unlimited"]),
                             limit_minutes=rnd.choice([1, 30, 60, 90, 180]),
                             window_enabled=rnd.random() < 0.6, window_start=ws, window_end=we))
        return days

    def test_parity_and_pin_hash(self):
        """300 Zufallsfaelle: PowerShell-Logik == Python-Referenz (Wochenplan, Fenster ueber Mitternacht,
        Freigaben, Restzeit, Sperrgrund, Vorausschau fuer Warnungen)."""
        rnd = random.Random(42)
        cases, pins = [], []
        for i in range(300):
            start = "%02d:%02d" % (rnd.randrange(24), rnd.choice([0, 15, 30, 59]))
            end = "%02d:%02d" % (rnd.randrange(24), rnd.choice([0, 15, 30, 59]))
            now = datetime(2026, 10, 26) + timedelta(days=rnd.randrange(14), seconds=rnd.randrange(86400))
            if rnd.random() < 0.25:   # Naehe zu Fensterwechsel / Mitternacht testen
                now = now.replace(hour=rnd.choice([23, 0, 5, 6, 19, 21]), minute=rnd.choice([0, 54, 55, 58, 59]))
            cases.append(dict(
                window_enabled=rnd.random() < 0.7, start=start, end=end,
                limit=rnd.choice([1, 30, 60, 120]), override=rnd.random() < 0.2,
                unlimited=rnd.random() < 0.1, blocked=rnd.random() < 0.08, bonus=rnd.choice([0, 0, 15, 60]),
                used=rnd.choice([0, 59, 1800, 3600, 7200, 7199.5]),
                days=self._rand_days(rnd) if i % 3 else None,    # 2/3 mit Wochenplan, 1/3 alte Einzel-Konfiguration
                now=now.strftime("%Y-%m-%dT%H:%M:%S")))
        # 200 gezielte Grenzfaelle: Minute vor/auf Fensterbeginn und -ende (auch ueber Mitternacht) mit Wochenplan
        for _ in range(200):
            days = self._rand_days(rnd)
            for dd in days:   # viele Fenster ueber Mitternacht
                if dd["window_enabled"] and rnd.random() < 0.5 and dd["window_start"] < dd["window_end"]:
                    dd["window_start"], dd["window_end"] = dd["window_end"], dd["window_start"]
            day = datetime(2026, 10, 26) + timedelta(days=rnd.randrange(14))
            src = days[(day.weekday() - rnd.choice([0, 1])) % 7]
            hh, mm = map(int, rnd.choice([src["window_start"], src["window_end"]]).split(":"))
            now = day + timedelta(hours=hh, minutes=mm + rnd.choice([-1, 0, 0, 1]), seconds=rnd.choice([0, 0, 29, 59]))
            now = max(now, day)   # nicht vor den Tagesbeginn rutschen
            cases.append(dict(
                window_enabled=False, start="16:00", end="20:00", limit=60, override=rnd.random() < 0.1,
                unlimited=rnd.random() < 0.05, blocked=rnd.random() < 0.05, bonus=rnd.choice([0, 0, 15]),
                used=rnd.choice([0, 1800, 3599.5]), days=days, now=now.strftime("%Y-%m-%dT%H:%M:%S")))
        for pin in ("1234", "00000000", "9876", "5", "Abcd1234", "S3cret!Pa$$w0rd#2026", "\"quoted\\back\"", "a" * 32):
            pins.append(dict(pin=pin, salt=os.urandom(16).hex()))
        with tempfile.TemporaryDirectory() as d:
            fin, fout = os.path.join(d, "in.json"), os.path.join(d, "out.json")
            with open(fin, "w") as f:
                json.dump(dict(window_cases=cases, pin_cases=pins), f)
            r = subprocess.run([PWSH, "-NoProfile", "-File", os.path.join(HERE, "parity.ps1"), fin, fout],
                               capture_output=True, text=True, env=ENV)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            with open(fout, encoding="utf-8") as f:
                res = json.load(f)
        nulls = lambda v: None if v == float("inf") else v  # noqa: E731
        kinds = set()
        for c, got in zip(cases, res["window_results"]):
            st = core.default_state()
            st.update(daily_limit_minutes=c["limit"], window_enabled=c["window_enabled"],
                      window_start=c["start"], window_end=c["end"], window_override=c["override"],
                      unlimited_today=c["unlimited"], blocked_today=c["blocked"], bonus_minutes=c["bonus"],
                      used_seconds=c["used"])
            if c["days"]:
                st["days"] = c["days"]
            now = datetime.strptime(c["now"], "%Y-%m-%dT%H:%M:%S")
            self.assertEqual(got["in_window"], core.in_window(st, now), c)
            self.assertEqual(got["remaining"], nulls(core.remaining_seconds(st, now)), c)
            self.assertEqual(got["allowed"], core.allowed_seconds(st, now), c)
            self.assertEqual(got["to_end"], nulls(core.seconds_to_window_end(st, now)), c)
            self.assertEqual(got["left"], nulls(core.seconds_left(st, now)), c)
            self.assertEqual(got["reason"], core.lock_reason(st, now), c)
            kinds.add((got["reason"] or "ok")[:12])
        # die Zufallsfaelle muessen alle Ergebnisarten abdecken (sonst waere der Vergleich wertlos)
        self.assertGreaterEqual(len(kinds), 4, kinds)
        # PBKDF2 (eigene C#-Implementierung) muss exakt hashlib entsprechen -> PIN-Hash kompatibel zu core.py
        for p, h in zip(pins, res["pin_hashes"]):
            self.assertEqual(h, core._hash(p["pin"], p["salt"]))

    def test_cycle_scenarios(self):
        r = subprocess.run([PWSH, "-NoProfile", "-File", os.path.join(HERE, "cycle_tests.ps1")],
                           capture_output=True, text=True, env=ENV)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("0 Fehler", r.stdout)

    def test_gui_smoke_with_stubs(self):
        """Eltern-Zentrale-Ablauf mit WinForms-Attrappen (kein echtes WinForms - das geht nur unter Windows)."""
        r = subprocess.run([PWSH, "-NoProfile", "-File", os.path.join(HERE, "gui_smoke.ps1")],
                           capture_output=True, text=True, env=ENV)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("Pruefungen OK", r.stdout)

    def test_viewer_smoke_with_stubs(self):
        """Restzeit-Anzeige (Kind, nur lesen) mit WinForms-Attrappen."""
        r = subprocess.run([PWSH, "-NoProfile", "-File", os.path.join(HERE, "viewer_smoke.ps1")],
                           capture_output=True, text=True, env=ENV)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("Pruefungen OK", r.stdout)

    def test_installer_dry_run_with_stubs(self):
        """Installer-Ablauf mit Attrappen fuer Konten/Aufgabenplanung/Registry (nicht echtes Windows)."""
        r = subprocess.run([PWSH, "-NoProfile", "-File", os.path.join(HERE, "installer_smoke.ps1")],
                           capture_output=True, text=True, env=ENV)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("Pruefungen OK", r.stdout)

    def test_relay_module(self):
        """Handy-Relay (StlRelay.ps1): Vektoren, eigene AES-GCM, Pairing-Code, PIN-Sperre, Replay, Befehle, Status."""
        r = subprocess.run([PWSH, "-NoProfile", "-File", os.path.join(HERE, "relay_tests.ps1")],
                           capture_output=True, text=True, env=ENV)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("Pruefungen bestanden", r.stdout)

    def test_all_scripts_parse(self):
        script = (
            "$bad=0; foreach($f in Get-ChildItem '%s' -Filter *.ps1){$t=$null;$e=$null;"
            "[void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName,[ref]$t,[ref]$e);"
            "if($e.Count){$bad++;$f.Name;$e|%%{$_.Message}}}; exit $bad" % os.path.join(HERE, ".."))
        r = subprocess.run([PWSH, "-NoProfile", "-Command", script], capture_output=True, text=True, env=ENV)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_ps1_files_have_utf8_bom(self):
        # Windows PowerShell 5.1 liest .ps1 ohne BOM als ANSI -> Umlaute kaputt
        for root in (os.path.join(HERE, ".."),):
            for n in os.listdir(root):
                if n.endswith(".ps1"):
                    with open(os.path.join(root, n), "rb") as f:
                        self.assertEqual(f.read(3), b"\xef\xbb\xbf", n)


if __name__ == "__main__":
    unittest.main()
