# Rauchtest der Eltern-Zentrale auf Linux mit Attrappen (gui_stub.cs): fuehrt den Ablauf aus
# (PIN, Laden, Presets, Speichern, Freigaben, PIN aendern). Prueft NICHT das echte WinForms-Verhalten.
$ErrorActionPreference = 'Stop'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('stl-gui-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$env:STL_DATA_DIR = $tmp
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'StlCommon.ps1')
Add-Type -TypeDefinition (Get-Content (Join-Path $PSScriptRoot 'gui_stub.cs') -Raw)

$script:fail = 0; $script:n = 0
function Check($cond, [string]$name) { $script:n++; if (-not $cond) { $script:fail++; Write-Host "FAIL: $name" -ForegroundColor Red } }

# Config mit PIN 1234, Konto Max, Altformat (ohne days)
$cfg0 = New-StlConfig; $cfg0.users = @('Max'); $cfg0.timezone = 'UTC'; $cfg0.daily_limit_minutes = 90
Set-StlPin $cfg0 '1234'
Write-StlJson (Get-StlConfigPath) $cfg0
New-Item -ItemType Directory -Path (Get-StlCommandDir) -Force | Out-Null

# GUI-Skript ohne Windows-Teile in eine Kopie schreiben
$src = Get-Content (Join-Path $root 'Eltern-Zentrale.ps1') -Raw -Encoding UTF8
$src = $src -replace '(?m)^Add-Type -AssemblyName .*$', ''
$src = $src.Replace('System.Drawing.', 'StubDrawing.')
$src = $src.Replace('if (-not (Test-StlIsAdmin))', 'if (-not $true)')
$copy = Join-Path $tmp 'Eltern-Zentrale.ps1'
Copy-Item (Join-Path $root 'StlCommon.ps1') (Join-Path $tmp 'StlCommon.ps1')
Copy-Item (Join-Path $root 'StlRelay.ps1') (Join-Path $tmp 'StlRelay.ps1')
[IO.File]::WriteAllText($copy, $src, (New-Object Text.UTF8Encoding($true)))

function Find-Ctl([string]$Type, [string]$Text) {
    foreach ($c in [System.Windows.Forms.Stub]::All) {
        if ($c.GetType().Name -eq $Type -and $c.P.ContainsKey('Text') -and $c.P['Text'] -eq $Text) { return $c }
    }
    throw "Control nicht gefunden: $Type '$Text'"
}
function Click([string]$Text) { $b = Find-Ctl 'Button' $Text; foreach ($h in $b.Handlers['Click']) { & $h $b $null } }
function Combos { @([System.Windows.Forms.Stub]::All | Where-Object { $_.GetType().Name -eq 'ComboBox' }) }
function Spinners { @([System.Windows.Forms.Stub]::All | Where-Object { $_.GetType().Name -eq 'NumericUpDown' }) }
function Checks { @([System.Windows.Forms.Stub]::All | Where-Object { $_.GetType().Name -eq 'CheckBox' }) }
function Pickers { @([System.Windows.Forms.Stub]::All | Where-Object { $_.GetType().Name -eq 'DateTimePicker' }) }
function Fire($c, [string]$ev) { foreach ($h in $c.Handlers[$ev]) { & $h $c $null } }
function Cmds { @(Get-ChildItem (Get-StlCommandDir) -Filter *.json | ForEach-Object { Read-StlJson $_.FullName }) }

