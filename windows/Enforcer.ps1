# Enforcer.ps1 - laeuft als SYSTEM (Geplante Aufgabe), unabhaengig vom Kind-Konto.
# Alle ~15 s: Kind-Sitzung pruefen, aktive Zeit zaehlen, bei Limit/Wochenplan/ausserhalb des Fensters warnen und abmelden.
# Die config.json (Wochenplan) wird in JEDEM Zyklus neu gelesen: Aenderungen der Eltern gelten nach spaetestens ~15 s.
# Es wird NICHTS mitgelesen oder aufgezeichnet. Nur Sitzungsstatus (aktiv/gesperrt/getrennt).
# Optional (standardmaessig AUS): Handy-App-Relay (StlRelay.ps1). Nur wenn die Eltern es in der Eltern-Zentrale aktivieren,
# wird der Limiter-Status verschluesselt veroeffentlicht und es werden verschluesselte, PIN-geschuetzte Befehle abgeholt.

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'StlCommon.ps1')
. (Join-Path $here 'StlEnforce.ps1')
$relayFile = Join-Path $here 'StlRelay.ps1'
$relayLoaded = $false
try { if (Test-Path -LiteralPath $relayFile) { . $relayFile; $relayLoaded = $true } } catch { $relayLoaded = $false }

$IntervalSeconds = 15
$MaxDelta = 30.0   # laengere Luecken (Ruhezustand, Haenger) werden nicht mitgezaehlt

