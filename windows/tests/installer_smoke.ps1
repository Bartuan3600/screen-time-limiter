# Trockenlauf des Installers/Uninstallers auf Linux mit Attrappen fuer Windows-Cmdlets (Konten, Aufgabenplanung,
# Registry, Rechte, Verknuepfung). Prueft den Skript-ABLAUF (Eingaben, Config, Dateien), nicht Windows selbst.
param([string]$Which = 'install')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('stl-inst-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$env:STL_DATA_DIR = Join-Path $tmp 'data'
$env:STL_INSTALL_DIR = Join-Path $tmp 'prog'
$env:ProgramData = Join-Path $tmp 'pd'; $env:SystemRoot = Join-Path $tmp 'win'; $env:TEMP = $tmp
New-Item -ItemType Directory -Path $env:ProgramData -Force | Out-Null

$script:fail = 0; $script:n = 0
function Check($cond, [string]$name) { $script:n++; if (-not $cond) { $script:fail++; Write-Host "FAIL: $name" -ForegroundColor Red } }

function Read-Json($p) { if (Test-Path $p) { Get-Content $p -Raw | ConvertFrom-Json } }
# ---- Attrappen
$overrides = @'
$script:Answers = New-Object System.Collections.Queue
$script:Calls = New-Object System.Collections.ArrayList
function Read-Host { param([string]$Prompt, [switch]$AsSecureString)
    $a = if ($script:Answers.Count) { $script:Answers.Dequeue() } else { '' }
    [void]$script:Calls.Add("Read-Host: $Prompt -> $a")
    if ($AsSecureString) { $s = New-Object Security.SecureString; foreach ($ch in $a.ToCharArray()) { $s.AppendChar($ch) }; return $s }
    return $a }
function Test-StlIsAdmin { $true }
function Set-StlAcl { param($Path, $UsersRight, [switch]$UsersOnFolderOnly) [void]$script:Calls.Add("ACL $Path $UsersRight") }
function Get-LocalGroupMember { param($SID) [pscustomobject]@{ SID = [pscustomobject]@{ Value = 'S-1-5-21-1-500' } } }
function Get-LocalUser {
    [pscustomobject]@{ Name = 'Papa'; Enabled = $true; SID = [pscustomobject]@{ Value = 'S-1-5-21-1-500' } }
    [pscustomobject]@{ Name = 'Max'; Enabled = $true; SID = [pscustomobject]@{ Value = 'S-1-5-21-1-1001' } } }
function Get-ScheduledTask { param($TaskName, $ErrorAction) $null }
function Register-ScheduledTask { param($TaskName, $Xml, [switch]$Force) [void]$script:Calls.Add("RegTask $TaskName"); 1 }
function Start-ScheduledTask { param($TaskName) [void]$script:Calls.Add("StartTask $TaskName") }
function Stop-ScheduledTask { param($TaskName, $ErrorAction) }
function Unregister-ScheduledTask { param($TaskName, $Confirm) }
function Get-CimInstance { param($ClassName, $Filter, $ErrorAction) @() }
function Set-ItemProperty { param($Path, $Name, $Value) [void]$script:Calls.Add("RUN $Name = $Value") }
function Remove-ItemProperty { param($Path, $Name, $ErrorAction) [void]$script:Calls.Add("RUNDEL $Name") }
function Unblock-File { param([Parameter(ValueFromPipeline)]$InputObject) process { } }
function Start-Sleep { param($Seconds) }
function Start-Process { param($FilePath, $ArgumentList, $Verb) [void]$script:Calls.Add("START $FilePath $($ArgumentList -join ' ')") }
function New-Object { param([Parameter(Position=0)]$TypeName, [Parameter(Position=1)]$ArgumentList, $ComObject)
    if ($ComObject) { throw 'COM nicht verfuegbar (Linux)' }
    if ($TypeName -like '*SecurityIdentifier') { return [string]$ArgumentList }
    if ($ArgumentList) { Microsoft.PowerShell.Utility\New-Object -TypeName $TypeName -ArgumentList $ArgumentList } else { Microsoft.PowerShell.Utility\New-Object -TypeName $TypeName } }
function icacls.exe { }
'@

function Prepare([string]$name) {
    $t = Get-Content (Join-Path $root $name) -Raw -Encoding UTF8
    $t = $t.Replace("[CmdletBinding()]", "[CmdletBinding()]")
    $anchor = ". (Join-Path `$src 'StlCommon.ps1')"
    if ($t.Contains($anchor)) { $t = $t.Replace($anchor, $anchor + "`n" + $overrides) }
    else { $anchor = ". (Join-Path `$here 'StlCommon.ps1')"; $t = $t.Replace($anchor, $anchor + "`n" + $overrides) }
    $dir = Join-Path $tmp ('src-' + [IO.Path]::GetFileNameWithoutExtension($name)); New-Item -ItemType Directory $dir -Force | Out-Null
    Get-ChildItem $root -File | Where-Object { $_.Extension -in '.ps1', '.md' } | ForEach-Object { Copy-Item $_.FullName $dir }
    New-Item -ItemType Directory (Join-Path $dir 'viewer') -Force | Out-Null
    Copy-Item (Join-Path $root 'viewer/stl_viewer.py') (Join-Path $dir 'viewer')
    $p = Join-Path $dir $name
    [IO.File]::WriteAllText($p, $t, (New-Object Text.UTF8Encoding($true)))
    return $p
}
function Run-Script([string]$path, [string[]]$answers) {
    # In neuem pwsh-Prozess ginge die Antwort-Queue verloren -> im selben Prozess, Skript als ScriptBlock-Datei
    $script:Answers = $null
    $sb = [scriptblock]::Create(([IO.File]::ReadAllText($path) -replace '(?m)^\[CmdletBinding\(\)\]\s*$', '' ))
    return $sb
}

if ($Which -eq 'install') {
    $p = Prepare 'Install-ScreenTimeLimiter.ps1'
    # Antworten: Konto, Wochenplan-Auswahl (1), PIN, PIN, GUI oeffnen? n
    $wrapper = @"
`$PSScriptRoot_ = '$((Split-Path $p -Parent).Replace("'", "''"))'
"@
    function Invoke-InstallRun([string[]]$answers, [string]$childAccount = '', [string]$preset = '') {
        $code = [IO.File]::ReadAllText($p)
        $code = $code.Replace('$src = $PSScriptRoot', "`$src = '" + (Split-Path $p -Parent) + "'")
        $code = $code -replace '(?m)^\[CmdletBinding\(\)\]\s*$', ''
        $code = $code -replace '(?m)^param\(.*\)\s*$', ('$NoViewer = $false; $ChildAccount = ''' + $childAccount + '''; $Preset = ''' + $preset + '''')
        $code = $code.Replace('$script:Answers = New-Object System.Collections.Queue', '$script:Answers = New-Object System.Collections.Queue; foreach ($x in @(' + (($answers | ForEach-Object { "'$_'" }) -join ',') + ')) { $script:Answers.Enqueue($x) }')
        $f = Join-Path $tmp 'inst-run.ps1'
        [IO.File]::WriteAllText($f, $code, (New-Object Text.UTF8Encoding($true)))
        return (& { try { . $f } catch { 'EXC: ' + $_.Exception.Message + ' @ ' + $_.ScriptStackTrace } } *>&1 | Out-String)
    }
    # Antworten: Konto, Wochenplan-Auswahl (2 = Schule/Wochenende), PIN, PIN, Handy-App? n, GUI oeffnen? n
    $out = Invoke-InstallRun @('Max', '2', '4711', '4711', 'n', 'n')
    Check ($out -notmatch 'ABBRUCH|EXC:') ('Installer lief ohne Abbruch: ' + ($out -split "`n" | Select-String 'ABBRUCH|EXC' | Select-Object -First 1))
    $cfg = Read-Json (Join-Path $env:STL_DATA_DIR 'config.json')
    Check ($null -ne $cfg) 'config.json geschrieben'
    Check ($cfg.version -eq 3 -and @($cfg.days).Count -eq 7) 'Wochenplan (7 Tage) in config'
    Check ($cfg.days[5].limit_minutes -gt $cfg.days[0].limit_minutes) 'Schule/Wochenende: Sa laenger als Mo'
    Check (@($cfg.users) -contains 'Max') 'Kind-Konto Max'
    foreach ($fn in @('Enforcer.ps1', 'StlCommon.ps1', 'StlEnforce.ps1', 'StlRelay.ps1', 'Eltern-Zentrale.ps1', 'Restzeit-Anzeige.ps1', 'Parent-Unlock.ps1', 'Uninstall-ScreenTimeLimiter.ps1', 'README_DE.md')) {
        Check (Test-Path (Join-Path $env:STL_INSTALL_DIR $fn)) ("kopiert: $fn")
    }
    Check ($cfg.pin_hash -or $cfg.pin_salt -or ($cfg.PSObject.Properties.Name -match 'pin')) 'PIN-Hash gesetzt'
    Check (-not ($cfg | ConvertTo-Json -Depth 6) -or ((($cfg | ConvertTo-Json -Depth 6) -notmatch '4711'))) 'PIN nicht im Klartext'
    Check ($out -match 'Wochenplan') 'Zusammenfassung zeigt Wochenplan'
    Check ($out -match 'Eltern - Bildschirmzeit') 'Zusammenfassung nennt die Verknuepfung'
    Check (-not (Test-Path (Join-Path $env:STL_DATA_DIR 'relay.json'))) 'Handy-App standardmaessig AUS (keine relay.json)'
    Check ($out -match 'Handy-App: AUS') 'Zusammenfassung: Handy-App AUS'
    # Zweiter Lauf (Update): Handy-App aktivieren
    $out2 = Invoke-InstallRun @('Max', '4', '4711', '4711', 'j', 'n')
    Check ($out2 -notmatch 'ABBRUCH|EXC:') ('Update-Lauf ohne Abbruch: ' + ($out2 -split "`n" | Select-String 'ABBRUCH|EXC' | Select-Object -First 1))
    . (Join-Path $root 'StlCommon.ps1'); . (Join-Path $root 'StlRelay.ps1')
    $rcfg = Read-StlRelayConfig
    Check ($rcfg -and $rcfg.enabled) 'Handy-App aktiviert: relay.json gueltig'
    Check ($rcfg -and ($out2 -match [regex]::Escape((Get-StlPairingCode $rcfg.Key)))) 'Kopplungscode wird angezeigt'
    Check ($out -notmatch 'STL1-') 'Kein Code bei AUS'
    # Dritter Lauf: erneut mit n -> ausgeschaltet, Schluessel bleibt erhalten
    $out3 = Invoke-InstallRun @('Max', '4', '4711', '4711', 'n', 'n')
    $r3 = Read-StlRelayConfig
    Check ($r3 -and -not $r3.enabled) 'erneut n -> Handy-App ausgeschaltet'
    # Vierter Lauf: nicht-interaktiv per Parameter (Konto + Preset), Passwort mit Buchstaben/Sonderzeichen wird nur abgefragt
    $out4 = Invoke-InstallRun @('Gut3s!Passwort', 'Gut3s!Passwort', 'n', 'n') 'Max' 'wochenende2h'
    Check ($out4 -notmatch 'ABBRUCH|EXC:') ('Parameter-Lauf ohne Abbruch: ' + ($out4 -split "`n" | Select-String 'ABBRUCH|EXC' | Select-Object -First 1))
    $c4 = Read-Json (Join-Path $env:STL_DATA_DIR 'config.json')
    Check (@($c4.users) -contains 'Max') 'Parameter -ChildAccount uebernommen'
    Check ((@($c4.days[0..4] | Where-Object { $_.mode -eq 'blocked' }).Count -eq 5) -and (@($c4.days[5..6] | Where-Object { $_.mode -eq 'limit' -and $_.limit_minutes -eq 120 -and -not $_.window_enabled }).Count -eq 2)) 'Preset wochenende2h: Mo-Fr gesperrt, Sa/So 2 Std. ohne Fenster'
    Check (-not ($out4 -match 'Name des Kind-Kontos') -and -not ($out4 -match 'Auswahl')) 'Parameter-Lauf fragt nicht nach Konto/Wochenplan'
    . (Join-Path $root 'StlCommon.ps1')
    Check ((Test-StlPin $c4 'Gut3s!Passwort') -and -not (Test-StlPin $c4 'gut3s!passwort')) 'Passwort mit Buchstaben/Sonderzeichen gesetzt und geprueft'
    Check (((Get-Content (Join-Path $env:STL_DATA_DIR 'config.json') -Raw)) -notmatch 'Gut3s') 'Passwort nicht im Klartext'
    # Standardauswahl (Enter) = Nur Wochenende, 2 Std.
    $out5 = Invoke-InstallRun @('Max', '', 'Gut3s!Passwort', 'Gut3s!Passwort', 'n', 'n')
    $c5 = Read-Json (Join-Path $env:STL_DATA_DIR 'config.json')
    Check ($c5.days[0].mode -eq 'blocked' -and $c5.days[6].limit_minutes -eq 120 -and -not $c5.days[6].window_enabled) 'Standard-Auswahl ist Nur Wochenende, 2 Std.'
    # Passwort-Eingaben ungleich (nur Gross-/Kleinschreibung) -> Abbruch
    $out6 = Invoke-InstallRun @('Gut3s!Passwort', 'gut3s!passwort', 'n', 'n') 'Max' 'wochenende2h'
    Check ($out6 -match 'ABBRUCH') 'Gross-/Kleinschreibung zaehlt beim Wiederholen'
    # Preset behalten/ungueltig
    if ($script:fail) { Write-Host $out2 }
}
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
if ($script:fail -eq 0) { Write-Host "installer_smoke: $($script:n) Pruefungen OK" } else { Write-Host "installer_smoke: $($script:fail) FEHLER"; exit 1 }
