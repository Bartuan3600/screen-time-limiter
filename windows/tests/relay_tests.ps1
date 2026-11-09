# Tests der Relay-Logik (StlRelay.ps1) ohne Netzwerk: HTTP wird durch eine Attrappe ersetzt (ntfy + textdb in-memory).
# Prueft Krypto-Vektoren (gleiche Datei wie Python/Kotlin), PIN-Sperre, Replay-Schutz, Alter, Plan-Aenderung, Status.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('stl-relay-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$env:STL_DATA_DIR = $tmp
. (Join-Path $root 'StlCommon.ps1')
. (Join-Path $root 'StlEnforce.ps1')
. (Join-Path $root 'StlRelay.ps1')

$script:fail = 0; $script:total = 0
function Check($cond, [string]$name) { $script:total++; if (-not $cond) { $script:fail++; Write-Host "FAIL: $name" -ForegroundColor Red } }

# ---------------- Vektoren
$vec = Get-Content (Join-Path $PSScriptRoot 'vectors/relay_vectors.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$key = [Convert]::FromBase64String($vec.key_b64)
Check ((Get-StlRelayTopic $key) -eq $vec.topic) 'topic-Ableitung'
Check ((Get-StlRelayDbKey $key) -eq $vec.db_key) 'db-key-Ableitung'
Check ((Get-StlRelayFingerprint $key) -eq $vec.fingerprint) 'Fingerprint'
Check ((Get-StlPairingCode $key) -eq $vec.pairing_code) 'Kopplungscode'
Check ([Convert]::ToBase64String((ConvertFrom-StlPairingCode $vec.pairing_code.ToLower())) -eq $vec.key_b64) 'Kopplungscode zurueck (klein geschrieben)'
$typo = $vec.pairing_code.Substring(0, 8) + 'Z' + $vec.pairing_code.Substring(9)
Check ($null -eq (ConvertFrom-StlPairingCode $typo)) 'Kopplungscode: Tippfehler wird erkannt'
Check ($null -eq (ConvertFrom-StlPairingCode 'quatsch')) 'Kopplungscode: Quatsch'
foreach ($e in $vec.envelopes) {
    $iv = [Convert]::FromBase64String($e.iv_b64)
    Check ((New-StlEnvelope $key $e.plaintext $iv) -eq $e.envelope) 'Umschlag identisch zu Python'
    Check ((Open-StlEnvelope $key $e.envelope) -eq $e.plaintext) 'Python-Umschlag entschluesselt'
}
$bad = $vec.envelopes[1].envelope -replace '"data":"(.)', '"data":"B'
Check ($null -eq (Open-StlEnvelope $key $bad)) 'manipulierter Umschlag -> null'
$wrong = New-Object byte[] 32
Check ($null -eq (Open-StlEnvelope $wrong $vec.envelopes[0].envelope)) 'falscher Schluessel -> null'
Check ($null -eq (Open-StlEnvelope $key 'kein json')) 'Muell -> null'
# Eigene GCM gegen .NET-AesGcm (nur PowerShell 7)
if ('System.Security.Cryptography.AesGcm' -as [type]) {
    $okAll = $true
    foreach ($len in @(0, 1, 15, 16, 17, 31, 32, 33, 100, 255, 1000)) {
        $pt = [StlGcm]::RandomBytes($len); $iv = [StlGcm]::RandomBytes(12); $k = [StlGcm]::RandomBytes(32)
        $g = New-Object System.Security.Cryptography.AesGcm (,$k)
        $ct = New-Object byte[] $len; $tag = New-Object byte[] 16
        $g.Encrypt($iv, $pt, $ct, $tag)
        $mine = [StlGcm]::Encrypt($k, $iv, $pt)
        $ref = [byte[]]($ct + $tag)
        if ([Convert]::ToBase64String($mine) -ne [Convert]::ToBase64String($ref)) { $okAll = $false }
        $back = [StlGcm]::Decrypt($k, $iv, $ref)
        if ([Convert]::ToBase64String($back) -ne [Convert]::ToBase64String($pt)) { $okAll = $false }
    }
    Check $okAll 'eigene AES-GCM == .NET AesGcm (verschiedene Laengen)'
} else { Write-Host 'Hinweis: AesGcm-Vergleich uebersprungen (nicht verfuegbar).' }
# NIST/McGrew Testfall 3 (AES-256, ohne AAD)
$k3 = [byte[]](ConvertFrom-StlHex 'feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308')
$iv3 = [byte[]](ConvertFrom-StlHex 'cafebabefacedbaddecaf888')
$pt3 = [byte[]](ConvertFrom-StlHex 'd9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b391aafd255')
$r3 = ConvertTo-StlHex ([StlGcm]::Encrypt($k3, $iv3, $pt3))
Check ($r3.EndsWith('b094dac5d93471bdec1a502270e3cc6c')) 'NIST-Testfall 15: Tag'
Check ($r3.StartsWith('522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa')) 'NIST-Testfall 15: Chiffretext'

# ---------------- Konfiguration + Attrappen
$cfg = New-StlConfig; $cfg.users = @('Max'); $cfg.timezone = 'UTC'; $cfg.daily_limit_minutes = 90
Set-StlPin $cfg '1234'
Set-StlDays $cfg (Get-StlPreset 'gleich' 90)
Write-StlJson (Get-StlConfigPath) $cfg
New-Item -ItemType Directory -Path (Get-StlCommandDir) -Force | Out-Null

Check ($null -eq (Read-StlRelayConfig)) 'ohne relay.json: nicht eingerichtet'
$code = Enable-StlRelay
$rc = Read-StlRelayConfig
Check ($rc -and $rc.enabled) 'Enable-StlRelay aktiviert'
Check ((ConvertFrom-StlPairingCode $code) -and ([Convert]::ToBase64String($rc.Key) -eq [Convert]::ToBase64String((ConvertFrom-StlPairingCode $code)))) 'Kopplungscode passt zum Schluessel'
$rc = Read-StlRelayConfig; $key1 = $rc.Key
Check ((Enable-StlRelay) -eq $code) 'erneutes Aktivieren behaelt den Schluessel'
Disable-StlRelay; Check (-not (Read-StlRelayConfig).enabled) 'Disable-StlRelay'
[void](Enable-StlRelay)
$code2 = Reset-StlRelayKey
Check ($code2 -ne $code) 'Reset-StlRelayKey: neuer Schluessel'
Check ((Read-StlRelayConfig).enabled) 'Reset behaelt den Aktiv-Zustand'
$rc = Read-StlRelayConfig; $key = $rc.Key
$h = [IO.File]::ReadAllText((Get-StlRelayPath)); Check ($h -notmatch 'STL1') 'Kopplungscode steht nicht in relay.json'
# http:// wird abgelehnt (ausser Test-Schalter)
$o = Get-Content (Get-StlRelayPath) -Raw | ConvertFrom-Json; $o | Add-Member server 'http://evil.example' -Force
Write-StlJson (Get-StlRelayPath) $o
Check ($null -eq (Read-StlRelayConfig)) 'http:// Server wird abgelehnt'
Save-StlRelayConfig $true $key '' ''

$script:Msgs = New-Object System.Collections.ArrayList
$script:Db = @{}
$script:Net = 'ok'      # ok | down | 500
$script:Seq = 0
$script:GetUrls = New-Object System.Collections.ArrayList
$http = {
    param($m, $u, $hd, $b)
    if ($script:Net -eq 'down') { throw 'offline' }
    if ($script:Net -eq '500') { return @{ Code = 500; Text = 'err' } }
    if ($m -eq 'GET' -and $u -match '/json\?poll=1&since=(.+)$') {
        [void]$script:GetUrls.Add($u)
        $since = $Matches[1]
        $list = @($script:Msgs)
        $idx = -1; for ($i = 0; $i -lt $list.Count; $i++) { if ($list[$i].id -eq $since) { $idx = $i } }
        if ($idx -ge 0) { $list = @($list | Select-Object -Skip ($idx + 1)) }
        $lines = foreach ($x in $list) { ConvertTo-Json -InputObject ([ordered]@{ id = $x.id; time = $x.time; event = 'message'; topic = 't'; message = $x.message; tags = $x.tags }) -Compress }
        return @{ Code = 200; Text = (($lines | ForEach-Object { $_ }) -join "`n") }
    }
    if ($m -eq 'POST') { $script:Db[$u] = $b; return @{ Code = 200; Text = 'ok' } }
    return @{ Code = 404; Text = '' }
}
function Add-Msg($plainObj, $when, [string[]]$tags = @('stl-cmd'), [byte[]]$withKey = $null) {
    $script:Seq++
    $k = if ($withKey) { $withKey } else { $key }
    $env = New-StlEnvelope $k (ConvertTo-Json -InputObject $plainObj -Compress -Depth 6)
    [void]$script:Msgs.Add([pscustomobject]@{ id = ('MSG{0:000000000}' -f $script:Seq); time = [DateTimeOffset]::new($when).ToUnixTimeSeconds(); tags = $tags; message = $env })
}
function CmdFiles { @(Get-ChildItem (Get-StlCommandDir) -Filter *.json -ErrorAction SilentlyContinue | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json }) }
function ClearCmds { Get-ChildItem (Get-StlCommandDir) -Filter *.json -ErrorAction SilentlyContinue | Remove-Item }
function LastRes($rs) { @($rs.last_cmds)[-1] }

