# Crash artifacts on disk: minidumps, full memory dump, LiveKernelReports, WER reports.

# Where Windows is configured to write dumps (CrashControl), with defaults.
function Get-CFDumpPaths {
    $mini = "$env:SystemRoot\Minidump"; $full = "$env:SystemRoot\MEMORY.DMP"
    try {
        $cc = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -ErrorAction Stop
        if ($cc.MinidumpDir) { $mini = [Environment]::ExpandEnvironmentVariables($cc.MinidumpDir) }
        if ($cc.DumpFile) { $full = [Environment]::ExpandEnvironmentVariables($cc.DumpFile) }
    } catch { }
    return [pscustomobject]@{ MinidumpDir = $mini; DumpFile = $full }
}

# Classifies a LiveKernelReports dump by its folder/file name. Only GPU-class
# dumps count as GPU evidence; USB/network/unknown watchdogs are shown but not scored.
function Get-CFLiveDumpClass {
    param([string]$Type, [string]$Name)
    $s = "$Type $Name"
    if ($s -match '(^|[\\\s_-])(141|117|1a8|193|1b0|116)([\\\s_-]|$)' -or $s -match 'VIDEO|dxgkrnl|WATCHDOG') { return 'GPU' }
    if ($s -match 'USBHUB|USBXHCI|UCX') { return 'USB' }
    if ($s -match 'NDIS|NetAdapter|NETIO') { return 'Network' }
    if ($s -match 'StorPort|stornvme|storahci') { return 'Storage' }
    return 'Unknown'
}

function Find-CFDebugger {
    $roots = @(${env:ProgramFiles(x86)}, $env:ProgramFiles) | Where-Object { $_ }
    $archs = switch ($env:PROCESSOR_ARCHITECTURE) { 'ARM64' { @('arm64', 'x64', 'x86') } 'x86' { @('x86') } default { @('x64', 'x86') } }
    foreach ($r in $roots) {
        foreach ($a in $archs) {
            $c = Join-Path $r "Windows Kits\10\Debuggers\$a\cdb.exe"
            if (Test-Path $c) { return $c }
        }
    }
    $cmd = Get-Command cdb.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return $null
}

function New-CFDebuggerArguments {
    param([string]$DumpPath, [string]$SymbolCache)
    $parts = @('-z', $DumpPath, '-y', "srv*$SymbolCache*https://msdl.microsoft.com/download/symbols", '-c', '!analyze -v; q')
    return (($parts | ForEach-Object { ConvertTo-CFArgument $_ }) -join ' ')
}

# Runs "!analyze -v" on a dump with cdb. Returns a result with a Status so a
# failed run is visible instead of looking like an empty analysis.
function Invoke-CFDumpAnalysis {
    param([string]$Cdb, $Dump, [int]$TimeoutSec = 180)
    $result = [ordered]@{ Dump = $Dump.Name; DumpTime = $Dump.Time; Status = 'Ok'; ExitCode = $null; Error = $null }
    try {
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $Cdb
        $psi.Arguments = New-CFDebuggerArguments -DumpPath $Dump.Path -SymbolCache (Join-Path $env:TEMP 'IcePickSymbols')
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.CreateNoWindow = $true
        $p = [Diagnostics.Process]::Start($psi)
        $outTask = $p.StandardOutput.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            try { $p.Kill() } catch { }
            $result.Status = 'TimedOut'; $result.Error = "no result within $TimeoutSec s"
            return [pscustomobject]$result
        }
        $out = $outTask.Result
        $result.ExitCode = $p.ExitCode
        $result.RawOutput = $out
        foreach ($field in 'BUGCHECK_CODE', 'BUGCHECK_STR', 'MODULE_NAME', 'IMAGE_NAME', 'PROCESS_NAME', 'FAILURE_BUCKET_ID') {
            if ($out -match "(?m)^$field\s*:\s*(.+)$") { $result[$field] = $Matches[1].Trim() }
        }
        if (-not ($result.Contains('BUGCHECK_CODE') -or $result.Contains('FAILURE_BUCKET_ID'))) {
            $result.Status = 'Failed'
            $result.Error = (($out -split "`r?`n" | Where-Object { $_ -match 'error|fail|cannot|unable' } | Select-Object -First 3) -join ' / ')
            if (-not $result.Error) { $result.Error = "cdb exited with code $($p.ExitCode) without an analysis" }
        }
    } catch {
        $result.Status = 'Failed'; $result.Error = $_.Exception.Message
    }
    return [pscustomobject]$result
}