[System.Windows.Forms.Stub]::PinText = '1234'
[System.Windows.Forms.Stub]::OnMainForm = [Action[System.Windows.Forms.Form]]{
    param($f)
    $modes = (Combos)[1..7]
    # Altconfig: alle 7 Tage = 90 Min, Modus 0
    Check ($modes.Count -eq 7) '7 Modus-Boxen'
    Check (($modes | ForEach-Object { $_.SelectedIndex }) -join ',' -eq '0,0,0,0,0,0,0') 'Altconfig -> Modus limit'
    Check (((Spinners)[0].P['Value'] -eq 1) -and ((Spinners)[1].P['Value'] -eq 30)) 'Mo = 1:30'
    Check ((Combos)[0].SelectedItem -eq 'Max') 'Kind-Konto Max gewaehlt'
    $lbl = [System.Windows.Forms.Stub]::All | Where-Object { $_.GetType().Name -eq 'Label' -and $_.P['Text'] -like 'Rest:*' } | Select-Object -First 1
    Check ($lbl.P['Text'] -like 'Rest: *') 'Rest-Anzeige gesetzt'
    Check ($lblState.Text -notlike 'Anzeige-Fehler*') ('Update-Today ohne Fehler: ' + $lblState.Text)

    # Preset Schule/Wochenende
    Click 'Schule / Wochenende'
    Check ($script:Dirty -eq $true) 'Dirty nach Preset'
    $p = Get-StlPreset 'schule'
    for ($i = 0; $i -lt 7; $i++) {
        $r = Get-RuleFromRow $i
        Check (($r.mode -eq $p[$i].mode) -and ($r.limit_minutes -eq $p[$i].limit_minutes) -and ($r.window_enabled -eq $p[$i].window_enabled)) "Preset Zeile $i"
    }
    # Samstag auf gesperrt aendern und Fenster Sonntag 20:00-01:00 setzen
    $modes[5].SelectedIndex = 1
    $checks = Checks; $pk = Pickers
    $checks[6].P['Checked'] = $true; Fire $checks[6] 'CheckedChanged'
    $pk[12].P['Value'] = [datetime]::Today.AddHours(20); $pk[13].P['Value'] = [datetime]::Today.AddHours(1)
    Click 'Speichern'
    $saved = Read-StlJson (Get-StlConfigPath)
    Check ($saved.version -eq 3) 'version 3'
    Check (@($saved.days).Count -eq 7) 'days gespeichert'
    Check ($saved.days[5].mode -eq 'blocked') 'Samstag blocked'
    Check (($saved.days[6].window_enabled -eq $true) -and ($saved.days[6].window_start -eq '20:00') -and ($saved.days[6].window_end -eq '01:00')) 'Sonntag Fenster ueber Mitternacht'
    Check (Test-StlPin $saved '1234') 'PIN blieb erhalten'
    Check ($script:Dirty -eq $false) 'Dirty nach Speichern aus'

    # Ungueltig: Limit 0 bei Modus limit
    $modes[0].SelectedIndex = 0; (Spinners)[0].P['Value'] = [decimal]0; (Spinners)[1].P['Value'] = [decimal]0
    $before = (Get-Content (Get-StlConfigPath) -Raw)
    $nmsg = [System.Windows.Forms.Stub]::Messages.Count
    Click 'Speichern'
    Check ([System.Windows.Forms.Stub]::Messages.Count -gt $nmsg) 'Fehlermeldung bei Limit 0'
    Check ((Get-Content (Get-StlConfigPath) -Raw) -eq $before) 'ungueltig wird nicht gespeichert'
    (Spinners)[0].P['Value'] = [decimal]2

    # Gleich jeden Tag (wie Montag)
    Click 'Gleich jeden Tag (wie Montag)'
    Check ((($modes | ForEach-Object { $_.SelectedIndex }) -join ',') -eq '0,0,0,0,0,0,0') 'Gleich jeden Tag'
    Click 'Nur am Wochenende'
    Check ((Get-RuleFromRow 0).mode -eq 'blocked') 'Nur am Wochenende: Mo gesperrt'

    # Freigaben
    Get-ChildItem (Get-StlCommandDir) | Remove-Item
    Click '+30 Min.'
    Click 'Heute sperren'
    Click 'Heute unbegrenzt'
    Click 'Nutzung auf 0'
    Click 'Freigaben aufheben'
    $c = Cmds
    Check ($c.Count -eq 5) ('5 Befehle, ist: ' + $c.Count)
    Check (@($c | Where-Object { $_.action -eq 'add_minutes' -and $_.minutes -eq 30 -and $_.user -eq 'Max' }).Count -eq 1) 'add_minutes 30'
    Check (@($c | Where-Object { $_.action -eq 'block_today' }).Count -eq 1) 'block_today'

    # Handy-App-Dialog: standardmaessig AUS, Aktivieren erzeugt Code, Neu koppeln aendert ihn, Ausschalten
    Check (-not (Test-Path (Get-StlRelayPath))) 'Relay: ohne Aktivierung keine relay.json'
    $script:dlgStage = 0
    [System.Windows.Forms.Stub]::OnRelayDialog = [Action[System.Windows.Forms.Form]]{
        param($rf)
        $chk = $script:RelayUi.Chk
        Check ($chk.P['Checked'] -eq $false) 'Relay-Dialog: Standard AUS'
        Check ($script:RelayUi.Copy.P['Enabled'] -eq $false) 'Relay-Dialog: Kopieren erst nach Aktivieren'
        $chk.P['Checked'] = $true; foreach ($h in $chk.Handlers['CheckedChanged']) { & $h $chk $null }
        $code1 = [string]$script:RelayUi.Txt.P['Text']
        Check ($code1 -match '^STL1-([A-Z2-7]{4}-){13}[A-Z2-7]{4}$') 'Relay-Dialog: Kopplungscode angezeigt'
        $rcfg = Read-StlRelayConfig
        Check ($rcfg -and $rcfg.enabled) 'Relay: aktiviert gespeichert'
        $cb = $script:RelayUi.Copy; foreach ($h in $cb.Handlers['Click']) { & $h $cb $null }
        Check ([System.Windows.Forms.Stub]::Clip -eq $code1) 'Relay-Dialog: Code in Zwischenablage'
        $nb = $script:RelayUi.New; foreach ($h in $nb.Handlers['Click']) { & $h $nb $null }
        $code2 = [string]$script:RelayUi.Txt.P['Text']
        Check (($code2 -match '^STL1-') -and ($code2 -ne $code1)) 'Relay-Dialog: Neu koppeln -> anderer Code'
        $chk.P['Checked'] = $false; foreach ($h in $chk.Handlers['CheckedChanged']) { & $h $chk $null }
        $r3 = Read-StlRelayConfig
        Check ($r3 -and -not $r3.enabled) 'Relay: ausgeschaltet gespeichert'
        Check ([string]$script:RelayUi.Txt.P['Text'] -eq '') 'Relay-Dialog: Code ausgeblendet bei AUS'
        $script:dlgStage = 1
    }
    Click 'Handy-App …'
    Check ($script:dlgStage -eq 1) 'Relay-Dialog lief durch'

    # PIN aendern
    [System.Windows.Forms.Stub]::PinText = '5678'
    Click 'PIN / Passwort ändern …'
    $saved = Read-StlJson (Get-StlConfigPath)
    Check ((Test-StlPin $saved '5678') -and -not (Test-StlPin $saved '1234')) 'PIN geaendert'
    [System.Windows.Forms.Stub]::PinText = '12'
    Click 'PIN / Passwort ändern …'
    $saved = Read-StlJson (Get-StlConfigPath)
    Check (Test-StlPin $saved '5678') 'ungueltiges PIN-Format aendert nichts'
    [System.Windows.Forms.Stub]::PinText = 'Gut3s!Passwort'
    Click 'PIN / Passwort ändern …'
    $saved = Read-StlJson (Get-StlConfigPath)
    Check ((Test-StlPin $saved 'Gut3s!Passwort') -and -not (Test-StlPin $saved '5678')) 'Passwort mit Buchstaben/Sonderzeichen geaendert'

    # Timer-Tick und Schliessen mit Dirty
    
}
# Find-Ctl fuer Timer-Tick: Timer hat keinen Text -> separat
$s2 = [scriptblock]::Create('')
try {
    . $copy
} catch {
    $script:fail++; Write-Host ('FAIL: GUI-Ablauf warf: ' + $_.Exception.Message + "`n" + $_.ScriptStackTrace) -ForegroundColor Red
}
if ($env:GUI_DEBUG) { [System.Windows.Forms.Stub]::Messages | ForEach-Object { Write-Host "MSG: $_" } }
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
if ($script:n -lt 20) { $script:fail++; Write-Host 'FAIL: Hook lief nicht (zu wenige Pruefungen)' -ForegroundColor Red }
if ($script:fail -eq 0) { Write-Host "gui_smoke: $($script:n) Pruefungen OK" } else { Write-Host "gui_smoke: $($script:fail) von $($script:n) FEHLER"; exit 1 }
