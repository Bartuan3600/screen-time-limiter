# Screen Time Limiter ⏱️ (Windows + Android parent app)

A **parental screen-time limiter for Windows** that cannot be bypassed by a standard (non-admin) child account, plus an optional **Android parent app** to check remaining time and grant extra minutes remotely – without any surveillance.

> 🤖 **Built with AI-assisted development (vibe coding).** I designed the features, tested them and iterated on the result; most of the code was written together with an AI coding assistant.

## Repository layout

| Folder | What |
|---|---|
| [`windows/`](windows) | PowerShell enforcer, installer/uninstaller, parent control panel ("Eltern-Zentrale", WinForms), child "time left" display, encrypted relay client, standalone Python prototype, tests |
| [`parent-app/`](parent-app) | Android app "Eltern Bildschirmzeit" (Kotlin + Jetpack Compose) |

Detailed German user manual: [`windows/README_DE.md`](windows/README_DE.md) · relay protocol: [`windows/PROTOCOL_RELAY.md`](windows/PROTOCOL_RELAY.md)

## Features

- ⏳ Counts **active session time** of the child's Windows account and logs it off when the daily limit is used up, the day is blocked, or the allowed time window is over
- 📅 **Weekly schedule** (Mon–Sun): per-day limit, "blocked" or "unlimited", optional allowed time window (also across midnight), presets ("weekends only", "school days")
- 🛡️ Runs as a **SYSTEM scheduled task**; data in protected ProgramData – a standard user can't stop, delete or change it
- 👨‍👩‍👦 Parent control panel with password/PIN (hashed): +15/+30/+60 min, "unlimited today", "block today", reset
- 🧒 Read-only "time left" window for the child
- 📱 Optional Android parent app: remaining time, today's rule, weekly plan, remote actions – commands are **AES-256-GCM end-to-end encrypted** and sent via ntfy.sh; status stored encrypted on textdb.dev. Topic/key derived from a pairing code (HMAC), replay & age checks
- ✅ Tests: PowerShell logic tests, Python parity tests, shared crypto test vectors for PowerShell / Python / Kotlin

## Tech stack

PowerShell 5.1 (Windows) · WinForms · Windows Task Scheduler · Python 3 (prototype & tests) · Kotlin · Jetpack Compose · AES-256-GCM / HMAC-SHA256

## Install (Windows)

1. Make sure the child's account is a **standard user**.
2. Run as administrator:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\windows\Install-ScreenTimeLimiter.ps1 -ChildAccount Max -Preset wochenende2h
   ```
   You'll be asked interactively for the parent password (never passed as a parameter).
3. Uninstall with `windows\Uninstall-ScreenTimeLimiter.ps1`.

## Build the parent app (Android)

```bash
cd parent-app
./gradlew testDebugUnitTest assembleDebug
```
Requirements: JDK 17, Android SDK 35. Pair it with the PC via the pairing code shown in the parent control panel.

> ⚠️ Honest status: logic is tested on Linux with PowerShell 7 + Python; the Windows-specific parts (task scheduler, ACLs, UAC, WinForms) were written carefully but need testing on a real Windows PC.

## License

[MIT](LICENSE) © 2026 Bartuan3600
