import os
import sys
import unittest
from datetime import datetime, timezone

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "viewer"))
import stl_viewer as v  # noqa: E402


class ViewerTests(unittest.TestCase):
    now = datetime(2026, 10, 26, 17, 0, 30, tzinfo=timezone.utc)

    def status(self, remaining=1800, updated="2026-10-26T17:00:20.1234567Z"):
        return {"updated_utc": updated, "users": [
            {"name": "Max", "remaining_seconds": remaining, "limit_minutes": 60, "window": "16:00–20:00", "lock_reason": None}]}

    def test_format(self):
        self.assertEqual(v.fmt_seconds(3725), "1:02:05")
        self.assertEqual(v.fmt_seconds(None), "unbegrenzt")
        self.assertEqual(v.fmt_seconds(-5), "0:00:00")

    def test_describe_ok_and_case_insensitive(self):
        big, small = v.describe(self.status(), "max", self.now)
        self.assertEqual(big, "0:30:00")
        self.assertIn("16:00–20:00", small)
        self.assertNotIn("veraltet", small)

    def test_week_rules_blocked_and_unlimited(self):
        st = self.status()
        st["users"][0].update(day="Samstag", mode="blocked", limit_minutes=0, window="", remaining_seconds=0,
                              lock_reason="Heute ist keine Bildschirmzeit erlaubt (gesperrt).")
        big, small = v.describe(st, "Max", self.now)
        self.assertEqual(big, "0:00:00")
        self.assertIn("Samstag: keine Bildschirmzeit", small)
        self.assertIn("gesperrt", small)
        st["users"][0].update(day="Sonntag", mode="unlimited", limit_minutes=None, remaining_seconds=None, lock_reason=None)
        big, small = v.describe(st, "Max", self.now)
        self.assertEqual(big, "unbegrenzt")
        self.assertIn("Sonntag: unbegrenzt", small)

    def test_stale_and_missing(self):
        big, small = v.describe(self.status(updated="2026-10-26T16:00:00.0000000+00:00"), "Max", self.now)
        self.assertIn("veraltet", small)
        self.assertIn("Kein Status", v.describe(None, "Max", self.now)[1])
        self.assertIn("kein Limit", v.describe(self.status(), "Anna", self.now)[1])

    def test_ps_iso_formats(self):
        # PowerShell 'o' mit 7 Nachkommastellen, 'Z' oder +00:00
        self.assertEqual(v.parse_utc("2026-10-26T17:00:20.1234567Z").second, 20)
        self.assertEqual(v.parse_utc("2026-10-26T17:00:20.1234567+00:00").second, 20)
        self.assertEqual(v.parse_utc("2026-10-26T17:00:20Z").second, 20)


if __name__ == "__main__":
    unittest.main()
