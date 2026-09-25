<#
.SYNOPSIS
    Dependency-free regression tests for IcePick (Windows PowerShell 5.1).
    Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-Tests.ps1 [-Filter B01]
    Exit code 0 = all passed.
#>
param([string]$Filter = '*')

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = Split-Path $PSScriptRoot
foreach ($f in 'Common', 'Collect-System', 'Collect-Events', 'Collect-Hardware', 'Collect-Artifacts', 'Collect-Changes', 'Collect-Reliability', 'Monitor', 'Analyze', 'Evidence', 'Logo', 'Report') {
    . (Join-Path $root "lib\$f.ps1")
}
. (Join-Path $PSScriptRoot 'Fixtures.ps1')

$script:TestTemp = Join-Path $env:TEMP "icepick-tests-$PID"
New-Item -ItemType Directory -Path $script:TestTemp -Force | Out-Null
$script:PsExe = (Get-Process -Id $PID).Path
$script:Engine = Join-Path $root 'IcePick.ps1'

function Assert-True { param($Condition, [string]$Message) if (-not $Condition) { throw "Assertion failed: $Message" } }
function Assert-Equal { param($Expected, $Actual, [string]$Message) if ("$Expected" -ne "$Actual") { throw "Expected '$Expected' but got '$Actual': $Message" } }
function Assert-Match { param([string]$Text, [string]$Pattern, [string]$Message) if ($Text -notmatch $Pattern) { throw "Expected match for /$Pattern/: $Message`n  got: $Text" } }
function Assert-NoMatch { param([string]$Text, [string]$Pattern, [string]$Message) if ($Text -match $Pattern) { throw "Did not expect /$Pattern/: $Message`n  got: $Text" } }

function New-TestDir { param([string]$Name) $d = Join-Path $script:TestTemp $Name; New-Item -ItemType Directory -Path $d -Force | Out-Null; return $d }
function Get-AllEvidence { param($Finding) (@($Finding.Items) | ForEach-Object { $_.Title; $_.Evidence }) -join "`n" }

# Runs the engine in a separate process (it calls exit). Returns exit code and output.
function Invoke-Engine {
    param([string[]]$Arguments)
    $argLine = (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:Engine) + $Arguments | ForEach-Object { ConvertTo-CFArgument $_ }) -join ' '
    $psi = New-Object Diagnostics.ProcessStartInfo($script:PsExe, $argLine)
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync()
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    return [pscustomobject]@{ ExitCode = $p.ExitCode; Output = $out + $errTask.Result }
}

# ---------------------------------------------------------------- B01
function Test-B01-PairedShutdownEventsFormOneIncident {
    $events = @(
        New-FakeBoot $T0.AddHours(-30)
        New-FakeBoot $T0
        New-Fake41 -Time $T0.AddSeconds(20)
        New-Fake6008 -Time $T0.AddSeconds(25) -CrashTime $T0.AddMinutes(-10)
    )
    $la = @([pscustomobject]@{ BootTime = $T0; Time = $T0.AddMinutes(-12); Source = 'Last logged event (Test)' })
    $inc = @(Invoke-CFStage 'Reconstructing unexpected shutdowns' { ConvertTo-CFIncidents -Events $events -LastAlive $la })
    Assert-True (-not (Test-CFStageFailed 'Reconstructing unexpected shutdowns')) 'reconstruction stage must not fail'
    Assert-Equal 1 $inc.Count 'a 41 + 6008 pair is one incident'
    Assert-Equal 'EventLog 6008' $inc[0].CrashSource 'latest last-alive candidate wins'
    Assert-Equal $T0.AddMinutes(-10).ToString('yyyy-MM-dd HH:mm') $inc[0].CrashTime.ToString('yyyy-MM-dd HH:mm') 'crash time from 6008'
    Assert-Equal 'Medium' $inc[0].TimingConfidence '10 minute gap'
}