$t0 = [DateTime]::UtcNow
$rs = New-StlRelayState
$config = Read-StlConfig

# ---- gueltiger Befehl
Add-Msg @{ v = 1; id = 'c1'; action = 'add_minutes'; user = 'Max'; minutes = 30; pin = '1234' } $t0
$n = Receive-StlRelayCommands $rc $rs $config $t0 $http
Check ($n -eq 1) 'ein Befehl verarbeitet'
$f = @(CmdFiles); Check ($f.Count -eq 1 -and $f[0].action -eq 'add_minutes' -and $f[0].minutes -eq 30 -and $f[0].user -eq 'Max') 'add_minutes -> commands\-Datei'
Check ((LastRes $rs).ok -eq $true -and (LastRes $rs).id -eq 'c1') 'Ergebnis ok mit Befehls-ID'
Check ($script:GetUrls[0] -match 'since=10m') 'erste Abfrage mit since=10m'
# Cursor + Replay: gleiche ID erneut zugestellt (anderer ntfy-Id) -> nur einmal
ClearCmds
Add-Msg @{ v = 1; id = 'c1'; action = 'add_minutes'; user = 'Max'; minutes = 30; pin = '1234' } $t0
$n = Receive-StlRelayCommands $rc $rs $config $t0 $http
Check ($script:GetUrls[1] -match 'since=MSG000000001') 'Folge-Abfrage mit Cursor (letzte ntfy-ID)'
Check (@(CmdFiles).Count -eq 0 -and $n -eq 0) 'Replay (gleiche Befehls-ID) wird nicht ausgefuehrt'
# Cursor verloren -> alles nochmal geliefert -> nichts doppelt
$rs.last_id = ''
$n = Receive-StlRelayCommands $rc $rs $config $t0 $http
Check (@(CmdFiles).Count -eq 0) 'Cursor verloren: nichts doppelt ausgefuehrt'
# Zustand ueberlebt Neustart
Save-StlRelayState $rs; $rs2 = Read-StlRelayState
Check (@($rs2.processed).Count -ge 2 -and $rs2.last_id -eq $rs.last_id) 'relay_state.json: Zustand gespeichert/gelesen'

