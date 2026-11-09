"""Leerlauf-Erkennung (Windows): fragt NUR ab, wie lange keine Eingabe war.
Es wird NICHT gelesen, WAS eingegeben wurde."""
import sys


def idle_seconds():
    if not sys.platform.startswith("win"):
        return 0.0
    try:
        import ctypes

        class LASTINPUTINFO(ctypes.Structure):
            _fields_ = [("cbSize", ctypes.c_uint), ("dwTime", ctypes.c_uint)]

        info = LASTINPUTINFO()
        info.cbSize = ctypes.sizeof(info)
        if not ctypes.windll.user32.GetLastInputInfo(ctypes.byref(info)):
            return 0.0
        millis = ctypes.windll.kernel32.GetTickCount() - info.dwTime
        return max(0.0, millis / 1000.0)
    except Exception:
        return 0.0
