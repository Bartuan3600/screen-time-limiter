# StlRelay.ps1 - Handy-Fernsteuerung ueber das Relay (ntfy.sh fuer Befehle, textdb.dev fuer den Status).
# AUS, solange nicht in der Eltern-Zentrale aktiviert. Protokoll: siehe PROTOCOL_RELAY.md (gleiche Konventionen wie die Ausgaben-App).
#
# Was gesendet wird (AES-256-GCM-verschluesselt, nur mit dem Kopplungs-Schluessel lesbar):
#   NUR was der Limiter ohnehin kennt: heute genutzt/uebrig, Regel von heute, Wochenplan, Sitzung aktiv/gesperrt/abgemeldet,
#   Ergebnis der letzten Befehle. KEINE Apps, Webseiten, Nachrichten oder Standorte.
# Kompatibel mit Windows PowerShell 5.1 (C# 5!) und PowerShell 7 (Tests auf Linux).
# Die AES-GCM-Implementierung ist selbst geschrieben (AES-ECB aus .NET + GHASH), weil .NET Framework 4.x kein AesGcm kennt.

Set-StrictMode -Version 2.0

if (-not ('StlGcm' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Security.Cryptography;
using System.Text;

public static class StlGcm {
    private static ICryptoTransform NewEcb(byte[] key) {
        Aes aes = Aes.Create();
        aes.Mode = CipherMode.ECB;
        aes.Padding = PaddingMode.None;
        aes.Key = key;
        return aes.CreateEncryptor();
    }
    private static void Mul(ulong[] x, ulong[] h) {
        ulong zh = 0, zl = 0, vh = h[0], vl = h[1];
        for (int i = 0; i < 128; i++) {
            ulong bit = (i < 64) ? ((x[0] >> (63 - i)) & 1UL) : ((x[1] >> (127 - i)) & 1UL);
            if (bit == 1UL) { zh ^= vh; zl ^= vl; }
            bool lsb = (vl & 1UL) == 1UL;
            vl = (vl >> 1) | (vh << 63);
            vh = vh >> 1;
            if (lsb) { vh ^= 0xE100000000000000UL; }
        }
        x[0] = zh; x[1] = zl;
    }
    private static ulong Be(byte[] b, int o) {
        ulong r = 0;
        for (int i = 0; i < 8; i++) { r = (r << 8) | b[o + i]; }
        return r;
    }
    private static void PutBe(ulong v, byte[] b, int o) {
        for (int i = 7; i >= 0; i--) { b[o + i] = (byte)(v & 0xFF); v >>= 8; }
    }
    private static byte[] Ghash(ulong[] h, byte[] c) {
        ulong[] y = new ulong[2];
        byte[] blk = new byte[16];
        int pos = 0;
        while (pos < c.Length) {
            Array.Clear(blk, 0, 16);
            int n = Math.Min(16, c.Length - pos);
            Buffer.BlockCopy(c, pos, blk, 0, n);
            y[0] ^= Be(blk, 0); y[1] ^= Be(blk, 8);
            Mul(y, h);
            pos += 16;
        }
        // Laengenblock: len(A)=0 Bit, len(C) in Bit
        y[0] ^= 0UL; y[1] ^= ((ulong)c.Length) * 8UL;
        Mul(y, h);
        byte[] s = new byte[16];
        PutBe(y[0], s, 0); PutBe(y[1], s, 8);
        return s;
    }
    private static byte[] Core(byte[] key, byte[] iv, byte[] input, bool encrypt, byte[] tagIn, out byte[] tagOut) {
        if (key == null || key.Length != 32) { throw new ArgumentException("key"); }
        if (iv == null || iv.Length != 12) { throw new ArgumentException("iv"); }
        using (ICryptoTransform ecb = NewEcb(key)) {
            byte[] zero = new byte[16], hb = new byte[16];
            ecb.TransformBlock(zero, 0, 16, hb, 0);
            ulong[] h = new ulong[] { Be(hb, 0), Be(hb, 8) };
            byte[] j0 = new byte[16];
            Buffer.BlockCopy(iv, 0, j0, 0, 12);
            j0[15] = 1;
            byte[] ctr = (byte[])j0.Clone();
            byte[] ks = new byte[16];
            byte[] outp = new byte[input.Length];
            for (int pos = 0; pos < input.Length; pos += 16) {
                for (int k = 15; k >= 12; k--) { ctr[k]++; if (ctr[k] != 0) { break; } }
                ecb.TransformBlock(ctr, 0, 16, ks, 0);
                int n = Math.Min(16, input.Length - pos);
                for (int i = 0; i < n; i++) { outp[pos + i] = (byte)(input[pos + i] ^ ks[i]); }
            }
            byte[] s = Ghash(h, encrypt ? outp : input);
            byte[] ej0 = new byte[16];
            ecb.TransformBlock(j0, 0, 16, ej0, 0);
            byte[] tag = new byte[16];
            for (int i = 0; i < 16; i++) { tag[i] = (byte)(s[i] ^ ej0[i]); }
            tagOut = tag;
            return outp;
        }
    }
    // -> Chiffretext || 16-Byte-Tag (wie Android/Python)
    public static byte[] Encrypt(byte[] key, byte[] iv, byte[] plain) {
        byte[] tag;
        byte[] ct = Core(key, iv, plain, true, null, out tag);
        byte[] r = new byte[ct.Length + 16];
        Buffer.BlockCopy(ct, 0, r, 0, ct.Length);
        Buffer.BlockCopy(tag, 0, r, ct.Length, 16);
        return r;
    }
    // Wirft CryptographicException, wenn der Tag nicht stimmt (falscher Schluessel / manipuliert)
    public static byte[] Decrypt(byte[] key, byte[] iv, byte[] ctTag) {
        if (ctTag == null || ctTag.Length < 16) { throw new CryptographicException("zu kurz"); }
        int n = ctTag.Length - 16;
        byte[] ct = new byte[n];
        Buffer.BlockCopy(ctTag, 0, ct, 0, n);
        byte[] tag;
        byte[] pt = Core(key, iv, ct, false, null, out tag);
        int diff = 0;
        for (int i = 0; i < 16; i++) { diff |= tag[i] ^ ctTag[n + i]; }
        if (diff != 0) { throw new CryptographicException("Tag stimmt nicht"); }
        return pt;
    }
    public static byte[] RandomBytes(int n) {
        byte[] b = new byte[n];
        RandomNumberGenerator r = RandomNumberGenerator.Create();
        try { r.GetBytes(b); } finally { r.Dispose(); }
        return b;
    }
}

public static class StlBase32 {
    private const string Alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
    public static string Encode(byte[] data) {
        StringBuilder sb = new StringBuilder();
        int buffer = 0, bits = 0;
        for (int i = 0; i < data.Length; i++) {
            buffer = (buffer << 8) | data[i]; bits += 8;
            while (bits >= 5) { sb.Append(Alpha[(buffer >> (bits - 5)) & 31]); bits -= 5; }
            buffer &= (1 << bits) - 1;
        }
        if (bits > 0) { sb.Append(Alpha[(buffer << (5 - bits)) & 31]); }
        return sb.ToString();
    }
    // null bei ungueltigen Zeichen
    public static byte[] Decode(string s) {
        s = s.ToUpperInvariant();
        byte[] outp = new byte[s.Length * 5 / 8];
        int buffer = 0, bits = 0, o = 0;
        for (int i = 0; i < s.Length; i++) {
            int v = Alpha.IndexOf(s[i]);
            if (v < 0) { return null; }
            buffer = (buffer << 5) | v; bits += 5;
            if (bits >= 8) { if (o < outp.Length) { outp[o++] = (byte)((buffer >> (bits - 8)) & 0xFF); } bits -= 8; buffer &= (1 << bits) - 1; }
        }
        return outp;
    }
}
'@
}

# ---------------------------------------------------------------- Pfade / Konfiguration
function Get-StlRelayPath      { Join-Path (Get-StlDataDir) 'relay.json' }        # NUR SYSTEM/Admins (enthaelt den Schluessel)
function Get-StlRelayStatePath { Join-Path (Get-StlDataDir) 'relay_state.json' }

$script:StlRelayDefaultServer = 'https://ntfy.sh'
$script:StlRelayDefaultDb     = 'https://textdb.dev/api/data'
$script:StlRelayTag           = 'stl-cmd'
$script:StlRelayActions       = @('add_minutes', 'unlimited_today', 'block_today', 'clear_extras', 'set_plan', 'refresh')
$script:StlRelayMaxAgeSeconds = 600     # aeltere Befehle werden nicht mehr ausgefuehrt (ntfy-Serverzeit)
$script:StlRelayLockSeconds   = @(30, 120, 600, 3600)   # Sperre nach 3 falschen PINs, steigt bei Wiederholung

function ConvertTo-StlB64([byte[]]$Bytes) { return [Convert]::ToBase64String($Bytes) }

# ---------------------------------------------------------------- Schluessel, Ableitung, Kopplungscode
function New-StlRelayKeyBytes { return ,[StlGcm]::RandomBytes(32) }

function Get-StlRelayHmacHex([byte[]]$Key, [string]$Label) {
    $h = New-Object System.Security.Cryptography.HMACSHA256 (,$Key)
    try { return (ConvertTo-StlHex ($h.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Label)))) } finally { $h.Dispose() }
}
function Get-StlRelayTopic([byte[]]$Key)    { return ('stl-' + (Get-StlRelayHmacHex $Key 'stl-topic-v1').Substring(0, 24)) }
function Get-StlRelayDbKey([byte[]]$Key)    { return ('stl-' + (Get-StlRelayHmacHex $Key 'stl-status-v1').Substring(0, 24)) }
function Get-StlRelayFingerprint([byte[]]$Key) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (ConvertTo-StlHex ($sha.ComputeHash($Key))).Substring(0, 8) } finally { $sha.Dispose() }
}