# ---- fremde Tags / fremder Schluessel / Muell / zu alt
$before = $script:Msgs.Count
Add-Msg @{ id = 'x1'; action = 'unlimited_today'; user = 'Max'; pin = '1234' } $t0 @('andere')
Add-Msg @{ id = 'x2'; action = 'unlimited_today'; user = 'Max'; pin = '1234' } $t0 @('stl-cmd') $wrong
[void]$script:Msgs.Add([pscustomobject]@{ id = 'MSGjunk00000'; time = [DateTimeOffset]::new($t0).ToUnixTimeSeconds(); tags = @('stl-cmd'); message = 'kein umschlag' })
Add-Msg @{ id = 'old1'; action = 'unlimited_today'; user = 'Max'; pin = '1234' } $t0.AddMinutes(-30)
$n = Receive-StlRelayCommands $rc $rs $config $t0 $http
Check (@(CmdFiles).Count -eq 0) 'fremder Tag / falscher Schluessel / Muell / zu alt: nichts ausgefuehrt'
Check ((LastRes $rs).id -eq 'old1' -and -not (LastRes $rs).ok -and (LastRes $rs).msg -match 'alt') 'zu alter Befehl: Rueckmeldung "zu alt"'

# ---- PIN: 3 falsche -> Sperre, auch richtige PIN waehrend der Sperre abgelehnt
Add-Msg @{ id = 'p1'; action = 'block_today'; user = 'Max'; pin = '0000' } $t0
$null = Receive-StlRelayCommands $rc $rs $config $t0 $http
Check ((LastRes $rs).msg -match '1 von 3') 'falsche PIN 1/3'
Add-Msg @{ id = 'p2'; action = 'block_today'; user = 'Max'; pin = '1111' } $t0
Add-Msg @{ id = 'p3'; action = 'block_today'; user = 'Max'; pin = '2222' } $t0
$null = Receive-StlRelayCommands $rc $rs $config $t0 $http
Check ((LastRes $rs).msg -match 'Gesperrt für 30 s') '3. falsche PIN -> 30 s Sperre'
Add-Msg @{ id = 'p4'; action = 'block_today'; user = 'Max'; pin = '1234' } $t0.AddSeconds(10)
$null = Receive-StlRelayCommands $rc $rs $config $t0.AddSeconds(10) $http
Check (-not (LastRes $rs).ok -and (LastRes $rs).msg -match 'gesperrt, noch') 'richtige PIN waehrend der Sperre abgelehnt'
Check (@(CmdFiles).Count -eq 0) 'waehrend Sperre kein Befehl ausgefuehrt'
Add-Msg @{ id = 'p5'; action = 'block_today'; user = 'Max'; pin = '1234' } $t0.AddSeconds(40)
$null = Receive-StlRelayCommands $rc $rs $config $t0.AddSeconds(40) $http
Check ((LastRes $rs).ok -and @(CmdFiles).Count -eq 1 -and @(CmdFiles)[0].action -eq 'block_today') 'nach der Sperre klappt die richtige PIN'
Check ($rs.lock_level -eq 0 -and $rs.fail_count -eq 0) 'Erfolg setzt Zaehler zurueck'
ClearCmds
# Eskalation: zweite Sperre 120 s
$tt = $t0.AddSeconds(100)
foreach ($i in 1..3) { Add-Msg @{ id = "q$i"; action = 'block_today'; user = 'Max'; pin = '9999' } $tt }
$null = Receive-StlRelayCommands $rc $rs $config $tt $http
foreach ($i in 4..6) { Add-Msg @{ id = "q$i"; action = 'block_today'; user = 'Max'; pin = '9999' } $tt.AddSeconds(40) }
$null = Receive-StlRelayCommands $rc $rs $config $tt.AddSeconds(40) $http
Check ((LastRes $rs).msg -match 'Gesperrt für 120 s') 'wiederholte Fehlversuche ohne Erfolg dazwischen -> 120 s'
$rs.locked_until = ''; $rs.fail_count = 0; $rs.lock_level = 0