# ---------------------------------------------------------------- B07
function Test-B07-RapidRebootsStaySeparateWithOwnBugchecks {
    $b1 = $T0; $b2 = $T0.AddMinutes(5)
    $events = @(
        New-FakeBoot $T0.AddHours(-1)
        New-FakeBoot $b1
        New-Fake41 -Time $b1.AddSeconds(10)
        New-FakeBoot $b2
        New-Fake41 -Time $b2.AddSeconds(10) -Bugcheck 0x9F
        New-FakeEvent -Time $b2.AddSeconds(20) -Key 'BugCheck' -Category 'Bugcheck' -Id 1001 -Summary 'The computer has rebooted from a bugcheck. The bugcheck was: 0x0000009f (0x0, 0x0, 0x0, 0x0).'
    )
    $inc = @(ConvertTo-CFIncidents -Events $events)
    Assert-Equal 2 $inc.Count 'two reboots five minutes apart are two incidents'
    Assert-True (-not $inc[0].Bugcheck) 'first reboot has no bugcheck'
    Assert-Equal '0x9F' $inc[1].Bugcheck 'second reboot keeps its own bugcheck'
    Assert-Equal 'Blue screen' $inc[1].Kind 'kind'
}

# ---------------------------------------------------------------- B02
function Test-B02-Whea46IsFatal {
    $events = @(New-FakeEvent -Time $T0 -Key 'WHEA' -Category 'Hardware' -Provider 'Microsoft-Windows-WHEA-Logger' -Id 46 -Summary 'A fatal hardware error has occurred.')
    $f = @(Get-CFRuleWhea -Events $events -Incidents @())
    Assert-Equal 1 $f.Count 'one finding'
    Assert-Match $f[0].Title 'Fatal' 'WHEA 46 is fatal'
    Assert-True ($f[0].Score -ge 70) "fatal score, got $($f[0].Score)"
    Assert-Match ($f[0].Evidence -join ' ') '1 fatal' 'counted as fatal'
}

# ---------------------------------------------------------------- B03
function Test-B03-NamedModuleNameIsUsed {
    $events = 1..3 | ForEach-Object { New-FakeEvent -Time $T0.AddHours($_) -Key 'AppCrash' -Category 'App' -Provider 'Application Error' -Id 1000 -Log 'Application' -Data @{ AppName = 'test.exe'; ModuleName = 'faulty.dll' } }
    Assert-Equal 'faulty.dll' $events[0].Norm.Module 'normalized module'
    $f = @(Get-CFRuleApps -Events $events)
    Assert-Equal 1 $f.Count 'recurring module finding'
    Assert-Match $f[0].Title 'faulty\.dll crashed 3 times' 'title'
    $data = New-FakeData -Events $events
    $a = Invoke-CFAnalysis -Data $data -Since $Since
    $html = Join-Path (New-TestDir 'b03') 'r.html'
    [void](Write-CFReport -Data $data -Analysis $a -Since $Since -Days 30 -Path $html -IsAdmin $true)
    Assert-Match ([IO.File]::ReadAllText($html)) '<td>faulty\.dll</td>' 'report module column filled'
}

# ---------------------------------------------------------------- B04
function Test-B04-NamedWerGpuEventIsDetected {
    $events = @(New-FakeEvent -Time $T0 -Key 'WER' -Category 'WER' -Provider 'Windows Error Reporting' -Id 1001 -Log 'Application' -Data @{ EventName = 'LiveKernelEvent'; P1 = '141' })
    Assert-True $events[0].Norm.IsGpuLiveKernel 'normalized as GPU live kernel event'
    $f = @(Get-CFRuleGpu -Events $events -Incidents @() -Artifacts (New-FakeData).Artifacts)
    Assert-Equal 1 $f.Count 'GPU finding from named WER fields'
    Assert-Match ($f[0].Evidence -join ' ') 'codes: 141' 'code reported'
}

