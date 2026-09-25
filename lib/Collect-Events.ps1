# Event log collection and unexpected-shutdown incident reconstruction.

# Each entry: Key, Category, Log, Providers, Ids (optional), Levels (optional).
# Levels: 1 = Critical, 2 = Error, 3 = Warning, 4 = Information.
$script:CFEventQueries = @(
    @{ Key = 'KernelPower41';   Category = 'Shutdown'; Log = 'System'; Providers = @('Microsoft-Windows-Kernel-Power'); Ids = @(41) }
    @{ Key = 'Unexpected6008';  Category = 'Shutdown'; Log = 'System'; Providers = @('EventLog'); Ids = @(6008) }
    @{ Key = 'BootStart';       Category = 'Boot';     Log = 'System'; Providers = @('Microsoft-Windows-Kernel-General'); Ids = @(12, 13) }
    @{ Key = 'PlannedShutdown'; Category = 'Boot';     Log = 'System'; Providers = @('User32'); Ids = @(1074) }
    @{ Key = 'BugCheck';        Category = 'Bugcheck'; Log = 'System'; Providers = @('Microsoft-Windows-WER-SystemErrorReporting', 'BugCheck'); Ids = @(1001) }
    @{ Key = 'WHEA';            Category = 'Hardware'; Log = 'System'; Providers = @('Microsoft-Windows-WHEA-Logger'); Ids = @(1, 17, 18, 19, 20, 46, 47) }
    @{ Key = 'TDR';             Category = 'GPU';      Log = 'System'; Providers = @('Display'); Ids = @(4101) }
    @{ Key = 'GPUDriver';       Category = 'GPU';      Log = 'System'; Providers = @('nvlddmkm', 'amdkmdag', 'amdkmdap', 'amdwddmg', 'igfx', 'igfxn', 'igfxnd'); Levels = @(1, 2, 3) }
    @{ Key = 'Disk';            Category = 'Storage';  Log = 'System'; Providers = @('disk'); Ids = @(7, 11, 51, 153, 157) }
    @{ Key = 'StorController';  Category = 'Storage';  Log = 'System'; Providers = @('stornvme', 'storahci', 'iaStorA', 'iaStorAC', 'iaStorAVC', 'iaStorV', 'nvme', 'secnvme', 'amdsata', 'rcbottom'); Levels = @(1, 2, 3) }
    @{ Key = 'Ntfs';            Category = 'Storage';  Log = 'System'; Providers = @('Ntfs', 'Microsoft-Windows-Ntfs'); Ids = @(55, 130, 137, 140); Levels = @(1, 2, 3) }
    # volmgr 45/46/161 are dump failures. 162 means a dump WAS written, so it is not collected here.
    @{ Key = 'DumpFailure';     Category = 'DumpConfig'; Log = 'System'; Providers = @('volmgr'); Ids = @(45, 46, 161) }
    @{ Key = 'MemDiag';         Category = 'Memory';   Log = 'System'; Providers = @('Microsoft-Windows-MemoryDiagnostics-Results') }
    @{ Key = 'ResExhaustion';   Category = 'Memory';   Log = 'System'; Providers = @('Microsoft-Windows-Resource-Exhaustion-Detector'); Ids = @(2004) }
    @{ Key = 'Throttle';        Category = 'Thermal';  Log = 'System'; Providers = @('Microsoft-Windows-Kernel-Processor-Power'); Ids = @(37) }
    @{ Key = 'DriverLoadFail';  Category = 'Driver';   Log = 'System'; Providers = @('Microsoft-Windows-Kernel-PnP'); Ids = @(219) }
    @{ Key = 'ServiceCrash';    Category = 'Service';  Log = 'System'; Providers = @('Service Control Manager'); Ids = @(7011, 7022, 7031, 7034) }
    @{ Key = 'DevInstall';      Category = 'Change';   Log = 'System'; Providers = @('Microsoft-Windows-UserPnp'); Ids = @(20001, 20003) }
    # Only successful update installs (19). Failures (20) are not changes.
    @{ Key = 'WindowsUpdate';   Category = 'Change';   Log = 'System'; Providers = @('Microsoft-Windows-WindowsUpdateClient'); Ids = @(19) }
    @{ Key = 'MsiInstall';      Category = 'Change';   Log = 'Application'; Providers = @('MsiInstaller'); Ids = @(11707, 11724) }
    @{ Key = 'AppCrash';        Category = 'App';      Log = 'Application'; Providers = @('Application Error'); Ids = @(1000) }
    @{ Key = 'AppHang';         Category = 'App';      Log = 'Application'; Providers = @('Application Hang'); Ids = @(1002) }
    @{ Key = 'WER';             Category = 'WER';      Log = 'Application'; Providers = @('Windows Error Reporting'); Ids = @(1001) }
)