# STL1-XXXX-XXXX-...-PPPP  (Base32 des 32-Byte-Schluessels in 4er-Gruppen + 4 Zeichen Pruefsumme)
function Get-StlPairingCode([byte[]]$Key) {
    $b32 = [StlBase32]::Encode($Key)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $chk = [StlBase32]::Encode(($sha.ComputeHash($Key))[0..4]).Substring(0, 4) } finally { $sha.Dispose() }
    $groups = @(); for ($i = 0; $i -lt $b32.Length; $i += 4) { $groups += $b32.Substring($i, [Math]::Min(4, $b32.Length - $i)) }
    return ('STL1-' + ($groups -join '-') + '-' + $chk)
}
# -> Schluessel (byte[]) oder $null
function ConvertFrom-StlPairingCode([string]$Code) {
    if (-not $Code) { return $null }
    $c = ($Code.ToUpperInvariant() -replace '[\s]', '')
    if (-not $c.StartsWith('STL1-')) { return $null }
    $parts = $c.Substring(5).Split('-')
    if ($parts.Count -ne 14) { return $null }
    $key = [StlBase32]::Decode(($parts[0..12] -join ''))
    if (-not $key -or $key.Length -ne 32) { return $null }
    if ((Get-StlPairingCode $key) -ne $c) { return $null }
    return ,$key
}