# ---------------------------------------------------------------- B05
function Test-B05-UsbLiveDumpIsNotGpuEvidence {
    Assert-Equal 'USB' (Get-CFLiveDumpClass -Type 'USBHUB3' -Name 'USBHUB3-20260901-1200.dmp') 'USB class'
    Assert-Equal 'Network' (Get-CFLiveDumpClass -Type 'NDIS' -Name 'NDIS-1.dmp') 'network class'
    Assert-Equal 'GPU' (Get-CFLiveDumpClass -Type 'WATCHDOG' -Name 'WATCHDOG-1.dmp') 'watchdog is GPU'
    Assert-Equal 'Unknown' (Get-CFLiveDumpClass -Type 'Something' -Name 'x.dmp') 'unknown class'

    $events = @(
        New-FakeBoot $T0.AddHours(-10)
        New-FakeBoot $T0
        New-Fake41 -Time $T0.AddSeconds(10)
        New-FakeEvent -Time $T0.AddDays(-5) -Key 'TDR' -Category 'GPU' -Provider 'Display' -Id 4101 -Summary 'Display driver stopped responding'
    )
    $la = @([pscustomobject]@{ BootTime = $T0; Time = $T0.AddMinutes(-2); Source = 'Test' })
    $art = (New-FakeData).Artifacts
    $art.LiveKernelReports = @([pscustomobject]@{ Type = 'USBHUB3'; Class = 'USB'; Name = 'USBHUB3-1.dmp'; Time = $T0.AddMinutes(-3); Size = '1 MB' })
    $data = New-FakeData -Events $events -LastAlive $la -Artifacts $art
    $data.Incidents = @(ConvertTo-CFIncidents -Events $events -LastAlive $la)
    $a = Invoke-CFAnalysis -Data $data -Since $Since
    $gpu = $a.Findings | Where-Object { $_.Category -eq 'GPU' }
    Assert-True ($gpu -and $gpu.Score -lt 61) "GPU score must not be boosted by a USB dump (got $($gpu.Score))"
    Assert-NoMatch (Get-AllEvidence $gpu) 'within 15 minutes' 'no GPU correlation claim'
    Assert-True ($data.Incidents[0].Precursors | Where-Object { $_.Category -eq 'USB' }) 'USB dump still shown as context'
    Assert-True ($a.Findings | Where-Object { $_.Category -eq 'Silent' }) 'a USB dump does not suppress the silent finding'
}

# ---------------------------------------------------------------- B06
function Test-B06-OldLastActivityGivesLowConfidenceAndNoCorrelation {
    $events = @(
        New-FakeBoot $T0.AddDays(-2)
        New-FakeBoot $T0
        New-Fake41 -Time $T0.AddSeconds(10)
        New-FakeEvent -Time $T0.AddDays(-1).AddMinutes(-5) -Key 'WHEA' -Category 'Hardware' -Provider 'Microsoft-Windows-WHEA-Logger' -Id 19 -Summary 'A corrected hardware error has occurred.'
    )
    $la = @([pscustomobject]@{ BootTime = $T0; Time = $T0.AddDays(-1); Source = 'Test' })
    $data = New-FakeData -Events $events -LastAlive $la
    $data.Incidents = @(ConvertTo-CFIncidents -Events $events -LastAlive $la)
    Assert-Equal 'Low' $data.Incidents[0].TimingConfidence 'a day-long gap is low confidence'
    $a = Invoke-CFAnalysis -Data $data -Since $Since
    $hw = $a.Findings | Where-Object { $_.Category -eq 'Hardware' }
    Assert-NoMatch (Get-AllEvidence $hw) 'within 15 minutes' 'no correlation bonus for low-confidence timing'

    # Candidates from before the previous boot are rejected.
    $la2 = @([pscustomobject]@{ BootTime = $T0; Time = $T0.AddDays(-3); Source = 'Test' })
    $inc = @(ConvertTo-CFIncidents -Events $events -LastAlive $la2)
    Assert-True ($inc[0].CrashSource -like 'Unknown*') 'last activity from an earlier session is ignored'
}

# ---------------------------------------------------------------- B08
function Test-B08-SecondMonitorCannotWrite {
    $dir = New-TestDir 'b08'
    $paths = Get-CFMonitorPaths -HeartbeatDir $dir
    $held = Enter-CFMonitorLock -Path $paths.Lock
    try {
        Assert-True $held 'first lock acquired'
        Assert-True (-not (Enter-CFMonitorLock -Path $paths.Lock -Attempts 1)) 'second lock refused'
        $code = Start-CFMonitor -HeartbeatDir $dir -IntervalSec 1 -MaxRows 1 -Quiet -SamplerScript { param($Sync, $I) }
        Assert-Equal 2 $code 'second monitor exits with code 2'
        Assert-True (-not (Get-ChildItem $dir -Filter 'heartbeat-*.csv')) 'second monitor wrote nothing'
        Assert-True (Get-CFMonitorState -HeartbeatDir $dir).Running 'state shows running while lock is held'
    } finally { $held.Dispose() }

    $code = Start-CFMonitor -HeartbeatDir $dir -IntervalSec 1 -MaxRows 3 -Quiet -SamplerScript { param($Sync, $I) $Sync.Sample = @{ CpuPct = 5 }; $Sync.SampleTime = Get-Date }
    Assert-Equal 0 $code 'monitor ran'
    $rows = @(Import-CFHeartbeat -HeartbeatDir $dir -Since (Get-Date).AddHours(-1))
    Assert-Equal 'start,sample,sample,stop' (($rows | ForEach-Object { $_.Event }) -join ',') 'start/sample/stop rows, none lost'
    Assert-True (-not (Get-CFMonitorState -HeartbeatDir $dir).Running) 'not running after stop'
}