# ---- Formate, Konto, Aktionen
$tn = $t0.AddMinutes(5)
Add-Msg @{ id = 'a1'; action = 'add_minutes'; user = 'Max'; minutes = 9999; pin = '1234' } $tn
Add-Msg @{ id = 'a2'; action = 'add_minutes'; user = 'Max'; minutes = 'abc'; pin = '1234' } $tn
Add-Msg @{ id = 'a3'; action = 'add_minutes'; user = 'Fremder'; minutes = 10; pin = '1234' } $tn
Add-Msg @{ id = 'a4'; action = 'format_c'; user = 'Max'; pin = '1234' } $tn
Add-Msg @{ id = 'a5'; action = 'reset_used'; user = 'Max'; pin = '1234' } $tn
Add-Msg @{ id = 'a6'; action = 'add_minutes'; user = 'Max'; minutes = 5; pin = 1234 } $tn
$null = Receive-StlRelayCommands $rc $rs $config $tn $http
$res = @($rs.last_cmds | Where-Object { $_.id -like 'a*' })
Check ($res.Count -eq 6 -and @($res | Where-Object { $_.ok }).Count -eq 0) 'ungueltige Befehle (Minuten, Konto, Aktion, reset_used, PIN als Zahl) werden abgelehnt'
Check (@(CmdFiles).Count -eq 0) 'ungueltige Befehle erzeugen keine Dateien'
$rs.fail_count = 0; $rs.lock_level = 0; $rs.locked_until = ''
foreach ($a in @('unlimited_today', 'clear_extras', 'block_today')) { Add-Msg @{ id = "ok_$a"; action = $a; pin = '1234' } $tn }   # ohne user -> erstes Konto
$null = Receive-StlRelayCommands $rc $rs $config $tn $http
$acts = @(CmdFiles | ForEach-Object { $_.action } | Sort-Object)
Check (($acts -join ',') -eq 'block_today,clear_extras,unlimited_today') 'Aktionen ohne user gehen an das erste Konto'
Check (@(CmdFiles | Where-Object { $_.user -eq 'Max' }).Count -eq 3) 'Konto = Max'
ClearCmds
Add-Msg @{ id = 'r1'; action = 'refresh' } $tn
$null = Receive-StlRelayCommands $rc $rs $config $tn $http
Check ((LastRes $rs).ok -and $rs.last_pub -eq '') 'refresh ohne PIN, loest sofortige Veroeffentlichung aus'