$script:CFGpuLiveCodes = '^(141|117|1a8|193|1b0|116)$'

# Adds a .Norm object with the fields the analysis needs, reading both the
# named template fields of current Windows and the positional Data<n> layout
# of older versions.
function Add-CFNormalizedFields {
    param($Ev)
    $d = $Ev.Data
    $n = [ordered]@{}
    switch ($Ev.Key) {
        'AppCrash' {
            $n.App = Get-CFField $d 'AppName', 'Data0'
            $n.Module = Get-CFField $d 'ModuleName', 'FaultingModuleName', 'Data3'
        }
        'AppHang' { $n.App = Get-CFField $d 'AppName', 'Data0' }
        'WER' {
            $n.EventName = Get-CFField $d 'EventName', 'Data2'
            $n.P1 = Get-CFField $d 'P1', 'Data5'
            $n.IsGpuLiveKernel = ($n.EventName -eq 'LiveKernelEvent' -and "$($n.P1)" -match $script:CFGpuLiveCodes)
        }
        'MemDiag' {
            $completion = "$(Get-CFField $d 'CompletionType')"
            $bad = Get-CFField $d 'NumBadPages'
            $n.Result = if ($Ev.Id -in 1102, 1202 -or $completion -match 'fail') { 'Fail' }
            elseif ($Ev.Id -in 1101, 1201) { 'Pass' } else { 'Other' }
            if ($null -ne $bad) { $n.BadPages = $bad }
        }
        'ServiceCrash' { $n.Service = Get-CFField $d 'param1', 'Data0' }
    }
    $Ev | Add-Member -NotePropertyName Norm -NotePropertyValue ([pscustomobject]$n) -Force
}

function Get-CFEvents {
    param([datetime]$Since)
    $all = New-Object System.Collections.Generic.List[object]
    foreach ($q in $script:CFEventQueries) {
        foreach ($provider in $q.Providers) {
            $filter = @{ LogName = $q.Log; ProviderName = $provider; StartTime = $Since }
            if ($q.Ids) { $filter.Id = $q.Ids }
            if ($q.Levels) { $filter.Level = $q.Levels }
            foreach ($rec in (Get-SafeWinEvent -Filter $filter -Source "Event log: $($q.Key)")) {
                $e = ConvertFrom-CFEventRecord -Record $rec -Category $q.Category -Key $q.Key
                Add-CFNormalizedFields $e
                $all.Add($e)
            }
        }
    }
    Write-CFLog "Collected $($all.Count) relevant events"
    return @($all.ToArray() | Sort-Object Time)
}

# How far back the System and Application logs actually go. If a log rolled
# over, "nothing was logged before X" is not evidence of anything.
function Get-CFLogCoverage {
    param([datetime]$Since)
    $cov = [ordered]@{}
    foreach ($log in 'System', 'Application') {
        try {
            $oldest = Get-WinEvent -LogName $log -Oldest -MaxEvents 1 -ErrorAction Stop
            $cov[$log] = $oldest.TimeCreated
            if ($oldest.TimeCreated -gt $Since) {
                Set-CFSourceStatus -Source "$log log history" -Status Truncated -Detail "the log only goes back to $($oldest.TimeCreated.ToString('yyyy-MM-dd HH:mm')) (older entries were overwritten)" -CoverageFrom $oldest.TimeCreated
            } else { Set-CFSourceStatus -Source "$log log history" -Status Complete }
        } catch {
            $cov[$log] = $null
            Set-CFSourceStatus -Source "$log log history" -Status Unavailable -Detail $_.Exception.Message
        }
    }
    return [pscustomobject]$cov
}

