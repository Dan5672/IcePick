<#
.SYNOPSIS
    IcePick: collects Windows freeze/crash evidence and writes an HTML report
    that ranks possible causes. Scans are read-only: they change no system settings.

.EXAMPLE
    .\IcePick.ps1                                   # scan the last 30 days and open the report
.EXAMPLE
    .\IcePick.ps1 -Days 90 -SkipSlow
.EXAMPLE
    .\IcePick.ps1 -FreezeTime '2026-09-24 21:40'    # tell it when you noticed a freeze
.EXAMPLE
    .\IcePick.ps1 -ReplayFrom .\raw\evidence.json   # rebuild a report offline from exported evidence
.EXAMPLE
    .\IcePick.ps1 -Monitor -IntervalSec 10          # heartbeat logger; leave running until the next freeze

.NOTES
    Exit codes: 0 = report written, 1 = scan or report failed, 2 = a monitor is already running.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 365)][int]$Days = 30,
    [string]$OutputDir,
    [string[]]$FreezeTime = @(),
    [string]$ReplayFrom,
    [switch]$IncludeDumps,
    [switch]$Monitor,
    [ValidateRange(1, 3600)][int]$IntervalSec = 10,
    [ValidateRange(1, 365)][int]$HeartbeatKeepDays = 14,
    [switch]$SkipSlow,
    [switch]$NoOpen
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
foreach ($f in 'Common', 'Collect-System', 'Collect-Events', 'Collect-Hardware', 'Collect-Artifacts', 'Collect-Changes', 'Collect-Reliability', 'Monitor', 'Analyze', 'Evidence', 'Logo', 'Report') {
    . (Join-Path $PSScriptRoot "lib\$f.ps1")
}

if (-not $OutputDir) { $OutputDir = Join-Path $PSScriptRoot 'IcePick-Output' }
$heartbeatDir = Join-Path $OutputDir 'heartbeat'

if ($Monitor) {
    exit (Start-CFMonitor -HeartbeatDir $heartbeatDir -IntervalSec $IntervalSec -KeepDays $HeartbeatKeepDays)
}

