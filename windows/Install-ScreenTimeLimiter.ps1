<#
.SYNOPSIS
  Installiert den Bildschirmzeit-Limiter mit Manipulationsschutz (nur als Administrator ausfuehren).
.DESCRIPTION
  - kopiert die Programmdateien nach C:\Program Files\ScreenTimeLimiter (Standardbenutzer: nur lesen/ausfuehren)
  - legt Einstellungen/Zeitzaehler in C:\ProgramData\ScreenTimeLimiter ab (Standardbenutzer: kein Schreibzugriff)
  - registriert eine Geplante Aufgabe, die als SYSTEM laeuft und nicht von Standardbenutzern beendet werden kann
  - legt die Eltern-Zentrale (Oberflaeche fuer Wochenplan/Freigaben) und eine Restzeit-Anzeige fuer das Kind an
  Keine Ueberwachung: es wird nur gezaehlt, wie lange das Kind-Konto aktiv angemeldet ist.
  Optional (Standard: AUS): Handy-App-Zugriff ueber ein verschluesseltes Relay (siehe README_DE.md, Kapitel Handy-App).
.PARAMETER ChildAccount
  Name des Kind-Kontos (ueberspringt die Abfrage), z. B. -ChildAccount Max. Mehrere mit Komma trennen.
.PARAMETER Preset
  Wochenplan-Startwert (ueberspringt die Abfrage): wochenende2h = Mo-Fr gesperrt, Sa+So 2 Std. ohne Zeitfenster (Standard),
  schule, gleich, behalten. Die PIN / das Passwort wird IMMER interaktiv eingegeben (nie als Parameter).
.EXAMPLE
  .\Install-ScreenTimeLimiter.ps1 -ChildAccount Max -Preset wochenende2h
#>
[CmdletBinding()]
param([switch]$NoViewer, [string]$ChildAccount = '', [ValidateSet('', 'wochenende2h', 'schule', 'gleich', 'behalten')][string]$Preset = '')

$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
. (Join-Path $src 'StlCommon.ps1')
. (Join-Path $src 'StlRelay.ps1')