# Providers that write at boot time and would make a crash look like it
# happened the instant before the reboot.
$script:CFBootProviders = @(
    'Microsoft-Windows-Kernel-Boot', 'Microsoft-Windows-Kernel-General', 'Microsoft-Windows-Kernel-Power',
    'EventLog', 'Microsoft-Windows-FilterManager', 'Microsoft-Windows-Kernel-Processor-Power',
    'Microsoft-Windows-Wininit', 'Microsoft-Windows-Kernel-PnP', 'Microsoft-Windows-Kernel-Dump',
    'volmgr', 'BugCheck', 'Microsoft-Windows-WER-SystemErrorReporting', 'Microsoft-Windows-Kernel-Tm'
)

# Newest non-boot event in System/Application between $After and $Before.
function Get-CFLastSignOfLife {
    param([datetime]$Before, [datetime]$After)
    $best = $null
    foreach ($log in 'System', 'Application') {
        $recs = Get-SafeWinEvent -Filter @{ LogName = $log; StartTime = $After; EndTime = $Before.AddSeconds(-1) } -MaxEvents 200
        foreach ($r in $recs) {
            if ($script:CFBootProviders -contains $r.ProviderName) { continue }
            if (-not $best -or $r.TimeCreated -gt $best.TimeCreated) { $best = $r }
            break
        }
    }
    return $best
}

