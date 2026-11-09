# StlCommon.ps1 - gemeinsame Logik (Pfade, JSON, PIN-Hash, Zeitfenster, Restzeit, Befehle).
# Wird vom Enforcer, von Parent-Unlock und vom Installer eingebunden (dot-sourcing).
# Gespeichert wird NUR: Einstellungen + heute genutzte Sekunden. Keine Ueberwachung.
# Kompatibel mit Windows PowerShell 5.1 (und PowerShell 7 fuer Tests auf Linux).

Set-StrictMode -Version 2.0

# ---------------------------------------------------------------- Pfade
function Get-StlDataDir {
    if ($env:STL_DATA_DIR) { return $env:STL_DATA_DIR }
    return (Join-Path $env:ProgramData 'ScreenTimeLimiter')
}
function Get-StlInstallDir {
    if ($env:STL_INSTALL_DIR) { return $env:STL_INSTALL_DIR }
    return (Join-Path $env:ProgramFiles 'ScreenTimeLimiter')
}
function Get-StlConfigPath  { Join-Path (Get-StlDataDir) 'config.json' }   # nur SYSTEM/Admins lesbar (enthaelt PIN-Hash)
function Get-StlStatePath   { Join-Path (Get-StlDataDir) 'state.json' }    # nur SYSTEM/Admins
function Get-StlCommandDir  { Join-Path (Get-StlDataDir) 'commands' }      # nur SYSTEM/Admins schreibbar
function Get-StlPublicDir   { Join-Path (Get-StlDataDir) 'public' }        # Benutzer duerfen LESEN
function Get-StlStatusPath  { Join-Path (Get-StlPublicDir) 'status.json' } # nur Restzeit-Anzeige
function Get-StlLogPath     { Join-Path (Get-StlDataDir) 'enforcer.log' }

$script:StlTaskName = 'ScreenTimeLimiterEnforcer'
$script:StlPbkdf2Rounds = 200000   # wie core.py

