# Bildschirmzeit-Limiter v5 – mit Wochenplan, Eltern-Zentrale und optionaler Handy-App (ohne Überwachung)

Windows-Programm für **den PC eures eigenen Kindes**. Es zählt, **wie lange das Kind-Konto aktiv angemeldet ist**, und meldet das Konto ab, wenn die Zeit des Tages aufgebraucht ist, der Tag gesperrt ist oder das erlaubte Zeitfenster vorbei ist. Das Kind kann es **ohne Administrator-Passwort weder beenden, noch löschen, noch umgehen** – vorausgesetzt, das Kind-Konto ist ein **Standardbenutzer** (Pflicht).

**Neu in v5**
- **Eltern-PIN ist jetzt ein Passwort:** 4–32 Zeichen mit Buchstaben, Ziffern und Sonderzeichen (statt 4–8 Ziffern), am PC und in der Handy-App. Alte Ziffern-PINs und ihr gespeicherter Hash bleiben gültig.
- **Installer-Voreinstellung „Nur Wochenende, 2 Std.“** (Mo–Fr gesperrt, Sa+So 2 Std. ohne Zeitfenster) ist jetzt die Vorgabe, und der Installer kennt die Parameter `-ChildAccount` und `-Preset` (siehe Schritt 2).

**Neu in v4**
- **Handy-App (Android, optional, standardmäßig AUS):** „Eltern Bildschirmzeit“ zeigt euch unterwegs die **Restzeit von heute**, die heutige Regel, den Wochenplan und ob das Kind gerade angemeldet oder gesperrt ist. Ihr könnt **+15/+30/+60 Min., „Heute unbegrenzt“, „Heute sperren“, „Freigaben aufheben“** und den **Wochenplan** ändern – mit der Eltern-PIN / dem Passwort. Siehe Kapitel „Handy-App“. Die App zeigt **nur**, was der Limiter ohnehin kennt – keine Überwachung.

**Neu in v3**
- **Wochenplan Montag–Sonntag:** pro Tag eigenes Limit, „gesperrt“ (kein Spielen an dem Tag) oder „unbegrenzt“, dazu optional ein erlaubtes Zeitfenster. Das war in v2 **nicht** dabei (dort gab es nur ein Limit für alle Tage).
- **Eltern-Zentrale:** ein Fenster (Windows-Oberfläche, deutsch) für Wochenplan, heutige Zeit, Freigaben, PIN und Kind-Konto. Kein Python nötig.
- **Restzeit-Anzeige fürs Kind** ist jetzt ebenfalls PowerShell (nur lesen) und zeigt auch die eigene Woche.

> **Ehrlich vorweg:** Ich konnte das auf keinem Windows-PC ausprobieren. Die Rechen- und Ablauflogik (inkl. Wochentage) ist unter Linux mit PowerShell 7 und Python getestet. Die Fenster (WinForms) laufen unter Linux nicht; ihr Ablauf wurde dort nur mit Attrappen geprüft, nicht mit echten Windows-Steuerelementen. Die Windows-Teile (Installer, Aufgabenplanung, Dateirechte, Sitzungs-Abfrage, Abmelden, UAC, Verknüpfung) sind sorgfältig geschrieben, aber **ungetestet**. Bitte beim ersten Mal in Ruhe ausprobieren („Schutz testen“), bevor ihr euch darauf verlasst. Siehe „Was ist getestet?“.

## Wie es funktioniert (kurz)
```
Eltern (Administrator)                         Kind (Standardbenutzer)
 Install-ScreenTimeLimiter.ps1                 kann nur LESEN/AUSFÜHREN in C:\Program Files\ScreenTimeLimiter
   ├─ Dateien → C:\Program Files\ScreenTimeLimiter   (Benutzer: nur lesen)
   ├─ Daten   → C:\ProgramData\ScreenTimeLimiter     (Benutzer: kein Zugriff, außer public\status.json: lesen)
   └─ Geplante Aufgabe „ScreenTimeLimiterEnforcer“ (läuft als SYSTEM)
        alle ~15 s: liest config.json (Wochenplan), Kind-Sitzung aktiv & nicht gesperrt? → Zeit +15 s
        Limit/Fenster überschritten oder Tag gesperrt? → Warnung → nach 30 s Abmeldung
        erneute Anmeldung → nach 10 s wieder Abmeldung
 Eltern-Zentrale (Startmenü „Eltern - Bildschirmzeit“) → UAC + Eltern-PIN
   ├─ Wochenplan speichern  → schreibt die geschützte config.json → gilt nach ca. 15 s
   └─ +15/+30/+60, heute unbegrenzt/gesperrt … → Befehl an den Enforcer → gilt nach ca. 15 s
 Restzeit-Anzeige (Kind, nur lesen) liest nur public\status.json
```
Der Zähler läuft **als SYSTEM**, nicht im Konto des Kindes. Ein Standardbenutzer kann den Prozess nicht beenden, die Dateien nicht löschen oder ändern, die Geplante Aufgabe nicht stoppen/löschen und die Zeitdaten nicht verändern.

