# Heartbeat monitor: appends one CSV row every N seconds with write-through so
# the last rows survive a hard reset.
#  - Only one monitor per PC and output folder can write (lock file).
#  - Metrics are sampled in a separate runspace, so a hung provider can delay
#    the readings but never the timestamps (SampleAgeSec shows staleness).
#  - start / stop rows mark deliberate monitoring gaps.
# Uses CIM perf classes (not Get-Counter) because counter paths are localized.

$script:CFHeartbeatColumns = @('Time', 'Event', 'SampleAgeSec', 'CpuPct', 'AvailMB', 'CommitPct', 'DiskQueue', 'DiskBusyPct', 'GpuPct', 'TempC', 'TopCpu', 'TopMem')
$script:CFMetricColumns = @('CpuPct', 'AvailMB', 'CommitPct', 'DiskQueue', 'DiskBusyPct', 'GpuPct', 'TempC', 'TopCpu', 'TopMem')

# Self-contained sampler loop; runs in its own runspace and publishes the
# latest reading into the synchronized $Sync hashtable.
$script:CFSamplerScript = {
    param($Sync, [int]$IntervalSec)
    $prevCpu = $null; $prevTime = $null
    while (-not $Sync.Stop) {
        $s = @{}
        try { $s.CpuPct = (Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -OperationTimeoutSec 3 -ErrorAction Stop).PercentProcessorTime } catch { }
        try {
            $m = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -OperationTimeoutSec 3 -ErrorAction Stop
            $s.AvailMB = $m.AvailableMBytes; $s.CommitPct = $m.PercentCommittedBytesInUse
        } catch { }
        try {
            $d = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'" -OperationTimeoutSec 3 -ErrorAction Stop
            $s.DiskQueue = $d.CurrentDiskQueueLength; $s.DiskBusyPct = [math]::Min(100, $d.PercentDiskTime)
        } catch { }
        try {
            $engines = Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -OperationTimeoutSec 3 -ErrorAction Stop | Where-Object { $_.Name -like '*engtype_3D' }
            $s.GpuPct = [math]::Min(100, ($engines | Measure-Object UtilizationPercentage -Sum).Sum)
        } catch { }
        try {
            $z = Get-CimInstance -Namespace root\wmi -ClassName MSAcpi_ThermalZoneTemperature -OperationTimeoutSec 3 -ErrorAction Stop | Select-Object -First 1
            if ($z) { $s.TempC = [math]::Round($z.CurrentTemperature / 10 - 273.15, 1) }
        } catch { }

        # Top CPU processes from the CPU-time delta since the previous sample.
        $procs = @(Get-Process -ErrorAction SilentlyContinue)
        $now = Get-Date
        $cpuNow = @{}
        foreach ($p in $procs) { try { if ($p.TotalProcessorTime) { $cpuNow[$p.Id] = $p.TotalProcessorTime.TotalSeconds } } catch { } }
        if ($prevCpu -and $prevTime) {
            $wall = ($now - $prevTime).TotalSeconds * [Environment]::ProcessorCount
            if ($wall -gt 0) {
                $s.TopCpu = ($procs | Where-Object { $cpuNow.ContainsKey($_.Id) -and $prevCpu.ContainsKey($_.Id) } | ForEach-Object {
                        [pscustomobject]@{ Name = $_.ProcessName; Pct = 100 * ($cpuNow[$_.Id] - $prevCpu[$_.Id]) / $wall }
                    } | Sort-Object Pct -Descending | Select-Object -First 3 | ForEach-Object { '{0}={1:N0}%' -f $_.Name, $_.Pct }) -join ' '
            }
        }
        $prevCpu = $cpuNow; $prevTime = $now
        $s.TopMem = ($procs | Sort-Object WorkingSet64 -Descending | Select-Object -First 3 |
                ForEach-Object { '{0}={1}MB' -f $_.ProcessName, [int]($_.WorkingSet64 / 1MB) }) -join ' '

        $Sync.Sample = $s
        $Sync.SampleTime = Get-Date
        $until = (Get-Date).AddSeconds($IntervalSec)
        while (-not $Sync.Stop -and (Get-Date) -lt $until) { Start-Sleep -Milliseconds 200 }
    }
}

function Get-CFMonitorPaths {
    param([string]$HeartbeatDir, [string]$Computer = $env:COMPUTERNAME)
    [pscustomobject]@{
        Lock   = Join-Path $HeartbeatDir "monitor-$Computer.lock"
        Stop   = Join-Path $HeartbeatDir "monitor-$Computer.stop"
        Status = Join-Path $HeartbeatDir "monitor-$Computer.status.json"
    }
}