# ---- Wochenplan
$plan = @(1..5 | ForEach-Object { @{ mode = 'limit'; limit_minutes = 45; window_enabled = $true; window_start = '16:00'; window_end = '19:00' } }) + @(1..2 | ForEach-Object { @{ mode = 'blocked'; limit_minutes = 0; window_enabled = $false; window_start = '16:00'; window_end = '20:00' } })
Add-Msg @{ id = 'pl1'; action = 'set_plan'; days = $plan; pin = '1234' } $tn
$null = Receive-StlRelayCommands $rc $rs $config $tn $http
Check ((LastRes $rs).ok) 'set_plan ok'
$c2 = Read-StlConfig
Check ($c2 -and @($c2.days).Count -eq 7 -and $c2.days[0].limit_minutes -eq 45 -and $c2.days[0].window_enabled -eq $true -and $c2.days[0].window_start -eq '16:00' -and $c2.days[6].mode -eq 'blocked') 'Wochenplan in config.json gespeichert'
Check ($c2.pin_hash -eq $config.pin_hash -and @($c2.users)[0] -eq 'Max') 'PIN-Hash und Konten unveraendert'
$badPlan = @($plan); $badPlan[2] = @{ mode = 'limit'; limit_minutes = 0; window_enabled = $false; window_start = '16:00'; window_end = '20:00' }
Add-Msg @{ id = 'pl2'; action = 'set_plan'; days = $badPlan; pin = '1234' } $tn
$null = Receive-StlRelayCommands $rc $rs $c2 $tn $http
Check (-not (LastRes $rs).ok) 'ungueltiger Plan (Limit 0) abgelehnt'
$badPlan2 = @($plan); $badPlan2[1] = @{ mode = 'limit'; limit_minutes = 30; window_enabled = $true; window_start = '10:00'; window_end = '10:00' }
Add-Msg @{ id = 'pl3'; action = 'set_plan'; days = $badPlan2; pin = '1234' } $tn
$null = Receive-StlRelayCommands $rc $rs $c2 $tn $http
Check (-not (LastRes $rs).ok) 'ungueltiger Plan (Fenster Anfang = Ende) abgelehnt'
Add-Msg @{ id = 'pl4'; action = 'set_plan'; days = @($plan[0..2]); pin = '1234' } $tn
$null = Receive-StlRelayCommands $rc $rs $c2 $tn $http
Check (-not (LastRes $rs).ok) 'Plan mit 3 Tagen abgelehnt'
Check ((Read-StlConfig).days[0].limit_minutes -eq 45) 'abgelehnte Plaene aendern die Config nicht'
$evil = @($plan); $evil[0] = @{ mode = 'limit'; limit_minutes = 45; window_enabled = $false; window_start = '16:00'; window_end = '20:00'; pin_hash = 'x'; users = @('Evil') }
Add-Msg @{ id = 'pl5'; action = 'set_plan'; days = $evil; pin = '1234' } $tn
$null = Receive-StlRelayCommands $rc $rs $c2 $tn $http
$c3 = Read-StlConfig
Check ($c3.pin_hash -eq $config.pin_hash -and @($c3.users)[0] -eq 'Max' -and -not $c3.days[0].PSObject.Properties['pin_hash']) 'fremde Felder im Plan werden verworfen'