function Fail([string]$m) { Write-Host ("`nABBRUCH: " + $m) -ForegroundColor Red; Read-Host 'Enter zum Schliessen'; exit 1 }
function Read-PlainSecret([string]$Prompt) {
    $sec = Read-Host -Prompt $Prompt -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
function Read-Default([string]$Prompt, [string]$Default) {
    $v = Read-Host ('{0} [{1}]' -f $Prompt, $Default)
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    return $v.Trim()
}

try {
    if (-not (Test-StlIsAdmin)) {
        Fail 'Bitte als Administrator ausfuehren (Rechtsklick auf PowerShell -> "Als Administrator ausfuehren", dann dieses Skript starten).'
    }
    if ($PSVersionTable.PSVersion.Major -lt 5) { Fail 'Windows PowerShell 5.1 oder neuer wird benoetigt (Windows 10/11).' }

    Write-Host ''
    Write-Host '=== Bildschirmzeit-Limiter: Installation ===' -ForegroundColor Cyan
    Write-Host 'Es wird NUR gezaehlt, wie lange das Kind-Konto aktiv angemeldet ist. Keine Ueberwachung,'
    Write-Host 'keine Screenshots, kein Tastatur- oder Browser-Protokoll. Sprecht mit eurem Kind darueber.'
    Write-Host ''

    $installDir = Get-StlInstallDir
    $dataDir = Get-StlDataDir
    $old = Read-StlConfig
    if ($old) { Write-Host 'Vorhandene Installation gefunden: sie wird aktualisiert (alte Werte sind Vorgabe).' -ForegroundColor Yellow }

    # ---- 1. Kind-Konto
    Write-Host 'Lokale, aktivierte Konten auf diesem PC:'
    $adminSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $adminSids = @(Get-LocalGroupMember -SID $adminSid | ForEach-Object { $_.SID.Value })
    $accounts = @(Get-LocalUser | Where-Object { $_.Enabled })
    foreach ($a in $accounts) {
        $tag = if ($adminSids -contains $a.SID.Value) { '  (Administrator)' } else { '' }
        Write-Host ('  - {0}{1}' -f $a.Name, $tag)
    }
    $defaultUsers = ''
    if ($old) { $defaultUsers = (@($old.users) -join ',') }
    $in = if ($ChildAccount) { $ChildAccount } elseif ($defaultUsers) { Read-Default 'Name des Kind-Kontos (mehrere mit Komma trennen)' $defaultUsers } else { Read-Host 'Name des Kind-Kontos (mehrere mit Komma trennen)' }
    $res = Resolve-StlChildAccounts $in
    if ($res.Error) { Fail $res.Error }
    $resolved = @($res.Names)

    # ---- 2. Wochenplan (feinere Einstellung spaeter in der 'Eltern-Zentrale')
    $oldDays = $null
    if ($old) { $oldDays = Get-StlProp $old 'days' }
    Write-Host ''
    Write-Host 'Startwert fuer den Wochenplan (spaeter jederzeit in der Eltern-Zentrale aenderbar):'
    Write-Host '  [1] Nur Wochenende, 2 Std.: Mo-Fr gesperrt, Sa+So je 2 Std. ohne Zeitfenster (Standard)'
    Write-Host '  [2] Schule / Wochenende: Mo-Fr kuerzer, Sa/So laenger'
    Write-Host '  [3] Gleiches Limit an jedem Tag'
    if ($old) { Write-Host '  [4] Vorhandene Einstellungen behalten' }
    $presetNums = @{ 'wochenende2h' = '1'; 'schule' = '2'; 'gleich' = '3'; 'behalten' = '4' }
    $choice = if ($Preset) { Write-Host ("Voreinstellung per Parameter: {0}" -f $Preset); $presetNums[$Preset] } else { Read-Default 'Auswahl' '1' }
    $days = $null
    $limit = 120; $winOn = $false; $wStart = '16:00'; $wEnd = '20:00'
    if ($old) {
        $limit = [int]$old.daily_limit_minutes; $winOn = [bool]$old.window_enabled
        $wStart = [string]$old.window_start; $wEnd = [string]$old.window_end
    }
    switch ($choice) {
        '1' {
            $days = Get-StlPreset 'wochenende2h'
            $limit = 120; $winOn = $false
        }
        '2' {
            $days = Get-StlPreset 'schule'
            $limit = 120
        }
        '3' {
            $limit = 0
            if (-not [int]::TryParse((Read-Default 'Tageslimit in Minuten' ([string]$limit)), [ref]$limit) -or $limit -lt 1 -or $limit -gt 1440) { Fail 'Ungueltiges Limit (1-1440).' }
            $winOn = ((Read-Default 'Nur in einem Zeitfenster erlauben? (j/n)' $(if ($winOn) { 'j' } else { 'n' })).ToLower() -in @('j', 'ja', 'y', 'yes'))
            if ($winOn) {
                $wStart = Read-Default 'Erlaubt von (HH:MM)' $wStart
                $wEnd = Read-Default 'Erlaubt bis (HH:MM)' $wEnd
                [void](ConvertTo-StlMinuteOfDay $wStart); [void](ConvertTo-StlMinuteOfDay $wEnd)
            }
            $rule = if ($winOn) { New-StlDayRule 'limit' $limit $wStart $wEnd } else { New-StlDayRule 'limit' $limit }
            $days = @(1..7 | ForEach-Object { $rule })
        }
        '4' {
            if (-not $old) { Fail 'Es gibt keine vorhandenen Einstellungen.' }
            if ($oldDays) { $days = @($oldDays) }
        }
        default { Fail 'Ungueltige Auswahl.' }
    }
    if ($days) {
        $dErr = Test-StlDays $days
        if ($dErr) { Fail $dErr }
    }

    # ---- 3. PIN
    $pin1 = Read-PlainSecret 'Neue Eltern-PIN / Passwort (4-32 Zeichen: Buchstaben, Ziffern, Sonderzeichen)'
    $pin2 = Read-PlainSecret 'PIN / Passwort wiederholen'
    if ($pin1 -cne $pin2) { Fail 'Die Eingaben stimmen nicht ueberein.' }
    if (-not (Test-StlPinFormat $pin1)) { Fail 'Die PIN / das Passwort muss 4 bis 32 Zeichen haben (Buchstaben, Ziffern, Sonderzeichen, keine Leerzeichen).' }

    # ---- 4. Alte Aufgabe/Prozess stoppen
    Write-Host "`nBereite vor ..."
    if (Get-ScheduledTask -TaskName $script:StlTaskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $script:StlTaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $script:StlTaskName -Confirm:$false
    }
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*ScreenTimeLimiter*Enforcer.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 1

    # ---- 5. Datenordner + Rechte
    New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
    Set-StlAcl $dataDir 'RX' -UsersOnFolderOnly          # Benutzer: nur den Ordner selbst auflisten, keine Dateien
    foreach ($sub in @((Get-StlCommandDir))) { New-Item -ItemType Directory -Path $sub -Force | Out-Null; Set-StlAcl $sub $null }
    New-Item -ItemType Directory -Path (Get-StlPublicDir) -Force | Out-Null
    Set-StlAcl (Get-StlPublicDir) 'RX'                   # Benutzer: nur LESEN (Restzeit-Anzeige)

    # ---- 6. Config schreiben
    $cfg = New-StlConfig
    $cfg.daily_limit_minutes = $limit
    $cfg.window_enabled = $winOn
    $cfg.window_start = $wStart
    $cfg.window_end = $wEnd
    if ($days) { Set-StlDays $cfg $days }
    $cfg.users = @($resolved)
    $cfg.timezone = (Get-TimeZone).Id
    Set-StlPin $cfg $pin1
    $pin1 = $null; $pin2 = $null
    Write-StlJson (Get-StlConfigPath) $cfg
    Remove-Item -LiteralPath (Get-StlStatePath) -Force -ErrorAction SilentlyContinue   # frischer Zaehler

    # ---- 7. Programmdateien kopieren + Rechte
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    foreach ($f in @('Enforcer.ps1', 'StlCommon.ps1', 'StlEnforce.ps1', 'StlRelay.ps1', 'Eltern-Zentrale.ps1', 'Restzeit-Anzeige.ps1', 'Parent-Unlock.ps1', 'Uninstall-ScreenTimeLimiter.ps1', 'README_DE.md')) {
        $p = Join-Path $src $f
        if (-not (Test-Path -LiteralPath $p)) { Fail ("Datei fehlt im Installationsordner: $f") }
        Copy-Item -LiteralPath $p -Destination (Join-Path $installDir $f) -Force
    }
    $viewerSrc = Join-Path $src 'viewer\stl_viewer.py'
    if (Test-Path -LiteralPath $viewerSrc) {
        New-Item -ItemType Directory -Path (Join-Path $installDir 'viewer') -Force | Out-Null
        Copy-Item -LiteralPath $viewerSrc -Destination (Join-Path $installDir 'viewer\stl_viewer.py') -Force
    }
    Get-ChildItem -LiteralPath $installDir -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
    Set-StlAcl $installDir 'RX'                          # SYSTEM/Admins: Vollzugriff, Benutzer: nur lesen/ausfuehren

    # ---- 8. Geplante Aufgabe (SYSTEM, beim Start + jede Minute Neustart-Versuch, Einzelinstanz)
    $enf = Join-Path $installDir 'Enforcer.ps1'
    $argXml = [Security.SecurityElement]::Escape(('-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $enf))
    $taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Bildschirmzeit-Limiter (Eltern). Zaehlt nur aktive Sitzungszeit.</Description></RegistrationInfo>
  <Triggers>
    <BootTrigger><Enabled>true</Enabled></BootTrigger>
    <TimeTrigger>
      <StartBoundary>2024-01-01T00:00:00</StartBoundary>
      <Repetition><Interval>PT1M</Interval></Repetition>
      <Enabled>true</Enabled>
    </TimeTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>6</Priority>
    <RestartOnFailure><Interval>PT1M</Interval><Count>999</Count></RestartOnFailure>
  </Settings>
  <Actions Context="Author">
    <Exec><Command>powershell.exe</Command><Arguments>$argXml</Arguments></Exec>
  </Actions>
</Task>
"@
    [void](Register-ScheduledTask -TaskName $script:StlTaskName -Xml $taskXml -Force)
    Start-ScheduledTask -TaskName $script:StlTaskName

    # ---- 9. Start-Menue-Verknuepfung 'Eltern-Zentrale' (Kind kann sie sehen, aber ohne Administrator-Passwort + PIN nichts tun)
    try {
        $lnkDir = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
        $oldLnk = Join-Path $lnkDir 'Eltern - Bildschirmzeit freigeben.lnk'
        if (Test-Path -LiteralPath $oldLnk) { Remove-Item -LiteralPath $oldLnk -Force -ErrorAction SilentlyContinue }
        $sh = New-Object -ComObject WScript.Shell
        $lnk = $sh.CreateShortcut((Join-Path $lnkDir 'Eltern - Bildschirmzeit.lnk'))
        $lnk.TargetPath = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
        $lnk.Arguments = ('-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}"' -f (Join-Path $installDir 'Eltern-Zentrale.ps1'))
        $lnk.WindowStyle = 7
        $lnk.Description = 'Eltern-Zentrale: Wochenplan, Zeit freigeben, PIN (Administrator-Passwort + PIN)'
        $lnk.Save()
    } catch { Write-Host ('Hinweis: Verknuepfung konnte nicht angelegt werden: ' + $_.Exception.Message) -ForegroundColor Yellow }

    # ---- 10. Restzeit-Anzeige fuers Kind (PowerShell, kein Python noetig), startet bei jeder Anmeldung
    $viewerMsg = 'Restzeit-Anzeige: nicht installiert.'
    $runKey = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'
    if (-not $NoViewer) {
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Set-ItemProperty -Path $runKey -Name 'ScreenTimeLimiterViewer' `
            -Value ('"{0}" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{1}"' -f $psExe, (Join-Path $installDir 'Restzeit-Anzeige.ps1'))
        $viewerMsg = 'Restzeit-Anzeige: startet bei der naechsten Anmeldung des Kindes (zeigt Restzeit und Wochenplan, nur lesen).'
    } else {
        Remove-ItemProperty -Path $runKey -Name 'ScreenTimeLimiterViewer' -ErrorAction SilentlyContinue
    }

    # ---- 11. Pruefen
    Write-Host 'Pruefe, ob der Enforcer laeuft (bis 45 s) ...'
    $okRun = $false
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Seconds 3
        $st = Read-StlJson (Get-StlStatusPath)
        if ($st -and $st.updated_utc) {
            $age = ([DateTime]::UtcNow - ([DateTime]::Parse([string]$st.updated_utc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind))).TotalSeconds
            if ($age -lt 40) { $okRun = $true; break }
        }
    }
    Write-Host ''
    if ($okRun) { Write-Host 'OK: Der Enforcer laeuft als SYSTEM und schreibt seinen Status.' -ForegroundColor Green }
    else { Write-Host ('WARNUNG: Noch kein Status vom Enforcer. Siehe ' + (Get-StlLogPath) + ' und Aufgabenplanung -> ' + $script:StlTaskName) -ForegroundColor Yellow }
    Write-Host ''
    Write-Host ('Kind-Konto/Konten : ' + ($resolved -join ', '))
    $finalCfg = Read-StlConfig
    if ($finalCfg) {
        Write-Host 'Wochenplan        :'
        $dn = $script:StlDayNames
        for ($i = 0; $i -lt 7; $i++) { Write-Host ('   {0,-10} {1}' -f $dn[$i], (Format-StlRule (Get-StlDayRule $finalCfg ([datetime]'2026-10-26').AddDays($i)))) }
    }
    Write-Host $viewerMsg
    # ---- 12. Handy-App (optional, Standard: AUS)
    $relayNow = $null
    try { $relayNow = Read-StlRelayConfig } catch { $relayNow = $null }
    $relayWasOn = [bool]($relayNow -and $relayNow.enabled)
    Write-Host ''
    Write-Host 'Handy-App (optional): Restzeit ansehen und Zeit freigeben per Android-App. Benoetigt Internet; es wird nur der' 
    Write-Host 'Limiter-Status (Restzeit, Regel, Wochenplan, aktiv/gesperrt) VERSCHLUESSELT ueber oeffentliche Relay-Server uebertragen.'
    $relayAns = Read-Default 'Handy-App-Zugriff aktivieren? (j/n)' $(if ($relayWasOn) { 'j' } else { 'n' })
    if ($relayAns.ToLower() -in @('j', 'ja', 'y', 'yes')) {
        $pairCode = Enable-StlRelay
        Write-Host ''
        Write-Host 'Handy-App aktiviert. Kopplungscode (wie ein Passwort behandeln, nur in die App einfuegen):' -ForegroundColor Green
        Write-Host ('   ' + $pairCode) -ForegroundColor Cyan
        Write-Host '   (Spaeter jederzeit in der Eltern-Zentrale -> "Handy-App ..." sichtbar bzw. mit "Neu koppeln" erneuerbar.)'
    } else {
        if ($relayNow) { Disable-StlRelay }
        Write-Host 'Handy-App: AUS (es wird nichts gesendet).'
    }
    Write-Host 'Eltern-Zentrale   : Startmenue -> "Eltern - Bildschirmzeit" (Administrator-Passwort + PIN)'
    Write-Host 'WICHTIG: Das Kind-Konto MUSS ein Standardbenutzer bleiben, sonst kann es alles entfernen.' -ForegroundColor Yellow
    Write-Host 'Teste den Schutz mit dem Kind-Konto (siehe README_DE.md, Abschnitt "Schutz testen").'
    $open = Read-Default 'Eltern-Zentrale jetzt oeffnen, um den Wochenplan fein einzustellen? (j/n)' 'j'
    if ($open.ToLower() -in @('j', 'ja', 'y', 'yes')) {
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f (Join-Path $installDir 'Eltern-Zentrale.ps1')))
    }
} catch {
    Fail $_.Exception.Message
}