# ---------------------------------------------------------------- Umschlag (wie PROTOCOL.md der Ausgaben-App)
function New-StlEnvelope([byte[]]$Key, [string]$PlainText, [byte[]]$Iv = $null) {
    if (-not $Iv) { $Iv = [StlGcm]::RandomBytes(12) }
    $ct = [StlGcm]::Encrypt($Key, $Iv, [System.Text.Encoding]::UTF8.GetBytes($PlainText))
    return ('{{"enc":"aes-256-gcm","iv":"{0}","data":"{1}"}}' -f (ConvertTo-StlB64 $Iv), (ConvertTo-StlB64 $ct))
}
# -> Klartext oder $null (kein Umschlag / falscher Schluessel / manipuliert)
function Open-StlEnvelope([byte[]]$Key, [string]$Text) {
    try {
        $o = $Text | ConvertFrom-Json
        if ([string](Get-StlProp $o 'enc') -ne 'aes-256-gcm') { return $null }
        $iv = [Convert]::FromBase64String([string]$o.iv)
        $data = [Convert]::FromBase64String([string]$o.data)
        if ($iv.Length -ne 12) { return $null }
        return [System.Text.Encoding]::UTF8.GetString([StlGcm]::Decrypt($Key, $iv, $data))
    } catch { return $null }
}