# ---- Netz
$rs3 = New-StlRelayState
$script:Net = 'down'
$n = Receive-StlRelayCommands $rc $rs3 $config $tn $http
Check ($n -eq 0 -and $rs3.backoff_until -ne '') 'offline: kein Absturz, Backoff gesetzt'
$script:GetUrls.Clear(); $script:Net = 'ok'
$n = Receive-StlRelayCommands $rc $rs3 $config $tn.AddSeconds(5) $http
Check ($script:GetUrls.Count -eq 0) 'waehrend Backoff keine Anfrage'
$n = Receive-StlRelayCommands $rc $rs3 $config $tn.AddSeconds(31) $http
Check ($script:GetUrls.Count -eq 1 -and $rs3.backoff_until -eq '') 'nach Backoff wieder Anfrage, Backoff geloescht'
$script:Net = '500'
$null = Receive-StlRelayCommands $rc $rs3 $config $tn.AddSeconds(100) $http
Check ($rs3.net_fails -eq 1) 'HTTP 500 -> Backoff'
$script:Net = 'ok'

# ---- Status
$state = New-StlState ((Get-StlLocalNow $config $tn).ToString('yyyy-MM-dd'))
$e = Get-StlEntry $state 'Max'; $e.used_seconds = 1234.5; $e.bonus_minutes = 15
$sessions = @([pscustomobject]@{ Id = 1; State = 0; User = 'PC\Max'; Locked = $false })
$cfgNow = Read-StlConfig
Set-StlDays $cfgNow (Get-StlPreset 'gleich' 90)   # unabhaengig vom Wochentag der Testausfuehrung
$rsP = New-StlRelayState
Add-StlRelayResult $rsP 'zz1' $true 'ok' $tn
$ok = Publish-StlRelayStatus $rc $rsP $cfgNow $state $sessions $tn $http
Check ($ok) 'Status veroeffentlicht'
$url = '{0}/{1}' -f $rc.db_base, $rc.DbKey
Check ($script:Db.ContainsKey($url)) 'Status unter dem abgeleiteten textdb-Schluessel'
$plain = Open-StlEnvelope $key $script:Db[$url]
Check ($plain -and $script:Db[$url] -notmatch 'Max') 'Status ist verschluesselt (kein Klartext)'
$st = $plain | ConvertFrom-Json
Check ($st.v -eq 1 -and @($st.users).Count -eq 1 -and $st.users[0].name -eq 'Max' -and $st.users[0].session -eq 'active') 'Status: Konto + Sitzung aktiv'
Check ($st.users[0].used_seconds -eq 1234 -and $st.users[0].bonus_minutes -eq 15) 'Status: genutzte Zeit, Bonus'
Check ($st.users[0].remaining_seconds -gt 0 -and @($st.plan).Count -eq 7 -and @($st.last_cmds)[0].id -eq 'zz1') 'Status: Restzeit, Plan (7), letzte Befehle'
$props = ($st.PSObject.Properties.Name + $st.users[0].PSObject.Properties.Name) -join ','
Check ($props -notmatch 'app|url|site|window_title|location|message') 'Status enthaelt keine Ueberwachungsfelder'
$cnt = $script:Db.Count
Check (-not (Publish-StlRelayStatus $rc $rsP $cfgNow $state $sessions $tn.AddSeconds(10) $http)) 'unveraendert < 90 s: nicht erneut schreiben'
Check (Publish-StlRelayStatus $rc $rsP $cfgNow $state $sessions $tn.AddSeconds(95) $http) 'Lebenszeichen nach 90 s'
$e.used_seconds = 1300
Check (-not (Publish-StlRelayStatus $rc $rsP $cfgNow $state $sessions $tn.AddSeconds(110) $http)) 'Aenderung < 30 s nach letzter Veroeffentlichung: noch nicht'
Check (Publish-StlRelayStatus $rc $rsP $cfgNow $state $sessions $tn.AddSeconds(130) $http) 'Aenderung nach 30 s: veroeffentlichen'
$rsP.last_pub = ''
Check (Publish-StlRelayStatus $rc $rsP $cfgNow $state $sessions $tn.AddSeconds(131) $http) 'last_pub leer (nach Befehl): sofort'
$script:Net = 'down'; $rsP.last_pub = ''
Check (-not (Publish-StlRelayStatus $rc $rsP $cfgNow $state $sessions $tn.AddSeconds(500) $http)) 'Publish offline: false, kein Absturz'
$script:Net = 'ok'
# Sitzungsstatus
Check ((Get-StlSessionStatus @() 'Max') -eq 'none') 'Sitzung: keine'
Check ((Get-StlSessionStatus @([pscustomobject]@{ Id = 1; State = 0; User = 'Max'; Locked = $true }) 'Max') -eq 'locked') 'Sitzung: gesperrt'
Check ((Get-StlSessionStatus @([pscustomobject]@{ Id = 1; State = 4; User = 'Max'; Locked = $false }) 'max') -eq 'disconnected') 'Sitzung: getrennt'
Check ((Get-StlSessionStatus @([pscustomobject]@{ Id = 2; State = 0; User = 'Papa'; Locked = $false }) 'Max') -eq 'none') 'Sitzung: andere Konten zaehlen nicht'
# unbegrenzt -> remaining null
$e.unlimited_today = $true
$rsU = New-StlRelayState
$stU = New-StlRelayStatus $cfgNow $state $sessions $rsU $tn
Check ($null -eq $stU.users[0].remaining_seconds) 'unbegrenzt -> remaining_seconds = null'
# Groesse (ntfy-Limit gilt nur fuer Befehle; der Plan-Befehl muss < 4096 Byte bleiben)
$big = New-StlEnvelope $key (ConvertTo-Json -InputObject @{ v = 1; id = ('a' * 32); action = 'set_plan'; pin = ('Z9!' * 10 + 'ab'); days = $plan } -Compress -Depth 6)
Check ($big.Length -lt 4096) ('set_plan-Umschlag < 4096 Byte (' + $big.Length + ')')

