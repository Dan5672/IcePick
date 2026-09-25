# Common helpers shared by all IcePick modules.
# Windows PowerShell 5.1 compatible. Keep this file ASCII-only.

$script:CFLogLines     = New-Object System.Collections.Generic.List[string]
$script:CFStageStatus  = New-Object System.Collections.Generic.List[object]
$script:CFSourceStatus = New-Object System.Collections.Generic.List[object]

function Write-CFLog {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR', 'STEP')][string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    $script:CFLogLines.Add($line)
    switch ($Level) {
        'STEP'  { Write-Host $Message -ForegroundColor Cyan }
        'WARN'  { Write-Host "  ! $Message" -ForegroundColor Yellow }
        'ERROR' { Write-Host "  x $Message" -ForegroundColor Red }
        default { Write-Verbose $Message }
    }
}

# Per-source collection status so the report can tell "nothing found" apart
# from "could not look". Worst status wins when a source is reported twice.
$script:CFStatusRank = @{ Complete = 0; Skipped = 1; Truncated = 2; TimedOut = 3; Unavailable = 4; Failed = 5 }

function Set-CFSourceStatus {
    param(
        [string]$Source,
        [ValidateSet('Complete', 'Truncated', 'Unavailable', 'Skipped', 'TimedOut', 'Failed')][string]$Status,
        [string]$Detail = '',
        $CoverageFrom = $null
    )
    $existing = $script:CFSourceStatus | Where-Object { $_.Source -eq $Source } | Select-Object -First 1
    if ($existing) {
        if ($script:CFStatusRank[$Status] -gt $script:CFStatusRank[$existing.Status]) { $existing.Status = $Status; $existing.Detail = $Detail }
        elseif ($Detail -and -not $existing.Detail) { $existing.Detail = $Detail }
        if ($CoverageFrom -and (-not $existing.CoverageFrom -or $CoverageFrom -gt $existing.CoverageFrom)) { $existing.CoverageFrom = $CoverageFrom }
    } else {
        $script:CFSourceStatus.Add([pscustomobject]@{ Source = $Source; Status = $Status; Detail = $Detail; CoverageFrom = $CoverageFrom })
    }
    if ($Status -notin 'Complete', 'Skipped') { Write-CFLog "$Source - $Status $Detail" 'WARN' }
}

# Kept for callers that only want to note a skipped section.
function Add-CFSkipped {
    param([string]$Section, [string]$Reason)
    Set-CFSourceStatus -Source $Section -Status Skipped -Detail $Reason
}

# True when any of the named sources is not Complete (used to caveat
# "nothing was found" style conclusions).
function Test-CFSourceGap {
    param([string[]]$Sources)
    return [bool]($script:CFSourceStatus | Where-Object { $_.Source -in $Sources -and $_.Status -ne 'Complete' })
}

function Test-CFAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

# Runs a stage, timing it and swallowing failures so one broken source never
# stops the whole report. The outcome is recorded so a failed stage is shown
# as "unavailable" instead of "nothing found".
function Invoke-CFStage {
    param([string]$Name, [scriptblock]$Script)
    Write-CFLog "  - $Name" 'STEP'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $status = 'Ok'; $err = ''
    try {
        $result = & $Script
    } catch {
        $status = 'Failed'; $err = $_.Exception.Message
        Write-CFLog "$Name failed: $err" 'ERROR'
        $result = $null
    }
    $sw.Stop()
    $script:CFStageStatus.Add([pscustomobject]@{ Name = $Name; Status = $status; Error = $err; Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1) })
    Write-CFLog ("{0} took {1:N1}s" -f $Name, $sw.Elapsed.TotalSeconds)
    return $result
}

function Test-CFStageFailed {
    param([string]$Name)
    return [bool]($script:CFStageStatus | Where-Object { $_.Name -eq $Name -and $_.Status -ne 'Ok' })
}

# Get-WinEvent wrapper: returns an empty array instead of throwing when a log
# or provider is missing or nothing matches. With -Source it records whether
# the query was complete, truncated or unavailable.
function Get-SafeWinEvent {
    param([hashtable]$Filter, [int]$MaxEvents = 5000, [string]$Source)
    try {
        $recs = @(Get-WinEvent -FilterHashtable $Filter -MaxEvents $MaxEvents -ErrorAction Stop)
        if ($Source) {
            if ($recs.Count -ge $MaxEvents) {
                $oldest = ($recs | Measure-Object TimeCreated -Minimum).Minimum
                Set-CFSourceStatus -Source $Source -Status Truncated -Detail "hit the $MaxEvents-event limit; only events after $($oldest.ToString('yyyy-MM-dd HH:mm')) were read" -CoverageFrom $oldest
            } else { Set-CFSourceStatus -Source $Source -Status Complete }
        }
        return $recs
    } catch {
        $msg = $_.Exception.Message
        $benign = $_.FullyQualifiedErrorId -match 'NoMatchingEventsFound' -or $msg -match 'No events were found|could not be found|not registered|no providers|There is not an event provider'
        if ($Source) {
            if ($benign) { Set-CFSourceStatus -Source $Source -Status Complete }
            elseif ($_.Exception -is [UnauthorizedAccessException] -or $msg -match 'unauthorized|access is denied') { Set-CFSourceStatus -Source $Source -Status Unavailable -Detail 'access denied (run as administrator)' }
            else { Set-CFSourceStatus -Source $Source -Status Failed -Detail $msg }
        } elseif (-not $benign) {
            Write-CFLog "Event query failed ($($Filter.LogName) / $($Filter.ProviderName)): $msg" 'WARN'
        }
        return @()
    }
}

