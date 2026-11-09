<#
.SYNOPSIS
  Entfernt den Bildschirmzeit-Limiter vollstaendig (nur als Administrator, mit Eltern-PIN / Passwort).
#>
[CmdletBinding()]
param([switch]$Relaunched, [string]$OriginalDir)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'StlCommon.ps1')

function Fail([string]$m) { Write-Host ("`nABBRUCH: " + $m) -ForegroundColor Red; Read-Host 'Enter zum Schliessen'; exit 1 }

try {
    if (-not (Test-StlIsAdmin)) { Fail 'Bitte als Administrator ausfuehren.' }
    $installDir = Get-StlInstallDir
    $dataDir = Get-StlDataDir

    # Laeuft das Skript selbst aus dem Installationsordner, in eine temporaere Kopie wechseln (sonst loescht es sich selbst).
    if (-not $Relaunched -and ($here.TrimEnd('\') -ieq $installDir.TrimEnd('\'))) {
        $tmp = Join-Path $env:TEMP ('stl-uninstall-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp | Out-Null
        Copy-Item -LiteralPath (Join-Path $here 'StlCommon.ps1'), $MyInvocation.MyCommand.Path -Destination $tmp
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tmp 'Uninstall-ScreenTimeLimiter.ps1') -Relaunched
        exit
    }

    Write-Host ''
    Write-Host '=== Bildschirmzeit-Limiter: Deinstallation ===' -ForegroundColor Cyan
    $cfg = Read-StlConfig
    if ($cfg) {
        $ok = $false
        for ($i = 1; $i -le 3; $i++) {
            $sec = Read-Host -Prompt 'Eltern-PIN / Passwort' -AsSecureString
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
            try { $pin = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
            if (Test-StlPin $cfg $pin) { $ok = $true; break }
            Write-Host 'Falsche PIN / falsches Passwort.' -ForegroundColor Red
        }
        if (-not $ok) { Fail 'PIN / Passwort falsch. Vergessen? Install-ScreenTimeLimiter.ps1 erneut als Administrator ausfuehren (setzt eine neue PIN / ein neues Passwort), dann deinstallieren.' }
    } else {
        Write-Host 'Keine gueltige Einrichtung gefunden - es wird trotzdem aufgeraeumt.' -ForegroundColor Yellow
    }

    if ((Read-Host 'Wirklich deinstallieren? Das Kind ist danach NICHT mehr begrenzt (j/n)').ToLower() -notin @('j', 'ja', 'y', 'yes')) {
        Write-Host 'Abgebrochen.'; exit 0
    }

    if (Get-ScheduledTask -TaskName $script:StlTaskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $script:StlTaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $script:StlTaskName -Confirm:$false
        Write-Host 'Geplante Aufgabe entfernt.'
    }
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*ScreenTimeLimiter*Enforcer.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 1

    Remove-ItemProperty -Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'ScreenTimeLimiterViewer' -ErrorAction SilentlyContinue
    foreach ($l in @('Eltern - Bildschirmzeit freigeben.lnk', 'Eltern - Bildschirmzeit.lnk')) {
        Remove-Item -LiteralPath (Join-Path $env:ProgramData ('Microsoft\Windows\Start Menu\Programs\' + $l)) -Force -ErrorAction SilentlyContinue
    }
    # laufende Restzeit-Anzeigen/Eltern-Zentrale beenden (sonst blockieren sie das Loeschen)
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*ScreenTimeLimiter*Restzeit-Anzeige.ps1*' -or $_.CommandLine -like '*ScreenTimeLimiter*Eltern-Zentrale.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

    # Handy-App-Relay: Schluessel und Zustand liegen im Datenordner und werden mit ihm geloescht (relay.json, relay_state.json).
    # Hinweis: Die zuletzt veroeffentlichte (verschluesselte) Status-Nachricht auf dem Relay-Server laesst sich ohne Schluessel nicht lesen.
    if (Test-Path -LiteralPath (Join-Path $dataDir 'relay.json')) { Write-Host 'Handy-App-Kopplung wird entfernt (die App verliert den Zugriff).' }

    foreach ($d in @($installDir, $dataDir)) {
        if (Test-Path -LiteralPath $d) {
            & icacls.exe $d /grant '*S-1-5-32-544:(OI)(CI)F' /T /C /Q | Out-Null   # Admins duerfen sicher loeschen
            Remove-Item -LiteralPath $d -Recurse -Force
            Write-Host ('Geloescht: ' + $d)
        }
    }
    Write-Host 'Fertig. Der Bildschirmzeit-Limiter ist entfernt.' -ForegroundColor Green
    Read-Host 'Enter zum Schliessen'
} catch {
    Fail $_.Exception.Message
}
