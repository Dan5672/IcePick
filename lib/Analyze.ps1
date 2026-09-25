# Correlates the collected evidence and ranks possible causes.
# Scores are a heuristic priority for what to check first, not a probability.

$script:CFCategoryInfo = [ordered]@{
    Hardware = @{ Name = 'CPU / RAM / motherboard hardware errors'; Recs = @(
            'Remove any CPU or RAM overclock and disable XMP/EXPO in the BIOS, then see if the problem stops.'
            'Update the motherboard BIOS/UEFI to the latest version.'
            'Run MemTest86 from a bootable USB for at least 4 passes.'
            'If the errors name a PCIe device, reseat that card or NVMe drive, and try turning off PCIe Link State Power Management in the power plan.'
            'Check CPU temperatures under load with HWiNFO64, and consider the power supply.') }
    GPU = @{ Name = 'Graphics driver / GPU hangs'; Recs = @(
            'Clean-install the GPU driver: run DDU (Display Driver Uninstaller) in Safe Mode, then install the latest (or the previous stable) driver from NVIDIA/AMD/Intel.'
            'Check GPU temperature and fans under load with HWiNFO64 or GPU-Z.'
            'Remove any GPU overclock/undervolt (MSI Afterburner, Adrenalin tuning, etc.).'
            'Make sure GPU power cables are fully seated (one separate PSU cable per connector) and the PSU is big enough.'
            'As a test, turn off Hardware-accelerated GPU scheduling and browser hardware acceleration.') }
    Storage = @{ Name = 'Disk / storage controller problems'; Recs = @(
            'Back up anything important now.'
            'Update the SSD firmware with the maker''s tool (Samsung Magician, WD Dashboard, Crucial Storage Executive, etc.).'
            'Update chipset and storage (NVMe / Intel RST / AMD SATA) drivers from the motherboard or laptop maker.'
            'Reseat the drive; for SATA, try a different cable and port.'
            'Check SMART details with CrystalDiskInfo and run "chkdsk C: /scan".'
            'As a test, set PCIe Link State Power Management to Off in the power plan.') }
    Memory = @{ Name = 'Memory (RAM) faults or memory exhaustion'; Recs = @(
            'Run MemTest86 for at least 4 passes; if it finds errors, test each stick on its own.'
            'Disable XMP/EXPO (run the RAM at default speed) as a test.'
            'If memory ran out, look at the processes named in the evidence for leaks, and keep the page file system-managed.') }
    Thermal = @{ Name = 'Overheating / thermal throttling'; Recs = @(
            'Watch CPU/GPU temperatures with HWiNFO64 during normal use.'
            'Clean dust out of heatsinks, fans and filters; check that every fan spins.'
            'Re-apply CPU thermal paste if the machine is several years old.'
            'Improve case airflow; for a laptop, use it on a hard surface and keep the vents clear.') }
    Silent = @{ Name = 'Unexpected shutdowns with nothing logged beforehand'; Recs = @(
            'Start the freeze monitor in IcePick (or Run-Monitor.cmd) and leave it running until the next freeze, then run this report again. It shows the last CPU, memory, disk and temperature readings.'
            'When it happens, note the time and enter it in IcePick ("I noticed a freeze at"), so the report can look at exactly that moment.'
            'Load BIOS defaults (which removes overclocks and XMP) and update the BIOS.'
            'Test the RAM with MemTest86.'
            'Suspect the power supply: faulty or undersized PSUs cause silent lockups and resets. Test with a known-good PSU if you can.'
            'Check temperatures with HWiNFO64.'
            'As a test, disable Fast Startup and set PCIe Link State Power Management to Off (known triggers for idle freezes).') }
    Driver = @{ Name = 'Faulty kernel driver'; Recs = @(
            'Update the driver named in the evidence, preferably from the device maker''s site.'
            'If the problem started after a driver update, roll it back in Device Manager.'
            'Advanced: Driver Verifier can pinpoint a bad driver, but only use it if you know how to turn it off from Safe Mode.') }
    Unknown = @{ Name = 'Blue screens without a clear culprit'; Recs = @(
            'Look up the stop code in Microsoft''s "Bug check code reference".'
            'Install the Windows SDK Debugging Tools (cdb.exe) and scan again so the dump is analysed, or bring the dump files back for analysis (tick "Include crash dumps").') }
    Change = @{ Name = 'Possible trigger: recent changes'; Recs = @(
            'As a test, roll back or uninstall the listed changes one at a time, drivers first, and see whether the problem stops.'
            'System Restore to a point before the first unexpected shutdown is another way to test this, if a restore point exists.') }
    App = @{ Name = 'Recurring application crashes / hangs'; Recs = @(
            'Update or reinstall the application or module named.'
            'If the faulting module belongs to a driver (graphics, audio, antivirus), update that software.') }
    Service = @{ Name = 'Crashing Windows services'; Recs = @('Look up the service named, then update, repair or remove the software that owns it.') }
    Config = @{ Name = 'Settings that hide the cause'; Recs = @() }
}