# ---------------------------------------------------------------- Krypto (PBKDF2-SHA256, wie core.py)
# Eigene kleine C#-Implementierung, weil Rfc2898DeriveBytes mit SHA256 erst ab .NET 4.7.2 geht.
if (-not ('StlCrypto' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Security.Cryptography;
public static class StlCrypto {
    public static byte[] Pbkdf2Sha256(byte[] password, byte[] salt, int iterations) {
        using (HMACSHA256 hmac = new HMACSHA256(password)) {
            byte[] block = new byte[salt.Length + 4];
            Buffer.BlockCopy(salt, 0, block, 0, salt.Length);
            block[salt.Length + 3] = 1;   // INT(1), ein 32-Byte-Block
            byte[] u = hmac.ComputeHash(block);
            byte[] t = (byte[])u.Clone();
            for (int i = 1; i < iterations; i++) {
                u = hmac.ComputeHash(u);
                for (int j = 0; j < t.Length; j++) { t[j] ^= u[j]; }
            }
            return t;
        }
    }
    public static bool ConstTimeEquals(string a, string b) {
        if (a == null || b == null || a.Length != b.Length) { return false; }
        int diff = 0;
        for (int i = 0; i < a.Length; i++) { diff |= a[i] ^ b[i]; }
        return diff == 0;
    }
}
'@
}

function ConvertTo-StlHex([byte[]]$Bytes) {
    return ([BitConverter]::ToString($Bytes) -replace '-', '').ToLowerInvariant()
}
function ConvertFrom-StlHex([string]$Hex) {
    $n = [int]($Hex.Length / 2)
    $b = New-Object 'byte[]' $n
    for ($i = 0; $i -lt $n; $i++) { $b[$i] = [Convert]::ToByte($Hex.Substring(2 * $i, 2), 16) }
    return ,$b
}
function Get-StlPinHash([string]$Pin, [string]$SaltHex) {
    $pw = [System.Text.Encoding]::UTF8.GetBytes($Pin)
    $salt = ConvertFrom-StlHex $SaltHex
    return (ConvertTo-StlHex ([StlCrypto]::Pbkdf2Sha256($pw, $salt, $script:StlPbkdf2Rounds)))
}
# PIN / Passwort: 4-32 Zeichen, nur sichtbare ASCII-Zeichen (Buchstaben, Ziffern, Sonderzeichen), keine Leerzeichen.
# Alte reine Ziffern-PINs (4-8) bleiben gueltig. \z statt $: kein erlaubter Zeilenumbruch am Ende.
function Test-StlPinFormat($Pin) {
    return (($Pin -is [string]) -and ($Pin -cmatch '^[\x21-\x7E]{4,32}\z'))
}
function Set-StlPin($Config, [string]$Pin) {
    if (-not (Test-StlPinFormat $Pin)) { throw 'PIN / Passwort muss 4 bis 32 Zeichen haben (Buchstaben, Ziffern, Sonderzeichen, keine Leerzeichen).' }
    $saltBytes = New-Object 'byte[]' 16
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    try { $rng.GetBytes($saltBytes) } finally { $rng.Dispose() }
    $Config.pin_salt = ConvertTo-StlHex $saltBytes
    $Config.pin_hash = Get-StlPinHash $Pin $Config.pin_salt
}
function Test-StlPin($Config, [string]$Pin) {
    if (-not $Config -or -not $Config.pin_hash -or -not $Pin) { return $false }
    return [StlCrypto]::ConstTimeEquals((Get-StlPinHash $Pin $Config.pin_salt), [string]$Config.pin_hash)
}

# ---------------------------------------------------------------- JSON (atomar schreiben, UTF-8 ohne BOM)
function Read-StlJson([string]$Path) {
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch { return $null }
}
function Write-StlJson([string]$Path, $Object) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = $Path + '.tmp'
    $json = ConvertTo-Json -InputObject $Object -Depth 8
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

# ---------------------------------------------------------------- Config / State
# Konfiguration v3: zusaetzlich 'days' = 7 Tagesregeln (Montag..Sonntag), je
#   mode ('limit' | 'blocked' | 'unlimited'), limit_minutes, window_enabled, window_start, window_end.
# Fehlt 'days' (alte v2-Konfiguration mit einem Limit), gilt fuer JEDEN Tag daily_limit_minutes + window_*.
$script:StlDayShort = @('Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So')
$script:StlDayNames = @('Montag', 'Dienstag', 'Mittwoch', 'Donnerstag', 'Freitag', 'Samstag', 'Sonntag')
$script:StlModes    = @('limit', 'blocked', 'unlimited')
$script:StlConfigError = ''

function New-StlConfig {
    return [pscustomobject]@{
        version             = 3
        pin_salt            = ''
        pin_hash            = ''
        daily_limit_minutes = 120          # Rueckfall/Altwert; gilt nur, solange 'days' fehlt
        window_enabled      = $false
        window_start        = '16:00'
        window_end          = '20:00'
        users               = @()          # Kind-Konten (Standard-Benutzer!), z. B. @('Max')
        timezone            = ''           # Windows-Zeitzonen-ID, beim Installieren festgelegt
        grace_seconds       = 30           # Wartezeit zwischen Warnung und Abmeldung
        regrace_seconds     = 10           # kuerzer, wenn das Limit heute schon erreicht war
    }
}

# Eigenschaft lesen, ohne bei fehlendem Feld abzubrechen (StrictMode) -> $null
function Get-StlProp($Obj, [string]$Name) {
    if ($null -eq $Obj) { return $null }
    $p = $Obj.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function New-StlDayRule([string]$Mode = 'limit', [int]$LimitMinutes = 120, [string]$Start = '', [string]$End = '') {
    $on = (-not [string]::IsNullOrEmpty($Start))
    return [pscustomobject]@{
        mode           = $Mode
        limit_minutes  = $LimitMinutes
        window_enabled = $on
        window_start   = $(if ($on) { $Start } else { '16:00' })
        window_end     = $(if ($on) { $End } else { '20:00' })
    }
}
# Voreinstellungen: 'schule' | 'gleich' | 'wochenende' | 'wochenende2h' (Mo-Fr gesperrt, Sa+So 2 Std. ohne Zeitfenster)
function Get-StlPreset([string]$Name, [int]$EveryDayLimit = 120) {
    switch ($Name) {
        'schule' {
            return @(1..5 | ForEach-Object { New-StlDayRule 'limit' 60 '16:00' '19:00' }) +
                   @(1..2 | ForEach-Object { New-StlDayRule 'limit' 180 '10:00' '21:00' })
        }
        'gleich' { return @(1..7 | ForEach-Object { New-StlDayRule 'limit' $EveryDayLimit }) }
        'wochenende' {
            return @(1..5 | ForEach-Object { New-StlDayRule 'blocked' 0 }) +
                   @(1..2 | ForEach-Object { New-StlDayRule 'limit' 180 '10:00' '21:00' })
        }
        'wochenende2h' {
            return @(1..5 | ForEach-Object { New-StlDayRule 'blocked' 0 }) +
                   @(1..2 | ForEach-Object { New-StlDayRule 'limit' 120 })
        }
        default { throw 'Unbekannte Voreinstellung.' }
    }
}
function Set-StlDays($Config, $Days) {
    $arr = @($Days)
    if ($arr.Count -ne 7) { throw 'Der Wochenplan braucht genau 7 Tage.' }
    Add-Member -InputObject $Config -NotePropertyName days -NotePropertyValue $arr -Force
}

# Regel fuer den Wochentag von $When (lokale Zeit; Montag = 0). Fehlende Felder -> Altwerte.
function Get-StlDayRule($Config, [datetime]$When) {
    $rule = [pscustomobject]@{
        mode           = 'limit'
        limit_minutes  = [int]$Config.daily_limit_minutes
        window_enabled = [bool]$Config.window_enabled
        window_start   = [string]$Config.window_start
        window_end     = [string]$Config.window_end
    }
    $days = Get-StlProp $Config 'days'
    if ($null -eq $days) { return $rule }
    $arr = @($days)
    $idx = ([int]$When.DayOfWeek + 6) % 7
    if ($arr.Count -ne 7 -or $null -eq $arr[$idx]) { return $rule }
    $d = $arr[$idx]
    $m = Get-StlProp $d 'mode'
    if ($m -and ($script:StlModes -contains [string]$m)) { $rule.mode = [string]$m }
    $v = Get-StlProp $d 'limit_minutes';  if ($null -ne $v) { $rule.limit_minutes = [int]$v }
    $v = Get-StlProp $d 'window_enabled'; if ($null -ne $v) { $rule.window_enabled = [bool]$v }
    $v = Get-StlProp $d 'window_start';   if ($null -ne $v) { $rule.window_start = [string]$v }
    $v = Get-StlProp $d 'window_end';     if ($null -ne $v) { $rule.window_end = [string]$v }
    return $rule
}

# Kurztext fuer eine Tagesregel, z. B. '60 Min. · 16:00–19:00', 'gesperrt', 'unbegrenzt'
function Format-StlRule($Rule) {
    $w = ''
    if ($Rule.window_enabled) { $w = (' · {0}–{1}' -f $Rule.window_start, $Rule.window_end) }
    switch ([string]$Rule.mode) {
        'blocked'   { return 'gesperrt' }
        'unlimited' { return ('unbegrenzt' + $w) }
        default {
            $m = [int]$Rule.limit_minutes
            $t = if ($m -ge 60) { ('{0} Std. {1:00} Min.' -f [int][Math]::Floor($m / 60), ($m % 60)) } else { ('{0} Min.' -f $m) }
            return ($t + $w)
        }
    }
}

# $null = ok, sonst Fehlertext (fuer Config-Pruefung und GUI)
function Test-StlDayRule($Rule, [string]$DayName = 'Tag') {
    $mode = [string](Get-StlProp $Rule 'mode')
    if ($script:StlModes -notcontains $mode) { return ('{0}: unbekannter Modus.' -f $DayName) }
    if ($mode -eq 'limit') {
        $l = 0
        if (-not [int]::TryParse([string](Get-StlProp $Rule 'limit_minutes'), [ref]$l) -or $l -lt 1 -or $l -gt 1440) {
            return ('{0}: Das Limit muss zwischen 1 Minute und 24 Stunden liegen (oder Modus gesperrt/unbegrenzt wählen).' -f $DayName)
        }
    }
    if ([bool](Get-StlProp $Rule 'window_enabled') -and $mode -ne 'blocked') {
        try {
            $s = ConvertTo-StlMinuteOfDay ([string](Get-StlProp $Rule 'window_start'))
            $e = ConvertTo-StlMinuteOfDay ([string](Get-StlProp $Rule 'window_end'))
        } catch { return ('{0}: ungültige Uhrzeit im Zeitfenster.' -f $DayName) }
        if ($s -eq $e) { return ('{0}: Beginn und Ende des Zeitfensters dürfen nicht gleich sein.' -f $DayName) }
    }
    return $null
}
function Test-StlDays($Days) {
    $arr = @($Days)
    if ($null -eq $Days -or $arr.Count -ne 7) { return 'Der Wochenplan braucht genau 7 Tage.' }
    for ($i = 0; $i -lt 7; $i++) {
        $err = Test-StlDayRule $arr[$i] $script:StlDayNames[$i]
        if ($err) { return $err }
    }
    return $null
}

function Read-StlConfig {
    $script:StlConfigError = ''
    try {
        $c = Read-StlJson (Get-StlConfigPath)
        if (-not $c) { $script:StlConfigError = 'Datei fehlt oder unlesbar'; return $null }
        if (-not $c.pin_hash -or -not @($c.users).Count) { $script:StlConfigError = 'PIN oder Konto fehlt'; return $null }
        $null = $c.daily_limit_minutes, $c.window_enabled, $c.window_start, $c.window_end, $c.grace_seconds, $c.regrace_seconds
        $days = Get-StlProp $c 'days'
        if ($null -ne $days) {
            $err = Test-StlDays $days
            if ($err) { $script:StlConfigError = $err; return $null }
        }
        return $c
    } catch { $script:StlConfigError = $_.Exception.Message; return $null }
}
function New-StlState([string]$DateString) {
    return [pscustomobject]@{ date = $DateString; users = @() }
}
function Read-StlState([string]$DateString) {
    $s = Read-StlJson (Get-StlStatePath)
    if (-not $s -or -not $s.date) { return (New-StlState $DateString) }
    return $s
}
function Get-StlEntry($State, [string]$Name) {
    foreach ($e in @($State.users)) {
        if ($e.name -ieq $Name) {
            if (-not $e.PSObject.Properties['blocked_today']) { Add-Member -InputObject $e -NotePropertyName blocked_today -NotePropertyValue $false }
            return $e
        }
    }
    $e = [pscustomobject]@{
        name            = $Name
        used_seconds    = 0.0
        bonus_minutes   = 0
        unlimited_today = $false
        blocked_today   = $false
        window_override = $false
        warned5         = $false
        warned1         = $false
        limit_hit       = $false
    }
    $State.users = @(@($State.users) + $e)
    return $e
}
function Reset-StlEntryDay($Entry) {
    $Entry.used_seconds = 0.0
    $Entry.bonus_minutes = 0
    $Entry.unlimited_today = $false
    $Entry.blocked_today = $false
    $Entry.window_override = $false
    $Entry.warned5 = $false
    $Entry.warned1 = $false
    $Entry.limit_hit = $false
}

# Nur nach vorne rollen: wird die Uhr zurueckgestellt, bleibt der Zaehler erhalten.
function Update-StlRollOver($State, [string]$TodayString) {
    if ([string]::CompareOrdinal($TodayString, [string]$State.date) -gt 0) {
        $State.date = $TodayString
        $State.users = @()
        return $true
    }
    return $false
}

function Get-StlLocalNow($Config, [datetime]$UtcNow) {
    try {
        if ($Config.timezone) {
            $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById([string]$Config.timezone)
            return [System.TimeZoneInfo]::ConvertTimeFromUtc($UtcNow, $tz)
        }
    } catch { }
    return $UtcNow.ToLocalTime()
}

# ---------------------------------------------------------------- Zeit-Logik (Paritaet zu standalone/core.py)
function ConvertTo-StlMinuteOfDay([string]$Hhmm) {
    $p = $Hhmm.Trim().Split(':')
    if ($p.Count -ne 2) { throw 'Ungueltige Uhrzeit' }
    $h = [int]$p[0]; $m = [int]$p[1]
    if ($h -lt 0 -or $h -gt 23 -or $m -lt 0 -or $m -gt 59) { throw 'Ungueltige Uhrzeit' }
    return ($h * 60 + $m)
}
# Fenster des Tages selbst. Geht es ueber Mitternacht (z. B. 22:00-06:00), gilt hier nur der Abend (ab Start).
function Test-StlOwnWindow($Rule, [datetime]$T) {
    if (-not $Rule.window_enabled) { return $true }
    $now = $T.Hour * 60 + $T.Minute
    $s = ConvertTo-StlMinuteOfDay $Rule.window_start
    $e = ConvertTo-StlMinuteOfDay $Rule.window_end
    if ($s -le $e) { return ($s -le $now -and $now -lt $e) }
    return ($now -ge $s)
}
# Nach Mitternacht gilt der Rest eines Fensters des VORTAGS, das ueber Mitternacht ging
# (nicht, wenn der Vortag gesperrt war; ob der neue Tag gesperrt ist, prueft der Aufrufer).
function Test-StlTailWindow($RulePrev, [datetime]$T) {
    if ([string]$RulePrev.mode -eq 'blocked' -or -not $RulePrev.window_enabled) { return $false }
    $now = $T.Hour * 60 + $T.Minute
    $s = ConvertTo-StlMinuteOfDay $RulePrev.window_start
    $e = ConvertTo-StlMinuteOfDay $RulePrev.window_end
    return ($s -gt $e -and $now -lt $e)
}
# Darf zur lokalen Zeit $T genutzt werden (nur Wochenplan/Fenster, ohne Tageslimit)?
# Freigaben von heute (unlimited/blocked/window_override) gelten nur fuer den Kalendertag $Today.
function Test-StlWindowAllowedAt($Config, $Entry, [datetime]$T, [datetime]$Today) {
    if ($T.Date -eq $Today.Date) {
        if ([bool](Get-StlProp $Entry 'unlimited_today')) { return $true }
        if ([bool](Get-StlProp $Entry 'blocked_today')) { return $false }
        if ([bool](Get-StlProp $Entry 'window_override')) { return $true }
    }
    $rule = Get-StlDayRule $Config $T
    if ([string]$rule.mode -eq 'blocked') { return $false }
    if (Test-StlOwnWindow $rule $T) { return $true }
    return (Test-StlTailWindow (Get-StlDayRule $Config $T.AddDays(-1)) $T)
}
function Test-StlInWindow($Config, $Entry, [datetime]$LocalNow) {
    return (Test-StlWindowAllowedAt $Config $Entry $LocalNow $LocalNow)
}
function Get-StlAllowedSeconds($Config, $Entry, [datetime]$LocalNow) {
    $rule = Get-StlDayRule $Config $LocalNow
    $base = 0.0
    if ([string]$rule.mode -ne 'blocked') { $base = [double]$rule.limit_minutes }
    return ($base * 60 + [double]$Entry.bonus_minutes * 60)
}
function Get-StlRemainingSeconds($Config, $Entry, [datetime]$LocalNow) {
    if ([bool](Get-StlProp $Entry 'unlimited_today')) { return [double]::PositiveInfinity }
    if ([bool](Get-StlProp $Entry 'blocked_today')) { return 0.0 }
    $rule = Get-StlDayRule $Config $LocalNow
    if ([string]$rule.mode -eq 'unlimited') { return [double]::PositiveInfinity }
    return [Math]::Max(0.0, (Get-StlAllowedSeconds $Config $Entry $LocalNow) - [double]$Entry.used_seconds)
}
# Sekunden, bis das erlaubte Fenster endet - nur bis 6 Minuten voraus gesucht (fuer die Warnungen), sonst Unendlich.
# Funktioniert auch ueber Mitternacht (z. B. wenn morgen 'gesperrt' ist).
$script:StlLookaheadMinutes = 6
function Get-StlSecondsToWindowEnd($Config, $Entry, [datetime]$LocalNow) {
    $base = $LocalNow.AddSeconds(-$LocalNow.Second).AddMilliseconds(-$LocalNow.Millisecond)
    for ($k = 1; $k -le $script:StlLookaheadMinutes; $k++) {
        $t = $base.AddMinutes($k)
        if (-not (Test-StlWindowAllowedAt $Config $Entry $t $LocalNow)) { return [double](($t - $LocalNow).TotalSeconds) }
    }
    return [double]::PositiveInfinity
}
# $null = nutzbar, sonst Text
function Get-StlLockReason($Config, $Entry, [datetime]$LocalNow) {
    if ([bool](Get-StlProp $Entry 'unlimited_today')) { return $null }
    if ([bool](Get-StlProp $Entry 'blocked_today')) { return 'Heute ist die Bildschirmzeit von den Eltern gesperrt.' }
    $rule = Get-StlDayRule $Config $LocalNow
    if ([string]$rule.mode -eq 'blocked' -and -not [bool](Get-StlProp $Entry 'window_override')) {
        return 'Heute ist keine Bildschirmzeit erlaubt (gesperrt).'
    }
    if (-not (Test-StlInWindow $Config $Entry $LocalNow)) {
        return ('Außerhalb der erlaubten Zeit ({0}–{1}).' -f $rule.window_start, $rule.window_end)
    }
    if ((Get-StlRemainingSeconds $Config $Entry $LocalNow) -le 0) { return 'Das Tageslimit ist aufgebraucht.' }
    return $null
}
# Sekunden bis zur naechsten Sperre (Limit oder Fensterende), Unendlich = keine in Sicht
function Get-StlSecondsLeft($Config, $Entry, [datetime]$LocalNow) {
    return [Math]::Min((Get-StlRemainingSeconds $Config $Entry $LocalNow), (Get-StlSecondsToWindowEnd $Config $Entry $LocalNow))
}

# ---------------------------------------------------------------- Eltern-Befehle (kommen aus dem Admin-Ordner commands\)
# action: add_minutes | unlimited_today | block_today | reset_used | clear_extras
# Die zuletzt gesendete Elternaktion gewinnt (z. B. '+15 Min.' hebt 'Heute sperren' auf).
function Invoke-StlCommand($State, $Cmd) {
    if (-not $Cmd -or -not $Cmd.user -or -not $Cmd.action) { return $false }
    $e = Get-StlEntry $State ([string]$Cmd.user)
    switch ([string]$Cmd.action) {
        'add_minutes' {
            $m = [int]$Cmd.minutes
            if ($m -lt 1 -or $m -gt 720) { return $false }
            $e.bonus_minutes = [int]$e.bonus_minutes + $m
            $e.window_override = $true
            $e.blocked_today = $false
            $e.warned5 = $false; $e.warned1 = $false; $e.limit_hit = $false
        }
        'unlimited_today' {
            $e.unlimited_today = $true
            $e.blocked_today = $false
            $e.limit_hit = $false
        }
        'block_today' {
            $e.blocked_today = $true
            $e.unlimited_today = $false
            $e.window_override = $false
            $e.bonus_minutes = 0
            $e.warned5 = $false; $e.warned1 = $false; $e.limit_hit = $false
        }
        'reset_used' {
            $e.used_seconds = 0.0
            $e.warned5 = $false; $e.warned1 = $false; $e.limit_hit = $false
        }
        'clear_extras' {
            $e.bonus_minutes = 0
            $e.unlimited_today = $false
            $e.blocked_today = $false
            $e.window_override = $false
        }
        default { return $false }
    }
    return $true
}

function Format-StlSeconds([double]$Sec) {
    if ([double]::IsInfinity($Sec)) { return 'unbegrenzt' }
    $s = [int][Math]::Floor($Sec)
    return ('{0}:{1:00}:{2:00}' -f [int][Math]::Floor($s / 3600), [int][Math]::Floor(($s % 3600) / 60), ($s % 60))
}

# ---------------------------------------------------------------- Log (nur Aktionen des Enforcers, kein Nutzerverhalten)
function Write-StlLog([string]$Message) {
    try {
        $p = Get-StlLogPath
        if ((Test-Path -LiteralPath $p) -and (Get-Item -LiteralPath $p).Length -gt 200KB) {
            Move-Item -LiteralPath $p -Destination ($p + '.old') -Force
        }
        $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        [System.IO.File]::AppendAllText($p, $line + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

function Get-StlShortName([string]$Name) {
    return ($Name -split '\\')[-1]
}

function Test-StlIsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.SecurityIdentifier]'S-1-5-32-544')
}

# Rechte per SID (unabhaengig von der Windows-Sprache). $UsersRight z. B. 'RX' oder $null (kein Zugriff).
function Set-StlAcl([string]$Path, [string]$UsersRight, [switch]$UsersOnFolderOnly) {
    $icaclsArgs = @($Path, '/inheritance:r', '/grant:r',
              '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F')
    if ($UsersRight) {
        if ($UsersOnFolderOnly) { $icaclsArgs += ('*S-1-5-32-545:({0})' -f $UsersRight) }
        else { $icaclsArgs += ('*S-1-5-32-545:(OI)(CI){0}' -f $UsersRight) }
    }
    $out = & icacls.exe @icaclsArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw ('icacls fehlgeschlagen fuer {0}: {1}' -f $Path, ($out -join ' ')) }
}

# ---------------------------------------------------------------- Helfer fuer Eltern-Zentrale, Installer und Restzeit-Anzeige
# (ohne Oberflaeche, damit sie auch auf Linux getestet werden koennen)

# Befehl fuer den Enforcer in den Admin-Ordner legen (er fuehrt ihn innerhalb von ~15 s aus)
$script:StlLastCmdTicks = 0L
function Send-StlCommand([string]$Action, [string]$User, [int]$Minutes = 0) {
    $dir = Get-StlCommandDir
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    # streng steigender Zeitstempel (die Uhr hat nur ~1-15 ms Aufloesung; die Reihenfolge der Befehle ist wichtig)
    $ticks = [DateTime]::UtcNow.Ticks
    if ($ticks -le $script:StlLastCmdTicks) { $ticks = $script:StlLastCmdTicks + 1 }
    $script:StlLastCmdTicks = $ticks
    $cmd = [pscustomobject]@{ action = $Action; user = $User; minutes = $Minutes; created_utc = (New-Object DateTime $ticks, ([DateTimeKind]::Utc)).ToString('o') }
    Write-StlJson (Join-Path $dir ([Guid]::NewGuid().ToString('N') + '.json')) $cmd
}

function Format-StlHhmm([int]$MinuteOfDay) {
    return ('{0:00}:{1:00}' -f [int][Math]::Floor($MinuteOfDay / 60), ($MinuteOfDay % 60))
}

# Tagesregel aus Eingabewerten (GUI). $Minutes = Limit in Minuten, $WinOn = Zeitfenster aktiv
function New-StlRuleFromParts([string]$Mode, [int]$Minutes, [bool]$WinOn, [string]$Start, [string]$End) {
    $r = New-StlDayRule $Mode $Minutes
    if ($Mode -ne 'blocked' -and $WinOn) {
        $r.window_enabled = $true; $r.window_start = $Start; $r.window_end = $End
    }
    return $r
}

# Zustand von heute fuer die Eltern-Anzeige (nur Zahlen aus config.json/state.json)
function Get-StlTodayInfo($Config, $State, [string]$Name, [datetime]$UtcNow) {
    $local = Get-StlLocalNow $Config $UtcNow
    $idx = ([int]$local.DayOfWeek + 6) % 7
    $entry = Get-StlEntry $State $Name
    $used = 0.0
    if ([string]$State.date -eq $local.ToString('yyyy-MM-dd')) { $used = [double]$entry.used_seconds }
    else { $entry = [pscustomobject]@{ used_seconds = 0.0; bonus_minutes = 0; unlimited_today = $false; blocked_today = $false; window_override = $false } }
    $rem = Get-StlRemainingSeconds $Config $entry $local
    $rule = Get-StlDayRule $Config $local
    return [pscustomobject]@{
        day_name        = $script:StlDayNames[$idx]
        rule_text       = (Format-StlRule $rule)
        used_seconds    = $used
        remaining       = $rem            # Unendlich = unbegrenzt
        bonus_minutes   = [int]$entry.bonus_minutes
        unlimited_today = [bool]$entry.unlimited_today
        blocked_today   = [bool]$entry.blocked_today
        lock_reason     = (Get-StlLockReason $Config $entry $local)
        local_now       = $local
    }
}

# Config pruefen und atomar schreiben (Enforcer liest sie in jedem Zyklus neu). $null = ok, sonst Fehlertext.
function Save-StlConfig($Config) {
    if (-not $Config.pin_hash) { return 'Es ist keine PIN gesetzt.' }
    if (-not @($Config.users).Count) { return 'Es ist kein Kind-Konto eingetragen.' }
    $days = Get-StlProp $Config 'days'
    if ($null -ne $days) { $err = Test-StlDays $days; if ($err) { return $err } }
    Write-StlJson (Get-StlConfigPath) $Config
    return $null
}

# Konten-Eingabe ('Max, Anna') pruefen: nur lokale, aktivierte Standard-Konten (nur Windows).
# -> @{ Names = @(...); Error = $null | 'Text' }
function Resolve-StlChildAccounts([string]$Text) {
    $names = @($Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object { Get-StlShortName $_ })
    if ($names.Count -eq 0) { return @{ Names = @(); Error = 'Kein Konto angegeben.' } }
    $adminSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $adminSids = @(Get-LocalGroupMember -SID $adminSid | ForEach-Object { $_.SID.Value })
    $accounts = @(Get-LocalUser | Where-Object { $_.Enabled })
    $out = @()
    foreach ($c in $names) {
        $acc = $accounts | Where-Object { $_.Name -ieq $c } | Select-Object -First 1
        if (-not $acc) { return @{ Names = @(); Error = ("Konto '{0}' nicht gefunden (nur lokale, aktivierte Konten werden unterstuetzt)." -f $c) } }
        if ($adminSids -contains $acc.SID.Value) {
            return @{ Names = @(); Error = ("Das Konto '{0}' ist ADMINISTRATOR. Dann koennte das Kind den Schutz entfernen. Bitte in den Windows-Einstellungen zuerst auf 'Standardbenutzer' umstellen (Einstellungen -> Konten -> Familie und andere Benutzer -> Kontotyp aendern)." -f $acc.Name) }
        }
        $out += $acc.Name
    }
    return @{ Names = $out; Error = $null }
}

# Alter der Status-Datei in Sekunden (Unendlich, wenn nicht lesbar). Windows PowerShell 5.1 liefert den Zeitstempel als Text, PowerShell 7 als DateTime.
function Get-StlStatusAgeSeconds($Status, [datetime]$UtcNow) {
    try {
        $u = Get-StlProp $Status 'updated_utc'
        if ($u -is [datetime]) { $t = $u.ToUniversalTime() }
        else { $t = [DateTime]::Parse([string]$u, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal) }
        return [double](($UtcNow - $t).TotalSeconds)
    } catch { return [double]::PositiveInfinity }
}

# Texte fuer die Restzeit-Anzeige des Kindes aus status.json (Paritaet zu viewer/stl_viewer.py:describe)
# -> @{ Big; Small; Week = @('Mo  ...', ...); TodayIndex }
function Get-StlViewerModel($Status, [string]$User, [datetime]$UtcNow) {
    $model = @{ Big = '--:--:--'; Small = ''; Week = @(); TodayIndex = -1 }
    if (-not $Status) { $model.Small = 'Kein Status gefunden (Dienst nicht aktiv?).'; return $model }
    $age = Get-StlStatusAgeSeconds $Status $UtcNow
    $mine = $null
    foreach ($x in @(Get-StlProp $Status 'users')) { if ($x -and ([string]$x.name) -ieq $User) { $mine = $x } }
    if ($null -eq $mine) { $model.Small = 'Für dieses Konto gilt kein Limit.'; return $model }
    $rem = Get-StlProp $mine 'remaining_seconds'
    $model.Big = $(if ($null -eq $rem) { 'unbegrenzt' } else { Format-StlSeconds ([double][Math]::Max(0, [double]$rem)) })
    $lim = Get-StlProp $mine 'limit_minutes'
    $day = [string](Get-StlProp $mine 'day'); if (-not $day) { $day = 'Heute' }
    $mode = [string](Get-StlProp $mine 'mode')
    if ($mode -eq 'blocked' -and (-not $lim)) { $small = ('{0}: keine Bildschirmzeit' -f $day) }
    elseif ($null -eq $lim) { $small = ('{0}: unbegrenzt' -f $day) }
    else { $small = ('{0}: Limit {1} Min.' -f $day, [int]$lim) }
    $win = [string](Get-StlProp $mine 'window')
    if ($win) { $small += (' · erlaubt ' + $win) }
    $lr = [string](Get-StlProp $mine 'lock_reason')
    if ($lr) { $small += ("`n" + $lr) }
    if ($age -gt 60) { $small += "`nAchtung: Der Zähl-Dienst meldet sich nicht (Stand veraltet)." }
    $model.Small = $small
    $wk = Get-StlProp $Status 'week'
    if ($null -ne $wk) { $model.Week = @(@($wk) | ForEach-Object { ('{0}   {1}' -f $_.day, $_.text) }) }
    $ti = Get-StlProp $Status 'today_index'
    if ($null -ne $ti) { $model.TodayIndex = [int]$ti }
    return $model
}