# Flattens an EventLogRecord into a plain object with named EventData fields.
function ConvertFrom-CFEventRecord {
    param($Record, [string]$Category, [string]$Key)
    $data = [ordered]@{}
    try {
        $xml = [xml]$Record.ToXml()
        $i = 0
        foreach ($n in $xml.SelectNodes("//*[local-name()='EventData']/*[local-name()='Data']")) {
            $name = $n.GetAttribute('Name')
            if (-not $name) { $name = "Data$i" }
            $data[$name] = $n.InnerText
            $i++
        }
        foreach ($n in $xml.SelectNodes("//*[local-name()='UserData']//*[not(*)]")) {
            if (-not $data.Contains($n.LocalName)) { $data[$n.LocalName] = $n.InnerText }
        }
    } catch { }

    $message = $null
    try { $message = $Record.Message } catch { }
    if (-not $message) { $message = ($data.Values | Where-Object { $_ }) -join ' | ' }
    $summary = ''
    if ($message) {
        $summary = ($message -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
        if ($summary.Length -gt 240) { $summary = $summary.Substring(0, 237) + '...' }
    }

    [pscustomobject]@{
        Time     = $Record.TimeCreated
        Log      = $Record.LogName
        Provider = $Record.ProviderName
        Id       = $Record.Id
        Level    = $Record.LevelDisplayName
        Category = $Category
        Key      = $Key
        Summary  = $summary
        Message  = $message
        Data     = $data
        Norm     = [pscustomobject]@{}
    }
}

# First non-empty value among the named fields. Works on the ordered
# dictionaries built at collection time and on the PSCustomObjects that come
# back from a JSON replay.
function Get-CFField {
    param($Data, [string[]]$Names)
    if ($null -eq $Data) { return $null }
    foreach ($n in $Names) {
        $v = $null
        if ($Data -is [System.Collections.IDictionary]) { if ($Data.Contains($n)) { $v = $Data[$n] } }
        else { $p = $Data.PSObject.Properties[$n]; if ($p) { $v = $p.Value } }
        if ($null -ne $v -and "$v" -ne '') { return $v }
    }
    return $null
}

function New-CFFinding {
    param(
        [string]$Category,
        [string]$Title,
        [double]$Score,
        [string[]]$Evidence = @(),
        [string[]]$Recommendation = @()
    )
    [pscustomobject]@{
        Category       = $Category
        Title          = $Title
        Score          = $Score
        Evidence       = @($Evidence)
        Recommendation = @($Recommendation)
    }
}

# Counts separate occurrences in a list of times: signals closer together than
# WindowSec (for example a TDR, its WER report and its live dump) count once.
function Measure-CFDistinctOccurrences {
    param([datetime[]]$Times, [int]$WindowSec = 120)
    $sorted = @($Times | Sort-Object)
    if (-not $sorted.Count) { return 0 }
    $count = 1
    for ($i = 1; $i -lt $sorted.Count; $i++) {
        if (($sorted[$i] - $sorted[$i - 1]).TotalSeconds -gt $WindowSec) { $count++ }
    }
    return $count
}

# Runs a self-contained script block in a separate runspace with a deadline.
# Throws TimeoutException if it does not finish in time (the runspace is
# abandoned; blocking COM calls cannot be interrupted).
function Invoke-CFWithTimeout {
    param([scriptblock]$Script, [object[]]$ArgumentList = @(), [int]$Seconds = 60)
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($Script.ToString())
    foreach ($a in $ArgumentList) { [void]$ps.AddArgument($a) }
    $handle = $ps.BeginInvoke()
    if (-not $handle.AsyncWaitHandle.WaitOne($Seconds * 1000)) {
        try { [void]$ps.BeginStop($null, $null) } catch { }
        throw (New-Object TimeoutException "did not finish within $Seconds s")
    }
    try {
        $out = $ps.EndInvoke($handle)
        if ($ps.Streams.Error.Count) { throw $ps.Streams.Error[0].Exception }
        foreach ($o in $out) { $o }
    } finally { $ps.Dispose() }
}

# Quotes one command-line argument using the Windows (CommandLineToArgvW) rules.
function ConvertTo-CFArgument {
    param([string]$Value)
    if ($Value -and $Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', { param($m) ($m.Groups[1].Value * 2) + '\"' })
    $escaped = [regex]::Replace($escaped, '(\\+)$', { param($m) $m.Groups[1].Value * 2 })
    return '"' + $escaped + '"'
}

function Format-CFBytes {
    param([double]$Bytes)
    if ($Bytes -ge 1TB) { return '{0:N1} TB' -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return '{0:N1} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N0} KB' -f ($Bytes / 1KB) }
    return '{0:N0} B' -f $Bytes
}

function Format-CFSpan {
    param($Span)
    if ($null -eq $Span) { return 'unknown' }
    if ($Span.TotalDays -ge 1) { return '{0}d {1}h' -f [int][math]::Floor($Span.TotalDays), $Span.Hours }
    if ($Span.TotalHours -ge 1) { return '{0}h {1}m' -f [int][math]::Floor($Span.TotalHours), $Span.Minutes }
    return '{0}m' -f [int][math]::Floor($Span.TotalMinutes)
}