# Stop code -> name, primary category, and other explanations worth checking.
$script:CFBugchecks = @{
    0x1A = @('MEMORY_MANAGEMENT', 'Memory', 'can also be a faulty driver'); 0x50 = @('PAGE_FAULT_IN_NONPAGED_AREA', 'Memory', 'often a faulty driver or antivirus')
    0x4E = @('PFN_LIST_CORRUPT', 'Memory', ''); 0x19 = @('BAD_POOL_HEADER', 'Driver', ''); 0x0A = @('IRQL_NOT_LESS_OR_EQUAL', 'Driver', 'can also be faulty RAM')
    0xD1 = @('DRIVER_IRQL_NOT_LESS_OR_EQUAL', 'Driver', ''); 0x3B = @('SYSTEM_SERVICE_EXCEPTION', 'Driver', ''); 0x7E = @('SYSTEM_THREAD_EXCEPTION_NOT_HANDLED', 'Driver', '')
    0x1E = @('KMODE_EXCEPTION_NOT_HANDLED', 'Driver', ''); 0x133 = @('DPC_WATCHDOG_VIOLATION', 'Driver', 'very often storage (SSD firmware / NVMe or SATA driver) or a GPU driver')
    0x9F = @('DRIVER_POWER_STATE_FAILURE', 'Driver', 'usually a device driver failing during sleep or resume'); 0xC4 = @('DRIVER_VERIFIER_DETECTED_VIOLATION', 'Driver', '')
    0x139 = @('KERNEL_SECURITY_CHECK_FAILURE', 'Driver', 'can also be faulty RAM'); 0xC2 = @('BAD_POOL_CALLER', 'Driver', ''); 0x13A = @('KERNEL_MODE_HEAP_CORRUPTION', 'Driver', '')
    0xEF = @('CRITICAL_PROCESS_DIED', 'Storage', 'can also be system file corruption or malware'); 0x7A = @('KERNEL_DATA_INPAGE_ERROR', 'Storage', 'can also be faulty RAM')
    0xF4 = @('CRITICAL_OBJECT_TERMINATION', 'Storage', ''); 0x77 = @('KERNEL_STACK_INPAGE_ERROR', 'Storage', ''); 0x154 = @('UNEXPECTED_STORE_EXCEPTION', 'Storage', '')
    0x124 = @('WHEA_UNCORRECTABLE_ERROR', 'Hardware', 'overclocking or power delivery can also cause it'); 0x101 = @('CLOCK_WATCHDOG_TIMEOUT', 'Hardware', 'CPU instability, overclock or outdated BIOS')
    0x9C = @('MACHINE_CHECK_EXCEPTION', 'Hardware', ''); 0x7F = @('UNEXPECTED_KERNEL_MODE_TRAP', 'Hardware', 'can also be a faulty driver')
    0x116 = @('VIDEO_TDR_FAILURE', 'GPU', ''); 0x117 = @('VIDEO_TDR_TIMEOUT_DETECTED', 'GPU', ''); 0x119 = @('VIDEO_SCHEDULER_INTERNAL_ERROR', 'GPU', '')
    0x10E = @('VIDEO_MEMORY_MANAGEMENT_INTERNAL', 'GPU', ''); 0x141 = @('VIDEO_ENGINE_TIMEOUT_DETECTED', 'GPU', '')
}

# Categories whose events count as "warnings before an unexpected shutdown".
$script:CFPrecursorCategories = @('Hardware', 'GPU', 'Storage', 'Memory', 'Thermal', 'Driver', 'Service', 'App', 'WER', 'Bugcheck', 'USB', 'Network', 'Other')
# ...of which these are too weak to say the shutdown "had a warning".
$script:CFWeakCategories = @('App', 'Service', 'USB', 'Network', 'Other')

$script:CFGenericModules = '^(nt|ntkrnlmp|ntoskrnl|ntkrpamp|ntkrnlpa|hal|halmacpi|win32k\w*|Unknown_Module\w*|Unknown_Image\w*|memory_corruption)(\.exe|\.sys|\.dll)?$'

function Get-CFBugcheckInfo {
    param([string]$Code)
    $n = [Convert]::ToInt64($Code, 16) -band 0x0FFFFFFF   # 0x1000007E -> 0x7E
    $hit = $script:CFBugchecks[[int]$n]
    if ($hit) { return [pscustomobject]@{ Code = ('0x{0:X}' -f $n); Name = $hit[0]; Category = $hit[1]; AlsoConsider = $hit[2] } }
    return [pscustomobject]@{ Code = ('0x{0:X}' -f $n); Name = 'unrecognized stop code'; Category = 'Unknown'; AlsoConsider = '' }
}

# Pull the informative lines out of a multi-line event message.
function Get-CFMessageDetail {
    param($Ev, [string]$Pattern)
    if (-not $Ev.Message) { return $Ev.Summary }
    $lines = @($Ev.Message -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match $Pattern })
    if ($lines.Count) { return ($lines -join '; ') }
    return $Ev.Summary
}

function Format-CFTime { param($t) if ($t) { return $t.ToString('yyyy-MM-dd HH:mm') } return '?' }

