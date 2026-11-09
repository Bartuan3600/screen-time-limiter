# Parent-Unlock.ps1 - Konsolen-Ausweichloesung zur Eltern-Zentrale (Eltern-Zentrale.ps1 hat die Oberflaeche): Zeit freigeben. Muss als Administrator laufen (UAC-Abfrage
# = Administrator-Passwort) UND verlangt zusaetzlich die Eltern-PIN.
# Schreibt nur einen kleinen Befehl in den Admin-Ordner; der Enforcer fuehrt ihn innerhalb von ~15 s aus.

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'StlCommon.ps1')

if (-not (Test-StlIsAdmin)) {
    # Selbst mit Administratorrechten neu starten -> Windows fragt nach dem Administrator-Passwort.
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $MyInvocation.MyCommand.Path))
    } catch {
        Write-Host 'Abgebrochen: Es wurde kein Administrator-Passwort bestaetigt.' -ForegroundColor Yellow
        Start-Sleep -Seconds 3
    }
    exit
}

function Read-PlainSecret([string]$Prompt) {
    $sec = Read-Host -Prompt $Prompt -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Send-Command([string]$Action, [string]$User, [int]$Minutes) { Send-StlCommand $Action $User $Minutes }

try {
    Write-Host ''
    Write-Host '=== Bildschirmzeit: Eltern-Freigabe ===' -ForegroundColor Cyan
    $config = Read-StlConfig
    if (-not $config) { throw 'Keine gueltige Einrichtung gefunden. Bitte zuerst Install-ScreenTimeLimiter.ps1 ausfuehren.' }

    $ok = $false
    for ($i = 1; $i -le 3; $i++) {
        $pin = Read-PlainSecret 'Eltern-PIN / Passwort'
        if (Test-StlPin $config $pin) { $ok = $true; break }
        Write-Host 'Falsche PIN / falsches Passwort.' -ForegroundColor Red
    }
    if (-not $ok) { throw 'Zu viele Fehlversuche. Abbruch.' }

    $users = @($config.users | ForEach-Object { Get-StlShortName ([string]$_) })
    $user = $users[0]
    if ($users.Count -gt 1) {
        for ($i = 0; $i -lt $users.Count; $i++) { Write-Host ('  [{0}] {1}' -f ($i + 1), $users[$i]) }
        $n = [int](Read-Host 'Fuer welches Konto?')
        if ($n -lt 1 -or $n -gt $users.Count) { throw 'Ungueltige Auswahl.' }
        $user = $users[$n - 1]
    }

    $utc = [DateTime]::UtcNow
    $local = Get-StlLocalNow $config $utc
    $state = Read-StlState $local.ToString('yyyy-MM-dd')
    $info = Get-StlTodayInfo $config $state $user $utc
    $restText = if ([double]::IsInfinity($info.remaining)) { 'unbegrenzt' } else { Format-StlSeconds $info.remaining }
    Write-Host ('Konto: {0}   Heute ({1}): {2}' -f $user, $info.day_name, $info.rule_text)
    Write-Host ('Heute genutzt: {0}   Rest: {1}' -f (Format-StlSeconds $info.used_seconds), $restText)

    while ($true) {
        Write-Host ''
        Write-Host '  [1] +15 Minuten freigeben'
        Write-Host '  [2] +30 Minuten freigeben'
        Write-Host '  [3] +60 Minuten freigeben'
        Write-Host '  [4] Andere Minutenzahl freigeben'
        Write-Host '  [5] Heute keine Begrenzung (Limit und Zeitfenster bis Mitternacht aus)'
        Write-Host '  [6] Freigaben von heute wieder aufheben'
        Write-Host '  [7] Heutige Nutzungszeit auf 0 setzen'
        Write-Host '  [8] Heute sperren (Rest des Tages kein Spielen)'
        Write-Host '  [0] Beenden'
        $c = Read-Host 'Auswahl'
        $done = $true
        switch ($c) {
            '1' { Send-Command 'add_minutes' $user 15 }
            '2' { Send-Command 'add_minutes' $user 30 }
            '3' { Send-Command 'add_minutes' $user 60 }
            '4' {
                $m = 0
                if ([int]::TryParse((Read-Host 'Minuten (1-720)'), [ref]$m) -and $m -ge 1 -and $m -le 720) { Send-Command 'add_minutes' $user $m }
                else { Write-Host 'Ungueltig.' -ForegroundColor Red; $done = $false }
            }
            '5' { Send-Command 'unlimited_today' $user 0 }
            '6' { Send-Command 'clear_extras' $user 0 }
            '7' { Send-Command 'reset_used' $user 0 }
            '8' { Send-Command 'block_today' $user 0 }
            '0' { break }
            default { Write-Host 'Ungueltig.' -ForegroundColor Red; $done = $false }
        }
        if ($c -eq '0') { break }
        if ($done) {
            Write-Host 'Gesendet. Wirksam innerhalb von ca. 15 Sekunden (Enforcer laeuft als Aufgabe).' -ForegroundColor Green
        }
    }
} catch {
    Write-Host ('Fehler: ' + $_.Exception.Message) -ForegroundColor Red
    Read-Host 'Enter zum Schliessen'
}
