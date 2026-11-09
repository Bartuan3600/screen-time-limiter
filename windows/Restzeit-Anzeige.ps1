<#
.SYNOPSIS
  Restzeit-Anzeige fuer das Kind: zeigt NUR die verbleibende Zeit und den Wochenplan (lesen, nichts aendern).
.DESCRIPTION
  Liest %ProgramData%\ScreenTimeLimiter\public\status.json (vom Waechter-Dienst geschrieben).
  Kann nichts sperren, entsperren oder aendern, darf jederzeit geschlossen werden (die Sperre laeuft
  unabhaengig davon) und sendet/ueberwacht nichts.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'StlCommon.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# nur eine Anzeige pro Benutzer-Sitzung
$createdNew = $false
$script:Mutex = New-Object System.Threading.Mutex($true, 'Local\ScreenTimeLimiterViewer', [ref]$createdNew)
if (-not $createdNew) { exit }

$script:User = $env:USERNAME

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Bildschirmzeit'
$form.StartPosition = 'Manual'
$form.FormBorderStyle = 'FixedToolWindow'
$form.TopMost = $true
$form.ClientSize = New-Object System.Drawing.Size(300, 330)
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Location = New-Object System.Drawing.Point(($wa.Right - 320), ($wa.Bottom - 350))
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$lblBig = New-Object System.Windows.Forms.Label
$lblBig.Location = New-Object System.Drawing.Point(10, 8); $lblBig.Size = New-Object System.Drawing.Size(280, 52)
$lblBig.Font = New-Object System.Drawing.Font('Segoe UI', 28, [System.Drawing.FontStyle]::Bold)
$lblBig.TextAlign = 'MiddleCenter'
$lblBig.Text = '--:--:--'

$lblSmall = New-Object System.Windows.Forms.Label
$lblSmall.Location = New-Object System.Drawing.Point(10, 64); $lblSmall.Size = New-Object System.Drawing.Size(280, 66)
$lblSmall.TextAlign = 'TopCenter'

$lblWeek = New-Object System.Windows.Forms.Label
$lblWeek.Location = New-Object System.Drawing.Point(10, 134); $lblWeek.Size = New-Object System.Drawing.Size(280, 18)
$lblWeek.Text = 'Meine Woche:'
$lblWeek.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

$lst = New-Object System.Windows.Forms.ListBox
$lst.Location = New-Object System.Drawing.Point(10, 154); $lst.Size = New-Object System.Drawing.Size(280, 140)
$lst.IntegralHeight = $false
$lst.TabStop = $false

$btnClose = New-Object System.Windows.Forms.Button
$btnClose.Text = 'Schließen'
$btnClose.Location = New-Object System.Drawing.Point(200, 298); $btnClose.Size = New-Object System.Drawing.Size(90, 26)
$btnClose.Add_Click({ $form.Close() })

$form.Controls.AddRange(@($lblBig, $lblSmall, $lblWeek, $lst, $btnClose))

function Update-View {
    try {
        $m = Get-StlViewerModel (Read-StlJson (Get-StlStatusPath)) $script:User ([DateTime]::UtcNow)
        $lblBig.Text = $m.Big
        $lblSmall.Text = $m.Small
        if ($m.Big -match '^0:00:00$') { $lblBig.ForeColor = [System.Drawing.Color]::Firebrick }
        else { $lblBig.ForeColor = [System.Drawing.Color]::Black }
        $lines = @($m.Week)
        $same = ($lst.Items.Count -eq $lines.Count)
        if ($same) { for ($i = 0; $i -lt $lines.Count; $i++) { if ([string]$lst.Items[$i] -ne $lines[$i]) { $same = $false; break } } }
        if (-not $same) {
            $lst.Items.Clear()
            foreach ($l in $lines) { [void]$lst.Items.Add($l) }
        }
        if ($m.TodayIndex -ge 0 -and $m.TodayIndex -lt $lst.Items.Count) { $lst.SelectedIndex = $m.TodayIndex }
        $lblWeek.Visible = ($lines.Count -gt 0); $lst.Visible = ($lines.Count -gt 0)
    } catch { $lblSmall.Text = 'Anzeige-Fehler: ' + $_.Exception.Message }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$timer.Add_Tick({ Update-View })
Update-View
$timer.Start()
[void]$form.ShowDialog()
$timer.Stop()