function Get-CFNum {
    param($v)
    $d = 0.0
    if ("$v" -ne '' -and [double]::TryParse("$v", [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
    return $null
}

# Incidents whose timing is good enough to correlate with nearby events.
function Get-CFCorrelatable { param($Incidents) @($Incidents | Where-Object { $_.TimingConfidence -in 'High', 'Medium' }) }

function Get-CFRuleWhea {
    param($Events, $Incidents)
    $whea = @($Events | Where-Object { $_.Key -eq 'WHEA' })
    $bootErrors = @($Incidents | Where-Object { $_.WheaBootErrors -gt 0 })
    if (-not $whea.Count -and -not $bootErrors.Count) { return }
    $fatal = @($whea | Where-Object { $_.Id -in 1, 18, 20, 46 })
    $corrected = @($whea | Where-Object { $_.Id -in 19, 47 })
    $pcie = @($whea | Where-Object { $_.Id -eq 17 })
    $inWin = @(Get-CFCorrelatable $Incidents | Where-Object { $_.Precursors | Where-Object { $_.Key -eq 'WHEA' } }).Count

    $score = 0
    if ($fatal.Count) { $score += 60 + 10 * [math]::Min((Measure-CFDistinctOccurrences -Times @($fatal.Time)), 4) }
    if ($corrected.Count) { $score += 30 + 5 * [math]::Min((Measure-CFDistinctOccurrences -Times @($corrected.Time)), 6) }
    if ($pcie.Count) { $score += 12 + 2 * [math]::Min($pcie.Count, 6) }
    if ($bootErrors.Count) { $score += 30 }
    $score += 30 * $inWin

    $ev = @()
    if ($whea.Count) { $ev += "$($whea.Count) WHEA hardware error events: $($fatal.Count) fatal, $($corrected.Count) corrected CPU/memory, $($pcie.Count) corrected PCIe" }
    if ($fatal | Where-Object { $_.Id -eq 46 }) { $ev += 'Fatal memory errors (WHEA 46) point at RAM or the memory controller' }
    if ($bootErrors.Count) { $ev += "Windows reported hardware errors at boot after $($bootErrors.Count) unexpected shutdown(s) (Kernel-Power 41 WHEABootErrorCount)" }
    if ($inWin) { $ev += "WHEA errors were logged within 15 minutes before $inWin unexpected shutdown(s)" }
    $details = $whea | ForEach-Object { Get-CFMessageDetail $_ 'Component|Error Source|Error Type|Device Name|Primary Bus|Processor APIC' } |
        Group-Object | Sort-Object Count -Descending | Select-Object -First 4
    foreach ($d in $details) { $ev += "$($d.Count)x $($d.Name)" }
    $title = if ($fatal.Count -or $bootErrors.Count) { 'Fatal hardware errors (WHEA) were logged' } elseif ($corrected.Count) { 'Corrected CPU/memory hardware errors (WHEA)' } else { 'Corrected PCIe errors (WHEA 17). Often harmless link noise, but worth checking if they recur' }
    New-CFFinding -Category 'Hardware' -Title $title -Score $score -Evidence $ev
}

function Get-CFRuleGpu {
    param($Events, $Incidents, $Artifacts)
    $gpuEvents = @($Events | Where-Object { $_.Category -eq 'GPU' })
    $werGpu = @($Events | Where-Object { $_.Key -eq 'WER' -and $_.Norm.IsGpuLiveKernel })
    $lkr = @($Artifacts.LiveKernelReports | Where-Object { $_.Class -eq 'GPU' })
    $werFolders = @($Artifacts.WerReports | Where-Object { $_.Folder -match '^Kernel_(141|117|1a8|193|116)_' })
    $times = @($gpuEvents.Time) + @($werGpu.Time) + @($lkr.Time) + @($werFolders.Time) | Where-Object { $_ }
    if (-not @($times).Count) { return }
    $occ = Measure-CFDistinctOccurrences -Times $times
    $inWin = @(Get-CFCorrelatable $Incidents | Where-Object { $_.Precursors | Where-Object { $_.Category -eq 'GPU' -or ($_.Key -eq 'WER' -and $_.Norm.IsGpuLiveKernel) } }).Count
    $score = 25 + 6 * [math]::Min($occ, 6) + 30 * $inWin

    $ev = @("$occ separate GPU hang/timeout occurrence(s) (related reports within 2 minutes counted once)")
    $tdr = @($gpuEvents | Where-Object { $_.Key -eq 'TDR' }).Count
    if ($tdr) { $ev += "$tdr display driver timeouts (Display 4101 - 'driver stopped responding and has recovered')" }
    foreach ($g in @($gpuEvents | Where-Object { $_.Key -eq 'GPUDriver' } | Group-Object Provider)) { $ev += "$($g.Count) error/warning events from GPU driver '$($g.Name)'" }
    if ($werGpu.Count) { $ev += "$($werGpu.Count) LiveKernelEvent GPU reports (codes: $((($werGpu | ForEach-Object { $_.Norm.P1 }) | Select-Object -Unique) -join ', '))" }
    if ($lkr.Count) { $ev += "$($lkr.Count) GPU watchdog dumps in LiveKernelReports (latest $(Format-CFTime $lkr[0].Time))" }
    if ($werFolders.Count) { $ev += "$($werFolders.Count) WER kernel GPU reports" }
    if ($inWin) { $ev += "GPU problems were logged within 15 minutes before $inWin unexpected shutdown(s)" }
    New-CFFinding -Category 'GPU' -Title 'The graphics driver is timing out / hanging' -Score $score -Evidence $ev
}

function Get-CFRuleStorage {
    param($Events, $Incidents, $Hardware)
    $st = @($Events | Where-Object { $_.Category -eq 'Storage' })
    if ($st.Count) {
        $occ = Measure-CFDistinctOccurrences -Times @($st.Time)
        $inWin = @(Get-CFCorrelatable $Incidents | Where-Object { $_.Precursors | Where-Object { $_.Category -eq 'Storage' } }).Count
        $ev = @("$($st.Count) storage error events in $occ separate episode(s)")
        $ev += @($st | Group-Object Provider, Id | Sort-Object Count -Descending | Select-Object -First 5 | ForEach-Object {
                $sample = $_.Group[0]
                "$($_.Count)x $($sample.Provider) $($sample.Id): $($sample.Summary)"
            })
        if ($inWin) { $ev += "Storage errors were logged within 15 minutes before $inWin unexpected shutdown(s)" }
        New-CFFinding -Category 'Storage' -Title 'Disk or storage controller errors / timeouts' -Score (30 + 6 * [math]::Min($occ, 6) + 30 * $inWin) -Evidence $ev
    }
    foreach ($d in @($Hardware.Disks)) {
        $problems = @(); $score = 0
        if ($d.Health -and $d.Health -ne 'Healthy') { $problems += "health status is $($d.Health)"; $score += 50 }
        if ((Get-CFNum $d.ReadErrorsUncorr) -gt 0) { $problems += "$($d.ReadErrorsUncorr) uncorrected read errors"; $score += 30 }
        if ((Get-CFNum $d.WriteErrorsUncorr) -gt 0) { $problems += "$($d.WriteErrorsUncorr) uncorrected write errors"; $score += 30 }
        if ((Get-CFNum $d.WearPercent) -ge 90) { $problems += "wear at $($d.WearPercent)%"; $score += 20 }
        if ((Get-CFNum $d.TemperatureMaxC) -ge 75) { $problems += "has reached $($d.TemperatureMaxC) C"; $score += 10 }
        if ($problems.Count) { New-CFFinding -Category 'Storage' -Title "Drive '$($d.Name)' reports problems" -Score $score -Evidence @($problems -join ', ') }
    }
    foreach ($s in @($Hardware.SmartPredictFailure | Where-Object { $_.PredictFailure })) {
        New-CFFinding -Category 'Storage' -Title 'SMART predicts a drive failure' -Score 70 -Evidence @("$($s.Instance) (reason code $($s.Reason))")
    }
    foreach ($v in @($Hardware.Volumes | Where-Object { $_.Drive -eq "$($env:SystemDrive)" -and (Get-CFNum $_.FreePercent) -lt 10 })) {
        New-CFFinding -Category 'Storage' -Title "System drive is nearly full ($($v.FreePercent)% free)" -Score 15 -Evidence @("$($v.Drive) has $($v.Free) free of $($v.Size)") -Recommendation @('Free up space on the system drive: at least 15% free keeps updates, the page file and crash dumps working.')
    }
}

function Get-CFRuleMemory {
    param($Events, $Incidents, $System)
    foreach ($e in @($Events | Where-Object { $_.Key -eq 'MemDiag' -and $_.Norm.Result -eq 'Fail' })) {
        $ev = @("$(Format-CFTime $e.Time): Windows Memory Diagnostic reported hardware errors (event $($e.Id))")
        if ($null -ne $e.Norm.PSObject.Properties['BadPages'] -and "$($e.Norm.BadPages)" -ne '') { $ev += "Bad memory pages found: $($e.Norm.BadPages)" }
        New-CFFinding -Category 'Memory' -Title 'Windows Memory Diagnostic found RAM errors' -Score 90 -Evidence $ev
    }
    $rx = @($Events | Where-Object { $_.Key -eq 'ResExhaustion' })
    if ($rx.Count) {
        $occ = Measure-CFDistinctOccurrences -Times @($rx.Time) -WindowSec 600
        $inWin = @(Get-CFCorrelatable $Incidents | Where-Object { $_.Precursors | Where-Object { $_.Key -eq 'ResExhaustion' } }).Count
        $ev = @("$($rx.Count) 'low on virtual memory' events (Resource-Exhaustion-Detector 2004) in $occ episode(s)")
        $procs = $rx | ForEach-Object { if ($_.Message -match 'most virtual memory:\s*(.+?)(\.\s|$)') { $Matches[1] } } | Select-Object -First 2
        foreach ($p in $procs) { $ev += "Top consumers: $p" }
        if ($inWin) { $ev += "Memory ran low within 15 minutes before $inWin unexpected shutdown(s)" }
        New-CFFinding -Category 'Memory' -Title 'Windows ran out of memory' -Score (30 + 10 * [math]::Min($occ, 4) + 30 * $inWin) -Evidence $ev
    }
    $mem = @($System.Memory)
    $fast = @($mem | Where-Object { ($_.Type -eq 'DDR4' -and (Get-CFNum $_.ConfiguredMHz) -gt 3200) -or ($_.Type -eq 'DDR5' -and (Get-CFNum $_.ConfiguredMHz) -gt 5600) -or ($_.Type -eq 'DDR3' -and (Get-CFNum $_.ConfiguredMHz) -gt 1600) })
    if ($fast.Count) {
        New-CFFinding -Category 'Memory' -Title 'RAM runs above standard speed (XMP/EXPO overclock profile likely enabled)' -Score 12 -Evidence @("$($fast[0].Type) configured at $($fast[0].ConfiguredMHz) MT/s. Memory overclocks are a common cause of random freezes.")
    }
    $parts = @($mem | ForEach-Object { $_.PartNumber } | Where-Object { $_ } | Select-Object -Unique)
    if ($parts.Count -gt 1) {
        New-CFFinding -Category 'Memory' -Title 'Mixed RAM modules installed' -Score 8 -Evidence @("Different part numbers: $($parts -join ', '). Mismatched kits can be unstable at XMP speeds.")
    }
}

function Get-CFRuleThermal {
    param($Events, $Incidents, $Hardware)
    $th = @($Events | Where-Object { $_.Key -eq 'Throttle' })
    if ($th.Count) {
        $occ = Measure-CFDistinctOccurrences -Times @($th.Time) -WindowSec 600
        $inWin = @(Get-CFCorrelatable $Incidents | Where-Object { $_.Precursors | Where-Object { $_.Key -eq 'Throttle' } }).Count
        $ev = @("$($th.Count) events where firmware limited CPU speed (Kernel-Processor-Power 37), in $occ episode(s). Usually heat or power limits.")
        if ($inWin) { $ev += "Throttling was logged within 15 minutes before $inWin unexpected shutdown(s)" }
        New-CFFinding -Category 'Thermal' -Title 'CPU is being throttled by firmware' -Score (15 + 3 * [math]::Min($occ, 10) + 25 * $inWin) -Evidence $ev
    }
    foreach ($z in @($Hardware.ThermalZones | Where-Object { (Get-CFNum $_.TemperatureC) -ge 85 })) {
        New-CFFinding -Category 'Thermal' -Title 'High temperature reading right now' -Score 30 -Evidence @("$($z.Zone) at $($z.TemperatureC) C")
    }
}

function Get-CFRuleBugchecks {
    param($Incidents, $Artifacts)
    $findings = @{}
    foreach ($inc in @($Incidents | Where-Object { $_.Bugcheck })) {
        $info = Get-CFBugcheckInfo $inc.Bugcheck
        $ev = @("Shutdown #$($inc.Number) at $(Format-CFTime $inc.CrashTime) ended in stop code $($info.Code) ($($info.Name))")
        if ($info.AlsoConsider) { $ev += "Note: this stop code $($info.AlsoConsider)." }
        $score = if ($info.Category -eq 'Unknown') { 15 } else { 35 }
        $findings[$inc.Number] = New-CFFinding -Category $info.Category -Title "Blue screen $($info.Code) $($info.Name)" -Score $score -Evidence $ev
    }
    # Debugger results: a third-party driver is a lead; the Windows kernel is inconclusive.
    $blamed = @{}
    foreach ($a in @($Artifacts.DumpAnalysis | Where-Object { $_.Status -eq 'Ok' })) {
        $module = "$($a.MODULE_NAME)"; $image = "$($a.IMAGE_NAME)"
        $inc = $Incidents | Where-Object { $_.BootTime -and $a.DumpTime -ge $_.CrashTime.AddMinutes(-5) -and $a.DumpTime -le $_.BootTime.AddMinutes(15) } | Select-Object -First 1
        $generic = (-not $module -or $module -match $script:CFGenericModules) -and (-not $image -or $image -match $script:CFGenericModules)
        $line = if ($generic) { "Debugger analysis of $($a.Dump) was inconclusive: it points at the Windows kernel ($module), which usually means the real cause is elsewhere (driver, RAM or hardware)." }
        else { "Debugger analysis of $($a.Dump) points at $image ($module). Probable, not proven." }
        if ($inc -and $findings.ContainsKey($inc.Number)) { $findings[$inc.Number].Evidence += $line }
        if (-not $generic -and $image -match '\.sys$' -and -not $blamed.ContainsKey($image)) {
            $blamed[$image] = $true
            New-CFFinding -Category 'Driver' -Title "Debugger analysis points at driver $image" -Score 20 -Evidence @("$($a.Dump): $($a.BUGCHECK_STR) - bucket $($a.FAILURE_BUCKET_ID). Treat this as a lead, not proof.")
        }
    }
    $findings.Values
}

function Get-CFRuleSilent {
    param($Incidents)
    $reboots = @($Incidents | Where-Object { $_.BootTime })
    if (-not $reboots.Count) { return }
    $silent = @($reboots | Where-Object { -not $_.Bugcheck -and -not @($_.Precursors | Where-Object { $_.Category -notin $script:CFWeakCategories }).Count })
    if (-not $silent.Count) { return }
    $sure = @($silent | Where-Object { $_.TimingConfidence -in 'High', 'Medium' })
    $unsure = $silent.Count - $sure.Count
    $ev = @("$($silent.Count) of $($reboots.Count) unexpected shutdowns had no blue screen and no hardware/driver warnings in the 15 minutes before the last sign of life")
    if ($unsure) { $ev += "For $unsure of them the exact time is uncertain (a long gap with nothing logged before the reboot)." }
    $kinds = $silent | Group-Object Kind | ForEach-Object { "$($_.Count)x $($_.Name)" }
    $ev += "Kinds: $($kinds -join ', ')"
    $pb = @($silent | Where-Object { $_.PowerButton -or $_.LongPress }).Count
    if ($pb) { $ev += "The power button was used to turn the PC off $pb time(s), consistent with it being unresponsive." }
    $slept = @($silent | Where-Object { $_.SleepInProgress }).Count
    if ($slept) { $ev += "$slept happened during sleep/resume. Suspect sleep states or chipset/GPU drivers." }
    if (Test-CFSourceGap -Sources @($script:CFSourceStatus | Where-Object { $_.Source -like 'Event log:*' -or $_.Source -like '* log history' } | ForEach-Object { $_.Source })) {
        $ev += 'Caveat: some event sources were truncated or unreadable (see Data coverage), so "nothing logged" may be incomplete.'
    }
    New-CFFinding -Category 'Silent' -Title 'Unexpected shutdowns that left no trace in the logs' -Score (20 + 12 * [math]::Min($sure.Count, 5) + 6 * [math]::Min($unsure, 5)) -Evidence $ev
}

function Get-CFRuleChanges {
    param($Events, $Incidents, $Changes, [datetime]$Since, $Coverage)
    $reboots = @($Incidents | Where-Object { $_.BootTime })
    if (-not $reboots.Count) { return }
    $first = ($reboots | Sort-Object CrashTime | Select-Object -First 1).CrashTime
    # Only claim the problem "started" if we can see at least 3 quiet days before it.
    $visibleFrom = $Since
    if ($Coverage -and $Coverage.System -and $Coverage.System -gt $visibleFrom) { $visibleFrom = $Coverage.System }
    if (($first - $visibleFrom).TotalDays -lt 3) { return }
    $before = @(Get-CFChangeTimeline -Changes $Changes -Events $Events | Where-Object { $_.Time -le $first -and $_.Time -ge $first.AddDays(-7) })
    if (-not $before.Count) { return }
    $drivers = @($before | Where-Object { $_.Kind -match 'Driver|Device' })
    $ev = @("The first unexpected shutdown the logs show was at $(Format-CFTime $first). These completed changes happened in the 7 days before it (a timing coincidence, not proof):")
    $ev += @($before | Select-Object -First 8 | ForEach-Object { "$(Format-CFTime $_.Time) [$($_.Kind)] $($_.Name)" })
    if ($before.Count -gt 8) { $ev += "...and $($before.Count - 8) more (see Recent changes)" }
    New-CFFinding -Category 'Change' -Title 'Changes shortly before the first unexpected shutdown' -Score (15 + 3 * [math]::Min($before.Count, 5) + 8 * [math]::Min($drivers.Count, 2)) -Evidence $ev
}

function Get-CFRuleApps {
    param($Events)
    $crashes = @($Events | Where-Object { $_.Key -eq 'AppCrash' -and $_.Norm.Module })
    foreach ($g in @($crashes | Group-Object { $_.Norm.Module } | Where-Object { $_.Count -ge 3 } | Sort-Object Count -Descending | Select-Object -First 3)) {
        $apps = ($g.Group | ForEach-Object { $_.Norm.App } | Select-Object -Unique | Select-Object -First 4) -join ', '
        if ($g.Name -match '^(nv|ati|amd|igd|ig\d|igxel|igc)') {
            New-CFFinding -Category 'GPU' -Title "Graphics driver module $($g.Name) keeps crashing apps" -Score (15 + 2 * [math]::Min($g.Count, 10)) -Evidence @("$($g.Count) crashes in: $apps")
        } else {
            New-CFFinding -Category 'App' -Title "Module $($g.Name) crashed $($g.Count) times" -Score (5 + 2 * [math]::Min($g.Count, 10)) -Evidence @("Apps affected: $apps")
        }
    }
    $shell = @($Events | Where-Object { $_.Key -eq 'AppHang' -and $_.Norm.App -in 'explorer.exe', 'dwm.exe', 'ShellExperienceHost.exe', 'StartMenuExperienceHost.exe' })
    if ($shell.Count -ge 2) {
        New-CFFinding -Category 'App' -Title 'Windows shell/desktop processes hang repeatedly' -Score (10 + 3 * [math]::Min($shell.Count, 8)) -Evidence @("$($shell.Count) hangs of explorer/dwm. System-wide stalls like this often come from storage or GPU problems.")
    }
}

function Get-CFRuleServices {
    param($Events)
    $svc = @($Events | Where-Object { $_.Key -eq 'ServiceCrash' -and $_.Norm.Service } | Group-Object { $_.Norm.Service } | Where-Object { $_.Count -ge 3 } | Sort-Object Count -Descending | Select-Object -First 3)
    foreach ($g in $svc) { New-CFFinding -Category 'Service' -Title "Service '$($g.Name)' crashed or hung $($g.Count) times" -Score (5 + [math]::Min($g.Count, 10)) }
}

function Get-CFRuleConfig {
    param($Events, $System)
    if ("$($System.CrashDumpEnabled)" -eq '0') {
        New-CFFinding -Category 'Config' -Title 'Crash dumps are turned off' -Score 15 -Evidence @('CrashControl\CrashDumpEnabled = 0, so blue screens leave no dump to analyse') -Recommendation @('Enable dumps: System Properties > Advanced > Startup and Recovery > Write debugging information: Automatic memory dump.')
    }
    $df = @($Events | Where-Object { $_.Key -eq 'DumpFailure' })
    if ($df.Count) {
        New-CFFinding -Category 'Config' -Title 'Windows could not write a crash dump' -Score 15 -Evidence @($df | Select-Object -First 3 | ForEach-Object { "$(Format-CFTime $_.Time): $($_.Summary)" }) -Recommendation @('Keep a system-managed page file on C: and enough free space so crash dumps can be written.')
    }
    if ($null -ne $System.PSObject.Properties['Pagefiles'] -and -not @($System.Pagefiles).Count -and $System.AutoPagefile -eq $false) {
        New-CFFinding -Category 'Config' -Title 'No page file' -Score 10 -Evidence @('Without a page file Windows cannot write crash dumps and runs out of memory sooner') -Recommendation @('Set the page file back to "System managed size".')
    }
    if ($System.BiosDate -and ((Get-Date) - [datetime]$System.BiosDate).TotalDays -gt 730) {
        $bd = [datetime]$System.BiosDate
        New-CFFinding -Category 'Config' -Title "BIOS/UEFI firmware is $([int](((Get-Date) - $bd).TotalDays / 365)) years old" -Score 10 -Evidence @("$($System.BiosVersion) dated $($bd.ToString('yyyy-MM-dd'))") -Recommendation @('Check the motherboard/laptop maker''s support page for a BIOS update; updates often fix stability issues (especially on newer CPUs).')
    }
    if ($System.FastStartup -eq $true) {
        New-CFFinding -Category 'Config' -Title 'Fast Startup is on' -Score 5 -Evidence @('Fast Startup hibernates the kernel and drivers instead of restarting them fresh') -Recommendation @('As a test, turn off Fast Startup: Control Panel > Power Options > Choose what the power buttons do.')
    }
}

# Heartbeat rows just before each incident. Memory exhaustion and heat are
# findings; ordinary CPU/GPU load is only context.
function Get-CFRuleHeartbeat {
    param($Incidents)
    foreach ($inc in @($Incidents | Where-Object { @($_.HeartbeatTail).Count })) {
        $tail = @($inc.HeartbeatTail | Where-Object { "$($_.Event)" -ne 'stop' })
        $stat = { param($prop, $op) $v = @($tail | ForEach-Object { Get-CFNum $_.$prop } | Where-Object { $null -ne $_ }); if (-not $v.Count) { return $null }; if ($op -eq 'max') { ($v | Measure-Object -Maximum).Maximum } else { ($v | Measure-Object -Minimum).Minimum } }
        $label = "Shutdown #$($inc.Number) ($(Format-CFTime $inc.CrashTime))"
        $avail = & $stat 'AvailMB' 'min'; $commit = & $stat 'CommitPct' 'max'
        $temp = & $stat 'TempC' 'max'; $queue = & $stat 'DiskQueue' 'max'
        $gpu = & $stat 'GpuPct' 'max'; $cpu = & $stat 'CpuPct' 'max'; $age = & $stat 'SampleAgeSec' 'max'
        if (($null -ne $avail -and $avail -lt 300) -or $commit -gt 92) { New-CFFinding -Category 'Memory' -Title 'Memory was nearly exhausted right before an unexpected shutdown' -Score 35 -Evidence @("${label}: min available $avail MB, max commit $commit%") }
        if ($temp -ge 90) { New-CFFinding -Category 'Thermal' -Title 'Temperature was very high right before an unexpected shutdown' -Score 35 -Evidence @("${label}: thermal zone reached $temp C") }
        if ($queue -ge 10) { New-CFFinding -Category 'Storage' -Title 'Disk queue backed up right before an unexpected shutdown' -Score 25 -Evidence @("${label}: disk queue length reached $queue") }
        $ctx = @()
        if ($cpu -ge 95) { $ctx += "CPU was at $cpu% (heavy load: cooling or power delivery is worth checking)" }
        if ($gpu -ge 95) { $ctx += "GPU 3D engine was at $gpu%" }
        if ($age -ge 30) { $ctx += "Heartbeat readings were $age s old: the system was struggling to answer performance queries" }
        $inc.Context = @($inc.Context) + $ctx
    }
}

function Invoke-CFAnalysis {
    param($Data, [datetime]$Since, [int]$WindowMinutes = 15)
    $events = @($Data.Events)
    $incidents = @($Data.Incidents)

    # Kernel live dumps become pseudo-events in their own class (not all are GPU).
    $classMap = @{ GPU = 'GPU'; USB = 'USB'; Network = 'Network'; Storage = 'Storage'; Unknown = 'Other' }
    $lkrEvents = @($Data.Artifacts.LiveKernelReports | Where-Object { $_ } | ForEach-Object {
            $cat = $classMap["$($_.Class)"]; if (-not $cat) { $cat = 'Other' }
            [pscustomobject]@{ Time = [datetime]$_.Time; Log = 'File'; Provider = 'LiveKernelReports'; Id = 0; Level = ''; Category = $cat; Key = 'LiveKernelReport'; Summary = "$($_.Type) live dump $($_.Name) ($($_.Class))"; Message = ''; Data = @{}; Norm = [pscustomobject]@{} }
        })
    $windowPool = @($events + $lkrEvents | Where-Object { $_.Category -in $script:CFPrecursorCategories })

    foreach ($inc in $incidents) {
        $from = $inc.CrashTime.AddMinutes(-$WindowMinutes)
        $to = $inc.CrashTime.AddMinutes(1)
        if ($inc.BootTime -and $to -gt $inc.BootTime) { $to = $inc.BootTime }
        $inc.Precursors = @($windowPool | Where-Object { $_.Time -ge $from -and $_.Time -le $to } | Sort-Object Time)
        $inc.HeartbeatTail = @($Data.Heartbeat | Where-Object { $_.Time -ge $inc.CrashTime.AddMinutes(-5) -and $_.Time -le $inc.CrashTime })
        $inc.Context = @()
    }

    $items = @(
        Get-CFRuleWhea -Events $events -Incidents $incidents
        Get-CFRuleGpu -Events $events -Incidents $incidents -Artifacts $Data.Artifacts
        Get-CFRuleStorage -Events $events -Incidents $incidents -Hardware $Data.Hardware
        Get-CFRuleMemory -Events $events -Incidents $incidents -System $Data.System
        Get-CFRuleThermal -Events $events -Incidents $incidents -Hardware $Data.Hardware
        Get-CFRuleBugchecks -Incidents $incidents -Artifacts $Data.Artifacts
        Get-CFRuleSilent -Incidents $incidents
        Get-CFRuleChanges -Events $events -Incidents $incidents -Changes $Data.Changes -Since $Since -Coverage $Data.Coverage
        Get-CFRuleApps -Events $events
        Get-CFRuleServices -Events $events
        Get-CFRuleConfig -Events $events -System $Data.System
        Get-CFRuleHeartbeat -Incidents $incidents
    ) | Where-Object { $_ }

    $ranked = @($items | Group-Object Category | ForEach-Object {
            $cat = $_.Name
            $info = $script:CFCategoryInfo[$cat]
            $score = [math]::Min(100, ($_.Group | Measure-Object Score -Sum).Sum)
            $recs = @($_.Group | ForEach-Object { $_.Recommendation }) + @($info.Recs) | Where-Object { $_ } | Select-Object -Unique
            [pscustomobject]@{
                Category       = $cat
                Name           = $info.Name
                Score          = [int]$score
                Severity       = if ($score -ge 60) { 'High' } elseif ($score -ge 30) { 'Medium' } else { 'Low' }
                Items          = @($_.Group | Sort-Object Score -Descending)
                Recommendation = @($recs)
            }
        } | Sort-Object Score -Descending)

    $reboots = @($incidents | Where-Object { $_.BootTime })
    $uptimes = @($reboots | Where-Object { $_.Uptime } | ForEach-Object { $_.Uptime.TotalHours } | Sort-Object)
    $unavailable = [bool]$Data.IncidentsUnavailable
    $stats = [pscustomobject]@{
        Incidents         = if ($unavailable) { $null } else { $reboots.Count }
        IncidentsUnavailable = $unavailable
        UserReported      = @($incidents | Where-Object { -not $_.BootTime }).Count
        Kinds             = @($reboots | Group-Object Kind | ForEach-Object { [pscustomobject]@{ Kind = $_.Name; Count = $_.Count } })
        Bugchecks         = @($reboots | Where-Object { $_.Bugcheck }).Count
        PowerButton       = @($reboots | Where-Object { $_.PowerButton -or $_.LongPress }).Count
        WithPrecursors    = @($reboots | Where-Object { @($_.Precursors | Where-Object { $_.Category -notin $script:CFWeakCategories }).Count }).Count
        UncertainTiming   = @($reboots | Where-Object { $_.TimingConfidence -eq 'Low' }).Count
        MedianUptimeH     = if ($uptimes.Count) { [math]::Round($uptimes[[int][math]::Floor(($uptimes.Count - 1) / 2)], 1) } else { $null }
        MinUptimeH        = if ($uptimes.Count) { [math]::Round($uptimes[0], 1) } else { $null }
        MaxUptimeH        = if ($uptimes.Count) { [math]::Round($uptimes[-1], 1) } else { $null }
        LastIncident      = if ($reboots.Count) { ($reboots | Sort-Object CrashTime | Select-Object -Last 1).CrashTime } else { $null }
        HeartbeatRows     = @($Data.Heartbeat).Count
    }

    return [pscustomobject]@{ Findings = $ranked; Stats = $stats }
}
