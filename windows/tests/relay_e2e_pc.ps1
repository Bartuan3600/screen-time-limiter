# Test-Treiber fuer relay_e2e.py: laeuft wie ein Enforcer-Zyklus (ohne Windows-Sitzungen) gegen den ECHTEN HTTP-Code (Invoke-StlHttp).
param([ValidateSet('setup', 'loop')][string]$Mode, [string]$Server, [string]$Db, [int]$Seconds = 15)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'StlCommon.ps1'); . (Join-Path $root 'StlEnforce.ps1'); . (Join-Path $root 'StlRelay.ps1')
$env:STL_RELAY_ALLOW_HTTP = '1'
if ($Mode -eq 'setup') {
    $cfg = New-StlConfig; $cfg.users = @('Max'); $cfg.timezone = 'UTC'; $cfg.daily_limit_minutes = 90
    Set-StlDays $cfg (Get-StlPreset 'gleich' 90)
    Set-StlPin $cfg '1234'
    Write-StlJson (Get-StlConfigPath) $cfg
    New-Item -ItemType Directory -Path (Get-StlCommandDir) -Force | Out-Null
    $key = New-StlRelayKeyBytes
    Save-StlRelayConfig $true $key $Server $Db
    Write-Output (Get-StlPairingCode $key)
    return
}
$pending = @{}; $rs = Read-StlRelayState
$end = [DateTime]::UtcNow.AddSeconds($Seconds)
while ([DateTime]::UtcNow -lt $end) {
    $utc = [DateTime]::UtcNow
    $config = Read-StlConfig
    $relay = Read-StlRelayConfig
    $today = (Get-StlLocalNow $config $utc).ToString('yyyy-MM-dd')
    $state = Read-StlState $today
    [void](Update-StlRollOver $state $today)
    $got = Receive-StlRelayCommands $relay $rs $config $utc
    if ($got -gt 0) { $config = Read-StlConfig }
    Invoke-StlPendingCommands $state
    [void](Invoke-StlEnforceCycle -Config $config -State $state -Sessions @() -UtcNow $utc -Delta 0 -Pending $pending -SendMessage { } -Logoff { })
    Write-StlJson (Get-StlStatePath) $state
    [void](Publish-StlRelayStatus $relay $rs $config $state @() $utc)
    Save-StlRelayState $rs
    Start-Sleep -Milliseconds 400
}