# Freeze times: accept "a,b" or "a;b" as well as real arrays (cmd / -File passes one string).
$freezeTimes = @()
foreach ($s in @($FreezeTime | ForEach-Object { "$_" -split '[;,]' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
    $t = [datetime]::MinValue
    if ([datetime]::TryParse($s, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$t) -or
        [datetime]::TryParse($s, [Globalization.CultureInfo]::CurrentCulture, [Globalization.DateTimeStyles]::None, [ref]$t)) { $freezeTimes += $t }
    else { Write-Host "SCAN FAILED: could not understand the freeze time '$s' (use e.g. 2026-09-24 21:40)" -ForegroundColor Red; exit 1 }
}

function Stop-CFScan([string]$Reason) {
    Write-Host ''
    Write-Host "SCAN FAILED: $Reason" -ForegroundColor Red
    exit 1
}

$total = [Diagnostics.Stopwatch]::StartNew()
$data = [ordered]@{}

if ($ReplayFrom) {
    # Offline: rebuild everything from an exported evidence.json.
    Write-CFLog "IcePick replaying $ReplayFrom" 'STEP'
    try { $ev = Import-CFEvidence -Path $ReplayFrom } catch { Stop-CFScan "could not read evidence: $($_.Exception.Message)" }
    $Days = [int]$ev.Params.Days
    $since = [datetime]$ev.Params.Since
    $until = [datetime]$ev.Generated
    $isAdmin = [bool]$ev.Params.IsAdmin
    $freezeTimes = @(@($ev.Params.FreezeTimes | Where-Object { $_ } | ForEach-Object { [datetime]$_ }) + $freezeTimes | Sort-Object -Unique)
    foreach ($k in 'System', 'Coverage', 'Hardware', 'Artifacts', 'Changes', 'Reliability') { $data[$k] = $ev.$k }
    $data.Events = @($ev.Events | Where-Object { $_ })
    $data.Heartbeat = @($ev.Heartbeat | Where-Object { $_ })
    $data.LastAlive = @($ev.LastAlive | Where-Object { $_ })
    $data.IncidentsUnavailable = [bool]$ev.IncidentsUnavailable
    $computer = $ev.Computer
    if (-not $data.IncidentsUnavailable) {
        $data.Incidents = @(Invoke-CFStage 'Reconstructing unexpected shutdowns' { ConvertTo-CFIncidents -Events $data.Events -Heartbeat $data.Heartbeat -LastAlive $data.LastAlive -FreezeTimes $freezeTimes } | Where-Object { $null -ne $_ })
        if (Test-CFStageFailed 'Reconstructing unexpected shutdowns') { $data.IncidentsUnavailable = $true }
    } else { $data.Incidents = @() }
} else {
    $isAdmin = Test-CFAdmin
    $since = (Get-Date).AddDays(-$Days)
    $computer = $env:COMPUTERNAME
    Write-CFLog "IcePick scanning $env:COMPUTERNAME - last $Days days" 'STEP'
    if (-not $isAdmin) { Write-CFLog 'Not running as administrator - some sources will be skipped. Use IcePick.cmd for a full scan.' 'WARN' }

    $data.System      = Invoke-CFStage 'System information'       { Get-CFSystemInfo }
    $data.Coverage    = Invoke-CFStage 'Log coverage'             { Get-CFLogCoverage -Since $since }
    $data.Events      = @(Invoke-CFStage 'Event logs'             { Get-CFEvents -Since $since } | Where-Object { $null -ne $_ })
    $data.Heartbeat   = @(Invoke-CFStage 'Heartbeat logs'         { Import-CFHeartbeat -HeartbeatDir $heartbeatDir -Since $since } | Where-Object { $null -ne $_ })
    $data.LastAlive   = @(Invoke-CFStage 'Last activity before each reboot' { Get-CFLastAliveCandidates -Events $data.Events } | Where-Object { $null -ne $_ })
    $data.Incidents   = @(Invoke-CFStage 'Reconstructing unexpected shutdowns' { ConvertTo-CFIncidents -Events $data.Events -Heartbeat $data.Heartbeat -LastAlive $data.LastAlive -FreezeTimes $freezeTimes } | Where-Object { $null -ne $_ })
    $data.IncidentsUnavailable = (Test-CFStageFailed 'Event logs') -or (Test-CFStageFailed 'Reconstructing unexpected shutdowns')
    $data.Hardware    = Invoke-CFStage 'Hardware health'          { Get-CFHardwareHealth }
    $data.Artifacts   = Invoke-CFStage 'Dumps and error reports'  { Get-CFCrashArtifacts -Since $since -SkipSlow:$SkipSlow }
    $data.Changes     = Invoke-CFStage 'Recent changes'           { Get-CFChanges -Since $since -SkipSlow:$SkipSlow }
    $data.Reliability = Invoke-CFStage 'Reliability Monitor'      { Get-CFReliability -Since $since -SkipSlow:$SkipSlow }
    $until = Get-Date
}

# Keep downstream code simple: never pass $null sections around.
foreach ($k in 'System', 'Coverage', 'Hardware', 'Artifacts', 'Changes', 'Reliability') { if (-not $data[$k]) { $data[$k] = [pscustomobject]@{} } }
$dataObj = [pscustomobject]$data

$analysis = Invoke-CFStage 'Analysing' { Invoke-CFAnalysis -Data $dataObj -Since $since }
if (-not $analysis) { $analysis = [pscustomobject]@{ Findings = @(); Stats = [pscustomobject]@{ IncidentsUnavailable = $true } } }

$runDir = Join-Path $OutputDir ('{0}-{1}' -f $computer, (Get-Date -Format 'yyyyMMdd-HHmmss'))
try { New-Item -ItemType Directory -Path $runDir -Force -ErrorAction Stop | Out-Null }
catch { Stop-CFScan "could not create the output folder $runDir ($($_.Exception.Message))" }
$reportPath = Join-Path $runDir "IcePick-$computer.html"

$params = @{ Days = $Days; Since = $since; Until = $until; FreezeTimes = @($freezeTimes); SkipSlow = [bool]$SkipSlow; IsAdmin = $isAdmin }
$reportOk = Invoke-CFStage 'Writing report' { Write-CFReport -Data $dataObj -Analysis $analysis -Since $since -Until $until -Days $Days -Path $reportPath -IsAdmin $isAdmin -ReplayOf $ReplayFrom }
$exportOk = Invoke-CFStage 'Exporting raw data' { Export-CFRawData -Data $dataObj -Analysis $analysis -Dir $runDir -Params $params -IncludeDumps:$IncludeDumps }

if ($reportOk -ne $true) { Stop-CFScan "the HTML report could not be written to $reportPath" }
if ($exportOk -ne $true) { Stop-CFScan "the report was written but the raw data export failed; see $runDir" }

$total.Stop()
$stats = $analysis.Stats
Write-Host ''
$countText = if ($stats.IncidentsUnavailable) { 'unknown (reconstruction failed)' } else { "$($stats.Incidents)" }
Write-Host ("Done in {0:N0}s. Unexpected shutdowns: {1}." -f $total.Elapsed.TotalSeconds, $countText) -ForegroundColor Green
$top = @($analysis.Findings) | Select-Object -First 3
if ($top) {
    Write-Host 'Highest-priority things to check:' -ForegroundColor Green
    $i = 0
    foreach ($f in $top) { $i++; Write-Host ("  {0}. {1} ({2} priority, {3}/100)" -f $i, $f.Name, $f.Severity, $f.Score) }
}
Write-Host "REPORT: $reportPath"

if (-not $NoOpen -and (Test-Path $reportPath)) { Start-Process $reportPath }
exit 0