function ConvertFrom-CF6008Time {
    param($Event6008)
    $marks = "[$([char]0x200E)$([char]0x200F)]"
    $t = ("$(Get-CFField $Event6008.Data 'Data0')" -replace $marks, '').Trim()
    $d = ("$(Get-CFField $Event6008.Data 'Data1')" -replace $marks, '').Trim()
    if (-not ($t -and $d)) { return $null }
    $parsed = [datetime]::MinValue
    foreach ($culture in [Globalization.CultureInfo]::CurrentCulture, [Globalization.CultureInfo]::InvariantCulture) {
        if ([datetime]::TryParse("$d $t", $culture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) { return $parsed }
    }
    Write-CFLog "Could not parse the EventLog 6008 time '$d $t'" 'WARN'
    return $null
}

$script:CFAnchorKeys = @('KernelPower41', 'Unexpected6008', 'BugCheck')

# Groups shutdown anchors by the boot they were logged in: one group per
# unclean reboot. Anchors with no boot record (log rolled over) stand alone.
function Get-CFAnchorGroups {
    param([object[]]$Events)
    $boots = @($Events | Where-Object { $_.Key -eq 'BootStart' -and $_.Id -eq 12 } | Sort-Object Time)
    $groups = [ordered]@{}
    foreach ($a in @($Events | Where-Object { $_.Key -in $script:CFAnchorKeys } | Sort-Object Time)) {
        $boot = $boots | Where-Object { $_.Time -le $a.Time.AddSeconds(5) } | Select-Object -Last 1
        if ($boot -and ($a.Time - $boot.Time).TotalHours -gt 2) { $boot = $null }   # logged long after boot: not a boot-time report
        $key = if ($boot) { 'boot:' + $boot.Time.ToString('o') } else { 'anchor:' + $a.Time.ToString('o') }
        if (-not $groups.Contains($key)) {
            $bootTime = if ($boot) { $boot.Time } else { $a.Time.AddMinutes(-2) }
            $prev = $boots | Where-Object { $_.Time -lt $bootTime.AddSeconds(-1) } | Select-Object -Last 1
            $groups[$key] = [pscustomobject]@{ BootTime = $bootTime; HasBootRecord = [bool]$boot; SessionStart = if ($prev) { $prev.Time } else { $null }; Anchors = New-Object System.Collections.Generic.List[object] }
        }
        $groups[$key].Anchors.Add($a)
    }
    return @($groups.Values)
}

# Live part: the last logged activity before each unclean reboot, bounded to
# the session that ended. Kept separate so reconstruction itself is pure.
function Get-CFLastAliveCandidates {
    param([object[]]$Events)
    foreach ($g in (Get-CFAnchorGroups -Events $Events)) {
        $after = if ($g.SessionStart) { $g.SessionStart } else { $g.BootTime.AddDays(-7) }
        $life = Get-CFLastSignOfLife -Before $g.BootTime -After $after
        if ($life) { [pscustomobject]@{ BootTime = $g.BootTime; Time = $life.TimeCreated; Source = "Last logged event ($($life.ProviderName))" } }
    }
}

function Get-CFTimingConfidence {
    param($Gap, [string]$Source)
    if ($Source -eq 'You') { return 'High' }
    if ($null -eq $Gap) { return 'Low' }
    if ($Gap.TotalMinutes -le 5) { return 'High' }
    if ($Gap.TotalMinutes -le 60) { return 'Medium' }
    return 'Low'
}

# Pure reconstruction: one incident per unclean reboot, plus user-reported
# hangs that did not end in a reboot.
function ConvertTo-CFIncidents {
    param([object[]]$Events, [object[]]$Heartbeat = @(), [object[]]$LastAlive = @(), [datetime[]]$FreezeTimes = @())
    $incidents = New-Object System.Collections.Generic.List[object]
    $usedFreezeTimes = @{}

    foreach ($g in (Get-CFAnchorGroups -Events $Events)) {
        $bootTime = $g.BootTime
        $lower = if ($g.SessionStart) { $g.SessionStart } else { $bootTime.AddDays(-7) }
        $kp = $g.Anchors | Where-Object { $_.Key -eq 'KernelPower41' } | Select-Object -First 1
        $ev6008 = $g.Anchors | Where-Object { $_.Key -eq 'Unexpected6008' } | Select-Object -First 1
        $bcEvent = $g.Anchors | Where-Object { $_.Key -eq 'BugCheck' } | Select-Object -First 1

        # Every candidate is a "last known alive" time inside the session that ended.
        $candidates = @()
        $hb = $Heartbeat | Where-Object { $_.Time -lt $bootTime -and $_.Time -gt $lower } | Sort-Object Time | Select-Object -Last 1
        if ($hb) {
            $stopped = "$($hb.Event)" -eq 'stop'
            $candidates += [pscustomobject]@{ Time = $hb.Time; Source = if ($stopped) { 'Heartbeat log (monitor had been stopped)' } else { 'Heartbeat log' }; Stopped = $stopped }
        }
        if ($ev6008) {
            $t = ConvertFrom-CF6008Time $ev6008
            if ($t -and $t -lt $bootTime -and $t -gt $lower) { $candidates += [pscustomobject]@{ Time = $t; Source = 'EventLog 6008'; Stopped = $false } }
        }
        foreach ($la in @($LastAlive | Where-Object { [math]::Abs(($_.BootTime - $bootTime).TotalSeconds) -lt 2 })) {
            if ($la.Time -lt $bootTime -and $la.Time -gt $lower) { $candidates += [pscustomobject]@{ Time = $la.Time; Source = $la.Source; Stopped = $false } }
        }
        $best = $candidates | Sort-Object Time | Select-Object -Last 1
        $lastAlive = if ($best) { $best.Time } else { $null }
        $source = if ($best) { $best.Source } else { 'Unknown (nothing logged before the reboot)' }

        # A freeze time entered by the user for this session pins the incident.
        $note = $null
        $user = $FreezeTimes | Where-Object { $_ -gt $lower -and $_ -le $bootTime } | Sort-Object | Select-Object -Last 1
        if ($user) {
            $usedFreezeTimes[$user.ToString('o')] = $true
            if ($lastAlive -and $lastAlive -gt $user) { $note = "Windows logged activity until $($lastAlive.ToString('HH:mm')), after the time you entered." }
            $crashTime = $user; $source = 'You'
        } else {
            $crashTime = if ($lastAlive) { $lastAlive } else { $bootTime }
        }
        $gap = if ($lastAlive -or $user) { $bootTime - $crashTime } else { $null }
        $confidence = Get-CFTimingConfidence -Gap $gap -Source $source
        if ($best -and $best.Stopped -and $source -ne 'You' -and $confidence -ne 'Low') { $confidence = if ($confidence -eq 'High') { 'Medium' } else { 'Low' } }

        $bugcheck = $null; $powerButton = $false; $longPress = $false; $sleep = $false; $wheaBoot = 0
        if ($kp) {
            $code = [int64]0
            [void][int64]::TryParse("$(Get-CFField $kp.Data 'BugcheckCode')", [ref]$code)
            if ($code -ne 0) { $bugcheck = '0x{0:X}' -f $code }
            $pb = [int64]0; [void][int64]::TryParse("$(Get-CFField $kp.Data 'PowerButtonTimestamp')", [ref]$pb)
            $powerButton = $pb -ne 0
            $longPress = "$(Get-CFField $kp.Data 'LongPowerButtonPressDetected')" -eq 'true'
            $sleep = "$(Get-CFField $kp.Data 'SleepInProgress')" -notin @('', '0', 'false')
            [void][int]::TryParse("$(Get-CFField $kp.Data 'WHEABootErrorCount')", [ref]$wheaBoot)
        }
        if (-not $bugcheck -and $bcEvent -and "$($bcEvent.Summary) $($bcEvent.Message)" -match '0x[0-9a-fA-F]{8}') {
            $bugcheck = '0x{0:X}' -f [Convert]::ToInt64($Matches[0], 16)
        }

        $kind = if ($bugcheck) { 'Blue screen' }
        elseif ($powerButton -or $longPress) { 'Forced off with the power button' }
        elseif ($kp) { 'Sudden reset or power loss' }
        else { 'Unexpected shutdown' }

        $incidents.Add([pscustomobject]@{
                Number           = 0
                Kind             = $kind
                ReportedAt       = $g.Anchors[0].Time
                BootTime         = $bootTime
                SessionStart     = $g.SessionStart
                LastAlive        = $lastAlive
                CrashTime        = $crashTime
                CrashSource      = $source
                Gap              = $gap
                TimingConfidence = $confidence
                Note             = $note
                Uptime           = if ($g.SessionStart) { $crashTime - $g.SessionStart } else { $null }
                Bugcheck         = $bugcheck
                PowerButton      = $powerButton
                LongPress        = $longPress
                SleepInProgress  = $sleep
                WheaBootErrors   = $wheaBoot
                Precursors       = @()
                HeartbeatTail    = @()
                Context          = @()
            })
    }

    # Freezes the user noticed that did not end in an unclean reboot.
    foreach ($t in @($FreezeTimes | Where-Object { -not $usedFreezeTimes.ContainsKey($_.ToString('o')) })) {
        $incidents.Add([pscustomobject]@{
                Number = 0; Kind = 'Hang you reported (no unclean reboot)'; ReportedAt = $t; BootTime = $null; SessionStart = $null
                LastAlive = $null; CrashTime = $t; CrashSource = 'You'; Gap = $null; TimingConfidence = 'High'; Note = $null
                Uptime = $null; Bugcheck = $null; PowerButton = $false; LongPress = $false; SleepInProgress = $false; WheaBootErrors = 0
                Precursors = @(); HeartbeatTail = @(); Context = @()
            })
    }

    $sorted = @($incidents.ToArray() | Sort-Object CrashTime)
    for ($i = 0; $i -lt $sorted.Count; $i++) { $sorted[$i].Number = $i + 1 }
    return $sorted
}
