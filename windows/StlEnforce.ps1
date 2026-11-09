# StlEnforce.ps1 - Durchsetzungs-Logik eines Zyklus (ohne Windows-APIs, damit testbar).
# Die Windows-Teile (Sitzungen abfragen, Meldung senden, abmelden) werden von Enforcer.ps1 eingesteckt.
# Es wird NUR gezaehlt, ob das Kind-Konto aktiv angemeldet und nicht gesperrt ist. Nichts sonst.

Set-StrictMode -Version 2.0

# Sitzungsobjekte: .Id (int) .State (int, 0 = Active, 4 = Disconnected) .User (string) .Locked (bool)
function Invoke-StlEnforceCycle {
    param(
        $Config, $State, $Sessions,
        [datetime]$UtcNow,
        [double]$Delta,          # monotone Sekunden seit dem letzten Zyklus (schon begrenzt)
        [hashtable]$Pending,     # SessionId -> Zeitpunkt der Abmeldung
        [scriptblock]$SendMessage,   # { param($sessionId, $text, $timeoutSeconds) }
        [scriptblock]$Logoff         # { param($sessionId) }
    )
    $Sessions = @(@($Sessions) | Where-Object { $_ })
    $local = Get-StlLocalNow $Config $UtcNow
    $rolled = Update-StlRollOver $State $local.ToString('yyyy-MM-dd')
    if ($rolled) { $Pending.Clear() }

    # Pending-Eintraege fuer verschwundene Sitzungen entfernen
    $liveIds = @{}
    foreach ($s in $Sessions) { $liveIds[[string]$s.Id] = $true }
    foreach ($k in @($Pending.Keys)) { if (-not $liveIds.ContainsKey($k)) { $Pending.Remove($k) } }

    foreach ($raw in @($Config.users)) {
        $name  = Get-StlShortName ([string]$raw)
        $entry = Get-StlEntry $State $name
        $mine  = @($Sessions | Where-Object { (Get-StlShortName ([string]$_.User)) -ieq $name })
        $active = @($mine | Where-Object { $_.State -eq 0 -and -not $_.Locked })

        $reason = Get-StlLockReason $Config $entry $local
        if (-not $reason -and $active.Count -gt 0 -and $Delta -gt 0) {
            $entry.used_seconds = [double]$entry.used_seconds + $Delta
            $reason = Get-StlLockReason $Config $entry $local
        }

        if (-not $reason) {
            foreach ($s in $mine) { $Pending.Remove([string]$s.Id) }
            if ($active.Count -gt 0) {
                $left = Get-StlSecondsLeft $Config $entry $local
                $text = $null
                if ($left -le 60 -and -not $entry.warned1) {
                    $entry.warned1 = $true; $entry.warned5 = $true
                    $text = 'Noch etwa 1 Minute Bildschirmzeit. Bitte speichere jetzt deine Arbeit.'
                } elseif ($left -le 300 -and -not $entry.warned5) {
                    $entry.warned5 = $true
                    $text = 'Noch etwa 5 Minuten Bildschirmzeit.'
                }
                if ($text) {
                    foreach ($s in $active) { & $SendMessage $s.Id $text 30 }
                }
            }
            continue
        }

        # Zeit ist um (oder ausserhalb des Fensters): aktive/getrennte Sitzungen abmelden
        foreach ($s in @($mine | Where-Object { $_.State -eq 0 -or $_.State -eq 4 })) {
            $key = [string]$s.Id
            if (-not $Pending.ContainsKey($key)) {
                $grace = [int]$Config.grace_seconds
                if ($entry.limit_hit) { $grace = [int]$Config.regrace_seconds }
                if ($s.State -eq 4) { $grace = 0 }   # getrennte Sitzung: kein Bildschirm, keine Warnung noetig
                $Pending[$key] = $UtcNow.AddSeconds($grace)
                $entry.limit_hit = $true
                if ($s.State -eq 0) {
                    $msg = ('{0} Du wirst in {1} Sekunden abgemeldet. Bitte speichere jetzt deine Arbeit.' -f $reason, $grace)
                    & $SendMessage $s.Id $msg ([Math]::Max($grace, 5))
                }
            }
            if ($UtcNow -ge $Pending[$key]) {
                & $Logoff $s.Id
                $Pending.Remove($key)
                Write-StlLog ('Abmeldung Sitzung {0} (Konto {1}): {2}' -f $s.Id, $name, $reason)
            }
        }
    }
    return $local
}