# ---- PIN / Passwort mit Buchstaben, Ziffern, Sonderzeichen (4-32), alte Ziffern-PIN bleibt gueltig (siehe oben mit '1234')
$cfgPw = Read-StlConfig; $pw = 'Gut3s!"Pa\ss$#2026'; Set-StlPin $cfgPw $pw
ClearCmds; $rsP = New-StlRelayState; $tn = $t0.AddMinutes(90)
Add-Msg @{ v = 1; id = 'w1'; action = 'add_minutes'; user = 'Max'; minutes = 15; pin = $pw } $tn
Add-Msg @{ v = 1; id = 'w2'; action = 'add_minutes'; user = 'Max'; minutes = 15; pin = 'gut3s!"pa\ss$#2026' } $tn
Add-Msg @{ v = 1; id = 'w3'; action = 'add_minutes'; user = 'Max'; minutes = 15; pin = ('x' * 33) } $tn
Add-Msg @{ v = 1; id = 'w4'; action = 'add_minutes'; user = 'Max'; minutes = 15; pin = '1234' } $tn
$null = Receive-StlRelayCommands $rc $rsP $cfgPw $tn $http
$rw = @{}; foreach ($x in $rsP.last_cmds) { $rw[$x.id] = $x }
Check ($rw['w1'].ok) 'Passwort mit Buchstaben/Sonderzeichen wird akzeptiert'
Check (-not $rw['w2'].ok -and $rw['w2'].msg -match 'Falsche PIN') 'Passwort ist case-sensitiv (falsch -> abgelehnt)'
Check (-not $rw['w3'].ok) 'zu langes Passwort (33) abgelehnt'
Check (-not $rw['w4'].ok) 'alte Ziffern-PIN passt nicht zum neuen Passwort'
Check ($rsP.fail_count -eq 2 -or $rsP.lock_level -ge 1) 'Fehlversuche mit neuem Format werden gezaehlt (Rate-Limit)'
ClearCmds

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
if ($script:fail -eq 0) { Write-Host ('OK: {0} Pruefungen bestanden.' -f $script:total); exit 0 } else { Write-Host ('{0} von {1} fehlgeschlagen.' -f $script:fail, $script:total); exit 1 }
