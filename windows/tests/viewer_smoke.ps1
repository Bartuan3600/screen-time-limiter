# Rauchtest der Restzeit-Anzeige mit WinForms-Attrappen (siehe gui_stub.cs). Prueft den Ablauf, nicht echtes WinForms.
$ErrorActionPreference = 'Stop'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('stl-view-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$env:STL_DATA_DIR = $tmp
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'StlCommon.ps1')
. (Join-Path $root 'StlEnforce.ps1')
Add-Type -TypeDefinition (Get-Content (Join-Path $PSScriptRoot 'gui_stub.cs') -Raw)
$script:fail = 0; $script:n = 0
function Check($cond, [string]$name) { $script:n++; if (-not $cond) { $script:fail++; Write-Host "FAIL: $name" -ForegroundColor Red } }

$cfg = New-StlConfig; $cfg.users = @('Max'); $cfg.timezone = 'UTC'; Set-StlPin $cfg '1234'; Set-StlDays $cfg (Get-StlPreset 'schule')
$utc = [DateTime]::UtcNow
$st = New-StlState ($utc.ToString('yyyy-MM-dd'))
New-Item -ItemType Directory -Path (Get-StlPublicDir) -Force | Out-Null
Write-StlJson (Get-StlStatusPath) (New-StlStatus $cfg $st $utc)
$env:USERNAME = 'Max'

$src = Get-Content (Join-Path $root 'Restzeit-Anzeige.ps1') -Raw -Encoding UTF8
$src = $src -replace '(?m)^Add-Type -AssemblyName .*$', ''
$src = $src.Replace('System.Drawing.', 'StubDrawing.')
Copy-Item (Join-Path $root 'StlCommon.ps1') (Join-Path $tmp 'StlCommon.ps1')
$copy = Join-Path $tmp 'Restzeit-Anzeige.ps1'
[IO.File]::WriteAllText($copy, $src, (New-Object Text.UTF8Encoding($true)))

[System.Windows.Forms.Stub]::OnMainForm = [Action[System.Windows.Forms.Form]]{
    param($f)
    Check ($lblBig.Text -ne '--:--:--') ('Restzeit angezeigt: ' + $lblBig.Text)
    Check ($lblSmall.Text -notlike 'Anzeige-Fehler*') ('kein Anzeigefehler: ' + $lblSmall.Text)
    Check ($lst.Items.Count -eq 7) 'Wochenliste hat 7 Zeilen'
    Check ($lst.SelectedIndex -eq ((([int]$utc.DayOfWeek) + 6) % 7)) 'heute markiert'
    $lblBig.Text = 'x'; foreach ($h in $timer.Handlers['Tick']) { & $h $timer $null }
    Check ($lblBig.Text -ne 'x') 'Timer aktualisiert'
    Remove-Item (Get-StlStatusPath) -Force
    foreach ($h in $timer.Handlers['Tick']) { & $h $timer $null }
    Check ($lblSmall.Text -like 'Kein Status*') 'ohne Status: Hinweis statt Absturz'
}
try { . $copy } catch { $script:fail++; Write-Host ('FAIL: Anzeige warf: ' + $_.Exception.Message + "`n" + $_.ScriptStackTrace) -ForegroundColor Red }
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
if ($script:n -lt 5) { $script:fail++; Write-Host 'FAIL: Hook lief nicht' -ForegroundColor Red }
if ($script:fail -eq 0) { Write-Host "viewer_smoke: $($script:n) Pruefungen OK" } else { Write-Host "viewer_smoke: $($script:fail) FEHLER"; exit 1 }