# ---------------------------------------------------------------- B09
function Test-B09-SuccessfulDumpIsNotAFailure {
    $q = $script:CFEventQueries | Where-Object { $_.Key -eq 'DumpFailure' }
    Assert-True ($q.Ids -notcontains 162) 'volmgr 162 (dump written) is not collected as a failure'
    Assert-True ($q.Ids -contains 161) 'volmgr 161 (dump failed) still is'
}

# ---------------------------------------------------------------- B10
function Test-B10-6008DateWithDirectionMarksParses {
    $crash = $T0.AddMinutes(-7)
    $ev = New-Fake6008 -Time $T0 -CrashTime $crash
    Assert-True ("$($ev.Data['Data1'])".Contains([string][char]0x200E)) 'fixture contains a left-to-right mark'
    $t = ConvertFrom-CF6008Time $ev
    Assert-True $t 'parsed'
    Assert-Equal $crash.ToString('yyyy-MM-dd HH:mm:ss') $t.ToString('yyyy-MM-dd HH:mm:ss') 'same time'
}

function Test-B10-SourceFilesAreAscii {
    $bad = @()
    foreach ($f in (Get-ChildItem $root -Recurse -Include *.ps1, *.cmd)) {
        $bytes = [IO.File]::ReadAllBytes($f.FullName)
        $start = 0
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $start = 3 }
        for ($i = $start; $i -lt $bytes.Length; $i++) { if ($bytes[$i] -gt 127) { $bad += "$($f.Name) byte $i"; break } }
    }
    Assert-Equal '' ($bad -join ', ') 'non-ASCII bytes break Windows PowerShell 5.1 parsing'
}