if (-not ('StlWts' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class StlSession {
    public int Id;
    public int State;     // 0 = Active, 1 = Connected, 4 = Disconnected, ...
    public string User;
    public bool Locked;
}

public static class StlWts {
    [StructLayout(LayoutKind.Sequential)]
    private struct WTS_SESSION_INFO {
        public int SessionId;
        public IntPtr pWinStationName;
        public int State;
    }

    [DllImport("wtsapi32.dll", EntryPoint = "WTSEnumerateSessionsW", SetLastError = true)]
    private static extern bool WTSEnumerateSessions(IntPtr hServer, int Reserved, int Version, out IntPtr ppSessionInfo, out int pCount);

    [DllImport("wtsapi32.dll")]
    private static extern void WTSFreeMemory(IntPtr pMemory);

    [DllImport("wtsapi32.dll", EntryPoint = "WTSQuerySessionInformationW", SetLastError = true)]
    private static extern bool WTSQuerySessionInformation(IntPtr hServer, int sessionId, int infoClass, out IntPtr ppBuffer, out int bytesReturned);

    [DllImport("wtsapi32.dll", EntryPoint = "WTSSendMessageW", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool WTSSendMessage(IntPtr hServer, int sessionId, string title, int titleLength,
        string message, int messageLength, int style, int timeout, out int response, bool wait);

    [DllImport("wtsapi32.dll", SetLastError = true)]
    private static extern bool WTSLogoffSession(IntPtr hServer, int sessionId, bool wait);

    private const int WTSUserName = 5;
    private const int WTSSessionInfoEx = 25;

    private static string QueryString(int id, int infoClass) {
        IntPtr buf; int bytes;
        if (!WTSQuerySessionInformation(IntPtr.Zero, id, infoClass, out buf, out bytes)) { return ""; }
        try { return Marshal.PtrToStringUni(buf) ?? ""; } finally { WTSFreeMemory(buf); }
    }

    // WTSINFOEX: Level (4 Byte) + Padding, dann Level1: SessionId @8, SessionState @12, SessionFlags @16.
    // SessionFlags: 0 = WTS_SESSIONSTATE_LOCK, 1 = UNLOCK (Windows 8/10/11).
    private static bool QueryLocked(int id) {
        IntPtr buf; int bytes;
        if (!WTSQuerySessionInformation(IntPtr.Zero, id, WTSSessionInfoEx, out buf, out bytes)) { return false; }
        try {
            if (bytes < 20) { return false; }
            int flags = Marshal.ReadInt32(buf, 16);
            return flags == 0;
        } finally { WTSFreeMemory(buf); }
    }

    public static List<StlSession> GetSessions() {
        List<StlSession> result = new List<StlSession>();
        IntPtr p; int count;
        if (!WTSEnumerateSessions(IntPtr.Zero, 0, 1, out p, out count)) { return result; }
        try {
            int size = Marshal.SizeOf(typeof(WTS_SESSION_INFO));
            for (int i = 0; i < count; i++) {
                WTS_SESSION_INFO info = (WTS_SESSION_INFO)Marshal.PtrToStructure(
                    new IntPtr(p.ToInt64() + (long)i * size), typeof(WTS_SESSION_INFO));
                string user = QueryString(info.SessionId, WTSUserName);
                if (user.Length == 0) { continue; }   // Dienste-Sitzung 0, Listener usw.
                StlSession s = new StlSession();
                s.Id = info.SessionId;
                s.State = info.State;
                s.User = user;
                s.Locked = (info.State == 0) && QueryLocked(info.SessionId);
                result.Add(s);
            }
        } finally { WTSFreeMemory(p); }
        return result;
    }

    public static bool Send(int sessionId, string title, string message, int timeoutSeconds) {
        int response;
        return WTSSendMessage(IntPtr.Zero, sessionId, title, title.Length * 2, message, message.Length * 2,
            0x30 /* MB_OK | MB_ICONWARNING */, timeoutSeconds, out response, false);
    }

    public static bool Logoff(int sessionId) {
        return WTSLogoffSession(IntPtr.Zero, sessionId, false);
    }
}
'@
}

$sendMessage = {
    param($sessionId, $text, $timeout)
    [void][StlWts]::Send([int]$sessionId, 'Bildschirmzeit', [string]$text, [int]$timeout)
}
$logoff = {
    param($sessionId)
    [void][StlWts]::Logoff([int]$sessionId)
}

# Einzelinstanz per Sperrdatei im Admin-Ordner (ein Kind kann keine Sperre dort anlegen;
# ein benannter Mutex waere von Standardbenutzern "besetzbar").
$dataDir = Get-StlDataDir
New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
try {
    $lockStream = [System.IO.File]::Open((Join-Path $dataDir 'enforcer.lock'),
        [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
} catch {
    exit 0   # laeuft schon
}

Write-StlLog 'Enforcer gestartet.'
$pending = @{}
$last = [System.Diagnostics.Stopwatch]::GetTimestamp()
$freq = [double][System.Diagnostics.Stopwatch]::Frequency
$configWarned = $false
$relayState = $null
$relayStateJson = ''
$relayFp = ''

while ($true) {
    try {
        $now = [System.Diagnostics.Stopwatch]::GetTimestamp()
        $delta = [Math]::Min(([double]($now - $last)) / $freq, $MaxDelta)
        $last = $now
        $utc = [DateTime]::UtcNow

        $config = Read-StlConfig
        if (-not $config) {
            if (-not $configWarned) { Write-StlLog ('Keine gueltige config.json (' + $script:StlConfigError + ') - es wird nichts erzwungen.'); $configWarned = $true }
        } else {
            $configWarned = $false
            $localToday = (Get-StlLocalNow $config $utc).ToString('yyyy-MM-dd')
            $state = Read-StlState $localToday
            [void](Update-StlRollOver $state $localToday)   # erst Tageswechsel, dann Befehle (sonst ginge ein Befehl um Mitternacht verloren)
            # Handy-Relay (optional): neue Befehle abholen, VOR den lokalen Befehlsdateien (best effort, blockiert nie die Durchsetzung)
            $relay = $null
            if ($relayLoaded) {
                try {
                    $relay = Read-StlRelayConfig
                    if ($relay -and -not $relay.enabled) { $relay = $null }
                    if ($relay) {
                        $fp = Get-StlRelayFingerprint $relay.Key
                        if ($fp -ne $relayFp) { $relayFp = $fp; $relayState = $null }   # neuer Schluessel (Neu koppeln) -> Zustand neu laden
                        if (-not $relayState) { $relayState = Read-StlRelayState; $relayStateJson = ConvertTo-Json -InputObject $relayState -Depth 6 -Compress }
                        $got = Receive-StlRelayCommands $relay $relayState $config $utc
                        if ($got -gt 0) { $c2 = Read-StlConfig; if ($c2) { $config = $c2 } }
                    }
                } catch { Write-StlLog ('Relay (Empfang): ' + $_.Exception.Message) }
            }
            Invoke-StlPendingCommands $state
            $sessions = @([StlWts]::GetSessions())
            [void](Invoke-StlEnforceCycle -Config $config -State $state -Sessions $sessions -UtcNow $utc `
                -Delta $delta -Pending $pending -SendMessage $sendMessage -Logoff $logoff)
            Write-StlJson (Get-StlStatePath) $state
            Write-StlJson (Get-StlStatusPath) (New-StlStatus $config $state $utc)
            if ($relay -and $relayState) {
                try {
                    [void](Publish-StlRelayStatus $relay $relayState $config $state $sessions $utc)
                    $rj = ConvertTo-Json -InputObject $relayState -Depth 6 -Compress
                    if ($rj -ne $relayStateJson) { Save-StlRelayState $relayState; $relayStateJson = $rj }
                } catch { Write-StlLog ('Relay (Status): ' + $_.Exception.Message) }
            }
        }
    } catch {
        Write-StlLog ('Fehler im Zyklus: ' + $_.Exception.Message)
    }
    Start-Sleep -Seconds $IntervalSeconds
}
