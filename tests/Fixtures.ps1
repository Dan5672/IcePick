# Builders for synthetic events and data sets used by Run-Tests.ps1.

# A fixed reference time inside a 30-day window.
$script:T0 = (Get-Date).Date.AddDays(-5).AddHours(12)
$script:Since = $script:T0.AddDays(-25)

function New-FakeEvent {
    param(
        [datetime]$Time, [string]$Key, [string]$Category, [string]$Provider = 'Test', [int]$Id = 0,
        [string]$Summary = 'test event', [hashtable]$Data = @{}, [string]$Message, [string]$Log = 'System'
    )
    $d = [ordered]@{}
    foreach ($k in $Data.Keys) { $d[$k] = $Data[$k] }
    if (-not $Message) { $Message = $Summary }
    $e = [pscustomobject]@{
        Time = $Time; Log = $Log; Provider = $Provider; Id = $Id; Level = 'Error'; Category = $Category; Key = $Key
        Summary = $Summary; Message = $Message; Data = $d; Norm = [pscustomobject]@{}
    }
    Add-CFNormalizedFields $e
    return $e
}

function New-FakeBoot { param([datetime]$Time) New-FakeEvent -Time $Time -Key 'BootStart' -Category 'Boot' -Provider 'Microsoft-Windows-Kernel-General' -Id 12 -Summary 'The operating system started' }

function New-Fake41 {
    param([datetime]$Time, [int64]$Bugcheck = 0, [int64]$PowerButton = 0)
    New-FakeEvent -Time $Time -Key 'KernelPower41' -Category 'Shutdown' -Provider 'Microsoft-Windows-Kernel-Power' -Id 41 `
        -Summary 'The system has rebooted without cleanly shutting down first.' `
        -Data @{ BugcheckCode = "$Bugcheck"; PowerButtonTimestamp = "$PowerButton"; SleepInProgress = '0'; WHEABootErrorCount = '0' }
}

# EventLog 6008 stores the crash time as localized strings, often with
# left-to-right marks around the date parts.
function New-Fake6008 {
    param([datetime]$Time, [datetime]$CrashTime)
    $lrm = [string][char]0x200E
    $culture = [Globalization.CultureInfo]::CurrentCulture
    $date = $lrm + $CrashTime.ToString($culture.DateTimeFormat.ShortDatePattern, $culture) + $lrm
    $timeStr = $CrashTime.ToString($culture.DateTimeFormat.LongTimePattern, $culture)
    New-FakeEvent -Time $Time -Key 'Unexpected6008' -Category 'Shutdown' -Provider 'EventLog' -Id 6008 -Summary 'The previous system shutdown was unexpected.' -Data @{ Data0 = $timeStr; Data1 = $date }
}

function New-FakeHeartbeat {
    param([datetime]$Time, [string]$Kind = 'sample', [hashtable]$Values = @{})
    $row = [ordered]@{ Time = $Time; Event = $Kind; SampleAgeSec = '0'; CpuPct = '10'; AvailMB = '4000'; CommitPct = '40'; DiskQueue = '0'; DiskBusyPct = '1'; GpuPct = '5'; TempC = ''; TopCpu = ''; TopMem = '' }
    foreach ($k in $Values.Keys) { $row[$k] = "$($Values[$k])" }
    return [pscustomobject]$row
}

function New-FakeData {
    param($Events = @(), $Incidents = @(), $Heartbeat = @(), $LastAlive = @(), $Artifacts, $Hardware, $Changes, $System)
    if (-not $Artifacts) { $Artifacts = [pscustomobject]@{ LiveKernelReports = @(); WerReports = @(); Minidumps = @(); DumpAnalysis = @(); DebuggerFound = $false } }
    if (-not $Hardware) { $Hardware = [pscustomobject]@{ Disks = @(); Volumes = @(); ThermalZones = @(); SmartPredictFailure = @() } }
    if (-not $Changes) { $Changes = [pscustomobject]@{ Timeline = @(); FailedUpdates = @(); ThirdPartyDrivers = @() } }
    if (-not $System) { $System = [pscustomobject]@{ ComputerName = 'TESTPC'; Memory = @(); Pagefiles = @(); AutoPagefile = $true; CPU = @(); GPU = @(); FastStartup = $false; CrashDumpEnabled = 7 } }
    [pscustomobject]@{
        Events = @($Events); Incidents = @($Incidents); Heartbeat = @($Heartbeat); LastAlive = @($LastAlive)
        System = $System; Hardware = $Hardware; Artifacts = $Artifacts; Changes = $Changes
        Reliability = [pscustomobject]@{ Records = @(); Stability = @() }
        Coverage = [pscustomobject]@{ System = $script:Since.AddDays(-10); Application = $script:Since.AddDays(-10) }
        IncidentsUnavailable = $false
    }
}

# A complete known crash: GPU timeout a few minutes before a hard hang that the
# user ended with the power button, with a heartbeat log running.
function New-KnownCrashData {
    $prev = $script:T0.AddHours(-8)
    $events = @(
        New-FakeBoot $prev
        New-FakeEvent -Time $script:T0.AddMinutes(-6) -Key 'TDR' -Category 'GPU' -Provider 'Display' -Id 4101 -Summary 'Display driver nvlddmkm stopped responding and has successfully recovered.'
        New-FakeEvent -Time $script:T0.AddMinutes(-6).AddSeconds(10) -Key 'WER' -Category 'WER' -Provider 'Windows Error Reporting' -Id 1001 -Log 'Application' -Data @{ EventName = 'LiveKernelEvent'; P1 = '141' }
        New-FakeBoot $script:T0
        New-Fake41 -Time $script:T0.AddSeconds(15) -PowerButton 133000000000
        New-Fake6008 -Time $script:T0.AddSeconds(20) -CrashTime $script:T0.AddMinutes(-5)
    )
    $hb = @()
    for ($t = $script:T0.AddMinutes(-20); $t -le $script:T0.AddMinutes(-3); $t = $t.AddSeconds(10)) { $hb += New-FakeHeartbeat -Time $t }
    $lastAlive = @([pscustomobject]@{ BootTime = $script:T0; Time = $script:T0.AddMinutes(-3).AddSeconds(-30); Source = 'Last logged event (Test)' })
    return (New-FakeData -Events $events -Heartbeat $hb -LastAlive $lastAlive)
}