function Get-CFCrashArtifacts {
    param([datetime]$Since, [switch]$SkipSlow, $DumpPaths)
    $art = [ordered]@{}
    $paths = if ($DumpPaths) { $DumpPaths } else { Get-CFDumpPaths }
    $art.DumpPaths = $paths

    # All minidumps are listed; only those inside the scan window are analysed and scored.
    $art.Minidumps = @(Get-ChildItem $paths.MinidumpDir -Filter *.dmp -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; Time = $_.LastWriteTime; Size = Format-CFBytes $_.Length; InWindow = ($_.LastWriteTime -ge $Since); Path = $_.FullName }
        })
    if (-not (Test-Path $paths.MinidumpDir -ErrorAction SilentlyContinue)) { Set-CFSourceStatus -Source 'Minidumps' -Status Complete -Detail "folder $($paths.MinidumpDir) does not exist" }
    else { Set-CFSourceStatus -Source 'Minidumps' -Status Complete }

    $art.MemoryDump = $null
    $md = Get-Item $paths.DumpFile -ErrorAction SilentlyContinue
    if ($md) { $art.MemoryDump = [pscustomobject]@{ Path = $md.FullName; Time = $md.LastWriteTime; Size = Format-CFBytes $md.Length; InWindow = ($md.LastWriteTime -ge $Since) } }

    $lkrRoot = "$env:SystemRoot\LiveKernelReports"
    $lkrError = $null
    $art.LiveKernelReports = @(Get-ChildItem $lkrRoot -Recurse -Filter *.dmp -ErrorAction SilentlyContinue -ErrorVariable lkrError |
            Where-Object { $_.LastWriteTime -ge $Since } | Sort-Object LastWriteTime -Descending | ForEach-Object {
                [pscustomobject]@{ Type = $_.Directory.Name; Class = (Get-CFLiveDumpClass -Type $_.Directory.Name -Name $_.Name); Name = $_.Name; Time = $_.LastWriteTime; Size = Format-CFBytes $_.Length }
            })
    if ($lkrError | Where-Object { $_.Exception -is [UnauthorizedAccessException] }) { Set-CFSourceStatus -Source 'LiveKernelReports' -Status Unavailable -Detail 'access denied (run as administrator)' }
    else { Set-CFSourceStatus -Source 'LiveKernelReports' -Status Complete }

    # WER report folders (kernel + app). Folder names look like Kernel_141_..., AppHang_..., AppCrash_...
    $werRoots = @("$env:ProgramData\Microsoft\Windows\WER\ReportArchive", "$env:ProgramData\Microsoft\Windows\WER\ReportQueue")
    $werDenied = 0
    $art.WerReports = @(foreach ($w in $werRoots) {
            Get-ChildItem $w -Directory -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $Since } | ForEach-Object {
                $eventType = $null; $app = $null
                $wer = Join-Path $_.FullName 'Report.wer'
                try {
                    $txt = Get-Content $wer -Encoding Unicode -ErrorAction Stop
                    $eventType = ($txt | Where-Object { $_ -like 'EventType=*' } | Select-Object -First 1) -replace '^EventType=', ''
                    $app = ($txt | Where-Object { $_ -like 'AppName=*' } | Select-Object -First 1) -replace '^AppName=', ''
                } catch [UnauthorizedAccessException] { $werDenied++ } catch { }
                [pscustomobject]@{ Folder = $_.Name; Time = $_.LastWriteTime; EventType = $eventType; App = $app; Queue = (Split-Path $w -Leaf) }
            }
        }) | Sort-Object Time -Descending
    if ($werDenied) { Set-CFSourceStatus -Source 'WER report details' -Status Unavailable -Detail "$werDenied report(s) could not be read (run as administrator)" }
    else { Set-CFSourceStatus -Source 'WER report details' -Status Complete }

    $art.DumpAnalysis = @()
    $cdb = Find-CFDebugger
    $art.DebuggerFound = [bool]$cdb
    $inWindow = @($art.Minidumps | Where-Object { $_.InWindow })
    if ($cdb -and $inWindow.Count) {
        if ($SkipSlow) { Add-CFSkipped 'Dump analysis' 'quick scan' }
        else {
            Write-CFLog 'Windows debugger found - analysing up to 3 recent minidumps (can take a few minutes)' 'STEP'
            $art.DumpAnalysis = @($inWindow | Select-Object -First 3 | ForEach-Object { Invoke-CFDumpAnalysis -Cdb $cdb -Dump $_ })
            $bad = @($art.DumpAnalysis | Where-Object { $_.Status -ne 'Ok' })
            if ($bad.Count) { Set-CFSourceStatus -Source 'Dump analysis' -Status Failed -Detail "$($bad.Count) of $($art.DumpAnalysis.Count) dumps could not be analysed: $($bad[0].Error)" }
            else { Set-CFSourceStatus -Source 'Dump analysis' -Status Complete }
        }
    }

    return [pscustomobject]$art
}