## Der Wochenplan
Für **jeden Wochentag** (Montag … Sonntag) gilt eine eigene Regel:

| Modus | Bedeutung |
|---|---|
| **Limit** | so viele Stunden/Minuten aktive Zeit an diesem Tag (z. B. 1 Std. 00 Min.) |
| **Gesperrt** | an diesem Tag kein Spielen: das Kind wird sofort wieder abgemeldet |
| **Unbegrenzt** | an diesem Tag keine Zeitbegrenzung (ein Zeitfenster kann trotzdem gesetzt werden) |

Zusätzlich pro Tag optional **„nur von–bis“** (erlaubtes Zeitfenster, z. B. 16:00–19:00). Außerhalb des Fensters wird abgemeldet, auch wenn noch Zeit übrig wäre.

**Voreinstellungen** (Knöpfe in der Eltern-Zentrale, Auswahl im Installer):
- **Schule / Wochenende:** Mo–Fr 1 Std., 16:00–19:00; Sa/So 3 Std., 10:00–21:00. Das ist nur ein Startwert – jeder Tag lässt sich danach einzeln ändern.
- **Gleich jeden Tag:** in der Eltern-Zentrale werden alle Tage wie die Zeile Montag; im Installer wird nach einem gemeinsamen Limit und optional Zeitfenster gefragt.
- **Nur am Wochenende:** Mo–Fr gesperrt, Sa/So 3 Std., 10:00–21:00.

**Zeitfenster über Mitternacht** (z. B. 20:00–02:00): Der Abendteil gehört zur Regel des Tages, an dem er beginnt; der Teil nach Mitternacht (00:00–02:00) gehört zur Regel des **Vortags**. Ist einer der beiden Tage „gesperrt“, gibt es diesen Nachtteil nicht. Das Tageslimit zählt trotzdem pro Kalendertag (Zähler um Mitternacht auf 0).

**Welcher Tag ist „heute“?** Der Tag in der Zeitzone, die beim Installieren festgelegt wurde (der Kalendertag wechselt um 00:00 dieser Zeitzone). Wer die Zeitzone ändert (z. B. Umzug), startet den Installer erneut.

**Einmalige Änderungen für heute** (Knöpfe unter „Heute“) überschreiben den Wochenplan **bis Mitternacht**; danach gilt wieder der Plan. Die **letzte** Aktion gewinnt (z. B. „Heute sperren“ nach „+30 Min.“ sperrt; „+30 Min.“ nach „Heute sperren“ hebt die Sperre auf).

**Alte Konfiguration (v2):** Fehlt der Wochenplan in der config.json, gilt das bisherige einzelne Tageslimit samt Zeitfenster für alle sieben Tage. Beim ersten Speichern in der Eltern-Zentrale wird daraus ein Wochenplan.

## Was es tut
- zählt die **aktive Zeit** des Kind-Kontos: Konto angemeldet **und nicht gesperrt** (Windows-Sperrbildschirm, Win+L und Benutzerwechsel zählen nicht)
- **Wochenplan** wie oben (Limit, gesperrt, unbegrenzt, Zeitfenster – je Tag)
- Warnung **5 Minuten** und **1 Minute** vorher (auch vor dem Ende eines Zeitfensters), dann Meldung und **Abmeldung** (Programme des Kindes werden dabei geschlossen – ungespeicherte Arbeit geht verloren, deshalb die Warnungen)
- **Neustart-fest:** startet mit dem PC, wird jede Minute neu gestartet, falls es abstürzt
- Zähler um **Mitternacht** zurücksetzen; die Zeitzone ist beim Installieren festgelegt (Umstellen der Zeitzone bringt dem Kind nichts); wird die Uhr zurückgestellt, bleibt der Zähler erhalten
- **Eltern-Freigabe und Wochenplan-Änderung** nur mit Administrator-Passwort (UAC) **und** PIN
- kleine **Restzeit-Anzeige** fürs Kind (nur Anzeige)
- PIN: nie im Klartext, nur gesalzener PBKDF2-SHA256-Hash (200 000 Runden); die config.json ist für das Kind nicht lesbar

