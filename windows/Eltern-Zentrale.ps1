<#
.SYNOPSIS
  Eltern-Zentrale: Wochenplan, heutige Zeit, Freigaben, PIN und Kind-Konto - alles in einem Fenster.
.DESCRIPTION
  Startet mit Administratorrechten (Windows fragt nach dem Administrator-Passwort) UND verlangt die Eltern-PIN.
  Schreibt die geschuetzte config.json bzw. legt kleine Befehle in den Admin-Ordner; der Enforcer
  (laeuft als SYSTEM) uebernimmt Aenderungen nach spaetestens ca. 15 Sekunden.
  Keine Ueberwachung: Es werden nur Einstellungen und die heute genutzten Sekunden angezeigt.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:ScriptPath = $MyInvocation.MyCommand.Path
$here = Split-Path -Parent $script:ScriptPath
. (Join-Path $here 'StlCommon.ps1')
. (Join-Path $here 'StlRelay.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

function Show-Msg([string]$Text, [string]$Title = 'Eltern-Zentrale', [string]$Icon = 'Information') {
    [void][System.Windows.Forms.MessageBox]::Show($Text, $Title, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::$Icon)
}
function Ask-YesNo([string]$Text, [string]$Title = 'Eltern-Zentrale') {
    return ([System.Windows.Forms.MessageBox]::Show($Text, $Title, [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question) -eq [System.Windows.Forms.DialogResult]::Yes)
}

# ---------------------------------------------------------------- 1. Administrator (UAC = Administrator-Passwort)
if (-not (Test-StlIsAdmin)) {
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $script:ScriptPath))
    } catch {
        Show-Msg 'Abgebrochen: Es wurde kein Administrator-Passwort bestätigt.' 'Eltern-Zentrale' 'Warning'
    }
    exit
}