# Kleine Status-Datei NUR fuer die Restzeit-Anzeige (fuer Benutzer lesbar): Restzeit + Regeln der Woche.
function New-StlStatus($Config, $State, [datetime]$UtcNow) {
    $local = Get-StlLocalNow $Config $UtcNow
    $idx = ([int]$local.DayOfWeek + 6) % 7
    $week = @()
    for ($i = 0; $i -lt 7; $i++) {
        $r = Get-StlDayRule $Config $local.Date.AddDays($i - $idx)
        $week += [pscustomobject]@{ day = $script:StlDayShort[$i]; text = (Format-StlRule $r) }
    }
    $list = @()
    foreach ($raw in @($Config.users)) {
        $name  = Get-StlShortName ([string]$raw)
        $entry = Get-StlEntry $State $name
        $rule  = Get-StlDayRule $Config $local
        $rem = Get-StlRemainingSeconds $Config $entry $local
        $remOut = $null
        if (-not [double]::IsInfinity($rem)) { $remOut = [int][Math]::Floor($rem) }
        $win = ''
        if ($rule.window_enabled -and [string]$rule.mode -ne 'blocked' -and -not $entry.window_override -and -not $entry.unlimited_today -and -not $entry.blocked_today) {
            $win = ('{0}–{1}' -f $rule.window_start, $rule.window_end)
        }
        $lim = $null
        if (-not $entry.unlimited_today -and [string]$rule.mode -ne 'unlimited') {
            $base = if ([string]$rule.mode -eq 'blocked') { 0 } else { [int]$rule.limit_minutes }
            $lim = $base + [int]$entry.bonus_minutes
        }
        $list += [pscustomobject]@{
            name              = $name
            remaining_seconds = $remOut
            limit_minutes     = $lim
            window            = $win
            mode              = $(if ($entry.blocked_today) { 'blocked' } else { [string]$rule.mode })
            day               = $script:StlDayNames[$idx]
            lock_reason       = (Get-StlLockReason $Config $entry $local)
        }
    }
    return [pscustomobject]@{
        updated_utc = $UtcNow.ToString('o')
        today_index = $idx
        week        = $week
        users       = $list
    }
}

# Befehle aus dem Admin-Ordner commands\ abarbeiten (jede Datei wird danach geloescht)
function Invoke-StlPendingCommands($State) {
    $dir = Get-StlCommandDir
    if (-not (Test-Path -LiteralPath $dir)) { return }
    # Reihenfolge: nach Erstellzeit im Befehl (created_utc, ISO-Format = sortierbar), sonst nach Dateizeit
    $items = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $cmd = $null
        try { $cmd = Read-StlJson $f.FullName } catch { Write-StlLog ('Befehl nicht lesbar: ' + $_.Exception.Message) }
        $raw = Get-StlProp $cmd 'created_utc'
        # PowerShell 7 macht aus ISO-Strings beim JSON-Lesen ein [datetime] -> sortierbar als 'o'-Text halten
        $created = if ($raw -is [datetime]) { $raw.ToUniversalTime().ToString('o') } else { [string]$raw }
        $items += [pscustomobject]@{ File = $f; Cmd = $cmd; Key = $created; Time = $f.LastWriteTimeUtc }
    }
    foreach ($it in @($items | Sort-Object Key, Time)) {
        try {
            $ok = Invoke-StlCommand $State $it.Cmd
            Write-StlLog ('Eltern-Befehl {0}: {1}' -f (Get-StlProp $it.Cmd 'action'), $(if ($ok) { 'ok' } else { 'ungueltig' }))
        } catch { Write-StlLog ('Befehl fehlgeschlagen: ' + $_.Exception.Message) }
        Remove-Item -LiteralPath $it.File.FullName -Force -ErrorAction SilentlyContinue
    }
}