## Was es NICHT tut (bewusst)
- **keine Überwachung:** kein Keylogger, keine Screenshots, kein Browser-/Programmverlauf, kein Mitlesen von Nachrichten
- es wird nur gespeichert: Einstellungen (Wochenplan), **heute** genutzte Sekunden pro Konto, Freigaben von heute und ein kleines Betriebslog (`enforcer.log`: Start, Fehler, „Sitzung X abgemeldet“, „Eltern-Befehl ausgeführt“ – ohne Inhalte)
- **ohne Handy-App keine Netzwerkverbindung** – nichts wird irgendwohin gesendet. **Nur wenn ihr die Handy-App aktiviert**, sendet der PC verschlüsselt seinen Limiter-Status (Restzeit, Regel, Wochenplan, aktiv/gesperrt) an öffentliche Relay-Server und holt eure Befehle ab (Kapitel „Handy-App“)
- sperrt sonst nichts (keine Webseiten, kein WLAN, kein Beenden anderer Programme); andere Konten (Eltern) werden nie angerührt

Sprecht mit eurem Kind **offen** darüber: dass das Programm läuft, was es zählt und warum. Zeigt ihm die Restzeit-Anzeige und den Wochenplan.

---

## Voraussetzungen
- Windows 10 oder 11 (Home oder Pro), Windows PowerShell 5.1 (ist dabei). Es wird **kein Python** gebraucht (weder für die Sperre noch für die Fenster).
- Ihr habt ein **Administrator-Konto** mit Passwort (gehört den Eltern, das Kind kennt das Passwort nicht).
- Das Kind hat ein **lokales Standardbenutzer-Konto**.

## Schritt 1: Kind-Konto als Standardbenutzer (PFLICHT)
**Ohne diesen Schritt hält der Schutz nicht:** Ein Administrator-Konto kann alles entfernen. Der Installer verweigert deshalb die Installation für Administrator-Konten.
1. Mit dem Eltern-Admin-Konto anmelden.
2. Einstellungen → Konten → **Familie** (oder „Andere Benutzer“) → Konto des Kindes → **Kontotyp ändern → Standardbenutzer**. Neues Konto: „Konto hinzufügen“, danach Typ prüfen.
3. Kein Administrator-Passwort an das Kind weitergeben, keine automatische Admin-Anmeldung einrichten. Das Kind soll sich **nicht** mit dem Admin-Konto anmelden können (eigenes Passwort).
4. Prüfen: Einstellungen → Konten → Familie und andere Benutzer: beim Kind-Konto muss „Standardbenutzer“ stehen (nicht „Administrator“).

## Schritt 2: Installieren (als Administrator)
1. Den entpackten Ordner `screen-time-limiter-v5` auf den Kinder-PC legen (z. B. auf den Desktop des **Eltern**-Kontos). Er wird nur zum Installieren gebraucht.
2. Mit dem **Eltern-Admin-Konto**: Doppelklick auf `Install-ScreenTimeLimiter.bat` (fragt nach Administratorrechten),
   **oder** PowerShell „Als Administrator ausführen“ und:
   ```powershell
   Set-Location "C:\Pfad\zu\screen-time-limiter-v5"
   powershell -ExecutionPolicy Bypass -File .\Install-ScreenTimeLimiter.ps1
   ```
