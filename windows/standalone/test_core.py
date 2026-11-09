import os, tempfile, unittest
from datetime import date, datetime
import core

class T(unittest.TestCase):
    def test_pin(self):
        st = core.default_state()
        core.set_pin(st, "1234")
        self.assertTrue(core.check_pin(st, "1234"))
        self.assertFalse(core.check_pin(st, "1235"))
        self.assertNotIn("1234", str(st))
        for bad in ("123", "x" * 33, "a b c d", "p\u00e4ssw\u00f6rt", "12\n34", "", None):
            with self.assertRaises(ValueError): core.set_pin(st, bad)
            self.assertFalse(core.valid_pin_format(bad))
        for good in ("1234", "12345678", "Abcd1234", "S3cret!Pa$$w0rd#2026", "a" * 32, "x.y-z_@?"):
            self.assertTrue(core.valid_pin_format(good), good)
            core.set_pin(st, good)
            self.assertTrue(core.check_pin(st, good))
            self.assertFalse(core.check_pin(st, good.swapcase() if good.swapcase() != good else good + "x"))
        # altes Hash-Format (PBKDF2-SHA256, UTF-8) bleibt gueltig
        old = core.default_state(); old["pin_salt"] = "00" * 16
        old["pin_hash"] = core._hash("2468", old["pin_salt"])
        self.assertTrue(core.check_pin(old, "2468"))
    def test_preset_wochenende2h(self):
        p = core.preset("wochenende2h")
        self.assertEqual(len(p), 7)
        self.assertTrue(all(r["mode"] == "blocked" for r in p[:5]))
        self.assertTrue(all(r["mode"] == "limit" and r["limit_minutes"] == 120 and not r["window_enabled"] for r in p[5:]))
    def test_window(self):
        st = core.default_state(); st.update(window_enabled=True, window_start="16:00", window_end="20:00")
        self.assertTrue(core.in_window(st, datetime(2026,1,1,17,0)))
        self.assertFalse(core.in_window(st, datetime(2026,1,1,20,0)))
        self.assertFalse(core.in_window(st, datetime(2026,1,1,9,0)))
        st.update(window_start="22:00", window_end="06:00")
        self.assertTrue(core.in_window(st, datetime(2026,1,1,23,0)))
        self.assertTrue(core.in_window(st, datetime(2026,1,1,5,0)))
        self.assertFalse(core.in_window(st, datetime(2026,1,1,12,0)))
    def test_limit_and_rollover(self):
        st = core.default_state(date(2026,1,1)); st["daily_limit_minutes"] = 10
        st["used_seconds"] = 600
        self.assertIn("Tageslimit", core.lock_reason(st))
        st["bonus_minutes"] = 5
        self.assertIsNone(core.lock_reason(st))
        core.roll_over(st, date(2026,1,2))
        self.assertEqual(st["used_seconds"], 0); self.assertEqual(st["bonus_minutes"], 0)
    def test_persist(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "s.json"); st = core.default_state(); st["used_seconds"] = 42
            core.save_state(st, p)
            self.assertEqual(core.load_state(p)["used_seconds"], 42)
    def test_unlimited(self):
        st = core.default_state(); st["unlimited_today"] = True; st["used_seconds"] = 1e6
        self.assertIsNone(core.lock_reason(st)); self.assertEqual(core.fmt_seconds(core.remaining_seconds(st)), "unbegrenzt")

    # ---- Wochenplan (2026-10-26 ist ein Montag)
    def week(self):
        st = core.default_state(date(2026, 10, 26))
        st["days"] = core.preset("schule")           # Mo-Fr 60 Min. 16-19, Sa/So 180 Min. 10-21
        st["days"][4] = {"mode": "limit", "limit_minutes": 120, "window_enabled": True,
                         "window_start": "20:00", "window_end": "01:00"}   # Freitag ueber Mitternacht
        st["days"][5] = {"mode": "blocked", "limit_minutes": 0, "window_enabled": False,
                         "window_start": "16:00", "window_end": "20:00"}   # Samstag gesperrt
        return st

    def test_week_basic(self):
        st = self.week()
        self.assertIsNone(core.lock_reason(st, datetime(2026, 10, 26, 17, 0)))            # Mo 17:00
        self.assertIn("Außerhalb", core.lock_reason(st, datetime(2026, 10, 26, 20, 0)))    # Mo 20:00
        self.assertIn("gesperrt", core.lock_reason(st, datetime(2026, 10, 31, 12, 0)))     # Sa
        self.assertIsNone(core.lock_reason(st, datetime(2026, 11, 1, 12, 0)))              # So 12:00
        self.assertEqual(core.remaining_seconds(st, datetime(2026, 11, 1, 12, 0)), 180 * 60)

    def test_week_midnight_window(self):
        st = self.week()
        self.assertIsNone(core.lock_reason(st, datetime(2026, 10, 30, 23, 30)))            # Fr 23:30
        self.assertIsNotNone(core.lock_reason(st, datetime(2026, 10, 31, 0, 30)))          # Sa gesperrt -> kein Rest
        st["days"][5] = dict(st["days"][4])                                                # Sa auch offen
        self.assertIsNone(core.lock_reason(st, datetime(2026, 10, 31, 0, 30)))
        self.assertIsNotNone(core.lock_reason(st, datetime(2026, 10, 31, 1, 0)))

    def test_week_parent_actions(self):
        st = self.week()
        sat = datetime(2026, 10, 31, 12, 0)
        st.update(bonus_minutes=30, window_override=True)
        self.assertIsNone(core.lock_reason(st, sat))
        self.assertEqual(core.remaining_seconds(st, sat), 1800)
        mon = datetime(2026, 10, 26, 17, 0)
        st2 = self.week(); st2["blocked_today"] = True
        self.assertIn("von den Eltern", core.lock_reason(st2, mon))
        self.assertEqual(core.remaining_seconds(st2, mon), 0)
        st2["unlimited_today"] = True
        self.assertIsNone(core.lock_reason(st2, datetime(2026, 10, 26, 23, 0)))

    def test_lookahead_and_legacy(self):
        st = self.week()
        self.assertEqual(core.seconds_to_window_end(st, datetime(2026, 10, 26, 18, 56, 30)), 210)  # Ende 19:00
        self.assertEqual(core.seconds_to_window_end(st, datetime(2026, 10, 26, 17, 0)), float("inf"))
        legacy = core.default_state(date(2026, 10, 26))      # alte Einzel-Konfiguration ohne "days"
        legacy.pop("days", None); legacy["daily_limit_minutes"] = 45
        self.assertEqual(core.remaining_seconds(legacy, datetime(2026, 10, 31, 12, 0)), 45 * 60)

    def test_presets(self):
        for n in ("schule", "gleich", "wochenende"):
            self.assertEqual(len(core.preset(n)), 7)
        with self.assertRaises(ValueError): core.preset("x")

if __name__ == "__main__": unittest.main()
