# Szenario-Tests fuer Invoke-StlEnforceCycle & Co. mit simulierten Sitzungen (ohne Windows-APIs).
$ErrorActionPreference = 'Stop'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('stl-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$env:STL_DATA_DIR = $tmp
. (Join-Path $PSScriptRoot '..\StlCommon.ps1')
. (Join-Path $PSScriptRoot '..\StlEnforce.ps1')

$script:fail = 0; $script:n = 0
function Check($cond, [string]$name) {
    $script:n++
    if (-not $cond) { $script:fail++; Write-Host "FAIL: $name" -ForegroundColor Red }
}

$script:msgs = New-Object System.Collections.ArrayList
$script:logoffs = New-Object System.Collections.ArrayList
$send = { param($id, $text, $to) [void]$script:msgs.Add(@{ id = $id; text = $text; to = $to }) }
$off  = { param($id) [void]$script:logoffs.Add($id) }

function New-Cfg([int]$limit = 60, [bool]$win = $false) {
    $c = New-StlConfig
    $c.daily_limit_minutes = $limit; $c.window_enabled = $win
    $c.users = @('Max'); $c.timezone = 'UTC'; $c.pin_hash = 'x'
    return $c
}
function Sess($id, $user, $state = 0, $locked = $false) { [pscustomobject]@{ Id = $id; User = $user; State = $state; Locked = $locked } }
function Reset-Rec { $script:msgs.Clear(); $script:logoffs.Clear() }
$t0 = [datetime]::SpecifyKind([datetime]'2026-10-26 17:00:00', 'Utc')

# --- 1. Zaehlen nur bei aktiver, nicht gesperrter Kind-Sitzung
$cfg = New-Cfg 60; $st = New-StlState '2026-10-26'; $p = @{}
[void](Invoke-StlEnforceCycle -Config $cfg -State $st -Sessions @((Sess 1 'Max')) -UtcNow $t0 -Delta 15 -Pending $p -SendMessage $send -Logoff $off)
Check ([int](Get-StlEntry $st 'Max').used_seconds -eq 15) 'aktiv zaehlt'
[void](Invoke-StlEnforceCycle -Config $cfg -State $st -Sessions @((Sess 1 'Max' 0 $true)) -UtcNow $t0 -Delta 15 -Pending $p -SendMessage $send -Logoff $off)
Check ([int](Get-StlEntry $st 'Max').used_seconds -eq 15) 'gesperrt zaehlt nicht'
[void](Invoke-StlEnforceCycle -Config $cfg -State $st -Sessions @((Sess 1 'Max' 4)) -UtcNow $t0 -Delta 15 -Pending $p -SendMessage $send -Logoff $off)
Check ([int](Get-StlEntry $st 'Max').used_seconds -eq 15) 'getrennt zaehlt nicht'
[void](Invoke-StlEnforceCycle -Config $cfg -State $st -Sessions @((Sess 2 'Papa')) -UtcNow $t0 -Delta 15 -Pending $p -SendMessage $send -Logoff $off)
Check ([int](Get-StlEntry $st 'Max').used_seconds -eq 15) 'fremdes Konto zaehlt nicht'
[void](Invoke-StlEnforceCycle -Config $cfg -State $st -Sessions @((Sess 3 'PC\max')) -UtcNow $t0 -Delta 15 -Pending $p -SendMessage $send -Logoff $off)
Check ([int](Get-StlEntry $st 'Max').used_seconds -eq 30) 'Domaene/Gross-Klein egal'
Check ($logoffs.Count -eq 0) 'Papa nie abgemeldet'

# --- 2. Warnungen bei 5 und 1 Minute, je einmal
Reset-Rec
$cfg = New-Cfg 10; $st = New-StlState '2026-10-26'; $p = @{}
(Get-StlEntry $st 'Max').used_seconds = 10 * 60 - 310
[void](Invoke-StlEnforceCycle -Config $cfg -State $st -Sessions @((Sess 1 'Max')) -UtcNow $t0 -Delta 15 -Pending $p -SendMessage $send -Logoff $off)  # Rest 295
Check ($msgs.Count -eq 1 -and $msgs[0].text -like '*5 Minuten*') '5-Min-Warnung'
[void](Invoke-StlEnforceCycle -Config $cfg -State $st -Sessions @((Sess 1 'Max')) -UtcNow $t0 -Delta 15 -Pending $p -SendMessage $send -Logoff $off)  # 280
Check ($msgs.Count -eq 1) '5-Min-Warnung nur einmal'
(Get-StlEntry $st 'Max').used_seconds = 10 * 60 - 70
[void](Invoke-StlEnforceCycle -Config $cfg -State $st -Sessions @((Sess 1 'Max')) -UtcNow $t0 -Delta 15 -Pending $p -SendMessage $send -Logoff $off)  # 55
Check ($msgs.Count -eq 2 -and $msgs[1].text -like '*1 Minute*') '1-Min-Warnung'

# --- 3. Limit erreicht: Meldung, Frist, Abmeldung; Wiederanmeldung = kuerzere Frist
Reset-Rec
$cfg = New-Cfg 1; $st = New-StlState '2026-10-26'; $p = @{}
(Get-StlEntry $st 'Max').used_seconds = 50
(Get-StlEntry $st 'Max').warned1 = $true; (Get-StlEntry $st 'Max').warned5 = $true
$s1 = @((Sess 7 'Max'))
[void](Invoke-StlEnforceCycle -Config $cfg -State $st -Sessions $s1 -UtcNow $t0 -Delta 15 -Pending $p -SendMessage $send -Logoff $off)  # 65s -> Limit
Check ($msgs.Count -eq 1 -and $msgs[0].text -like '*abgemeldet*' -and $logoffs.Count -eq 0) 'Limit: Meldung, noch keine Abmeldung'
[void](Invoke-StlEnforceCycle -Config $cfg -State $st -Sessions $s1 -UtcNow $t0.AddSeconds(15) -Delta 15 -Pending $p -SendMessage $send -Logoff $off)
Check ($logoffs.Count -eq 0) 'innerhalb der Frist keine Abmeldung'
[void](Invoke-StlEnforceCycle -Config $cfg -State $st -Sessions $s1 -UtcNow $t0.AddSeconds(31) -Delta 15 -Pending $p -SendMessage $send -Logoff $off)
Check ($logoffs.Count -eq 1 -and $logoffs[0] -eq 7) 'nach Frist: Abmeldung Sitzung 7'
$s2 = @((Sess 8 'Max'))
[void](Invoke-StlEnforceCycle -Config $cfg -State $st -Sessions $s2 -UtcNow $t0.AddSeconds(60) -Delta 15 -Pending $p -SendMessage $send -Logoff $off)
Check ($msgs.Count -eq 2) 'Wiederanmeldung: sofort neue Meldung'
[void](Invoke-StlEnforceCycle -Config $cfg -State $st -Sessions $s2 -UtcNow $t0.AddSeconds(71) -Delta 15 -Pending $p -SendMessage $send -Logoff $off)
Check ($logoffs.Count -eq 2 -and $logoffs[1] -eq 8) 'Wiederanmeldung: nach 10 s abgemeldet'

# --- 4. Getrennte Sitzung wird sofort abgemeldet, Papa nie
Reset-Rec; $p = @{}
[void](Invoke-StlEnforceCycle -Config $cfg -State $st -Sessions @((Sess 9 'Max' 4), (Sess 1 'Papa')) -UtcNow $t0.AddSeconds(100) -Delta 15 -Pending $p -SendMessage $send -Logoff $off)
Check ($logoffs.Count -eq 1 -and $logoffs[0] -eq 9 -and $msgs.Count -eq 0) 'getrennte Sitzung sofort weg, Papa unberuehrt'

# --- 5. Eltern geben Zeit frei -> keine Abmeldung, Pending geloescht
Reset-Rec; $p = @{}
[void](Invoke-StlEnforceCycle -Config $cfg -State $st -Sessions $s2 -UtcNow $t0.AddSeconds(200) -Delta 15 -Pending $p -SendMessage $send -Logoff $off)
Check ($p.Count -eq 1) 'Pending gesetzt'
Check (Invoke-StlCommand $st ([pscustomobject]@{ action = 'add_minutes'; user = 'Max'; minutes = 15 })) 'Befehl add_minutes ok'
[void](Invoke-StlEnforceCycle -Config $cfg -State $st -Sessions $s2 -UtcNow $t0.AddSeconds(260) -Delta 15 -Pending $p -SendMessage $send -Logoff $off)
Check ($p.Count -eq 0 -and $logoffs.Count -eq 0) 'nach Freigabe: keine Abmeldung'
Check (-not (Invoke-StlCommand $st ([pscustomobject]@{ action = 'add_minutes'; user = 'Max'; minutes = 99999 }))) 'unplausible Minuten abgelehnt'
Check (-not (Invoke-StlCommand $st ([pscustomobject]@{ action = 'format_c'; user = 'Max' }))) 'unbekannte Aktion abgelehnt'
Invoke-StlCommand $st ([pscustomobject]@{ action = 'unlimited_today'; user = 'Max' }) | Out-Null
Check ($null -eq (Get-StlLockReason $cfg (Get-StlEntry $st 'Max') $t0)) 'unlimited_today'
Invoke-StlCommand $st ([pscustomobject]@{ action = 'clear_extras'; user = 'Max' }) | Out-Null
Check ($null -ne (Get-StlLockReason $cfg (Get-StlEntry $st 'Max') $t0)) 'clear_extras'

# --- 6. Zeitfenster
$cfg = New-Cfg 600 $true; $cfg.window_start = '16:00'; $cfg.window_end = '20:00'
$st = New-StlState '2026-10-26'; $p = @{}; Reset-Rec
$late = [datetime]::SpecifyKind([datetime]'2026-10-26 21:00:00', 'Utc')
[void](Invoke-StlEnforceCycle -Config $cfg -State $st -Sessions @((Sess 4 'Max')) -UtcNow $late -Delta 15 -Pending $p -SendMessage $send -Logoff $off)
Check ($msgs.Count -eq 1 -and $msgs[0].text -like '*Außerhalb*') 'ausserhalb Fenster: Meldung'
[void](Invoke-StlEnforceCycle -Config $cfg -State $st -Sessions @((Sess 4 'Max')) -UtcNow $late.AddSeconds(31) -Delta 15 -Pending $p -SendMessage $send -Logoff $off)
Check ($logoffs.Count -eq 1) 'ausserhalb Fenster: Abmeldung'
Check ([int](Get-StlEntry $st 'Max').used_seconds -eq 0) 'ausserhalb Fenster: nichts gezaehlt'

# --- 7. Tageswechsel / Uhr zurueckstellen
$cfg = New-Cfg 60; $st = New-StlState '2026-10-26'; $p = @{}
(Get-StlEntry $st 'Max').used_seconds = 3000
$back = [datetime]::SpecifyKind([datetime]'2026-10-25 12:00:00', 'Utc')
[void](Invoke-StlEnforceCycle -Config $cfg -State $st -Sessions @((Sess 1 'Max' 0 $true)) -UtcNow $back -Delta 0 -Pending $p -SendMessage $send -Logoff $off)
Check ($st.date -eq '2026-10-26' -and [int](Get-StlEntry $st 'Max').used_seconds -eq 3000) 'Uhr zurueck: Zaehler bleibt'
$next = [datetime]::SpecifyKind([datetime]'2026-10-27 00:00:05', 'Utc')
[void](Invoke-StlEnforceCycle -Config $cfg -State $st -Sessions @((Sess 1 'Max' 0 $true)) -UtcNow $next -Delta 0 -Pending $p -SendMessage $send -Logoff $off)
Check ($st.date -eq '2026-10-27' -and [int](Get-StlEntry $st 'Max').used_seconds -eq 0) 'Mitternacht: Reset'

# --- 8. Zeitzone aus der Config (Kind aendert die Windows-Zeitzone -> egal)
$cfgTz = New-Cfg 60; $cfgTz.timezone = 'Pacific/Auckland'
$loc = Get-StlLocalNow $cfgTz ([datetime]::SpecifyKind([datetime]'2026-10-26 12:00:00', 'Utc'))
Check ($loc.Hour -eq 1 -and $loc.Day -eq 27) 'feste Zeitzone aus Config'

# --- 9. Status-Datei: keine Unendlich-Werte, nur Restzeit
$st = New-StlState '2026-10-26'; $cfg = New-Cfg 60
$status = New-StlStatus $cfg $st $t0
Check ($status.users[0].remaining_seconds -eq 3600) 'Status Restzeit'
Invoke-StlCommand $st ([pscustomobject]@{ action = 'unlimited_today'; user = 'Max' }) | Out-Null
$j = ConvertTo-Json -InputObject (New-StlStatus $cfg $st $t0) -Depth 5
Check ($j -notmatch 'Infinity' -and $j -match '"remaining_seconds":\s*null') 'Status unbegrenzt = null'

# --- 10. Befehle aus Dateien (Admin-Ordner) + Atomares Schreiben/Lesen
New-Item -ItemType Directory -Path (Get-StlCommandDir) -Force | Out-Null
Write-StlJson (Join-Path (Get-StlCommandDir) 'a.json') ([pscustomobject]@{ action = 'add_minutes'; user = 'Max'; minutes = 30 })
Set-Content -LiteralPath (Join-Path (Get-StlCommandDir) 'kaputt.json') -Value '{ nope'
$st = New-StlState '2026-10-26'
Invoke-StlPendingCommands $st
Check ((Get-StlEntry $st 'Max').bonus_minutes -eq 30) 'Befehl aus Datei'
Check (@(Get-ChildItem (Get-StlCommandDir)).Count -eq 0) 'Befehlsdateien geloescht'
Write-StlJson (Get-StlStatePath) $st
$st2 = Read-StlState '2026-10-26'
Check ((Get-StlEntry $st2 'Max').bonus_minutes -eq 30) 'State Roundtrip'

# --- 11. PIN
$c = New-StlConfig; Set-StlPin $c '2468'
Check (Test-StlPin $c '2468') 'PIN richtig'
Check (-not (Test-StlPin $c '2469')) 'PIN falsch'
Check ($c.pin_hash.Length -eq 64 -and $c.pin_salt.Length -eq 32) 'Hash-/Salt-Laenge wie core.py'
$threw = $false; try { Set-StlPin $c 'abc' } catch { $threw = $true }
Check $threw 'PIN-Format wird geprueft (zu kurz)'
foreach ($ok in @('1234', '12345678', 'Abcd1234', 'S3cret!Pa$$w0rd#2026', ('a' * 32), 'x.y-z_@?', '"q\b"')) {
    Check (Test-StlPinFormat $ok) ("PIN/Passwort gueltig: $ok")
    $c2 = New-StlConfig; Set-StlPin $c2 $ok
    Check ((Test-StlPin $c2 $ok) -and -not (Test-StlPin $c2 ($ok + 'x'))) ("Hash/Pruefung: $ok")
}
foreach ($bad in @('abc', ('a' * 33), 'ab cd', "12`n34", "1234`n", ('p' + [char]0xE4 + 'ssword'), '', $null, 1234)) {
    Check (-not (Test-StlPinFormat $bad)) ('PIN/Passwort ungueltig: ' + ([string]$bad -replace "`n", '\n'))
}
Check (-not (Test-StlPin $c 'ABCD')) 'Gross-/Kleinschreibung zaehlt (cmatch)'
$cs = New-StlConfig; Set-StlPin $cs 'AbCd1234'
Check (-not (Test-StlPin $cs 'abcd1234')) 'Passwort ist case-sensitiv'
# altes Format: Hash einer 4-8-stelligen Ziffern-PIN (wie v1-v4 erzeugt) bleibt gueltig
$leg = New-StlConfig; $leg.pin_salt = ('ab' * 16); $leg.pin_hash = Get-StlPinHash '2468' $leg.pin_salt
Check ((Test-StlPin $leg '2468') -and -not (Test-StlPin $leg '2469')) 'Altes Hash-Format gueltig'

# --- 12. Config-Roundtrip mit einem Kind (Array mit 1 Element bleibt Array)
$cfg = New-Cfg 90; Set-StlPin $cfg '1234'
Write-StlJson (Get-StlConfigPath) $cfg
$r = Read-StlConfig
Check ($r -and @($r.users).Count -eq 1 -and $r.users[0] -eq 'Max' -and $r.daily_limit_minutes -eq 90) 'Config Roundtrip'

# --- 13. Wochenplan (2026-10-26 ist ein Montag; Zeitzone UTC)
function New-WeekCfg {
    $c = New-Cfg 60
    $days = @(
        (New-StlDayRule 'limit' 60 '16:00' '19:00'),    # Mo
        (New-StlDayRule 'limit' 60 '16:00' '19:00'),    # Di
        (New-StlDayRule 'limit' 60 '16:00' '19:00'),    # Mi
        (New-StlDayRule 'limit' 60 '16:00' '19:00'),    # Do
        (New-StlDayRule 'limit' 120 '20:00' '01:00'),   # Fr: Fenster ueber Mitternacht
        (New-StlDayRule 'blocked' 0),                   # Sa: gesperrt
        (New-StlDayRule 'limit' 180 '10:00' '21:00')    # So
    )
    Set-StlDays $c $days
    return $c
}
function At([string]$s) { [datetime]::SpecifyKind([datetime]$s, 'Utc') }
$cfgW = New-WeekCfg
$mon17 = At '2026-10-26 17:00:00'
$st = New-StlState '2026-10-26'
Check ($null -eq (Get-StlLockReason $cfgW (Get-StlEntry $st 'Max') $mon17)) 'Wochenplan: Montag 17:00 erlaubt'
Check ((Get-StlLockReason $cfgW (Get-StlEntry $st 'Max') (At '2026-10-26 20:00:00')) -like '*Außerhalb*16:00–19:00*') 'Wochenplan: Montag 20:00 ausserhalb'
Check ((Get-StlLockReason $cfgW (Get-StlEntry $st 'Max') (At '2026-10-31 12:00:00')) -like '*gesperrt*') 'Wochenplan: Samstag gesperrt'
Check ($null -eq (Get-StlLockReason $cfgW (Get-StlEntry $st 'Max') (At '2026-11-01 12:00:00'))) 'Wochenplan: Sonntag 12:00 erlaubt'
Check ((Get-StlRemainingSeconds $cfgW (Get-StlEntry $st 'Max') (At '2026-11-01 12:00:00')) -eq 180 * 60) 'Wochenplan: Sonntag 3 h'
# Fenster ueber Mitternacht: Freitag 20:00-01:00; Samstag ist gesperrt -> Rest nach 00:00 gilt NICHT
Check ($null -eq (Get-StlLockReason $cfgW (Get-StlEntry $st 'Max') (At '2026-10-30 23:30:00'))) 'Mitternachtsfenster: Fr 23:30 erlaubt'
Check ($null -ne (Get-StlLockReason $cfgW (Get-StlEntry $st 'Max') (At '2026-10-31 00:30:00'))) 'Mitternachtsfenster: Sa 00:30 gesperrt (Samstag gesperrt)'
$cfgW2 = New-WeekCfg; $cfgW2.days[5] = New-StlDayRule 'limit' 120 '20:00' '01:00'    # Samstag ebenfalls offen
Check ($null -eq (Get-StlLockReason $cfgW2 (Get-StlEntry $st 'Max') (At '2026-10-31 00:30:00'))) 'Mitternachtsfenster: Sa 00:30 erlaubt (Freitagsfenster)'
Check ($null -ne (Get-StlLockReason $cfgW2 (Get-StlEntry $st 'Max') (At '2026-10-31 01:00:00'))) 'Mitternachtsfenster: Sa 01:00 vorbei'
Check ($null -ne (Get-StlLockReason $cfgW2 (Get-StlEntry $st 'Max') (At '2026-10-31 12:00:00'))) 'Mitternachtsfenster: Sa 12:00 ausserhalb'

# Samstag gesperrt: Kind wird abgemeldet; Eltern geben +30 Min. -> erlaubt, Limit 30 Min.
$st = New-StlState '2026-10-31'; $p = @{}; Reset-Rec
$sat = At '2026-10-31 12:00:00'
[void](Invoke-StlEnforceCycle -Config $cfgW -State $st -Sessions @((Sess 5 'Max')) -UtcNow $sat -Delta 15 -Pending $p -SendMessage $send -Logoff $off)
Check ($msgs.Count -eq 1 -and $msgs[0].text -like '*gesperrt*') 'Samstag: Meldung "gesperrt"'
[void](Invoke-StlEnforceCycle -Config $cfgW -State $st -Sessions @((Sess 5 'Max')) -UtcNow $sat.AddSeconds(31) -Delta 15 -Pending $p -SendMessage $send -Logoff $off)
Check ($logoffs.Count -eq 1) 'Samstag: Abmeldung'
Check ([int](Get-StlEntry $st 'Max').used_seconds -eq 0) 'Samstag: nichts gezaehlt'
Invoke-StlCommand $st ([pscustomobject]@{ action = 'add_minutes'; user = 'Max'; minutes = 30 }) | Out-Null
Check ((Get-StlRemainingSeconds $cfgW (Get-StlEntry $st 'Max') $sat) -eq 1800) 'Samstag +30 Min. = 30 Min. Rest'
Check ($null -eq (Get-StlLockReason $cfgW (Get-StlEntry $st 'Max') $sat)) 'Samstag +30 Min. erlaubt'

# "Heute sperren" / "Heute unbegrenzt": die letzte Elternaktion gewinnt
$st = New-StlState '2026-10-26'
Invoke-StlCommand $st ([pscustomobject]@{ action = 'block_today'; user = 'Max' }) | Out-Null
Check ((Get-StlLockReason $cfgW (Get-StlEntry $st 'Max') $mon17) -like '*von den Eltern gesperrt*') 'Heute sperren'
Invoke-StlCommand $st ([pscustomobject]@{ action = 'unlimited_today'; user = 'Max' }) | Out-Null
Check ($null -eq (Get-StlLockReason $cfgW (Get-StlEntry $st 'Max') (At '2026-10-26 23:00:00'))) 'Heute unbegrenzt hebt Sperre auf (auch ausserhalb des Fensters)'
Invoke-StlCommand $st ([pscustomobject]@{ action = 'block_today'; user = 'Max' }) | Out-Null
Check ($null -ne (Get-StlLockReason $cfgW (Get-StlEntry $st 'Max') $mon17)) 'erneut sperren'
Invoke-StlCommand $st ([pscustomobject]@{ action = 'add_minutes'; user = 'Max'; minutes = 15 }) | Out-Null
Check ($null -eq (Get-StlLockReason $cfgW (Get-StlEntry $st 'Max') $mon17)) '+15 Min. hebt "Heute sperren" auf'
Invoke-StlCommand $st ([pscustomobject]@{ action = 'block_today'; user = 'Max' }) | Out-Null
[void](Update-StlRollOver $st '2026-10-27')
Check (-not (Get-StlEntry $st 'Max').blocked_today) 'Sperre gilt nur bis Mitternacht'

# Warnung vor Fensterende (Mo 18:55, Fenster bis 19:00): Hinweis 5 Minuten, dann Abmeldung ausserhalb
$st = New-StlState '2026-10-26'; $p = @{}; Reset-Rec
[void](Invoke-StlEnforceCycle -Config $cfgW -State $st -Sessions @((Sess 6 'Max')) -UtcNow (At '2026-10-26 18:55:30') -Delta 15 -Pending $p -SendMessage $send -Logoff $off)
Check ($msgs.Count -eq 1 -and $msgs[0].text -like '*5 Minuten*') 'Fensterende: 5-Min-Warnung'
[void](Invoke-StlEnforceCycle -Config $cfgW -State $st -Sessions @((Sess 6 'Max')) -UtcNow (At '2026-10-26 18:59:10') -Delta 15 -Pending $p -SendMessage $send -Logoff $off)
Check ($msgs.Count -eq 2 -and $msgs[1].text -like '*1 Minute*') 'Fensterende: 1-Min-Warnung'
[void](Invoke-StlEnforceCycle -Config $cfgW -State $st -Sessions @((Sess 6 'Max')) -UtcNow (At '2026-10-26 19:00:05') -Delta 15 -Pending $p -SendMessage $send -Logoff $off)
Check ($msgs.Count -eq 3 -and $msgs[2].text -like '*Außerhalb*') 'Fensterende: Meldung ausserhalb'

# Zeitzone: Wochentag wird in der Config-Zeitzone bestimmt (UTC So 23:30 = Auckland Mo 12:30)
$cfgA = New-WeekCfg; $cfgA.timezone = 'Pacific/Auckland'; $cfgA.days[0] = New-StlDayRule 'blocked' 0
$locA = Get-StlLocalNow $cfgA (At '2026-10-25 23:30:00')
Check ($locA.DayOfWeek -eq 'Monday' -and (Get-StlLockReason $cfgA (Get-StlEntry (New-StlState '2026-10-26') 'Max') $locA) -like '*gesperrt*') 'Wochentag in Config-Zeitzone'

# Status mit Wochenplan
$st = New-StlState '2026-10-26'
$stat = New-StlStatus $cfgW $st $mon17
Check ($stat.week.Count -eq 7 -and $stat.today_index -eq 0 -and $stat.week[5].text -eq 'gesperrt' -and $stat.week[0].text -eq '1 Std. 00 Min. · 16:00–19:00') 'Status: Wochenplan'
Check ($stat.users[0].window -eq '16:00–19:00' -and $stat.users[0].limit_minutes -eq 60 -and $stat.users[0].day -eq 'Montag') 'Status: heutige Regel'
Check ($stat.users[0].remaining_seconds -eq 3600) 'Status: Restzeit = Limit'
$stat = New-StlStatus $cfgW (New-StlState '2026-11-01') (At '2026-11-01 12:00:00')
Check ($stat.users[0].day -eq 'Sonntag' -and $stat.today_index -eq 6) 'Status: Sonntag'
$cfgU = New-WeekCfg; $cfgU.days[0] = New-StlDayRule 'unlimited' 0
$jU = ConvertTo-Json -InputObject (New-StlStatus $cfgU $st $mon17) -Depth 6
Check ($jU -notmatch 'Infinity' -and $jU -match '"limit_minutes":\s*null' -and $jU -match '"remaining_seconds":\s*null') 'Status: unbegrenzter Tag = null'

# Config mit Wochenplan: Roundtrip, Validierung, alte Config ohne days
$cfgR = New-WeekCfg; Set-StlPin $cfgR '1234'; $cfgR.users = @('Max')
Write-StlJson (Get-StlConfigPath) $cfgR
$r = Read-StlConfig
Check ($r -and @($r.days).Count -eq 7 -and $r.days[5].mode -eq 'blocked' -and $r.days[4].window_end -eq '01:00') 'Wochenplan-Config Roundtrip'
Check ((Get-StlDayRule $r (At '2026-10-31 12:00:00')).mode -eq 'blocked') 'Wochenplan nach Roundtrip: Samstag gesperrt'
$bad = New-WeekCfg; Set-StlPin $bad '1234'; $bad.days[2].limit_minutes = 0
Write-StlJson (Get-StlConfigPath) $bad
Check ($null -eq (Read-StlConfig) -and $script:StlConfigError -like '*Mittwoch*') 'ungueltiger Wochenplan wird abgelehnt (mit Grund)'
$bad = New-WeekCfg; Set-StlPin $bad '1234'; $bad.days = @($bad.days[0..5])
Write-StlJson (Get-StlConfigPath) $bad
Check ($null -eq (Read-StlConfig)) 'Wochenplan mit 6 Tagen abgelehnt'
$old = [pscustomobject]@{ version = 2; pin_salt = $cfgR.pin_salt; pin_hash = $cfgR.pin_hash; daily_limit_minutes = 45; window_enabled = $true
    window_start = '17:00'; window_end = '18:00'; users = @('Max'); timezone = 'UTC'; grace_seconds = 30; regrace_seconds = 10 }
Write-StlJson (Get-StlConfigPath) $old
$ro = Read-StlConfig
Check ($ro -and (Get-StlDayRule $ro (At '2026-10-31 12:00:00')).limit_minutes -eq 45 -and (Get-StlDayRule $ro (At '2026-10-28 12:00:00')).window_start -eq '17:00') 'alte v2-Config ohne days gilt weiter fuer jeden Tag'
Check ($null -eq (Test-StlDays (Get-StlPreset 'schule'))) 'Preset schule gueltig'
Check ($null -eq (Test-StlDays (Get-StlPreset 'gleich' 90))) 'Preset gleich gueltig'
Check ($null -eq (Test-StlDays (Get-StlPreset 'wochenende'))) 'Preset wochenende gueltig'
$w2 = Get-StlPreset 'wochenende2h'
Check (($null -eq (Test-StlDays $w2)) -and $w2.Count -eq 7 -and @($w2[0..4] | Where-Object { $_.mode -eq 'blocked' }).Count -eq 5 -and @($w2[5..6] | Where-Object { $_.mode -eq 'limit' -and $_.limit_minutes -eq 120 -and -not $_.window_enabled }).Count -eq 2) 'Preset wochenende2h: Mo-Fr gesperrt, Sa/So 2h ohne Fenster'
Check ((Get-StlPreset 'schule').Count -eq 7 -and (Get-StlPreset 'schule')[5].window_start -eq '10:00') 'Preset schule: Mo-Fr 16-19, Sa/So 10-21'
Check ($null -ne (Test-StlDayRule (New-StlDayRule 'limit' 60 '20:00' '20:00') 'X')) 'Fenster Beginn=Ende abgelehnt'
Check ($null -ne (Test-StlDayRule (New-StlDayRule 'limit' 60 '25:00' '20:00') 'X')) 'ungueltige Uhrzeit abgelehnt'
Check ($null -eq (Test-StlDayRule (New-StlDayRule 'blocked' 0) 'X')) 'gesperrter Tag ohne Limit gueltig'

# --- 14. Helfer der Eltern-Zentrale / Restzeit-Anzeige
Get-ChildItem (Get-StlCommandDir) -ErrorAction SilentlyContinue | Remove-Item -Force
$cfgG = New-WeekCfg; Set-StlPin $cfgG '1234'; $cfgG.users = @('Max'); $cfgG.timezone = 'UTC'
$stG = New-StlState '2026-10-26'
Send-StlCommand 'add_minutes' 'Max' 30
Send-StlCommand 'block_today' 'Max' 0
Check (@(Get-ChildItem (Get-StlCommandDir) -Filter *.json).Count -eq 2) 'Send-StlCommand legt Dateien an'
$mon = At '2026-10-26 17:00:00'
Invoke-StlPendingCommands $stG
$eg = Get-StlEntry $stG 'Max'
Check ($eg.blocked_today -eq $true -and [int]$eg.bonus_minutes -eq 0) 'Send-StlCommand -> Invoke-StlPendingCommands: heute gesperrt'
Check (@(Get-ChildItem (Get-StlCommandDir) -Filter *.json).Count -eq 0) 'Befehle werden nach Ausfuehrung entfernt'
$info = Get-StlTodayInfo $cfgG $stG 'Max' $mon
Check ($info.day_name -eq 'Montag' -and $info.blocked_today -eq $true -and $info.lock_reason) 'TodayInfo: gesperrt + Grund'
$stH = New-StlState '2026-10-26'; $eh = Get-StlEntry $stH 'Max'; $eh.used_seconds = 600
$info = Get-StlTodayInfo $cfgG $stH 'Max' $mon
Check ($info.used_seconds -eq 600 -and $info.remaining -gt 0 -and $info.remaining -lt [double]::PositiveInfinity) 'TodayInfo: genutzt/Rest'
$stOld = New-StlState '2026-10-25'; (Get-StlEntry $stOld 'Max').used_seconds = 999
$info = Get-StlTodayInfo $cfgG $stOld 'Max' $mon
Check ($info.used_seconds -eq 0) 'TodayInfo: Zaehler von gestern zaehlt nicht'
Check ((Format-StlHhmm 0) -eq '00:00' -and (Format-StlHhmm 1385) -eq '23:05' -and (Format-StlHhmm 61) -eq '01:01') 'Format-StlHhmm'
$rr = New-StlRuleFromParts 'limit' 90 $true '20:00' '01:00'
Check ($rr.mode -eq 'limit' -and $rr.limit_minutes -eq 90 -and $rr.window_enabled -and $rr.window_start -eq '20:00' -and $rr.window_end -eq '01:00') 'New-StlRuleFromParts mit Fenster'
$rr = New-StlRuleFromParts 'blocked' 0 $true '20:00' '21:00'
Check ($rr.mode -eq 'blocked' -and -not $rr.window_enabled) 'New-StlRuleFromParts: gesperrt ohne Fenster'
Check ($null -eq (Save-StlConfig $cfgG)) 'Save-StlConfig gueltig'
$noPin = New-WeekCfg; $noPin.pin_hash = ''
Check ($null -ne (Save-StlConfig $noPin)) 'Save-StlConfig ohne PIN abgelehnt'
$badD = New-WeekCfg; Set-StlPin $badD '1234'; $badD.users = @('Max'); $badD.days[0].limit_minutes = 0
$before = Get-Content (Get-StlConfigPath) -Raw
Check ($null -ne (Save-StlConfig $badD) -and (Get-Content (Get-StlConfigPath) -Raw) -eq $before) 'Save-StlConfig ungueltiger Plan: nichts geschrieben'
# Viewer-Modell aus echtem Status
$stV = New-StlState '2026-10-26'
$vm = Get-StlViewerModel (ConvertFrom-Json (ConvertTo-Json -InputObject (New-StlStatus $cfgG $stV $mon) -Depth 6)) 'max' $mon
Check ($vm.Week.Count -eq 7 -and $vm.TodayIndex -eq 0 -and $vm.Week[0] -like 'Mo*') 'ViewerModel: Woche + heute'
Check ($vm.Big -ne '--:--:--') 'ViewerModel: Restzeit'
$vm = Get-StlViewerModel (ConvertFrom-Json (ConvertTo-Json -InputObject (New-StlStatus $cfgG $stV $mon) -Depth 6)) 'Fremd' $mon
Check ($vm.Small -like '*kein Limit*') 'ViewerModel: fremdes Konto'
$vm = Get-StlViewerModel $null 'Max' $mon
Check ($vm.Small -like 'Kein Status*') 'ViewerModel: ohne Status'
$vm = Get-StlViewerModel (ConvertFrom-Json (ConvertTo-Json -InputObject (New-StlStatus $cfgG $stV $mon) -Depth 6)) 'Max' $mon.AddMinutes(10)
Check ($vm.Small -like '*veraltet*') 'ViewerModel: veralteter Status'
Check ([double]::IsInfinity([double](Get-StlStatusAgeSeconds $null $mon)) -or (Get-StlStatusAgeSeconds $null $mon) -gt 1e6) 'StatusAge ohne Status = sehr gross'

Remove-Item -Recurse -Force $tmp
Write-Host ("{0} Pruefungen, {1} Fehler" -f $script:n, $script:fail)
exit $script:fail
