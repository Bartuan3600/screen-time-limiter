# Handy-App-Relay – Protokoll (v1)

Gleiche Konventionen wie das Ausgaben-Relay (ntfy für Befehle, textdb.dev für den letzten Stand, AES-256-GCM-Umschlag),
aber mit **eigenem, pro Installation frisch erzeugtem Schlüssel**. Es wird nie ein Schlüssel einer anderen App verwendet.

## Schlüssel und Kopplungscode
- `key` = 32 Zufallsbytes, erzeugt am PC (`Enable-StlRelay`), gespeichert in `ProgramData\ScreenTimeLimiter\relay.json` (nur SYSTEM/Admins).
- Kopplungscode: `STL1-` + Base32 (RFC 4648, ohne Padding, 52 Zeichen) in 13 Vierergruppen, getrennt durch `-`, + `-` + 4 Zeichen Prüfsumme.
  Prüfsumme = erste 4 Zeichen von Base32(SHA-256(key)[0..4]). Eingabe ist unabhängig von Groß-/Kleinschreibung, Trennzeichen werden ignoriert.
- `topic` = `"stl-" + hex(HMAC-SHA256(key, "stl-topic-v1"))[0:24]`
- `dbkey` = `"stl-" + hex(HMAC-SHA256(key, "stl-status-v1"))[0:24]`
- Fingerabdruck (nur Anzeige) = erste 8 Hex-Zeichen von SHA-256(key).
- Neu koppeln = neuer `key` → neues Thema/neuer Schlüsselname; das alte Handy findet nichts mehr.

## Umschlag (Befehl wie Status)
```json
{"enc":"aes-256-gcm","iv":"<base64, 12 Byte>","data":"<base64, Chiffretext || 16-Byte-Tag>"}
```
Kein AAD. Klartext ist UTF-8-JSON. Entschlüsselung schlägt bei falschem Schlüssel/Manipulation fehl → Nachricht wird ignoriert.
Testvektoren (Test-Schlüssel 0..31): `tests/vectors/relay_vectors.json` (PowerShell-, Python- und Kotlin-Tests nutzen dieselbe Datei).

## Server
- Befehle: `https://ntfy.sh` – App: `POST {server}/{topic}` mit Header `Tags: stl-cmd`, Body = Umschlag (< 4096 Byte).
  PC: `GET {server}/{topic}/json?poll=1&since=<id|Zeit>`; Wiederholungsschutz über ntfy-ID **und** `c:<Befehls-ID>`.
- Status: `https://textdb.dev/api/data` – PC: `POST {db}/{dbkey}` (`Content-Type: text/plain`, Body = Umschlag); App: `GET {db}/{dbkey}?t=<ms>` mit `Cache-Control: no-cache`.
- Nur https. Server sind in `relay.json` änderbar (z. B. selbst gehostetes ntfy).

## Befehl (Klartext)
```json
{"v":1,"id":"[A-Za-z0-9_-]{1,64}","action":"...","user":"Name","minutes":15,"pin":"1234","days":[ ... 7 Regeln ... ]}
```
| action | Felder | Wirkung |
|---|---|---|
| `add_minutes` | `user`, `minutes` 1..720, `pin` | +Minuten heute (hebt Sperre für heute auf) |
| `unlimited_today` | `user`, `pin` | heute unbegrenzt |
| `block_today` | `user`, `pin` | heute gesperrt (hebt Freigaben auf) |
| `clear_extras` | `user`, `pin` | Freigaben von heute aufheben |
| `set_plan` | `days` (genau 7, Montag..Sonntag), `pin` | Wochenplan ersetzen |
| `refresh` | – (keine PIN) | sofort Status veröffentlichen |

`reset_used` („Nutzung auf 0“) gibt es **nicht** über das Relay. PIN / Passwort: 4–32 sichtbare ASCII-Zeichen (Buchstaben, Ziffern, Sonderzeichen, keine Leerzeichen; alte 4–8-stellige Ziffern-PINs bleiben gültig), als String im verschlüsselten Befehl (`pin`), geprüft gegen denselben PBKDF2-Hash wie in der Eltern-Zentrale.
Wochenplan-Regel: `{"mode":"limit|blocked|unlimited","limit_minutes":1..1440,"window_enabled":true|false,"window_start":"HH:mm","window_end":"HH:mm"}`;
Start ≠ Ende; über Mitternacht erlaubt.

Prüfungen am PC (Reihenfolge): Umschlag entschlüsselbar → JSON/Schema → Alter ≤ 600 s (ntfy-Zeit) → nicht schon gesehen → PIN-Sperre aktiv? →
PIN (3 Fehlversuche → Sperre 30 s, danach 120 s, 600 s, 3600 s) → Aktion. Jedes Ergebnis landet in `last_cmds` des nächsten Status.

## Status (Klartext)
```json
{"v":1,"t":"ISO-8601","day":"Sonntag","today_index":6,
 "users":[{"name":"Max","session":"active|locked|disconnected|none","used_seconds":1800,"remaining_seconds":3600,
           "bonus_minutes":15,"unlimited_today":false,"blocked_today":false,"rule":"60 Min.","lock_reason":null}],
 "plan":[ 7 Regeln wie oben ],
 "last_cmds":[{"id":"...","ok":true,"msg":"...","t":"..."}],   // höchstens 8
 "locked_until":null}
```
`remaining_seconds` ist `null` bei „unbegrenzt“. Enthalten ist **nur**, was der Limiter ohnehin kennt – keine Apps, Webseiten, Nachrichten, Standorte.
Veröffentlichung: bei Änderung höchstens alle 30 s, Lebenszeichen alle 90 s, sofort nach einem Befehl; bei Netzfehlern Backoff 30–300 s.
Die App zählt die Restzeit zwischen zwei Abrufen nur bei `session = active` und frischen Daten (< 210 s) weiter herunter.

## Sicherheit / Grenzen
- Vertraulichkeit und Echtheit durch AES-GCM; Metadaten (Zeitpunkt, Größe, IP) sehen die Server-Betreiber. Keine Verfügbarkeitsgarantie.
- Einspielen alter Befehle verhindern ID-Merker und 10-Minuten-Frist; ein altes Status-Paket erscheint in der App als „veraltet“.
- Wer Kopplungscode **und** PIN hat, kann Zeit freigeben. Der Code ist wie ein Passwort zu behandeln.