# ---------------------------------------------------------------- Konfiguration (relay.json)
function Read-StlRelayConfig {
    $c = Read-StlJson (Get-StlRelayPath)
    if (-not $c) { return $null }
    try {
        $key = [Convert]::FromBase64String([string]$c.key)
        if ($key.Length -ne 32) { return $null }
        $server = [string](Get-StlProp $c 'server'); if (-not $server) { $server = $script:StlRelayDefaultServer }
        $db = [string](Get-StlProp $c 'db_base');    if (-not $db) { $db = $script:StlRelayDefaultDb }
        foreach ($u in @($server, $db)) {
            if ($u -notmatch '^https://' -and -not ($env:STL_RELAY_ALLOW_HTTP -eq '1' -and $u -match '^http://')) { return $null }
        }
        return [pscustomobject]@{
            enabled = [bool](Get-StlProp $c 'enabled'); Key = $key; server = $server.TrimEnd('/'); db_base = $db.TrimEnd('/')
            Topic = (Get-StlRelayTopic $key); DbKey = (Get-StlRelayDbKey $key)
        }
    } catch { return $null }
}
function Save-StlRelayConfig([bool]$Enabled, [byte[]]$Key, [string]$Server = '', [string]$Db = '') {
    $o = [ordered]@{ version = 1; enabled = $Enabled; key = (ConvertTo-StlB64 $Key); created_utc = [DateTime]::UtcNow.ToString('o') }
    if ($Server) { $o['server'] = $Server }
    if ($Db) { $o['db_base'] = $Db }
    Write-StlJson (Get-StlRelayPath) ([pscustomobject]$o)
}
# Aktivieren (erzeugt beim ersten Mal einen frischen Schluessel). -> Kopplungscode
function Enable-StlRelay {
    $rc = Read-StlRelayConfig
    if ($rc) { $key = $rc.Key; $srv = $rc.server; $db = $rc.db_base } else { $key = New-StlRelayKeyBytes; $srv = ''; $db = '' }
    Save-StlRelayConfig $true $key $srv $db
    return (Get-StlPairingCode $key)
}
function Disable-StlRelay {
    $rc = Read-StlRelayConfig
    if ($rc) { Save-StlRelayConfig $false $rc.Key $rc.server $rc.db_base }
}
# Neuer Schluessel: das bisherige Handy verliert den Zugriff. -> neuer Kopplungscode
function Reset-StlRelayKey {
    $rc = Read-StlRelayConfig
    $en = if ($rc) { $rc.enabled } else { $false }
    $key = New-StlRelayKeyBytes
    Save-StlRelayConfig $en $key '' ''
    Remove-Item -LiteralPath (Get-StlRelayStatePath) -Force -ErrorAction SilentlyContinue
    return (Get-StlPairingCode $key)
}

# ---------------------------------------------------------------- HTTP (austauschbar fuer Tests)
# -> @{ Code = 200; Text = '...' }; bei Verbindungsfehlern wird eine Exception geworfen
function Invoke-StlHttp([string]$Method, [string]$Url, [hashtable]$Headers, [string]$Body) {
    try { [Net.ServicePointManager]::SecurityProtocol = ([Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12) } catch { }
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = $Method
    $req.Timeout = 8000; $req.ReadWriteTimeout = 8000
    $req.UserAgent = 'ScreenTimeLimiter/4'
    $req.AllowAutoRedirect = $false
    $req.Headers['Cache-Control'] = 'no-cache'
    if ($Headers) { foreach ($k in $Headers.Keys) { if ($k -eq 'Content-Type') { $req.ContentType = [string]$Headers[$k] } else { $req.Headers[[string]$k] = [string]$Headers[$k] } } }
    if ($null -ne $Body -and $Method -ne 'GET') {
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Body)
        $req.ContentLength = $bytes.Length
        $st = $req.GetRequestStream(); try { $st.Write($bytes, 0, $bytes.Length) } finally { $st.Dispose() }
    }
    $resp = $null
    try { $resp = $req.GetResponse() }
    catch [System.Net.WebException] { $resp = $_.Exception.Response; if (-not $resp) { throw } }
    try {
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
        try { $text = $sr.ReadToEnd() } finally { $sr.Dispose() }
        return @{ Code = [int]$resp.StatusCode; Text = $text }
    } finally { $resp.Dispose() }
}
$script:StlDefaultHttp = { param($m, $u, $h, $b) Invoke-StlHttp $m $u $h $b }