3. Fragen beantworten:
   - **Name des Kind-Kontos** (der Installer listet die lokalen Konten; Administratoren sind markiert)
   - **Startwert für den Wochenplan:** [1] **„Nur Wochenende, 2 Std.“** (Vorgabe: Mo–Fr gesperrt, Sa+So je 2 Std. ohne Zeitfenster, also ganztägig), [2] „Schule / Wochenende“, [3] „Gleiches Limit jeden Tag“ (fragt nach Limit und optional Zeitfenster), bei einer vorhandenen Installation außerdem [4] „Vorhandene Einstellungen behalten“
   - **Eltern-PIN / Passwort** (4–32 Zeichen: Buchstaben, Ziffern, Sonderzeichen wie `!?#-_.@`, keine Leerzeichen; Groß-/Kleinschreibung zählt; zweimal). Alte reine Ziffern-PINs (4–8) funktionieren weiter. Die Eingabe wird immer **interaktiv** abgefragt, nie als Parameter.
   - ob die **Eltern-Zentrale** gleich geöffnet werden soll, um den Wochenplan fein einzustellen

   **Schnell-Start per Parameter** (überspringt die Fragen nach Konto und Wochenplan; PIN/Passwort wird trotzdem eingetippt):
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Install-ScreenTimeLimiter.ps1 -ChildAccount Max -Preset wochenende2h
   ```
   oder per Doppelklick-Datei: `Install-ScreenTimeLimiter.bat -ChildAccount Max -Preset wochenende2h`.
   `-Preset` kann `wochenende2h` (Mo–Fr gesperrt, Sa+So 2 Std. ganztägig), `schule`, `gleich` oder `behalten` sein. Beispiel „Max“: Montag bis Freitag gesperrt, Samstag und Sonntag je 2 Stunden ohne Zeitfenster.
4. Am Ende meldet der Installer „OK: Der Enforcer läuft als SYSTEM“. Falls nicht: `C:\ProgramData\ScreenTimeLimiter\enforcer.log` ansehen (als Admin) und in der Aufgabenplanung die Aufgabe `ScreenTimeLimiterEnforcer` prüfen.
5. Den Installationsordner danach nicht in einem Ordner liegen lassen, auf den das Kind Zugriff hat. Die installierten Dateien liegen sicher in `C:\Program Files\ScreenTimeLimiter`.

Der Installer kann **erneut** ausgeführt werden (Update oder Neu-Einstellung). Die alten Werte sind Vorgabe; der Zähler von heute wird dabei zurückgesetzt. Feine Änderungen am Wochenplan macht man **besser in der Eltern-Zentrale** (ohne Neuinstallation).

## Eltern-Zentrale (Wochenplan, Freigaben, PIN)
Start: Startmenü → **„Eltern - Bildschirmzeit“** (oder `C:\Program Files\ScreenTimeLimiter\Eltern-Zentrale.ps1`, Rechtsklick → „Mit PowerShell ausführen“ / `Eltern-Zentrale.ps1` über die Verknüpfung).

1. Windows fragt nach der **Administrator-Berechtigung** (UAC). Wichtig: Ist euer Eltern-Konto selbst Administrator, fragt Windows je nach Einstellung nur nach einem Klick auf „Ja“; das **Passwort** wird verlangt, wenn man vom Standardkonto des Kindes aus startet. Deshalb gibt es als zweite Hürde die **Eltern-PIN**, die zu Beginn abgefragt wird.
2. Oben, Bereich **„Heute“:** Kind-Konto, genutzte und **verbleibende Zeit**, Hinweise (z. B. „Heute unbegrenzt freigegeben“) und ob der Wächter-Dienst läuft. Knöpfe:
   **+15 / +30 / +60 Min.**, **Heute unbegrenzt**, **Heute sperren**, **Freigaben aufheben**, **Nutzung auf 0** (heutigen Zähler zurücksetzen). Diese Aktionen wirken sofort (nach ca. 15 s) und gelten bis Mitternacht.
3. **Wochenplan-Tabelle:** je Tag Modus (Limit/Gesperrt/Unbegrenzt), Std. und Min., „nur von–bis“ mit Uhrzeiten. Knöpfe **Schule / Wochenende**, **Gleich jeden Tag (wie Montag)**, **Nur am Wochenende** füllen die Tabelle als Startwert.
4. **Kind-Konto(en)** (mehrere mit Komma) und **PIN ändern …**.
5. **Speichern** schreibt den Plan in die geschützte `config.json`. Der Enforcer liest sie bei jedem Durchlauf neu: **Änderungen gelten nach ca. 15 Sekunden**. Ohne „Speichern“ gelten Änderungen an der Tabelle **nicht** (die Titelzeile zeigt „ungespeicherte Änderungen“).

**Eine „+Minuten“-Freigabe** gilt auch außerhalb des Zeitfensters und hebt eine Sperre für heute auf. Umgekehrt hebt „Heute sperren“ vorherige Freigaben auf – die letzte Aktion gewinnt. Ein im Wochenplan **gesperrter** Tag lässt sich also mit „+15 Min.“ oder „Heute unbegrenzt“ ausnahmsweise öffnen.

**Ohne Fenster (Notfall/Konsole):** `Parent-Unlock.ps1` bietet dasselbe als Textmenü (UAC + PIN): +15/+30/+60, andere Minutenzahl, heute unbegrenzt, heute sperren, Freigaben aufheben, Nutzung auf 0.

## Handy-App (optional, ab v4)
**Was sie kann:** Dashboard mit großem Restzeit-Ring pro Kind-Konto, die Knöpfe +15/+30/+60 Min., „Heute unbegrenzt“, „Heute sperren“, „Freigaben aufheben“, ein Wochenplan-Editor (Limit/Gesperrt/Unbegrenzt, optionales Zeitfenster je Tag), eine Anzeige „PC nicht erreichbar“, automatische Aktualisierung alle 15 s (nach einem Befehl kurz schneller) und – nur solange die App geöffnet ist – eine optionale Meldung, wenn die Zeit abläuft. Es gibt **keinen Hintergrunddienst**.

**Was sie NICHT kann (bewusst):** keine Apps, Webseiten, Nachrichten, Bildschirminhalte oder Standorte. „Nutzung auf 0“ gibt es in der App absichtlich nicht (nur am PC).

**Koppeln (einmalig):**
1. Auf dem PC: Installer (Frage „Handy-App-Zugriff aktivieren?“ mit *j*) **oder** Eltern-Zentrale → **„Handy-App …“** → Haken setzen. Es wird ein **frischer, zufälliger Kopplungscode** erzeugt (`STL1-XXXX-…`), nur auf diesem PC gespeichert (`C:\ProgramData\ScreenTimeLimiter\relay.json`, für das Kind nicht lesbar). In dieser APK und diesem Paket steckt **kein** Schlüssel.
2. `Eltern-Bildschirmzeit.apk` auf dem Handy installieren („Installation aus unbekannten Quellen“ erlauben; die App ist nur mit einem Debug-Zertifikat signiert, nicht im Play Store).
3. In der App den Kopplungscode eintippen oder einfügen (Groß-/Kleinschreibung egal; ein Tippfehler wird durch die Prüfsumme erkannt). Nach ca. 15–90 s erscheint der erste Status.
4. Befehle brauchen die **Eltern-PIN / das Passwort** (dasselbe wie in der Eltern-Zentrale, 4–32 Zeichen, normales Passwortfeld mit „Anzeigen“; alte Ziffern-PINs gehen weiter). Die App sendet sie nur innerhalb des Ende-zu-Ende-verschlüsselten Befehls. Optional kann die App sie im Android-Keystore merken („PIN speichern“, standardmäßig AUS; „Heute unbegrenzt“ und „Heute sperren“ fragen immer nach). Drei falsche Eingaben sperren Befehle für 30 s, dann 2 min, 10 min, 1 h.

**Neu koppeln:** Eltern-Zentrale → „Handy-App …“ → **Neu koppeln …**. Das alte Handy verliert **sofort** den Zugriff (anderer Schlüssel = anderes Thema). Ausschalten: Haken entfernen – dann wird nichts mehr gesendet. Der Uninstaller löscht die Relay-Einstellungen.

**Wie es technisch läuft:** Befehle gehen als AES-256-GCM-verschlüsselte Nachricht über ein geheimes ntfy-Thema (`ntfy.sh`), der PC fragt sie ab (ausgehend, keine Portfreigabe nötig) und prüft PIN, Format, Alter (max. 10 min) und Wiederholung. Der letzte Status liegt verschlüsselt unter einem geheimen Schlüsselnamen bei `textdb.dev`. Thema und Schlüsselname werden per HMAC aus dem Kopplungscode abgeleitet. Details: `PROTOCOL_RELAY.md`.

**Ehrliche Grenzen der Handy-App:**
- Das ist **öffentliche Infrastruktur Dritter** (ntfy.sh, textdb.dev) ohne Verfügbarkeitszusage. Inhalte sind Ende-zu-Ende verschlüsselt, aber **Metadaten** (dass eine Nachricht zu einem Zeitpunkt gesendet wurde, Größe, IP) sind für den Betreiber sichtbar. Wer den geheimen Schlüsselnamen kennt (nur mit dem Kopplungscode ableitbar), könnte den Status überschreiben – er kann ihn aber nicht fälschen (Entschlüsselung/Prüfung scheitert), keine Befehle ausführen und höchstens einen alten Status erneut einspielen – der wird in der App wegen des Zeitstempels als „veraltet“ angezeigt.
- **Der PC muss eingeschaltet und online sein**, sonst zeigt die App „PC nicht erreichbar“ und Befehle kommen erst später an (nach 10 min verfallen sie).
- Wer den **Kopplungscode** hat **und** die PIN kennt, kann Zeit freigeben. Den Code wie ein Passwort behandeln. Das Kind darf ihn nicht sehen (er steht nur in der Eltern-Zentrale/auf eurem Handy).
- Die gespeicherte PIN schützt vor anderen Apps und Backups, **nicht** vor jemandem, der euer entsperrtes Handy benutzt (keine Fingerabdruck-Abfrage).
- Die Anzeige verlässt sich darauf, dass Handy- und PC-Uhr ungefähr stimmen; ältere Daten (> ca. 3,5 min) werden als „veraltet“ markiert und nicht weitergezählt.
- Kein QR-Code (der Code wird getippt/eingefügt), kein Push im Hintergrund.

## Restzeit-Anzeige fürs Kind
Der Installer trägt `Restzeit-Anzeige.ps1` in den Autostart ein (bei jeder Anmeldung, für alle Benutzer). Das kleine Fenster „Bildschirmzeit“ zeigt die **verbleibende Zeit**, den Hinweis (z. B. „Heute gesperrt“, „bis 19:00 erlaubt“) und die Woche. Es liest nur `public\status.json` und kann **nichts ändern**; schließt das Kind es, läuft die Sperre trotzdem. Der Installer-Schalter `-NoViewer` lässt die Anzeige weg. Optional gibt es weiterhin `viewer\stl_viewer.py` (Python/tkinter), wird aber nicht mehr eingetragen.

## Schutz testen (bitte einmal machen)
Mit dem **Kind-Konto** anmelden (Standardbenutzer) und prüfen:
1. **Task-Manager → Details:** `powershell.exe` läuft als `SYSTEM`. Rechtsklick → „Task beenden“ → **Zugriff verweigert**.
2. `C:\Program Files\ScreenTimeLimiter` öffnen: Datei löschen oder umbenennen → **Administrator-Passwort wird verlangt** (und ohne Passwort geht es nicht).
3. `C:\ProgramData\ScreenTimeLimiter\config.json` öffnen → **kein Zugriff**.
4. `taskschd.msc` → Aufgabe `ScreenTimeLimiterEnforcer` lässt sich nicht beenden/deaktivieren/löschen.
5. Zum Probieren das heutige Limit in der Eltern-Zentrale kurz auf 2 Minuten setzen und speichern: Warnung bei 1 Minute, Abmeldung nach Ablauf, erneute Anmeldung → nach ca. 10 s wieder abgemeldet.
Wenn einer dieser Punkte **nicht** so ist, ist das Konto vermutlich Administrator oder die Rechte sind nicht gesetzt: bitte nicht darauf verlassen.

Als Admin kann man die Rechte so ansehen: `icacls "C:\Program Files\ScreenTimeLimiter"` und `icacls "C:\ProgramData\ScreenTimeLimiter"`. Erwartet: `SYSTEM` und `Administratoren` Vollzugriff; `Benutzer` nur Lesen/Ausführen (Programmordner) bzw. nur `public` lesbar (Datenordner).

## Zusätzliche Hinweise zum Betrieb
- **Zeit für ein Fest/Ausnahmetag:** In der Eltern-Zentrale „Heute unbegrenzt“ – gilt bis Mitternacht, danach wieder der Wochenplan.
- **Nur an bestimmten Tagen spielen:** Die anderen Tage auf „Gesperrt“ stellen (oder „Nur am Wochenende“), speichern, ca. 15 s warten.
- **PIN / Passwort vergessen:** `Install-ScreenTimeLimiter.ps1` als Administrator erneut ausführen (setzt eine neue PIN).

## Deinstallieren
1. Mit dem Admin-Konto: `Uninstall-ScreenTimeLimiter.bat` (oder `Uninstall-ScreenTimeLimiter.ps1` als Administrator).
2. Eltern-PIN eingeben, mit `j` bestätigen. Es werden Aufgabe, Autostart-Eintrag, Verknüpfungen, Programm- und Datenordner entfernt.
3. **PIN vergessen?** Siehe oben (Installer erneut ausführen, danach deinstallieren). Das geht nur mit dem Administrator-Passwort.

## Ehrliche Grenzen (was Software nicht verhindern kann)
- **Das Administrator-Passwort ist der eigentliche Schutz.** Die PIN ist eine zweite Hürde für Eltern-Zentrale und Freigabe-Werkzeug. Wer das Admin-Passwort kennt (oder eine Admin-Sitzung offen findet), kann alles ändern. Admin-Passwort geheim halten, Admin-Konto sperren (Win+L), wenn ihr vom PC weggeht.
- **Standardbenutzer ist Pflicht.** Ein Kind mit Administratorrechten kann alles entfernen. Der Installer verweigert Administrator-Konten. Auch Konten in Gruppen wie „Sicherungs-Operatoren“ sind ungeeignet.
- **UAC-Verhalten:** Ob Windows beim Start der Eltern-Zentrale ein Passwort oder nur einen Klick verlangt, hängt vom Konto (Administrator oder Standard) ab. Meldet ihr euch mit dem Admin-Konto an, ist die **PIN** der einzige Schutz gegen ein Kind, das an eurem angemeldeten PC sitzt – Konto sperren!
- **Abgesicherter Modus, anderes Betriebssystem (Linux-USB), BIOS/UEFI-Reset, Festplatte ausbauen oder Windows neu installieren** kann Software **nicht** verhindern. Gegenmittel außerhalb dieses Programms: UEFI-Passwort, Boot von USB sperren, BitLocker. Das Verhalten im abgesicherten Modus ist **nicht geprüft**.
- **Es zählt „angemeldet und nicht gesperrt“**, nicht „wirklich benutzt“. Wer den PC angemeldet stehen lässt, verbraucht Zeit. Tipp: Windows so einstellen, dass der Bildschirm nach einigen Minuten gesperrt wird.
- **Andere Geräte** (Handy, Konsole, Schul-PC) und ein **zweites Konto** auf demselben PC, das ihr nicht eingetragen habt, sind nicht erfasst. Jedes Kind-Konto eintragen, jedes andere Konto mit Passwort schützen.
- **Uhr/Zeitzone:** Standardbenutzer dürfen die Systemzeit normalerweise nicht ändern. Gezählt wird mit einem Zeitgeber, der nicht von der Uhr abhängt. **Wochentag, Tageswechsel und Zeitfenster** nutzen die Uhr in der beim Installieren festgelegten Zeitzone; wird die Uhr zurückgestellt, bleibt der Zähler erhalten. Wird sie vorgestellt (nur mit Admin-Rechten), beginnt ein neuer Tag.
- **Genauigkeit:** ca. 15 Sekunden. Ruhezustand/Standby wird nicht mitgezählt.
- **Mehrere gleichzeitige Sitzungen** desselben Kontos zählen zusammen einfach.
- **Windows-Konten mit Microsoft-Konto:** Der Installer nutzt den lokalen Kontonamen (so, wie ihn `Get-LocalUser` anzeigt). Domänenkonten werden nicht unterstützt.
- Antivirus-Programme können ein PowerShell-Skript, das als SYSTEM läuft und Benutzer abmeldet, anmeckern. Gegebenenfalls Ausnahme für `C:\Program Files\ScreenTimeLimiter` setzen.
- **Sprecht mit eurem Kind.** Technik ersetzt kein Gespräch: erklärt die Regeln, warum es sie gibt und wie ihr sie anpasst.

## Was ist getestet, was nicht?
**Getestet (Linux, PowerShell 7.6, Python 3):** `python3 -m unittest discover -s tests -v` und `cd standalone && python3 -m unittest test_core`
- Wochentags-, Zeitfenster-, Restzeit- und Sperr-Logik (inkl. Fenster über Mitternacht, gesperrte/unbegrenzte Tage, alte Config ohne Wochenplan): 300 Zufalls- und 200 Grenzfälle stimmen zwischen PowerShell und der Python-Referenz (`standalone/core.py`) überein
- PBKDF2-SHA256-PIN-Hash identisch mit Python (auch für Passwörter mit Buchstaben/Sonderzeichen); PIN-/Passwort-Format (4–32 Zeichen) und Prüfung, alte Ziffern-PINs
- Szenarien mit simulierten Sitzungen: nur aktives, nicht gesperrtes Kind-Konto zählt; Warnung bei 5/1 Min.; Abmeldung nach Frist; Wiederanmeldung; Eltern-Aktionen (+Min., unbegrenzt, sperren, „letzte Aktion gewinnt“); Tageswechsel; Uhr zurückgestellt; Wochenplan wird bei Config-Änderung nach dem nächsten Durchlauf übernommen; Status-Datei; Config-Roundtrip (`cycle_tests.ps1`, 124 Prüfungen)
- Ablauf der **Eltern-Zentrale** und der **Restzeit-Anzeige** mit Windows-Forms-**Attrappen** (Laden, Tabelle füllen, Validieren, Speichern, Aktionsknöpfe, PIN ändern) – das prüft Logik, Variablen-Gültigkeit und Fehlerbehandlung, **nicht** das echte Aussehen/Verhalten der Steuerelemente
- **Trockenlauf des Installers** mit Attrappen für Konten, Aufgabenplanung und Registry (Config, Dateien, Wochenplan-Vorgabe, PIN-Hash)
- alle `.ps1`-Dateien parsen fehlerfrei und haben UTF-8-BOM
- **Handy-App-Relay (PC-Seite):** Schlüsselableitung, Kopplungscode, Verschlüsselung und Befehlsprüfung (PIN, Sperre nach Fehlversuchen, Alter, Wiederholung, Plan-Validierung; `relay_tests.ps1`, 86 Prüfungen); Ende-zu-Ende gegen einen **lokalen Attrappen-Server** mit einer unabhängigen Python-Nachbildung der App (+15 Min., falsche PIN, Wochenplan ändern, fremde Nachrichten, Serverausfall und Erholung)
- **Handy-App:** 31 JVM-Unit-Tests (u. a. Passwort mit Sonderzeichen durch die Verschlüsselung, PIN-Regeln) (gleiche Testvektoren wie PowerShell: Thema, Schlüsselname, Kopplungscode, Umschläge; Statusauswertung, Restzeit-Logik, Befehlsaufbau, Client gegen Attrappe); die APK baut und ist signiert

**Nicht getestet (kein Windows-PC und kein Handy verfügbar):**
- die **Handy-App auf einem echten Android-Gerät** (Aussehen, Zeitwähler, Keystore-PIN, Benachrichtigungen, Verhalten bei schlechtem Netz) – es gibt nur den Build und JVM-Tests
- das Relay auf **echtem Windows** (C#-Kompilierung unter Windows PowerShell 5.1, Rechte an `relay.json`, Verhalten hinter Firmen-Firewall/Proxy) und die Erreichbarkeit/Limits der öffentlichen Server ntfy.sh und textdb.dev im Dauerbetrieb
- die **echten Windows-Forms-Fenster** (Layout, Schriftgrößen, DateTimePicker/NumericUpDown-Verhalten, Anzeige hoher DPI)
- UAC-Selbsterhöhung der Eltern-Zentrale und von `Parent-Unlock.ps1`, die `.bat`-Starter, Startmenü-Verknüpfung, Autostart der Anzeige
- der echte Installer/Deinstaller: Rechtevergabe mit `icacls`, Registrierung der Geplanten Aufgabe (XML) und Sofortstart, Kontenliste
- die Windows-Sitzungs-API (`WTSEnumerateSessions`, Sperrstatus, `WTSSendMessage`, `WTSLogoffSession`) auf echten Windows-Versionen
- ob die Schutzwirkungen (Task-Manager „Zugriff verweigert“, Dateien nicht löschbar) auf eurem PC genau so greifen – deshalb der Abschnitt „Schutz testen“

Wenn etwas hakt: Fehlermeldung bzw. Inhalt von `C:\ProgramData\ScreenTimeLimiter\enforcer.log` schicken.

## Dateien
| Datei | Zweck |
|---|---|
| `Install-ScreenTimeLimiter.ps1` / `.bat` | Installer (Administrator) |
| `Uninstall-ScreenTimeLimiter.ps1` / `.bat` | Deinstaller (Administrator + PIN) |
| `Eltern-Zentrale.ps1` | Fenster für Eltern: Wochenplan, Freigaben, PIN, Kind-Konto (UAC + PIN) |
| `Restzeit-Anzeige.ps1` | kleines Fenster fürs Kind, nur lesen |
| `StlRelay.ps1` | Handy-App-Relay (Kopplungscode, Verschlüsselung, Befehle prüfen, Status senden), unter Linux getestet |
| `PROTOCOL_RELAY.md` | Protokoll der Handy-App-Verbindung |
| `android/` | Quelltext der Handy-App (Kotlin/Compose); APK separat: `Eltern-Bildschirmzeit.apk` |
| `Parent-Unlock.ps1` | Textmenü als Ersatz zur Eltern-Zentrale (UAC + PIN) |
| `Enforcer.ps1` | läuft als SYSTEM: Sitzung abfragen, Zeit zählen, abmelden |
| `StlCommon.ps1`, `StlEnforce.ps1` | Logik (Wochenplan, Einstellungen, PIN, Zeit, Zyklus), unter Linux getestet |
| `viewer/stl_viewer.py` | optionale Python-Restzeit-Anzeige (nicht mehr automatisch eingetragen) |
| `tests/` | Tests (Python + PowerShell 7, inkl. Attrappen-Tests) |
| `standalone/` | Python-Referenz der Logik (`core.py`) und Tests; **ohne** Manipulationsschutz, nur für Tests |

## Zugriffsrechte im Überblick
| Ort | SYSTEM / Administratoren | Benutzer (Kind) |
|---|---|---|
| `C:\Program Files\ScreenTimeLimiter` | Vollzugriff | lesen/ausführen |
| `C:\ProgramData\ScreenTimeLimiter` (`config.json` mit Wochenplan und PIN-Hash, `state.json`, `commands\`, Log) | Vollzugriff | **kein Zugriff** |
| `C:\ProgramData\ScreenTimeLimiter\public\status.json` (nur Restzeit) | Vollzugriff | lesen |
| Geplante Aufgabe | läuft als SYSTEM, nur Admins ändern | kann nicht ändern |

Abweichung zum ursprünglichen Plan: `config.json` (mit PIN-Hash) ist für Benutzer **nicht** lesbar, damit das Kind den PIN-Hash nicht offline knacken kann; lesbar ist nur die kleine Restzeit-Datei.
