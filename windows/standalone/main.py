"""Bildschirmzeit-Limiter (ohne Ueberwachung).
Zaehlt nur aktive Nutzungszeit, sperrt bei Limit/ausserhalb des Zeitfensters,
Entsperren nur mit Eltern-PIN / Passwort. Start: python main.py"""
import time
import tkinter as tk
from tkinter import messagebox, ttk

import core
import idle

TICK_MS = 1000
SAVE_EVERY_S = 30


class App:
    def __init__(self):
        self.st = core.load_state()
        self.root = tk.Tk()
        self.root.title("Bildschirmzeit")
        self.root.geometry("320x190")
        self.root.resizable(False, False)
        self.root.protocol("WM_DELETE_WINDOW", self.root.iconify)  # nur minimieren
        self.lock_win = None
        self.last_tick = time.monotonic()
        self.last_save = time.monotonic()
        self.fail_count = 0
        self.fail_until = 0.0

        f = ttk.Frame(self.root, padding=14)
        f.pack(fill="both", expand=True)
        ttk.Label(f, text="Verbleibende Zeit heute", font=("Segoe UI", 11)).pack()
        self.lbl_time = ttk.Label(f, text="--:--:--", font=("Segoe UI", 28, "bold"))
        self.lbl_time.pack(pady=4)
        self.lbl_info = ttk.Label(f, text="", font=("Segoe UI", 9))
        self.lbl_info.pack()
        ttk.Button(f, text="Eltern-Einstellungen", command=self.open_settings_with_pin).pack(pady=8)
        ttk.Label(f, text="Dieses Fenster darf minimiert werden.",
                  font=("Segoe UI", 8), foreground="#666").pack()

        if not core.has_pin(self.st):
            self.root.after(200, lambda: self.settings_dialog(first_run=True))
        self.root.after(TICK_MS, self.tick)

    # ---------- Zeitzaehlung ----------
    def tick(self):
        now = time.monotonic()
        delta = min(now - self.last_tick, 5.0)  # Ruhezustand nicht mitzaehlen
        self.last_tick = now
        core.roll_over(self.st)
        reason = core.lock_reason(self.st) if core.has_pin(self.st) else None

        if reason is None and self.lock_win is None and core.has_pin(self.st):
            pause = self.st.get("idle_pause_minutes", 5) * 60
            if not (pause and idle.idle_seconds() > pause):
                self.st["used_seconds"] += delta
            reason = core.lock_reason(self.st)  # evtl. gerade aufgebraucht

        self.lbl_time.config(text=core.fmt_seconds(core.remaining_seconds(self.st)))
        info = "Limit: %d Min./Tag" % self.st["daily_limit_minutes"]
        if self.st.get("window_enabled"):
            info += " · erlaubt %s–%s" % (self.st["window_start"], self.st["window_end"])
        self.lbl_info.config(text=info)

        if reason and self.lock_win is None:
            self.show_lock(reason)
        if now - self.last_save > SAVE_EVERY_S:
            self.save()
        self.root.after(TICK_MS, self.tick)

    def save(self):
        core.save_state(self.st)
        self.last_save = time.monotonic()

    # ---------- Sperrbildschirm ----------
    def show_lock(self, reason):
        self.save()
        w = tk.Toplevel(self.root)
        self.lock_win = w
        w.configure(bg="#14213d")
        w.overrideredirect(True)
        w.geometry("%dx%d+0+0" % (w.winfo_screenwidth(), w.winfo_screenheight()))
        w.attributes("-topmost", True)
        w.protocol("WM_DELETE_WINDOW", lambda: None)
        c = tk.Frame(w, bg="#14213d")
        c.place(relx=0.5, rely=0.5, anchor="center")
        tk.Label(c, text="🔒 Gesperrt", font=("Segoe UI", 40, "bold"), fg="white", bg="#14213d").pack(pady=10)
        tk.Label(c, text=reason, font=("Segoe UI", 18), fg="#fca311", bg="#14213d").pack(pady=6)
        tk.Label(c, text="Eltern-PIN / Passwort eingeben zum Entsperren:", font=("Segoe UI", 14),
                 fg="white", bg="#14213d").pack(pady=(30, 6))
        self.pin_var = tk.StringVar()
        e = tk.Entry(c, textvariable=self.pin_var, show="•", font=("Segoe UI", 24),
                     justify="center", width=10)
        e.pack()
        e.bind("<Return>", lambda _e: self.try_unlock())
        self.lock_msg = tk.Label(c, text="", font=("Segoe UI", 12), fg="#ff6b6b", bg="#14213d")
        self.lock_msg.pack(pady=6)
        tk.Button(c, text="Entsperren", font=("Segoe UI", 14), command=self.try_unlock).pack(pady=6)
        self.lock_entry = e
        self.keep_on_top()

    def keep_on_top(self):
        w = self.lock_win
        if w is None:
            return
        try:
            if not self.dialog_open:
                w.attributes("-topmost", True)
                w.lift()
                w.focus_force()
                self.lock_entry.focus_set()
        except tk.TclError:
            return
        self.root.after(500, self.keep_on_top)

    dialog_open = False

    def try_unlock(self):
        now = time.monotonic()
        if now < self.fail_until:
            self.lock_msg.config(text="Bitte warten (%d s)…" % int(self.fail_until - now))
            return
        pin = self.pin_var.get()
        self.pin_var.set("")
        if core.check_pin(self.st, pin):
            self.fail_count = 0
            self.parent_choice()
        else:
            self.fail_count += 1
            if self.fail_count >= 3:
                self.fail_until = now + 30
                self.lock_msg.config(text="3× falsch – 30 Sekunden Pause.")
            else:
                self.lock_msg.config(text="Falsche PIN / falsches Passwort.")

    def parent_choice(self):
        """Nach korrekter PIN: was soll passieren?"""
        self.dialog_open = True
        d = tk.Toplevel(self.lock_win)
        d.title("Eltern")
        d.attributes("-topmost", True)
        d.geometry("+%d+%d" % (self.root.winfo_screenwidth() // 2 - 170,
                               self.root.winfo_screenheight() // 2 - 150))
        d.protocol("WM_DELETE_WINDOW", lambda: None)
        f = ttk.Frame(d, padding=14)
        f.pack()
        ttk.Label(f, text="PIN / Passwort korrekt. Was möchten Sie tun?", font=("Segoe UI", 11, "bold")).pack(pady=6)

        def close():
            self.dialog_open = False
            d.destroy()

        def bonus(m):
            self.st["bonus_minutes"] += m
            self.st["window_override"] = True
            self.save()
            close()
            self.unlock()

        for m in (15, 30, 60):
            ttk.Button(f, text="+%d Minuten freigeben" % m, command=lambda m=m: bonus(m)).pack(fill="x", pady=2)

        def free_day():
            self.st["unlimited_today"] = True
            self.save()
            close()
            self.unlock()

        ttk.Button(f, text="Heute komplett freigeben (Tag beenden)", command=free_day).pack(fill="x", pady=2)

        def settings():
            close()
            self.unlock()
            self.settings_dialog()

        ttk.Button(f, text="Einstellungen öffnen", command=settings).pack(fill="x", pady=2)
        ttk.Button(f, text="Gesperrt lassen", command=close).pack(fill="x", pady=(8, 2))

    def unlock(self):
        if self.lock_win is not None:
            self.lock_win.destroy()
            self.lock_win = None
        self.last_tick = time.monotonic()

    # ---------- Einstellungen ----------
    def open_settings_with_pin(self):
        pin = PinPrompt(self.root, "Eltern-PIN / Passwort eingeben").result
        if pin is None:
            return
        if core.check_pin(self.st, pin):
            self.settings_dialog()
        else:
            messagebox.showerror("Falsche PIN / Passwort", "Die PIN / das Passwort ist nicht korrekt.", parent=self.root)

    def settings_dialog(self, first_run=False):
        d = tk.Toplevel(self.root)
        d.title("Eltern-Einstellungen")
        d.attributes("-topmost", True)
        d.wait_visibility()
        d.grab_set()
        f = ttk.Frame(d, padding=14)
        f.pack()
        st = self.st
        r = 0
        if first_run:
            ttk.Label(f, text="Ersteinrichtung: bitte PIN / Passwort und Limit festlegen.",
                      font=("Segoe UI", 10, "bold")).grid(row=r, columnspan=4, pady=6)
            r += 1

        ttk.Label(f, text="Tageslimit:").grid(row=r, column=0, sticky="w")
        v_h = tk.IntVar(value=st["daily_limit_minutes"] // 60)
        v_m = tk.IntVar(value=st["daily_limit_minutes"] % 60)
        ttk.Spinbox(f, from_=0, to=23, width=4, textvariable=v_h).grid(row=r, column=1)
        ttk.Label(f, text="Std.").grid(row=r, column=2, sticky="w")
        ttk.Spinbox(f, from_=0, to=59, width=4, textvariable=v_m).grid(row=r, column=3)
        ttk.Label(f, text="Min.").grid(row=r, column=4, sticky="w")
        r += 1

        v_win = tk.BooleanVar(value=st["window_enabled"])
        ttk.Checkbutton(f, text="Nur in diesem Zeitfenster erlauben:", variable=v_win).grid(
            row=r, columnspan=5, sticky="w", pady=(10, 0))
        r += 1
        v_s, v_e = tk.StringVar(value=st["window_start"]), tk.StringVar(value=st["window_end"])
        ttk.Label(f, text="von (HH:MM)").grid(row=r, column=0, sticky="w")
        ttk.Entry(f, textvariable=v_s, width=7).grid(row=r, column=1)
        ttk.Label(f, text="bis").grid(row=r, column=2)
        ttk.Entry(f, textvariable=v_e, width=7).grid(row=r, column=3)
        r += 1

        ttk.Label(f, text="Leerlauf nicht zählen nach (Min., 0=aus):").grid(
            row=r, columnspan=3, sticky="w", pady=(10, 0))
        v_idle = tk.IntVar(value=st["idle_pause_minutes"])
        ttk.Spinbox(f, from_=0, to=60, width=4, textvariable=v_idle).grid(row=r, column=3, pady=(10, 0))
        r += 1

        ttk.Separator(f).grid(row=r, columnspan=5, sticky="ew", pady=10)
        r += 1
        ttk.Label(f, text="Neue PIN / Passwort (4–32 Zeichen)" + ("" if first_run else ", leer = behalten") + ":").grid(
            row=r, columnspan=3, sticky="w")
        v_p1 = tk.StringVar()
        ttk.Entry(f, textvariable=v_p1, show="•", width=22).grid(row=r, column=3, columnspan=2)
        r += 1
        ttk.Label(f, text="PIN / Passwort wiederholen:").grid(row=r, columnspan=3, sticky="w")
        v_p2 = tk.StringVar()
        ttk.Entry(f, textvariable=v_p2, show="•", width=22).grid(row=r, column=3, columnspan=2)
        r += 1

        def reset_today():
            if messagebox.askyesno("Zurücksetzen", "Genutzte Zeit von heute auf 0 setzen?", parent=d):
                st["used_seconds"] = 0.0
                self.save()

        if not first_run:
            ttk.Button(f, text="Heutige Nutzungszeit zurücksetzen", command=reset_today).grid(
                row=r, columnspan=5, pady=8)
            r += 1

        def save():
            try:
                minutes = v_h.get() * 60 + v_m.get()
                if minutes <= 0:
                    raise ValueError("Das Limit muss mindestens 1 Minute betragen.")
                core.parse_hhmm(v_s.get())
                core.parse_hhmm(v_e.get())
                p1, p2 = v_p1.get(), v_p2.get()
                if first_run or p1 or p2:
                    if p1 != p2:
                        raise ValueError("Die PINs stimmen nicht überein.")
                    core.set_pin(st, p1)
                st["daily_limit_minutes"] = minutes
                st["window_enabled"] = v_win.get()
                st["window_start"] = v_s.get().strip()
                st["window_end"] = v_e.get().strip()
                st["idle_pause_minutes"] = max(0, v_idle.get())
            except (ValueError, tk.TclError) as ex:
                messagebox.showerror("Fehler", str(ex), parent=d)
                return
            self.save()
            d.destroy()
            self.last_tick = time.monotonic()

        ttk.Button(f, text="Speichern", command=save).grid(row=r, columnspan=5, pady=8)
        if first_run:
            d.protocol("WM_DELETE_WINDOW", lambda: None)  # PIN ist Pflicht

    def run(self):
        self.root.mainloop()


class PinPrompt(tk.Toplevel):
    def __init__(self, parent, title):
        super().__init__(parent)
        self.title(title)
        self.result = None
        self.attributes("-topmost", True)
        self.resizable(False, False)
        f = ttk.Frame(self, padding=14)
        f.pack()
        ttk.Label(f, text=title + ":").pack()
        self.v = tk.StringVar()
        e = ttk.Entry(f, textvariable=self.v, show="•", width=24)
        e.pack(pady=6)
        e.focus_set()
        e.bind("<Return>", lambda _e: self.ok())
        ttk.Button(f, text="OK", command=self.ok).pack()
        self.wait_visibility()
        self.grab_set()
        self.wait_window()

    def ok(self):
        self.result = self.v.get()
        self.destroy()


if __name__ == "__main__":
    App().run()