# ---------------------------------------------------------------- 2. PIN-Dialog
function Read-PinDialog([string]$Title, [string]$Prompt) {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $Title; $f.StartPosition = 'CenterScreen'; $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.ClientSize = New-Object System.Drawing.Size(300, 120)
    $f.TopMost = $true
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Prompt; $l.Location = New-Object System.Drawing.Point(12, 12); $l.Size = New-Object System.Drawing.Size(276, 32)
    $t = New-Object System.Windows.Forms.TextBox
    $t.UseSystemPasswordChar = $true; $t.MaxLength = 32
    $t.Location = New-Object System.Drawing.Point(12, 48); $t.Size = New-Object System.Drawing.Size(276, 24)
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'OK'; $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $ok.Location = New-Object System.Drawing.Point(132, 84); $ok.Size = New-Object System.Drawing.Size(75, 26)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Abbrechen'; $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $cancel.Location = New-Object System.Drawing.Point(213, 84); $cancel.Size = New-Object System.Drawing.Size(75, 26)
    $chkShow = New-Object System.Windows.Forms.CheckBox
    $chkShow.Text = 'Anzeigen'; $chkShow.Location = New-Object System.Drawing.Point(12, 86); $chkShow.Size = New-Object System.Drawing.Size(100, 22)
    $null = $chkShow.Add_CheckedChanged({ $t.UseSystemPasswordChar = -not $chkShow.Checked }.GetNewClosure())
    $f.Controls.AddRange(@($l, $t, $chkShow, $ok, $cancel))
    $f.AcceptButton = $ok; $f.CancelButton = $cancel
    $res = $f.ShowDialog()
    $pin = $t.Text
    $f.Dispose()
    if ($res -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    return $pin
}

$script:Config = Read-StlConfig
if (-not $script:Config) {
    Show-Msg ("Keine gültige Einrichtung gefunden.`n`nGrund: {0}`n`nBitte zuerst Install-ScreenTimeLimiter.bat ausführen." -f $script:StlConfigError) 'Eltern-Zentrale' 'Error'
    exit 1
}
$pinOk = $false
for ($i = 1; $i -le 3; $i++) {
    $p = Read-PinDialog 'Eltern-PIN / Passwort' 'Bitte die Eltern-PIN / das Passwort eingeben:'
    if ($null -eq $p) { exit }
    if (Test-StlPin $script:Config $p) { $pinOk = $true; break }
    Show-Msg ('Falsche PIN / falsches Passwort ({0}/3).' -f $i) 'Eltern-Zentrale' 'Warning'
}
if (-not $pinOk) { Show-Msg 'Zu viele Fehlversuche. Das Programm wird beendet.' 'Eltern-Zentrale' 'Error'; exit 1 }

# ---------------------------------------------------------------- 3. Oberflaeche
$script:Rows = @()
$script:Loading = $true
$script:Dirty = $false
$script:ModeTexts = @('Zeit begrenzen', 'gesperrt (kein Spielen)', 'unbegrenzt')   # gleiche Reihenfolge wie $script:StlModes

function New-Ctl($Type, [int]$X, [int]$Y, [int]$W, [int]$H, [string]$Text = '') {
    $c = New-Object $Type
    $c.Location = New-Object System.Drawing.Point($X, $Y)
    $c.Size = New-Object System.Drawing.Size($W, $H)
    if ($Text) { $c.Text = $Text }
    return $c
}
function Set-Dirty { if (-not $script:Loading) { $script:Dirty = $true; $script:Form.Text = 'Eltern-Zentrale – Bildschirmzeit  (ungespeicherte Änderungen)' } }

$script:Form = New-Object System.Windows.Forms.Form
$form = $script:Form
$form.Text = 'Eltern-Zentrale – Bildschirmzeit'
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.ClientSize = New-Object System.Drawing.Size(800, 660)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

# ---- Heute
$gbToday = New-Ctl System.Windows.Forms.GroupBox 10 8 780 158 'Heute'
$lblKonto = New-Ctl System.Windows.Forms.Label 12 26 50 20 'Konto:'
$cmbChild = New-Ctl System.Windows.Forms.ComboBox 64 23 160 24
$cmbChild.DropDownStyle = 'DropDownList'
$lblDay = New-Ctl System.Windows.Forms.Label 240 26 530 20 ''
$lblDay.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$lblUsed = New-Ctl System.Windows.Forms.Label 12 54 250 26 'Genutzt: –'
$lblUsed.Font = New-Object System.Drawing.Font('Segoe UI', 12)
$lblRest = New-Ctl System.Windows.Forms.Label 280 50 300 32 'Rest: –'
$lblRest.Font = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
$lblState = New-Ctl System.Windows.Forms.Label 12 84 756 18 ''
$lblSvc = New-Ctl System.Windows.Forms.Label 12 102 756 18 ''
$lblSvc.ForeColor = [System.Drawing.Color]::DimGray
$gbToday.Controls.AddRange(@($lblKonto, $cmbChild, $lblDay, $lblUsed, $lblRest, $lblState, $lblSvc))

$btnDefs = @(
    @{ T = '+15 Min.';          A = 'add_minutes';     M = 15 },
    @{ T = '+30 Min.';          A = 'add_minutes';     M = 30 },
    @{ T = '+60 Min.';          A = 'add_minutes';     M = 60 },
    @{ T = 'Heute unbegrenzt';  A = 'unlimited_today'; M = 0 },
    @{ T = 'Heute sperren';     A = 'block_today';     M = 0 },
    @{ T = 'Freigaben aufheben'; A = 'clear_extras';   M = 0 },
    @{ T = 'Nutzung auf 0';     A = 'reset_used';      M = 0 }
)
$bx = 10
foreach ($d in $btnDefs) {
    $b = New-Ctl System.Windows.Forms.Button $bx 126 104 26 $d.T
    $b.Tag = $d
    $b.Add_Click({
        param($sender, $e)
        Invoke-ParentAction $sender.Tag
    })
    $gbToday.Controls.Add($b)
    $bx += 110
}

# ---- Wochenplan
$gbWeek = New-Ctl System.Windows.Forms.GroupBox 10 172 780 330 'Wochenplan (gilt jede Woche)'
$hdr = @(@('Tag', 12, 60), @('Modus', 90, 170), @('Std.', 270, 50), @('Min.', 328, 50), @('Zeitfenster', 400, 90), @('von', 496, 60), @('bis', 600, 60))
foreach ($h in $hdr) {
    $l = New-Ctl System.Windows.Forms.Label $h[1] 22 $h[2] 18 $h[0]
    $l.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $gbWeek.Controls.Add($l)
}
for ($i = 0; $i -lt 7; $i++) {
    $y = 46 + $i * 33
    $row = @{}
    $row.Day  = New-Ctl System.Windows.Forms.Label 12 ($y + 3) 74 20 $script:StlDayNames[$i]
    $row.Mode = New-Ctl System.Windows.Forms.ComboBox 90 $y 170 24
    $row.Mode.DropDownStyle = 'DropDownList'
    foreach ($mt in $script:ModeTexts) { [void]$row.Mode.Items.Add($mt) }
    $row.Hours = New-Ctl System.Windows.Forms.NumericUpDown 270 $y 50 24
    $row.Hours.Minimum = 0; $row.Hours.Maximum = 24
    $row.Mins = New-Ctl System.Windows.Forms.NumericUpDown 328 $y 50 24
    $row.Mins.Minimum = 0; $row.Mins.Maximum = 59; $row.Mins.Increment = 5
    $row.Win = New-Ctl System.Windows.Forms.CheckBox 400 ($y + 2) 90 22 'nur von–bis'
    $row.From = New-Ctl System.Windows.Forms.DateTimePicker 496 $y 80 24
    $row.To   = New-Ctl System.Windows.Forms.DateTimePicker 600 $y 80 24
    foreach ($dtp in @($row.From, $row.To)) {
        $dtp.Format = [System.Windows.Forms.DateTimePickerFormat]::Custom
        $dtp.CustomFormat = 'HH:mm'
        $dtp.ShowUpDown = $true
    }
    $row.Mode.Add_SelectedIndexChanged({ Update-RowStates; Set-Dirty })
    $row.Hours.Add_ValueChanged({ Set-Dirty })
    $row.Mins.Add_ValueChanged({ Set-Dirty })
    $row.Win.Add_CheckedChanged({ Update-RowStates; Set-Dirty })
    $row.From.Add_ValueChanged({ Set-Dirty })
    $row.To.Add_ValueChanged({ Set-Dirty })
    $gbWeek.Controls.AddRange(@($row.Day, $row.Mode, $row.Hours, $row.Mins, $row.Win, $row.From, $row.To))
    $script:Rows += , $row
}
$btnSchool = New-Ctl System.Windows.Forms.Button 12 284 200 28 'Schule / Wochenende'
$btnEvery  = New-Ctl System.Windows.Forms.Button 220 284 210 28 'Gleich jeden Tag (wie Montag)'
$btnWeekend = New-Ctl System.Windows.Forms.Button 438 284 200 28 'Nur am Wochenende'
$gbWeek.Controls.AddRange(@($btnSchool, $btnEvery, $btnWeekend))
$lblHintWin = New-Ctl System.Windows.Forms.Label 650 280 120 40 'Fenster über Mitternacht (z. B. 20:00–01:00) ist möglich.'
$lblHintWin.Font = New-Object System.Drawing.Font('Segoe UI', 7.5)
$lblHintWin.ForeColor = [System.Drawing.Color]::DimGray
$gbWeek.Controls.Add($lblHintWin)

# ---- Einstellungen
$gbSet = New-Ctl System.Windows.Forms.GroupBox 10 508 780 62 'Einstellungen'
$lblChild = New-Ctl System.Windows.Forms.Label 12 28 150 20 'Kind-Konto(en), Komma:'
$txtChild = New-Ctl System.Windows.Forms.TextBox 166 25 220 24
$btnPin = New-Ctl System.Windows.Forms.Button 410 22 150 28 'PIN / Passwort ändern …'
$btnApp = New-Ctl System.Windows.Forms.Button 570 22 200 28 'Handy-App …'
$gbSet.Controls.AddRange(@($lblChild, $txtChild, $btnPin, $btnApp))
$txtChild.Add_TextChanged({ Set-Dirty })

# ---- Unten
$lblStatus = New-Ctl System.Windows.Forms.Label 10 578 780 36 ''
$lblStatus.ForeColor = [System.Drawing.Color]::DimGray
$btnSave = New-Ctl System.Windows.Forms.Button 10 618 200 34 'Speichern'
$btnSave.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$btnClose = New-Ctl System.Windows.Forms.Button 690 618 100 34 'Schließen'
$lblNote = New-Ctl System.Windows.Forms.Label 222 622 450 28 'Es werden nur Einstellungen und die heute aktive Zeit gespeichert – keine Überwachung.'
$lblNote.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$lblNote.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.AddRange(@($gbToday, $gbWeek, $gbSet, $lblStatus, $btnSave, $btnClose, $lblNote))

# ---------------------------------------------------------------- 4. Logik der Oberflaeche
function Update-RowStates {
    foreach ($r in $script:Rows) {
        $mi = $r.Mode.SelectedIndex
        $isLimit = ($mi -eq 0); $isBlocked = ($mi -eq 1)
        $r.Hours.Enabled = $isLimit; $r.Mins.Enabled = $isLimit
        $r.Win.Enabled = (-not $isBlocked)
        $on = ((-not $isBlocked) -and $r.Win.Checked)
        $r.From.Enabled = $on; $r.To.Enabled = $on
    }
}
function Set-RowFromRule([int]$Index, $Rule) {
    $r = $script:Rows[$Index]
    $mi = [Array]::IndexOf($script:StlModes, [string]$Rule.mode)
    if ($mi -lt 0) { $mi = 0 }
    $r.Mode.SelectedIndex = $mi
    $lim = [Math]::Min(1440, [Math]::Max(0, [int]$Rule.limit_minutes))
    $r.Hours.Value = [decimal][Math]::Floor($lim / 60)
    $r.Mins.Value = [decimal]($lim % 60)
    $r.Win.Checked = [bool]$Rule.window_enabled
    $r.From.Value = [datetime]::Today.AddMinutes((ConvertTo-StlMinuteOfDay ([string]$Rule.window_start)))
    $r.To.Value = [datetime]::Today.AddMinutes((ConvertTo-StlMinuteOfDay ([string]$Rule.window_end)))
}
function Get-RuleFromRow([int]$Index) {
    $r = $script:Rows[$Index]
    $mode = $script:StlModes[[Math]::Max(0, $r.Mode.SelectedIndex)]
    $minutes = [int]$r.Hours.Value * 60 + [int]$r.Mins.Value
    $s = Format-StlHhmm ($r.From.Value.Hour * 60 + $r.From.Value.Minute)
    $e = Format-StlHhmm ($r.To.Value.Hour * 60 + $r.To.Value.Minute)
    return (New-StlRuleFromParts $mode $minutes $r.Win.Checked $s $e)
}
# Die 7 Tagesregeln aus einer (auch alten) Config - fuer jeden Wochentag
function Get-DaysFromConfig($Cfg) {
    $monday = [datetime]'2026-10-26'     # ein Montag
    $out = @()
    for ($i = 0; $i -lt 7; $i++) { $out += (Get-StlDayRule $Cfg $monday.AddDays($i)) }
    return $out
}
function Set-AllRows($Days) {
    $script:Loading = $true
    for ($i = 0; $i -lt 7; $i++) { Set-RowFromRule $i $Days[$i] }
    Update-RowStates
    $script:Loading = $false
}
function Get-ChildNames { return @(@($script:Config.users) | ForEach-Object { Get-StlShortName ([string]$_) }) }
function Get-CurrentChild { if ($cmbChild.SelectedItem) { return [string]$cmbChild.SelectedItem } return '' }

function Update-ChildList {
    $cur = Get-CurrentChild
    $cmbChild.Items.Clear()
    foreach ($n in (Get-ChildNames)) { [void]$cmbChild.Items.Add($n) }
    if ($cmbChild.Items.Count -gt 0) {
        $i = $cmbChild.Items.IndexOf($cur)
        $cmbChild.SelectedIndex = $(if ($i -ge 0) { $i } else { 0 })
    }
}

function Update-Today {
    try {
        $cfg = Read-StlConfig
        if (-not $cfg) { $lblState.Text = 'Config nicht lesbar: ' + $script:StlConfigError; return }
        $name = Get-CurrentChild
        if (-not $name) { return }
        $utc = [DateTime]::UtcNow
        $local = Get-StlLocalNow $cfg $utc
        $state = Read-StlState $local.ToString('yyyy-MM-dd')
        $info = Get-StlTodayInfo $cfg $state $name $utc
        $lblDay.Text = ('{0}: {1}' -f $info.day_name, $info.rule_text)
        $lblUsed.Text = 'Genutzt: ' + (Format-StlSeconds $info.used_seconds)
        if ([double]::IsInfinity($info.remaining)) {
            $lblRest.Text = 'Rest: unbegrenzt'; $lblRest.ForeColor = [System.Drawing.Color]::DarkGreen
        } else {
            $lblRest.Text = 'Rest: ' + (Format-StlSeconds $info.remaining)
            if ($info.lock_reason) { $lblRest.ForeColor = [System.Drawing.Color]::Firebrick }
            elseif ($info.remaining -lt 600) { $lblRest.ForeColor = [System.Drawing.Color]::DarkOrange }
            else { $lblRest.ForeColor = [System.Drawing.Color]::DarkGreen }
        }
        $notes = @()
        if ($info.unlimited_today) { $notes += 'Heute unbegrenzt freigegeben.' }
        if ($info.blocked_today) { $notes += 'Heute von dir gesperrt.' }
        if ($info.bonus_minutes -gt 0) { $notes += ('Extra heute: +{0} Min.' -f $info.bonus_minutes) }
        if ($info.lock_reason) { $notes += ('Jetzt gesperrt: ' + $info.lock_reason) } else { $notes += 'Jetzt nutzbar.' }
        $lblState.Text = ($notes -join '   ')
        $age = Get-StlStatusAgeSeconds (Read-StlJson (Get-StlStatusPath)) $utc
        if ($age -lt 45) { $lblSvc.Text = 'Wächter-Dienst: läuft'; $lblSvc.ForeColor = [System.Drawing.Color]::DimGray }
        else { $lblSvc.Text = 'ACHTUNG: Der Wächter-Dienst meldet sich nicht (Aufgabenplanung -> ScreenTimeLimiterEnforcer).'; $lblSvc.ForeColor = [System.Drawing.Color]::Firebrick }
    } catch { $lblState.Text = 'Anzeige-Fehler: ' + $_.Exception.Message }
}

function Invoke-ParentAction($Def) {
    $name = Get-CurrentChild
    if (-not $name) { Show-Msg 'Kein Konto ausgewählt.'; return }
    if ($Def.A -eq 'unlimited_today' -and -not (Ask-YesNo ("Für {0} heute ALLE Begrenzungen (Limit und Zeitfenster) bis Mitternacht aufheben?" -f $name))) { return }
    if ($Def.A -eq 'block_today' -and -not (Ask-YesNo ("{0} heute für den Rest des Tages sperren? (Wer gerade am PC sitzt, wird nach einer kurzen Warnung abgemeldet.)" -f $name))) { return }
    if ($Def.A -eq 'reset_used' -and -not (Ask-YesNo ("Die heute genutzte Zeit von {0} auf 0 setzen?" -f $name))) { return }
    try {
        Send-StlCommand $Def.A $name ([int]$Def.M)
        $lblStatus.Text = ('Gesendet: {0} für {1}. Wirksam in ca. 15 Sekunden.' -f $Def.T, $name)
    } catch { Show-Msg ('Fehler beim Senden: ' + $_.Exception.Message) 'Eltern-Zentrale' 'Error' }
}

function Save-FromGui {
    $days = @()
    for ($i = 0; $i -lt 7; $i++) { $days += (Get-RuleFromRow $i) }
    $err = Test-StlDays $days
    if ($err) { Show-Msg $err 'Bitte prüfen' 'Warning'; return $false }
    $names = Get-ChildNames
    $typed = @($txtChild.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $same = (($typed -join ',') -ieq ($names -join ','))
    $newUsers = @($script:Config.users)
    if (-not $same) {
        $res = Resolve-StlChildAccounts ($typed -join ',')
        if ($res.Error) { Show-Msg $res.Error 'Kind-Konto' 'Warning'; return $false }
        $newUsers = @($res.Names)
    }
    try {
        Add-Member -InputObject $script:Config -NotePropertyName version -NotePropertyValue 3 -Force
        Set-StlDays $script:Config $days
        $script:Config.users = @($newUsers)
        $e = Save-StlConfig $script:Config
        if ($e) { Show-Msg $e 'Speichern' 'Warning'; return $false }
    } catch {
        Show-Msg ('Speichern fehlgeschlagen: ' + $_.Exception.Message) 'Eltern-Zentrale' 'Error'
        return $false
    }
    $script:Dirty = $false
    $form.Text = 'Eltern-Zentrale – Bildschirmzeit'
    $lblStatus.Text = ('Gespeichert um {0}. Der Wächter übernimmt es in ca. 15 Sekunden.' -f (Get-Date -Format 'HH:mm:ss'))
    Update-ChildList
    $script:Loading = $true; $txtChild.Text = ((Get-ChildNames) -join ', '); $script:Loading = $false
    Update-Today
    return $true
}

# ---- Handy-App (Relay): standardmaessig AUS. Aktivieren erzeugt einen frischen Kopplungscode (nur auf diesem PC gespeichert).
function Show-RelayDialog {
    $rc = Read-StlRelayConfig
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Handy-App koppeln'; $f.StartPosition = 'CenterParent'; $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.ClientSize = New-Object System.Drawing.Size(560, 330)
    $f.Tag = 'relay'
    $f.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $info = New-Ctl System.Windows.Forms.Label 12 10 536 92 ('Mit der Android-App „Eltern Bildschirmzeit“ siehst du die heutige Restzeit und kannst +15/+30/+60 Min., „Heute unbegrenzt“, „Heute sperren“ und den Wochenplan aus der Ferne ändern.' + "`n`n" + 'Gesendet wird NUR, was der Limiter ohnehin kennt (genutzte/übrige Zeit, Regel, Wochenplan, Sitzung aktiv/gesperrt) – verschlüsselt (AES-256-GCM). KEINE Apps, Webseiten, Nachrichten oder Standorte. Der Kopplungscode ist wie ein Passwort: nur auf dein Handy tippen/einfügen.')
    $chk = New-Ctl System.Windows.Forms.CheckBox 12 108 536 24 'Handy-App-Zugriff aktivieren (benötigt Internet; der PC muss eingeschaltet sein)'
    $lblCode = New-Ctl System.Windows.Forms.Label 12 142 536 18 'Kopplungscode:'
    $txt = New-Ctl System.Windows.Forms.TextBox 12 164 536 50
    $txt.Multiline = $true; $txt.ReadOnly = $true
    $txt.Font = New-Object System.Drawing.Font('Consolas', 11)
    $btnCopy = New-Ctl System.Windows.Forms.Button 12 222 150 28 'Code kopieren'
    $btnNew = New-Ctl System.Windows.Forms.Button 172 222 190 28 'Neu koppeln …'
    $lblFp = New-Ctl System.Windows.Forms.Label 12 258 536 36 ''
    $lblFp.ForeColor = [System.Drawing.Color]::DimGray
    $btnX = New-Ctl System.Windows.Forms.Button 448 290 100 30 'Schließen'
    $btnX.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $f.Controls.AddRange(@($info, $chk, $lblCode, $txt, $btnCopy, $btnNew, $lblFp, $btnX))
    $f.CancelButton = $btnX
    $script:RelayUi = @{ Chk = $chk; Txt = $txt; Fp = $lblFp; Copy = $btnCopy; New = $btnNew; Loading = $true }
    $refresh = {
        $r = Read-StlRelayConfig
        $ui = $script:RelayUi
        if ($r -and $r.enabled) {
            $ui.Txt.Text = (Get-StlPairingCode $r.Key)
            $ui.Fp.Text = ('Aktiv. Kennung: {0}. In der App: „Mit PC koppeln“ → Code einfügen. Befehle ohne richtige PIN werden abgelehnt.' -f (Get-StlRelayFingerprint $r.Key))
        } elseif ($r) {
            $ui.Txt.Text = ''; $ui.Fp.Text = 'Ausgeschaltet. Es wird nichts gesendet und nichts abgeholt.'
        } else {
            $ui.Txt.Text = ''; $ui.Fp.Text = 'Ausgeschaltet (noch nie aktiviert). Es wird nichts gesendet.'
        }
        $on = ($r -and $r.enabled)
        $ui.Copy.Enabled = [bool]$on; $ui.New.Enabled = [bool]$r
    }
    $script:RelayRefresh = $refresh
    $chk.Checked = [bool]($rc -and $rc.enabled)
    & $refresh
    $script:RelayUi.Loading = $false
    $chk.Add_CheckedChanged({
        if ($script:RelayUi.Loading) { return }
        try {
            if ($script:RelayUi.Chk.Checked) {
                [void](Enable-StlRelay)
                $lblStatus.Text = 'Handy-App-Zugriff aktiviert. Der Wächter übernimmt es in ca. 15 Sekunden.'
            } else {
                Disable-StlRelay
                $lblStatus.Text = 'Handy-App-Zugriff ausgeschaltet.'
            }
        } catch { Show-Msg ('Konnte nicht gespeichert werden: ' + $_.Exception.Message) 'Handy-App' 'Error' }
        & $script:RelayRefresh
    })
    $btnCopy.Add_Click({
        try { [System.Windows.Forms.Clipboard]::SetText([string]$script:RelayUi.Txt.Text); $lblStatus.Text = 'Kopplungscode in die Zwischenablage kopiert (nach dem Einfügen am besten wieder leeren).' }
        catch { Show-Msg 'Kopieren nicht möglich – bitte den Code markieren und mit Strg+C kopieren.' 'Handy-App' 'Warning' }
    })
    $btnNew.Add_Click({
        if (-not (Ask-YesNo "Neuen Kopplungscode erzeugen?`n`nDas bisher gekoppelte Handy verliert sofort den Zugriff und muss mit dem neuen Code gekoppelt werden.")) { return }
        try { [void](Reset-StlRelayKey); $lblStatus.Text = 'Neuer Kopplungscode erzeugt. Das alte Handy ist abgekoppelt.' }
        catch { Show-Msg ('Konnte nicht gespeichert werden: ' + $_.Exception.Message) 'Handy-App' 'Error' }
        & $script:RelayRefresh
    })
    [void]$f.ShowDialog()
    $f.Dispose()
}

# ---- Ereignisse
$btnSchool.Add_Click({ Set-AllRows (Get-StlPreset 'schule'); Set-Dirty })
$btnWeekend.Add_Click({ Set-AllRows (Get-StlPreset 'wochenende'); Set-Dirty })
$btnEvery.Add_Click({
    $mon = Get-RuleFromRow 0
    $all = @(1..7 | ForEach-Object { $mon })
    Set-AllRows $all; Set-Dirty
})
$btnSave.Add_Click({ [void](Save-FromGui) })
$btnApp.Add_Click({ Show-RelayDialog })
$btnClose.Add_Click({ $script:Form.Close() })
$cmbChild.Add_SelectedIndexChanged({ Update-Today })
$btnPin.Add_Click({
    $p1 = Read-PinDialog 'Neue PIN / Passwort' 'Neue Eltern-PIN / Passwort (4-32 Zeichen, Buchstaben, Ziffern, Sonderzeichen):'
    if ($null -eq $p1) { return }
    if (-not (Test-StlPinFormat $p1)) { Show-Msg 'Die PIN / das Passwort muss 4 bis 32 Zeichen haben (Buchstaben, Ziffern, Sonderzeichen, keine Leerzeichen).' 'PIN / Passwort' 'Warning'; return }
    $p2 = Read-PinDialog 'PIN / Passwort wiederholen' 'Neue PIN / Passwort zur Bestätigung noch einmal eingeben:'
    if ($null -eq $p2) { return }
    if ($p1 -cne $p2) { Show-Msg 'Die Eingaben stimmen nicht überein.' 'PIN / Passwort' 'Warning'; return }
    try {
        Set-StlPin $script:Config $p1
        $e = Save-StlConfig $script:Config
        if ($e) { Show-Msg $e 'PIN' 'Warning'; return }
        $lblStatus.Text = 'PIN / Passwort geändert.'
        Show-Msg 'Die neue PIN / das neue Passwort ist gespeichert. Bitte gut merken - ohne sie gibt es nur den Weg über eine Neuinstallation.' 'PIN / Passwort'
    } catch { Show-Msg ('PIN konnte nicht gespeichert werden: ' + $_.Exception.Message) 'PIN' 'Error' }
})
$form.Add_FormClosing({
    param($sender, $e)
    if ($script:Dirty -and -not (Ask-YesNo 'Es gibt ungespeicherte Änderungen. Trotzdem schließen?')) { $e.Cancel = $true }
})
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.Add_Tick({ Update-Today })

# ---- Start
Set-AllRows (Get-DaysFromConfig $script:Config)
Update-ChildList
$script:Loading = $true; $txtChild.Text = ((Get-ChildNames) -join ', '); $script:Loading = $false
Update-Today
$lblStatus.Text = 'Änderungen am Wochenplan gelten erst nach „Speichern“. Freigaben (+15 Min. usw.) wirken sofort (ca. 15 s).'
$timer.Start()
[void]$form.ShowDialog()
$timer.Stop()
