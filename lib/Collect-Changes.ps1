# Recent changes: driver installs (setupapi log), Windows Update history,
# hotfixes, newly installed programs, and the current third-party driver set.
# Only changes that actually completed are treated as changes.

function Get-CFSetupApiInstalls {
    param([datetime]$Since, [string]$Path = "$env:SystemRoot\INF\setupapi.dev.log")
    $log = $Path
    if (-not (Test-Path $log)) { Set-CFSourceStatus -Source 'Driver install log' -Status Complete -Detail 'no setupapi.dev.log'; return @() }
    $results = New-Object System.Collections.Generic.List[object]
    $title = $null; $start = $null
    try {
        foreach ($line in [IO.File]::ReadLines($log)) {
            if ($line.StartsWith('>>>  [')) { $title = $line.Substring(5).Trim('[', ']', ' '); $start = $null; continue }
            if ($title -and $line.StartsWith('>>>  Section start ')) {
                $t = [datetime]::MinValue
                if ([datetime]::TryParseExact($line.Substring(19).Trim(), 'yyyy/MM/dd HH:mm:ss.fff', [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$t)) { $start = $t }
                continue
            }
            if ($title -and $line.StartsWith('<<<  [Exit status:')) {
                $ok = $line -match 'Exit status:\s*SUCCESS'
                if ($ok -and $start -and $start -ge $Since -and $title -match 'Device Install|Install Driver|Driver Install|Import Driver Package' -and $title -notmatch 'Delete|Remove') {
                    $results.Add([pscustomobject]@{ Time = $start; Kind = 'Driver install'; Name = $title })
                }
                $title = $null; $start = $null
            }
        }
        Set-CFSourceStatus -Source 'Driver install log' -Status Complete
    } catch { Set-CFSourceStatus -Source 'Driver install log' -Status Failed -Detail $_.Exception.Message }
    return $results.ToArray()
}

# Self-contained so it can run in a separate runspace with a deadline.
$script:CFUpdateHistoryScript = {
    param([datetime]$Since, [int]$Max)
    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $total = $searcher.GetTotalHistoryCount()
    $read = 0; $truncated = $false
    while ($read -lt $total) {
        if ($read -ge $Max) { $truncated = $true; break }
        $page = $searcher.QueryHistory($read, [math]::Min(200, $total - $read))
        $n = 0; $older = $false
        foreach ($h in $page) {
            $n++
            if (-not $h.Date) { continue }
            $local = $h.Date.ToLocalTime()
            if ($local -lt $Since) { $older = $true; continue }
            [pscustomobject]@{ Time = $local; Title = "$($h.Title)"; ResultCode = [int]$h.ResultCode }
        }
        $read += $n
        if ($n -eq 0 -or $older) { break }
    }
    if ($truncated) { [pscustomobject]@{ Truncated = $true } }
}

function Get-CFUpdateHistory {
    param([datetime]$Since, [int]$TimeoutSec = 60)
    try {
        $rows = @(Invoke-CFWithTimeout -Script $script:CFUpdateHistoryScript -ArgumentList @($Since, 5000) -Seconds $TimeoutSec)
    } catch [TimeoutException] {
        Set-CFSourceStatus -Source 'Windows Update history' -Status TimedOut -Detail $_.Exception.Message
        return @()
    } catch {
        Set-CFSourceStatus -Source 'Windows Update history' -Status Unavailable -Detail $_.Exception.Message
        return @()
    }
    if ($rows | Where-Object { $_.PSObject.Properties['Truncated'] }) { Set-CFSourceStatus -Source 'Windows Update history' -Status Truncated -Detail 'more than 5000 history entries' }
    else { Set-CFSourceStatus -Source 'Windows Update history' -Status Complete }
    return @($rows | Where-Object { $_.PSObject.Properties['Title'] } | ForEach-Object {
            $status = switch ($_.ResultCode) { 1 { 'In progress' } 2 { 'Succeeded' } 3 { 'Succeeded with errors' } 4 { 'Failed' } 5 { 'Aborted' } default { "Result $($_.ResultCode)" } }
            $kind = if ($_.Title -match 'driver|Display|Graphics|Chipset|Firmware|BIOS|- Net -|- System -|- Extension -|- SoftwareComponent -') { 'Driver/firmware update' } else { 'Windows Update' }
            [pscustomobject]@{ Time = $_.Time; Kind = $kind; Name = $_.Title; Status = $status; Succeeded = ($_.ResultCode -in 2, 3) }
        })
}

function Get-CFRecentPrograms {
    param([datetime]$Since)
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $out = foreach ($k in $keys) {
        Get-ItemProperty $k -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -and $_.InstallDate -match '^\d{8}$' } | ForEach-Object {
            $d = [datetime]::MinValue
            if ([datetime]::TryParseExact($_.InstallDate, 'yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$d) -and $d -ge $Since.Date) {
                [pscustomobject]@{ Time = $d; Kind = 'Program installed'; Name = "$($_.DisplayName) $($_.DisplayVersion)".Trim() }
            }
        }
    }
    return @($out | Sort-Object Name -Unique)
}

# Identity used to merge the same change reported by several sources
# (update history, WindowsUpdateClient events, hotfix list).
function Get-CFChangeKey {
    param([string]$Name, $Time)
    $day = if ($Time) { ([datetime]$Time).ToString('yyyy-MM-dd') } else { '' }
    if ($Name -match '(KB\d{6,8})') { return "$($Matches[1].ToUpper())|$day" }
    $norm = ($Name.ToLowerInvariant() -replace '\[.*?\]|\(.*?\)', '' -replace '[^a-z0-9]+', ' ').Trim()
    return "$norm|$day"
}

# Merges collected changes with change events from the logs, keeping only
# completed changes and each change once.
function Get-CFChangeTimeline {
    param($Changes, [object[]]$Events)
    $items = @($Changes.Timeline) + @($Events | Where-Object { $_.Category -eq 'Change' } | ForEach-Object {
            $name = Get-CFField $_.Data 'updateTitle'
            if (-not $name) { $name = $_.Summary }
            $kind = switch ($_.Key) { 'WindowsUpdate' { 'Windows Update' } 'DevInstall' { 'Device install' } 'MsiInstall' { if ($_.Id -eq 11724) { 'Program removed' } else { 'Program installed' } } default { $_.Key } }
            [pscustomobject]@{ Time = $_.Time; Kind = $kind; Name = $name }
        })
    $seen = @{}
    $out = foreach ($i in ($items | Where-Object { $_ } | Sort-Object Time)) {
        $k = Get-CFChangeKey -Name "$($i.Name)" -Time $i.Time
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        $i
    }
    return @($out | Sort-Object Time -Descending)
}

function Get-CFChanges {
    param([datetime]$Since, [switch]$SkipSlow)
    $c = [ordered]@{}
    $timeline = New-Object System.Collections.Generic.List[object]

    foreach ($x in (Get-CFSetupApiInstalls -Since $Since)) { $timeline.Add($x) }

    $c.FailedUpdates = @()
    if ($SkipSlow) { Add-CFSkipped 'Windows Update history' 'quick scan' }
    else {
        $history = @(Get-CFUpdateHistory -Since $Since)
        foreach ($x in ($history | Where-Object { $_.Succeeded })) { $timeline.Add([pscustomobject]@{ Time = $x.Time; Kind = $x.Kind; Name = $x.Name }) }
        $c.FailedUpdates = @($history | Where-Object { -not $_.Succeeded } | Select-Object Time, Kind, Name, Status)
    }
    foreach ($x in (Get-CFRecentPrograms -Since $Since)) { $timeline.Add($x) }

    $c.HotFixes = @(Get-HotFix -ErrorAction SilentlyContinue | Where-Object { $_.InstalledOn -and $_.InstalledOn -ge $Since } | ForEach-Object {
            [pscustomobject]@{ Time = $_.InstalledOn; Kind = 'Hotfix'; Name = "$($_.HotFixID) ($($_.Description))" }
        })
    foreach ($x in $c.HotFixes) { $timeline.Add($x) }
    $c.Timeline = @($timeline.ToArray() | Sort-Object Time -Descending)

    # Current non-Microsoft drivers, newest first (slow on some machines).
    $c.ThirdPartyDrivers = @()
    if (-not $SkipSlow) {
        try {
            $c.ThirdPartyDrivers = @(Get-CimInstance Win32_PnPSignedDriver -OperationTimeoutSec 60 -ErrorAction Stop |
                    Where-Object { $_.DriverProviderName -and $_.DriverProviderName -notmatch '^Microsoft' -and $_.DeviceName } | ForEach-Object {
                        [pscustomobject]@{
                            Device   = $_.DeviceName
                            Class    = $_.DeviceClass
                            Provider = $_.DriverProviderName
                            Version  = $_.DriverVersion
                            Date     = if ($_.DriverDate) { $_.DriverDate.ToString('yyyy-MM-dd') } else { '' }
                            Inf      = $_.InfName
                        }
                    } | Sort-Object Device, Version -Unique | Sort-Object Date -Descending)
            Set-CFSourceStatus -Source 'Installed drivers' -Status Complete
        } catch { Set-CFSourceStatus -Source 'Installed drivers' -Status Failed -Detail $_.Exception.Message }
    } else { Add-CFSkipped 'Installed drivers' 'quick scan' }

    return [pscustomobject]$c
}