# Exclusive lock: a second monitor for the same PC and folder cannot write.
function Enter-CFMonitorLock {
    param([string]$Path, [int]$Attempts = 3)
    for ($i = 0; $i -lt $Attempts; $i++) {
        try { return New-Object IO.FileStream($Path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch [IO.IOException] { Start-Sleep -Milliseconds 300 }
    }
    return $null
}

function Open-CFHeartbeatWriter {
    param([string]$Path)
    $isNew = -not (Test-Path $Path)
    # FileShare.Read: readers (the report, the GUI) are fine; a second writer is not.
    $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read, 4096, [IO.FileOptions]::WriteThrough)
    $w = New-Object IO.StreamWriter($fs, (New-Object Text.UTF8Encoding $false))
    $w.AutoFlush = $true
    if ($isNew) { $w.WriteLine(($script:CFHeartbeatColumns -join ',')) }
    return $w
}

function ConvertTo-CFHeartbeatLine {
    param([datetime]$Time, [string]$Kind, $AgeSec, [hashtable]$Sample)
    $values = @($Time.ToString('yyyy-MM-dd HH:mm:ss'), $Kind, $AgeSec)
    foreach ($c in $script:CFMetricColumns) { $v = $null; if ($Sample) { $v = $Sample[$c] }; $values += $v }
    return ($values | ForEach-Object { '"{0}"' -f ("$_" -replace '"', "'") }) -join ','
}

# Deletes this PC's heartbeat files older than KeepDays (by the date in the
# file name). Other PCs' files in a shared folder are left alone.
function Remove-CFOldHeartbeat {
    param([string]$HeartbeatDir, [string]$Computer = $env:COMPUTERNAME, [int]$KeepDays = 14, [datetime]$Now = (Get-Date))
    $cutoff = $Now.Date.AddDays(-$KeepDays)
    $pattern = '^heartbeat-(v2-)?' + [regex]::Escape($Computer) + '-(\d{8})\.csv$'
    foreach ($f in (Get-ChildItem $HeartbeatDir -Filter 'heartbeat-*.csv' -ErrorAction SilentlyContinue)) {
        if ($f.Name -match $pattern) {
            $day = [datetime]::ParseExact($Matches[2], 'yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture)
            if ($day -lt $cutoff) { Remove-Item $f.FullName -ErrorAction SilentlyContinue }
        }
    }
}

function Write-CFMonitorStatus {
    param([string]$Path, [hashtable]$Status)
    try { [IO.File]::WriteAllText($Path, ($Status | ConvertTo-Json -Compress)) } catch { }
}

# Returns the monitor's exit code: 0 = stopped normally, 2 = another monitor holds the lock.
function Start-CFMonitor {
    param(
        [string]$HeartbeatDir,
        [int]$IntervalSec = 10,
        [int]$KeepDays = 14,
        [int]$MaxRows = 0,                 # tests: stop after this many sample rows
        [scriptblock]$SamplerScript = $script:CFSamplerScript,
        [switch]$Quiet
    )
    New-Item -ItemType Directory -Path $HeartbeatDir -Force | Out-Null
    $paths = Get-CFMonitorPaths -HeartbeatDir $HeartbeatDir
    $lock = Enter-CFMonitorLock -Path $paths.Lock
    if (-not $lock) {
        $other = $null
        try { $other = (Get-Content $paths.Status -Raw | ConvertFrom-Json).Pid } catch { }
        Write-Host "Another IcePick monitor is already running for this PC$(if ($other) { " (PID $other)" }). Not starting a second one." -ForegroundColor Yellow
        return 2
    }
    Remove-Item $paths.Stop -ErrorAction SilentlyContinue
    if (-not $Quiet) { Write-Host "IcePick heartbeat monitor - writing to $HeartbeatDir every $IntervalSec s. Press Ctrl+C to stop." -ForegroundColor Cyan }

    $sync = [hashtable]::Synchronized(@{ Stop = $false; Sample = $null; SampleTime = $null })
    $sampler = [PowerShell]::Create()
    [void]$sampler.AddScript($SamplerScript.ToString()).AddArgument($sync).AddArgument($IntervalSec)
    $samplerHandle = $sampler.BeginInvoke()

    $started = Get-Date
    $status = @{ Pid = $PID; Computer = $env:COMPUTERNAME; Started = $started.ToString('o'); IntervalSec = $IntervalSec; LastRow = $null; Running = $true }
    $currentDay = $null; $writer = $null; $rows = 0; $rowKind = 'start'
    try {
        while ($true) {
            $now = Get-Date
            $day = $now.ToString('yyyyMMdd')
            if ($day -ne $currentDay) {
                if ($writer) { $writer.Dispose() }
                Remove-CFOldHeartbeat -HeartbeatDir $HeartbeatDir -KeepDays $KeepDays -Now $now
                $writer = Open-CFHeartbeatWriter -Path (Join-Path $HeartbeatDir "heartbeat-v2-$env:COMPUTERNAME-$day.csv")
                $currentDay = $day
            }
            $age = $null
            if ($sync.SampleTime) { $age = [int]($now - $sync.SampleTime).TotalSeconds }
            $writer.WriteLine((ConvertTo-CFHeartbeatLine -Time $now -Kind $rowKind -AgeSec $age -Sample $sync.Sample))
            $rowKind = 'sample'
            $rows++
            $status.LastRow = $now.ToString('o')
            Write-CFMonitorStatus -Path $paths.Status -Status $status
            if ($MaxRows -gt 0 -and $rows -ge $MaxRows) { break }

            $next = $now.AddSeconds($IntervalSec)
            $stopRequested = $false
            while ((Get-Date) -lt $next) {
                if (Test-Path $paths.Stop) { $stopRequested = $true; break }
                Start-Sleep -Milliseconds 250
            }
            if ($stopRequested) { break }
        }
    } finally {
        if ($writer) {
            try { $writer.WriteLine((ConvertTo-CFHeartbeatLine -Time (Get-Date) -Kind 'stop' -AgeSec $null -Sample $null)) } catch { }
            $writer.Dispose()
        }
        $sync.Stop = $true
        try { [void]$samplerHandle.AsyncWaitHandle.WaitOne(2000) } catch { }
        try { $sampler.Dispose() } catch { }
        $status.Running = $false
        Write-CFMonitorStatus -Path $paths.Status -Status $status
        Remove-Item $paths.Stop -ErrorAction SilentlyContinue
        $lock.Dispose()
        Remove-Item $paths.Lock -ErrorAction SilentlyContinue
    }
    return 0
}

# Asks a running monitor to stop gracefully (it writes a 'stop' row).
function Request-CFMonitorStop {
    param([string]$HeartbeatDir)
    $paths = Get-CFMonitorPaths -HeartbeatDir $HeartbeatDir
    New-Item -ItemType File -Path $paths.Stop -Force | Out-Null
}

# Cheap state check for the GUI: lock held = running; status file gives the
# PID and the time of the last row (stale if older than 3 intervals).
function Get-CFMonitorState {
    param([string]$HeartbeatDir)
    $paths = Get-CFMonitorPaths -HeartbeatDir $HeartbeatDir
    $running = $false
    if (Test-Path $paths.Lock) {
        try { $fs = New-Object IO.FileStream($paths.Lock, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None); $fs.Dispose() }
        catch [IO.IOException] { $running = $true }
        catch { }
    }
    $st = $null
    try { $st = Get-Content $paths.Status -Raw -ErrorAction Stop | ConvertFrom-Json } catch { }
    $last = $null; $interval = 10; $procId = $null
    if ($st) {
        if ($st.LastRow) { $last = [datetime]::Parse($st.LastRow, $null, [Globalization.DateTimeStyles]::RoundtripKind) }
        if ($st.IntervalSec) { $interval = [int]$st.IntervalSec }
        $procId = $st.Pid
    }
    $age = if ($last) { ((Get-Date) - $last).TotalSeconds } else { $null }
    [pscustomobject]@{
        Running     = $running
        Pid         = $procId
        LastRow     = $last
        IntervalSec = $interval
        Stale       = ($running -and ($null -eq $age -or $age -gt 3 * $interval + 5))
        AgeSec      = $age
    }
}

function Import-CFHeartbeat {
    param([string]$HeartbeatDir, [datetime]$Since, [string]$Computer = $env:COMPUTERNAME)
    if (-not (Test-Path $HeartbeatDir)) { return @() }
    $pattern = '^heartbeat-(v2-)?' + [regex]::Escape($Computer) + '-\d{8}\.csv$'
    $rows = foreach ($f in (Get-ChildItem $HeartbeatDir -Filter 'heartbeat-*.csv' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $pattern } | Sort-Object Name)) {
        if ($f.LastWriteTime -lt $Since) { continue }
        try {
            # Read with sharing so a running monitor does not block us.
            $fs = New-Object IO.FileStream($f.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            $sr = New-Object IO.StreamReader($fs)
            $text = $sr.ReadToEnd(); $sr.Dispose()
            $text | ConvertFrom-Csv | ForEach-Object {
                $t = [datetime]::MinValue
                if ([datetime]::TryParseExact($_.Time, 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$t)) {
                    $_.Time = $t
                    if (-not $_.PSObject.Properties['Event']) { $_ | Add-Member -NotePropertyName Event -NotePropertyValue 'sample' }
                    $_
                }
            }
        } catch { Write-CFLog "Could not read $($f.Name): $($_.Exception.Message)" 'WARN' }
    }
    # Files are read in date order and rows are written in time order; re-sorting
    # by the one-second timestamps would not be stable (stop rows could move).
    return @($rows | Where-Object { $_.Time -ge $Since })
}
