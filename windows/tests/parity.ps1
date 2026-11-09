# Liest eine JSON-Fallliste, berechnet mit der PowerShell-Logik und schreibt das Ergebnis als JSON.
param([Parameter(Mandatory)][string]$InFile, [Parameter(Mandatory)][string]$OutFile)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\StlCommon.ps1')
$in = Get-Content -Raw -Encoding UTF8 $InFile | ConvertFrom-Json
$out = @()
foreach ($c in @($in.window_cases)) {
    $cfg = [pscustomobject]@{ window_enabled = [bool]$c.window_enabled; window_start = $c.start; window_end = $c.end
        daily_limit_minutes = [int]$c.limit }
    if ($c.PSObject.Properties['days'] -and $null -ne $c.days) { Add-Member -InputObject $cfg -NotePropertyName days -NotePropertyValue @($c.days) }
    $entry = [pscustomobject]@{ window_override = [bool]$c.override; unlimited_today = [bool]$c.unlimited
        blocked_today = [bool]$c.blocked; bonus_minutes = [int]$c.bonus; used_seconds = [double]$c.used }
    # PowerShell 7 wandelt ISO-Strings beim JSON-Lesen selbst in DateTime um
    if ($c.now -is [datetime]) { $now = $c.now } else { $now = [datetime]::ParseExact($c.now, 'yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) }
    $rem = Get-StlRemainingSeconds $cfg $entry $now
    $toEnd = Get-StlSecondsToWindowEnd $cfg $entry $now
    $left = Get-StlSecondsLeft $cfg $entry $now
    $out += [pscustomobject]@{
        in_window = (Test-StlInWindow $cfg $entry $now)
        remaining = $(if ([double]::IsInfinity($rem)) { $null } else { $rem })
        allowed   = (Get-StlAllowedSeconds $cfg $entry $now)
        to_end    = $(if ([double]::IsInfinity($toEnd)) { $null } else { $toEnd })
        left      = $(if ([double]::IsInfinity($left)) { $null } else { $left })
        reason    = (Get-StlLockReason $cfg $entry $now)
    }
}
$pins = @()
foreach ($p in @($in.pin_cases)) { $pins += (Get-StlPinHash ([string]$p.pin) ([string]$p.salt)) }
$res = [pscustomobject]@{ window_results = $out; pin_hashes = $pins }
[System.IO.File]::WriteAllText($OutFile, (ConvertTo-Json -InputObject $res -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