# ---------------------------------------------------------------- Zustand des Relays (relay_state.json)
function New-StlRelayState {
    return [pscustomobject]@{
        last_id = ''; processed = @(); fail_count = 0; lock_level = 0; locked_until = ''
        last_cmds = @(); last_pub = ''; last_plain = ''; backoff_until = ''; net_fails = 0
    }
}
function Read-StlRelayState {
    $s = Read-StlJson (Get-StlRelayStatePath)
    $n = New-StlRelayState
    if (-not $s) { return $n }
    foreach ($p in $n.PSObject.Properties) {
        $v = Get-StlProp $s $p.Name
        if ($null -ne $v) {
            if ($v -is [datetime]) { $v = $v.ToUniversalTime().ToString('o') }
            $n.($p.Name) = $v
        }
    }
    $n.processed = @($n.processed); $n.last_cmds = @($n.last_cmds)
    return $n
}
function Save-StlRelayState($RS) { try { Write-StlJson (Get-StlRelayStatePath) $RS } catch { Write-StlLog ('Relay-Zustand nicht speicherbar: ' + $_.Exception.Message) } }
function ConvertTo-StlUtc($Value) {
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    $s = [string]$Value
    if (-not $s) { return [DateTime]::MinValue }
    return [DateTime]::Parse($s, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
}
function Add-StlRelayResult($RS, [string]$Id, [bool]$Ok, [string]$Msg, [datetime]$UtcNow) {
    $e = [pscustomobject]@{ id = $Id; ok = $Ok; msg = $Msg; t = $UtcNow.ToString('o') }
    $RS.last_cmds = @((@($RS.last_cmds) + $e) | Select-Object -Last 8)
}

# ---------------------------------------------------------------- Befehle ausfuehren
# -> @{ Ok; Msg }. Alle Befehle ausser 'refresh' brauchen die PIN der Eltern (gleicher PBKDF2-Hash wie die Eltern-Zentrale).
function Invoke-StlRelayCommand($Config, $RS, $Cmd, [datetime]$UtcNow) {
    $action = [string](Get-StlProp $Cmd 'action')
    if ($script:StlRelayActions -notcontains $action) { return @{ Ok = $false; Msg = 'Unbekannter Befehl.' } }
    if ($action -eq 'refresh') { return @{ Ok = $true; Msg = 'Status aktualisiert.' } }

    # PIN-Sperre: 3 falsche Versuche -> 30 s (bei Wiederholung 2 Min., 10 Min., 1 Std.)
    if ($RS.locked_until) {
        $until = ConvertTo-StlUtc $RS.locked_until
        if ($UtcNow -lt $until) {
            return @{ Ok = $false; Msg = ('Zu viele falsche PINs - gesperrt, noch {0} s.' -f [int][Math]::Ceiling(($until - $UtcNow).TotalSeconds)) }
        }
    }
    $pin = Get-StlProp $Cmd 'pin'
    $pinOk = ($pin -is [string]) -and (Test-StlPinFormat $pin) -and (Test-StlPin $Config $pin)
    if (-not $pinOk) {
        $RS.fail_count = [int]$RS.fail_count + 1
        if ($RS.fail_count -ge 3) {
            $lv = [Math]::Min([int]$RS.lock_level, $script:StlRelayLockSeconds.Count - 1)
            $secs = $script:StlRelayLockSeconds[$lv]
            $RS.lock_level = [int]$RS.lock_level + 1
            $RS.fail_count = 0
            $RS.locked_until = $UtcNow.AddSeconds($secs).ToString('o')
            Write-StlLog ('Handy-Befehl: 3 falsche PINs - Sperre {0} s.' -f $secs)
            return @{ Ok = $false; Msg = ('Falsche PIN. Gesperrt für {0} s.' -f $secs) }
        }
        return @{ Ok = $false; Msg = ('Falsche PIN ({0} von 3).' -f [int]$RS.fail_count) }
    }
    $RS.fail_count = 0; $RS.lock_level = 0; $RS.locked_until = ''

    if ($action -eq 'set_plan') {
        $days = @(Get-StlProp $Cmd 'days')
        if ($days.Count -ne 7) { return @{ Ok = $false; Msg = 'Der Wochenplan braucht genau 7 Tage.' } }
        $rules = @()
        foreach ($d in $days) {
            $mode = [string](Get-StlProp $d 'mode')
            $lim = 0
            [void][int]::TryParse([string](Get-StlProp $d 'limit_minutes'), [ref]$lim)
            $winOn = ([string](Get-StlProp $d 'window_enabled') -eq 'True')
            $r = New-StlRuleFromParts $mode $lim $winOn ([string](Get-StlProp $d 'window_start')) ([string](Get-StlProp $d 'window_end'))
            $rules += $r
        }
        $err = Test-StlDays $rules
        if ($err) { return @{ Ok = $false; Msg = $err } }
        $fresh = Read-StlConfig
        if (-not $fresh) { return @{ Ok = $false; Msg = 'Konfiguration nicht lesbar.' } }
        Set-StlDays $fresh $rules
        $err = Save-StlConfig $fresh
        if ($err) { return @{ Ok = $false; Msg = $err } }
        Write-StlLog 'Wochenplan per Handy geaendert.'
        return @{ Ok = $true; Msg = 'Wochenplan gespeichert.' }
    }

    # Konto bestimmen (nur eingetragene Kind-Konten)
    $want = [string](Get-StlProp $Cmd 'user')
    $name = $null
    foreach ($raw in @($Config.users)) {
        $n = Get-StlShortName ([string]$raw)
        if (-not $want) { $name = $n; break }
        if ($n -ieq (Get-StlShortName $want)) { $name = $n; break }
    }
    if (-not $name) { return @{ Ok = $false; Msg = 'Konto unbekannt.' } }
    switch ($action) {
        'add_minutes' {
            $m = 0
            if (-not [int]::TryParse([string](Get-StlProp $Cmd 'minutes'), [ref]$m) -or $m -lt 1 -or $m -gt 720) { return @{ Ok = $false; Msg = 'Minuten müssen zwischen 1 und 720 liegen.' } }
            Send-StlCommand 'add_minutes' $name $m
            Write-StlLog ('Handy-Befehl: +{0} Min. fuer {1}' -f $m, $name)
            return @{ Ok = $true; Msg = ('+{0} Minuten für {1}.' -f $m, $name) }
        }
        'unlimited_today' { Send-StlCommand $action $name 0; Write-StlLog ('Handy-Befehl: heute unbegrenzt fuer ' + $name); return @{ Ok = $true; Msg = ('Heute unbegrenzt für {0}.' -f $name) } }
        'block_today'     { Send-StlCommand $action $name 0; Write-StlLog ('Handy-Befehl: heute gesperrt fuer ' + $name);   return @{ Ok = $true; Msg = ('Heute gesperrt für {0}.' -f $name) } }
        'clear_extras'    { Send-StlCommand $action $name 0; Write-StlLog ('Handy-Befehl: Freigaben aufgehoben fuer ' + $name); return @{ Ok = $true; Msg = ('Freigaben aufgehoben für {0}.' -f $name) } }
    }
    return @{ Ok = $false; Msg = 'Unbekannter Befehl.' }
}

# ---------------------------------------------------------------- Befehle abholen (vor Invoke-StlPendingCommands aufrufen)
# -> Anzahl neu verarbeiteter Befehle. Wirft nie (Netzfehler -> Backoff).
function Receive-StlRelayCommands($Relay, $RS, $Config, [datetime]$UtcNow, [scriptblock]$Http = $script:StlDefaultHttp) {
    if ($RS.backoff_until -and $UtcNow -lt (ConvertTo-StlUtc $RS.backoff_until)) { return 0 }
    $since = if ($RS.last_id) { [string]$RS.last_id } else { '10m' }
    $url = '{0}/{1}/json?poll=1&since={2}' -f $Relay.server, $Relay.Topic, $since
    $resp = $null
    try { $resp = & $Http 'GET' $url @{} $null } catch { Set-StlRelayBackoff $RS $UtcNow; return 0 }
    if ($resp.Code -ge 500 -or $resp.Code -eq 429) { Set-StlRelayBackoff $RS $UtcNow; return 0 }
    if ($resp.Code -ne 200) {
        if ($RS.last_id) { $RS.last_id = '' }   # z. B. ungueltiger Cursor -> naechstes Mal mit Zeitfenster
        Set-StlRelayBackoff $RS $UtcNow; return 0
    }
    $RS.net_fails = 0; $RS.backoff_until = ''
    $handled = 0
    foreach ($line in @(([string]$resp.Text) -split "`n")) {
        if (-not $line.Trim()) { continue }
        $m = $null
        try { $m = $line | ConvertFrom-Json } catch { continue }
        if ([string](Get-StlProp $m 'event') -ne 'message') { continue }
        $id = [string](Get-StlProp $m 'id'); if (-not $id) { continue }
        $RS.last_id = $id
        if (@(Get-StlProp $m 'tags') -notcontains $script:StlRelayTag) { continue }
        if (@($RS.processed) -contains $id) { continue }
        $RS.processed = @((@($RS.processed) + $id) | Select-Object -Last 200)
        $age = 0
        $tm = Get-StlProp $m 'time'
        if ($null -ne $tm) { $age = ($UtcNow - [DateTimeOffset]::FromUnixTimeSeconds([long]$tm).UtcDateTime).TotalSeconds }
        $plain = Open-StlEnvelope $Relay.Key ([string](Get-StlProp $m 'message'))
        if ($null -eq $plain) { Write-StlLog 'Relay: Nachricht nicht entschluesselbar - ignoriert.'; continue }
        $cmd = $null
        try { $cmd = $plain | ConvertFrom-Json } catch { continue }
        $cid = [string](Get-StlProp $cmd 'id')
        if ($cid -notmatch '^[A-Za-z0-9_-]{1,64}$') { $cid = $id }
        if (@($RS.processed) -contains ('c:' + $cid)) { continue }   # gleiche Befehls-ID zweimal -> nur einmal ausfuehren
        $RS.processed = @((@($RS.processed) + ('c:' + $cid)) | Select-Object -Last 200)
        if ($age -gt $script:StlRelayMaxAgeSeconds -or $age -lt -$script:StlRelayMaxAgeSeconds) {
            Add-StlRelayResult $RS $cid $false 'Zu alt - nicht ausgeführt (PC war aus oder offline).' $UtcNow
            $handled++; continue
        }
        $res = $null
        try { $res = Invoke-StlRelayCommand $Config $RS $cmd $UtcNow } catch { $res = @{ Ok = $false; Msg = 'Fehler beim Ausführen.' }; Write-StlLog ('Relay-Befehl Fehler: ' + $_.Exception.Message) }
        Add-StlRelayResult $RS $cid $res.Ok $res.Msg $UtcNow
        $handled++
    }
    if ($handled -gt 0) { $RS.last_pub = '' }   # sofort neuen Status veroeffentlichen
    return $handled
}
function Set-StlRelayBackoff($RS, [datetime]$UtcNow) {
    $RS.net_fails = [int]$RS.net_fails + 1
    $secs = [Math]::Min(300, 30 * [Math]::Pow(2, [Math]::Min([int]$RS.net_fails - 1, 4)))
    $RS.backoff_until = $UtcNow.AddSeconds($secs).ToString('o')
}

# ---------------------------------------------------------------- Status
# Sitzung des Kontos: active | locked | disconnected | none (nur das, was der Enforcer ohnehin abfragt)
function Get-StlSessionStatus($Sessions, [string]$Name) {
    $best = 'none'
    foreach ($s in @(@($Sessions) | Where-Object { $_ })) {
        if ((Get-StlShortName ([string]$s.User)) -ine $Name) { continue }
        if ([int]$s.State -eq 0 -and -not [bool]$s.Locked) { return 'active' }
        if ([int]$s.State -eq 0) { $best = 'locked' }
        elseif ($best -eq 'none') { $best = 'disconnected' }
    }
    return $best
}
function New-StlRelayStatus($Config, $State, $Sessions, $RS, [datetime]$UtcNow) {
    $local = Get-StlLocalNow $Config $UtcNow
    $idx = ([int]$local.DayOfWeek + 6) % 7
    $plan = @()
    for ($i = 0; $i -lt 7; $i++) {
        $r = Get-StlDayRule $Config $local.Date.AddDays($i - $idx)
        $plan += [ordered]@{ mode = [string]$r.mode; limit_minutes = [int]$r.limit_minutes; window_enabled = [bool]$r.window_enabled; window_start = [string]$r.window_start; window_end = [string]$r.window_end }
    }
    $users = @()
    foreach ($raw in @($Config.users)) {
        $name = Get-StlShortName ([string]$raw)
        $info = Get-StlTodayInfo $Config $State $name $UtcNow
        $rem = $null
        if (-not [double]::IsInfinity([double]$info.remaining)) { $rem = [int][Math]::Max(0, [Math]::Floor([double]$info.remaining)) }
        $users += [ordered]@{
            name = $name; session = (Get-StlSessionStatus $Sessions $name)
            used_seconds = [int][Math]::Floor([double]$info.used_seconds); remaining_seconds = $rem
            bonus_minutes = [int]$info.bonus_minutes; unlimited_today = [bool]$info.unlimited_today; blocked_today = [bool]$info.blocked_today
            rule = [string]$info.rule_text; lock_reason = $(if ($info.lock_reason) { [string]$info.lock_reason } else { $null })
        }
    }
    $cmds = @(); foreach ($c in @($RS.last_cmds)) { $cmds += [ordered]@{ id = [string]$c.id; ok = [bool]$c.ok; msg = [string]$c.msg; t = (ConvertTo-StlUtc $c.t).ToString('o') } }
    return [ordered]@{
        v = 1; t = $UtcNow.ToString('o'); day = $script:StlDayNames[$idx]; today_index = $idx
        users = $users; plan = $plan; last_cmds = $cmds
        locked_until = $(if ($RS.locked_until -and $UtcNow -lt (ConvertTo-StlUtc $RS.locked_until)) { (ConvertTo-StlUtc $RS.locked_until).ToString('o') } else { $null })
    }
}

# Status verschluesselt in den textdb-Schluessel schreiben (nach einem Befehl sofort). -> $true, wenn veroeffentlicht.
function Publish-StlRelayStatus($Relay, $RS, $Config, $State, $Sessions, [datetime]$UtcNow, [scriptblock]$Http = $script:StlDefaultHttp) {
    if ($RS.backoff_until -and $UtcNow -lt (ConvertTo-StlUtc $RS.backoff_until)) { return $false }
    $st = New-StlRelayStatus $Config $State $Sessions $RS $UtcNow
    # Vergleich ohne Zeitstempel: nur bei inhaltlicher Aenderung (und nach >= 30 s) neu schreiben, sonst Lebenszeichen alle 90 s
    $plainNoT = ConvertTo-Json -InputObject ([ordered]@{ u = $st.users; p = $st.plan; c = $st.last_cmds }) -Depth 8 -Compress
    $sinceLast = if ($RS.last_pub) { ($UtcNow - (ConvertTo-StlUtc $RS.last_pub)).TotalSeconds } else { [double]::MaxValue }
    $changed = ($plainNoT -ne [string]$RS.last_plain)
    if (-not $changed -and $sinceLast -lt 90) { return $false }
    if ($changed -and $sinceLast -lt 30) { return $false }
    $json = ConvertTo-Json -InputObject $st -Depth 8 -Compress
    $body = New-StlEnvelope $Relay.Key $json
    $url = '{0}/{1}' -f $Relay.db_base, $Relay.DbKey
    try { $resp = & $Http 'POST' $url @{ 'Content-Type' = 'text/plain' } $body }
    catch { Set-StlRelayBackoff $RS $UtcNow; return $false }
    if ($resp.Code -lt 200 -or $resp.Code -ge 300) { Set-StlRelayBackoff $RS $UtcNow; return $false }
    $RS.net_fails = 0; $RS.backoff_until = ''
    $RS.last_pub = $UtcNow.ToString('o'); $RS.last_plain = $plainNoT
    return $true
}