# ---------------------------------------------------------------- B11
function Test-B11-LocalizedMemoryDiagnosticFailure {
    $e = New-FakeEvent -Time $T0 -Key 'MemDiag' -Category 'Memory' -Provider 'Microsoft-Windows-MemoryDiagnostics-Results' -Id 1102 `
        -Summary 'Die Windows-Speicherdiagnose hat Hardwarefehler festgestellt.' -Data @{ CompletionType = '1'; NumBadPages = '12' }
    Assert-Equal 'Fail' $e.Norm.Result 'failure from the event ID'
    $f = @(Get-CFRuleMemory -Events @($e) -Incidents @() -System (New-FakeData).System)
    Assert-True ($f | Where-Object { $_.Title -match 'found RAM errors' }) 'RAM failure finding'
    Assert-Match (($f | ForEach-Object { $_.Evidence }) -join ' ') 'Bad memory pages found: 12' 'bad pages'
}

# ---------------------------------------------------------------- B12
function Test-B12-OldMinidumpsAreOutsideTheWindow {
    $dir = New-TestDir 'b12'
    $new = Join-Path $dir 'new.dmp'; $old = Join-Path $dir 'old.dmp'
    Set-Content $new 'x'; Set-Content $old 'x'
    (Get-Item $old).LastWriteTime = (Get-Date).AddDays(-90)
    $art = Get-CFCrashArtifacts -Since (Get-Date).AddDays(-30) -SkipSlow -DumpPaths ([pscustomobject]@{ MinidumpDir = $dir; DumpFile = (Join-Path $dir 'none.dmp') })
    Assert-True (($art.Minidumps | Where-Object { $_.Name -eq 'new.dmp' }).InWindow) 'recent dump is in window'
    Assert-True (-not ($art.Minidumps | Where-Object { $_.Name -eq 'old.dmp' }).InWindow) 'old dump is outside the window'
}

# ---------------------------------------------------------------- B13
function Test-B13-KernelModuleIsInconclusive {
    $events = @(New-FakeBoot $T0.AddHours(-5); New-FakeBoot $T0; New-Fake41 -Time $T0.AddSeconds(10) -Bugcheck 0x1A)
    $la = @([pscustomobject]@{ BootTime = $T0; Time = $T0.AddMinutes(-1); Source = 'Test' })
    $inc = @(ConvertTo-CFIncidents -Events $events -LastAlive $la)
    $art = (New-FakeData).Artifacts
    $art.DumpAnalysis = @(
        [pscustomobject]@{ Dump = 'a.dmp'; DumpTime = $T0.AddMinutes(1); Status = 'Ok'; MODULE_NAME = 'nt'; IMAGE_NAME = 'ntkrnlmp.exe'; BUGCHECK_STR = '0x1A'; FAILURE_BUCKET_ID = 'x' }
    )
    $f = @(Get-CFRuleBugchecks -Incidents $inc -Artifacts $art)
    Assert-True (-not ($f | Where-Object { $_.Category -eq 'Driver' })) 'the kernel is not blamed as a driver'
    Assert-Match (($f | ForEach-Object { $_.Evidence }) -join ' ') 'inconclusive' 'kernel result marked inconclusive'

    $art.DumpAnalysis = @([pscustomobject]@{ Dump = 'b.dmp'; DumpTime = $T0.AddMinutes(1); Status = 'Ok'; MODULE_NAME = 'badfilter'; IMAGE_NAME = 'badfilter.sys'; BUGCHECK_STR = '0x1A'; FAILURE_BUCKET_ID = 'y' })
    $d = @(Get-CFRuleBugchecks -Incidents $inc -Artifacts $art | Where-Object { $_.Category -eq 'Driver' })
    Assert-Equal 1 $d.Count 'third-party driver is a lead'
    Assert-Equal 20 $d[0].Score 'modest score'
}

# ---------------------------------------------------------------- B14
function Test-B14-TruncatedSourceIsReportedAndCaveated {
    [void](Get-SafeWinEvent -Filter @{ LogName = 'System' } -MaxEvents 1 -Source 'Event log: Probe')
    $st = $script:CFSourceStatus | Where-Object { $_.Source -eq 'Event log: Probe' }
    Assert-Equal 'Truncated' $st.Status 'hitting the limit marks the source truncated'
    $events = @(New-FakeBoot $T0.AddHours(-5); New-FakeBoot $T0; New-Fake41 -Time $T0.AddSeconds(10))
    $inc = @(ConvertTo-CFIncidents -Events $events -LastAlive @([pscustomobject]@{ BootTime = $T0; Time = $T0.AddMinutes(-1); Source = 'Test' }))
    $f = Get-CFRuleSilent -Incidents $inc
    Assert-Match ($f.Evidence -join ' ') 'Caveat' 'silent finding is caveated when sources are incomplete'
}

# ---------------------------------------------------------------- B15
function Test-B15-StalledSamplerDoesNotStopHeartbeats {
    $dir = New-TestDir 'b15'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $code = Start-CFMonitor -HeartbeatDir $dir -IntervalSec 1 -MaxRows 4 -Quiet -SamplerScript {
        param($Sync, $I)
        $Sync.Sample = @{ CpuPct = 7 }; $Sync.SampleTime = Get-Date
        while (-not $Sync.Stop) { Start-Sleep -Milliseconds 100 }   # then hangs
    }
    $sw.Stop()
    Assert-Equal 0 $code 'monitor ran'
    Assert-True ($sw.Elapsed.TotalSeconds -lt 10) "rows kept coming on schedule ($([int]$sw.Elapsed.TotalSeconds) s)"
    $rows = @(Import-CFHeartbeat -HeartbeatDir $dir -Since (Get-Date).AddHours(-1) | Where-Object { $_.Event -ne 'stop' })
    Assert-Equal 4 $rows.Count 'four rows despite the stalled sampler'
    Assert-True ([int]$rows[-1].SampleAgeSec -ge 2) "sample age grows (last row: $($rows[-1].SampleAgeSec))"
}

# ---------------------------------------------------------------- B16
function Test-B16-FailedAndDuplicateChanges {
    $log = Join-Path (New-TestDir 'b16') 'setupapi.dev.log'
    $day = $T0.ToString('yyyy/MM/dd')
    Set-Content $log @(
        '>>>  [Device Install (Hardware initiated) - PCI\VEN_1\GOOD]', ">>>  Section start $day 10:00:00.000", '<<<  Section end', '<<<  [Exit status: SUCCESS]',
        '>>>  [Device Install (Hardware initiated) - PCI\VEN_1\BAD]', ">>>  Section start $day 11:00:00.000", '<<<  Section end', '<<<  [Exit status: FAILURE(0xe0000219)]'
    )
    $installs = @(Get-CFSetupApiInstalls -Since $Since -Path $log)
    Assert-Equal 1 $installs.Count 'only the successful install'
    Assert-Match $installs[0].Name 'GOOD' 'successful one kept'

    $changes = [pscustomobject]@{ Timeline = @([pscustomobject]@{ Time = $T0.AddHours(-2); Kind = 'Windows Update'; Name = '2026-09 Cumulative Update (KB5000001)' }); FailedUpdates = @([pscustomobject]@{ Time = $T0; Kind = 'Windows Update'; Name = 'Broken (KB5000002)'; Status = 'Failed' }); ThirdPartyDrivers = @() }
    $ev = New-FakeEvent -Time $T0.AddHours(-1) -Key 'WindowsUpdate' -Category 'Change' -Provider 'Microsoft-Windows-WindowsUpdateClient' -Id 19 -Data @{ updateTitle = '2026-09 Cumulative Update for Windows 11 (KB5000001)' }
    $tl = @(Get-CFChangeTimeline -Changes $changes -Events @($ev))
    Assert-Equal 1 $tl.Count 'same KB on the same day counted once, failed update excluded'
}

# ---------------------------------------------------------------- B17
function Test-B17-ReportFailureGivesExitCode1 {
    $dir = New-TestDir 'b17'
    $evidence = Join-Path $dir 'evidence.json'
    Export-CFEvidence -Data (New-KnownCrashData) -Params @{ Days = 30; Since = $Since; Until = $T0.AddHours(1); FreezeTimes = @(); IsAdmin = $true } -Path $evidence
    $blocker = Join-Path $dir 'not-a-folder'
    Set-Content $blocker 'x'
    $r = Invoke-Engine @('-ReplayFrom', $evidence, '-OutputDir', (Join-Path $blocker 'out'), '-NoOpen')
    Assert-Equal 1 $r.ExitCode "exit code (output: $($r.Output))"
    Assert-Match $r.Output 'SCAN FAILED' 'failure is announced'
    Assert-NoMatch $r.Output 'REPORT:' 'no success marker'
}

# ---------------------------------------------------------------- B18
function Test-B18-EvidenceRoundTripReproducesFindings {
    $data = New-KnownCrashData
    $data.Incidents = @(ConvertTo-CFIncidents -Events $data.Events -Heartbeat $data.Heartbeat -LastAlive $data.LastAlive)
    $a1 = Invoke-CFAnalysis -Data $data -Since $Since
    $path = Join-Path (New-TestDir 'b18') 'evidence.json'
    Export-CFEvidence -Data $data -Params @{ Days = 30; Since = $Since } -Path $path
    $ev = Import-CFEvidence -Path $path
    Assert-True ($ev.Events[0].Time -is [datetime]) 'times come back as DateTime'
    Assert-True ($ev.Events[0].Data -is [System.Collections.IDictionary]) 'event data comes back as a dictionary'
    $data2 = New-FakeData -Events $ev.Events -Heartbeat $ev.Heartbeat -LastAlive $ev.LastAlive
    $data2.Incidents = @(ConvertTo-CFIncidents -Events $data2.Events -Heartbeat $data2.Heartbeat -LastAlive $data2.LastAlive)
    $a2 = Invoke-CFAnalysis -Data $data2 -Since ([datetime]$ev.Params.Since)
    $sig = { param($a) ($a.Findings | ForEach-Object { "$($_.Category)=$($_.Score)" }) -join ';' }
    Assert-Equal (& $sig $a1) (& $sig $a2) 'same findings after replay'
    Assert-Equal $data.Incidents[0].CrashTime $data2.Incidents[0].CrashTime 'same incident time'
}

# ---------------------------------------------------------------- B19
function Test-B19-UnknownStopCodeAndSaturationContext {
    Assert-Equal 'Unknown' (Get-CFBugcheckInfo '0x1234').Category 'unrecognized stop codes are not assumed to be drivers'
    Assert-Match (Get-CFBugcheckInfo '0x133').AlsoConsider 'storage' 'ambiguous codes carry alternatives'
    $inc = [pscustomobject]@{ Number = 1; CrashTime = $T0; HeartbeatTail = @(New-FakeHeartbeat -Time $T0 -Values @{ CpuPct = 100; GpuPct = 99 }); Context = @() }
    $f = @(Get-CFRuleHeartbeat -Incidents @($inc))
    Assert-Equal 0 $f.Count 'ordinary CPU/GPU saturation is not a finding'
    Assert-Match ($inc.Context -join ' ') 'CPU was at 100' 'but it is shown as context'
}

# ---------------------------------------------------------------- B20
function Test-B20-DebuggerArgumentsSurviveSpaces {
    $argLine = New-CFDebuggerArguments -DumpPath 'C:\Dump Dir\mini 1.dmp' -SymbolCache 'C:\Users\Test User\AppData\Local\Temp\IcePickSymbols'
    $echo = Join-Path $PSScriptRoot 'fakes\echo-args.ps1'
    $psi = New-Object Diagnostics.ProcessStartInfo($script:PsExe, "-NoProfile -ExecutionPolicy Bypass -File $(ConvertTo-CFArgument $echo) $argLine")
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi); $out = $p.StandardOutput.ReadToEnd(); $p.WaitForExit()
    $parts = @($out -split "`r?`n" | Where-Object { $_ })
    Assert-Equal 6 $parts.Count "six arguments (got: $($parts -join ' '))"
    Assert-Equal '<C:\Dump Dir\mini 1.dmp>' $parts[1] 'dump path is one argument'
    Assert-Equal '<srv*C:\Users\Test User\AppData\Local\Temp\IcePickSymbols*https://msdl.microsoft.com/download/symbols>' $parts[3] 'symbol path is one argument'
    Assert-Equal '<!analyze -v; q>' $parts[5] 'command is one argument'
}

# ---------------------------------------------------------------- B21
function Test-B21-RetentionIsScopedToThisPc {
    $dir = New-TestDir 'b21'
    $old = (Get-Date).AddDays(-30).ToString('yyyyMMdd'); $new = (Get-Date).ToString('yyyyMMdd')
    foreach ($n in "heartbeat-v2-PC1-$old.csv", "heartbeat-PC1-$old.csv", "heartbeat-v2-PC2-$old.csv", "heartbeat-v2-PC1-$new.csv") { Set-Content (Join-Path $dir $n) 'x' }
    Remove-CFOldHeartbeat -HeartbeatDir $dir -Computer 'PC1' -KeepDays 14
    $left = (Get-ChildItem $dir | ForEach-Object { $_.Name } | Sort-Object) -join ','
    Assert-Equal "heartbeat-v2-PC1-$new.csv,heartbeat-v2-PC2-$old.csv" $left 'only this PC''s old files are removed'
}

# ---------------------------------------------------------------- G01
function Test-G01-UserReportedFreezeTimes {
    $inc = @(ConvertTo-CFIncidents -Events @() -FreezeTimes @($T0))
    Assert-Equal 1 $inc.Count 'a reported hang without a reboot is still an incident'
    Assert-Match $inc[0].Kind 'you reported' 'kind'
    $events = @(New-FakeBoot $T0.AddHours(-5); New-FakeBoot $T0; New-Fake41 -Time $T0.AddSeconds(10))
    $inc = @(ConvertTo-CFIncidents -Events $events -LastAlive @([pscustomobject]@{ BootTime = $T0; Time = $T0.AddHours(-2); Source = 'Test' }) -FreezeTimes @($T0.AddMinutes(-30)))
    Assert-Equal 1 $inc.Count 'the reported time pins the reboot incident'
    Assert-Equal 'You' $inc[0].CrashSource 'source'
    Assert-Equal 'High' $inc[0].TimingConfidence 'confidence'
}

# ---------------------------------------------------------------- Acceptance
function Test-Acceptance-KnownCrashSequenceEndToEnd {
    $dir = New-TestDir 'acceptance'
    $evidence = Join-Path $dir 'evidence.json'
    Export-CFEvidence -Data (New-KnownCrashData) -Params @{ Days = 30; Since = $Since; Until = $T0.AddHours(1); FreezeTimes = @(); IsAdmin = $true } -Path $evidence
    $r = Invoke-Engine @('-ReplayFrom', $evidence, '-OutputDir', (Join-Path $dir 'out'), '-NoOpen')
    Assert-Equal 0 $r.ExitCode "engine exit code (output: $($r.Output))"
    $summary = Get-ChildItem (Join-Path $dir 'out') -Recurse -Filter summary.json | Select-Object -First 1
    $s = Get-Content $summary.FullName -Raw | ConvertFrom-Json
    Assert-Equal 1 $s.Stats.Incidents 'exactly one unexpected shutdown'
    Assert-Equal 'GPU' $s.Findings[0].Category 'the GPU hang ranks first'
    Assert-Match ((@($s.Findings[0].Items) | ForEach-Object { $_.Evidence }) -join ' ') 'within 15 minutes before 1' 'GPU evidence is linked to the shutdown'
    $csv = Import-Csv (Join-Path $summary.Directory.FullName 'shutdowns.csv')
    Assert-Equal 'Forced off with the power button' $csv[0].Kind 'kind'
    Assert-Equal 'High' $csv[0].TimingConfidence 'heartbeat gives high timing confidence'
    Assert-Equal $T0.AddMinutes(-3).ToString('yyyy-MM-dd HH:mm:ss') ([datetime]::Parse($csv[0].CrashTime, [Globalization.CultureInfo]::CurrentCulture)).ToString('yyyy-MM-dd HH:mm:ss') 'last heartbeat is the last known alive time'
    $html = Get-Content (Get-ChildItem (Join-Path $dir 'out') -Recurse -Filter '*.html' | Select-Object -First 1).FullName -Raw
    Assert-NoMatch $html 'No unexpected shutdowns were found' 'the report does not miss the crash'
}

# ---------------------------------------------------------------- summary.json shape
function Test-SummaryJsonItemsAreLists {
    # Two findings in one category: on PS 5.1 their Items array used to serialise
    # as {"value": [...], "Count": 2}, which hid the titles from the GUI.
    $sys = (New-FakeData).System
    $sys | Add-Member -NotePropertyName BiosDate -NotePropertyValue $T0.AddYears(-3) -Force
    $sys | Add-Member -NotePropertyName BiosVersion -NotePropertyValue 'Test 1.0' -Force
    $sys.FastStartup = $true
    $data = New-FakeData -System $sys
    $a = Invoke-CFAnalysis -Data $data -Since $Since
    $dir = New-TestDir 'summary'
    Assert-True (Export-CFRawData -Data $data -Analysis $a -Dir $dir -Params @{ Days = 30; Since = $Since }) 'export succeeded'
    $text = [IO.File]::ReadAllText((Join-Path $dir 'raw\summary.json'))
    Assert-NoMatch $text '"value"\s*:' 'no PowerShell array wrappers in summary.json'
    $cfg = (ConvertFrom-Json $text).Findings | Where-Object { $_.Category -eq 'Config' }
    Assert-Equal 2 @($cfg.Items).Count 'both config findings listed'
    Assert-Match @($cfg.Items)[0].Title 'BIOS' 'first item has its title'
}

# ---------------------------------------------------------------- runner
# Only the tests defined in this file (the library has Test-CF* helpers too).
$tests = @(Get-ChildItem function:\Test-* | Where-Object { $_.ScriptBlock.File -eq $PSCommandPath -and ($_.Name -like "Test-$Filter*" -or $_.Name -like $Filter) } | Sort-Object Name)
$failed = 0
foreach ($t in $tests) {
    $script:CFSourceStatus.Clear(); $script:CFStageStatus.Clear()
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        & $t.Name 6>$null 3>$null | Out-Null
        Write-Host ("PASS  {0} ({1:N1}s)" -f $t.Name, $sw.Elapsed.TotalSeconds) -ForegroundColor Green
    } catch {
        $failed++
        Write-Host ("FAIL  {0}: {1}" -f $t.Name, $_.Exception.Message) -ForegroundColor Red
        Write-Host "      at $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor DarkGray
    }
}
Remove-Item $script:TestTemp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ("{0} passed, {1} failed" -f ($tests.Count - $failed), $failed) -ForegroundColor $(if ($failed) { 'Red' } else { 'Green' })
exit ([int]($failed -gt 0))
