<#
.SYNOPSIS
    Windows Forms front end for IcePick. Runs IcePick.ps1 in a background
    process (so the window stays responsive) and manages the freeze monitor.
    Launch with IcePick.cmd so it runs as administrator.
#>
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
try {
    Add-Type -Namespace IcePick -Name Native -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();' -ErrorAction Stop
    [void][IcePick.Native]::SetProcessDPIAware()
} catch { }
[Windows.Forms.Application]::EnableVisualStyles()

. (Join-Path $PSScriptRoot 'lib\Common.ps1')
. (Join-Path $PSScriptRoot 'lib\Monitor.ps1')
. (Join-Path $PSScriptRoot 'lib\Logo.ps1')

$script:Engine = Join-Path $PSScriptRoot 'IcePick.ps1'
$script:OutDir = Join-Path $PSScriptRoot 'IcePick-Output'
$script:HeartbeatDir = Join-Path $script:OutDir 'heartbeat'
$script:PsExe = (Get-Process -Id $PID).Path
$script:IsAdmin = Test-CFAdmin
$script:TaskName = 'IcePick Monitor'
$script:ScanProc = $null
$script:ScanLog = $null
$script:ScanOffset = 0
$script:ReportPath = $null
$script:FreezeTimes = New-Object System.Collections.Generic.List[datetime]
$script:StopRequestedAt = $null

# ---------- helpers ----------
# The window is built from layout panels and auto-sized controls, and every
# explicit size is a multiple of the font height ($script:Em). Nothing sits at
# a fixed pixel position, so larger text or a different DPI can never make a
# label paint over an input.
function New-Label([string]$text, $font, [int]$wrapEm = 0) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $text; $l.AutoSize = $true
    $l.Anchor = 'Left'                      # vertically centred in its row
    $l.Margin = New-Object Windows.Forms.Padding(3, 4, 3, 4)
    if ($font) { $l.Font = $font }
    if ($wrapEm) { $l.MaximumSize = New-Object Drawing.Size([int]($script:Em * $wrapEm), 0) }
    return $l
}
function New-Button([string]$text) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text; $b.AutoSize = $true; $b.AutoSizeMode = 'GrowAndShrink'
    $pad = [int]($script:Em * 0.5)
    $b.Padding = New-Object Windows.Forms.Padding($pad, [int]($script:Em * 0.15), $pad, [int]($script:Em * 0.15))
    $b.Anchor = 'Left'
    return $b
}
function New-Check([string]$text) {
    $c = New-Object Windows.Forms.CheckBox
    $c.Text = $text; $c.AutoSize = $true
    return $c
}
# A horizontal strip of controls.
function New-Row {
    $p = New-Object Windows.Forms.FlowLayoutPanel
    $p.FlowDirection = 'LeftToRight'; $p.WrapContents = $false; $p.AutoSize = $true; $p.AutoSizeMode = 'GrowAndShrink'
    $p.Margin = New-Object Windows.Forms.Padding(0)
    foreach ($c in $args) { $p.Controls.Add($c) }
    return $p
}
# A group box holding rows stacked top to bottom.
function New-Group([string]$text) {
    $stack = New-Object Windows.Forms.FlowLayoutPanel
    $stack.FlowDirection = 'TopDown'; $stack.WrapContents = $false; $stack.AutoSize = $true; $stack.AutoSizeMode = 'GrowAndShrink'
    $stack.Dock = 'Fill'
    foreach ($c in $args) { $stack.Controls.Add($c) }
    $g = New-Object Windows.Forms.GroupBox
    $g.Text = $text; $g.AutoSize = $true; $g.AutoSizeMode = 'GrowAndShrink'; $g.Dock = 'Fill'
    $g.Padding = New-Object Windows.Forms.Padding([int]($script:Em * 0.4))
    $g.Controls.Add($stack)
    return $g
}
# A one-row table: columns are AutoSize except the ones listed in $Stretch (share the rest).
function New-Strip([int[]]$Stretch) {
    $t = New-Object Windows.Forms.TableLayoutPanel
    $t.AutoSize = $true; $t.AutoSizeMode = 'GrowAndShrink'; $t.Dock = 'Fill'; $t.RowCount = 1
    $t.Margin = New-Object Windows.Forms.Padding(0)
    [void]$t.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize')))
    $t.ColumnCount = $args.Count
    for ($i = 0; $i -lt $args.Count; $i++) {
        if ($Stretch -contains $i) { [void]$t.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', (100 / $Stretch.Count)))) }
        else { [void]$t.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('AutoSize'))) }
        $t.Controls.Add($args[$i], $i, 0)
    }
    return $t
}
function Add-LogText([string]$text) {
    if (-not $text) { return }
    $log.AppendText(($text -replace "`r?`n", "`r`n"))
}
function Get-EngineArgs([string[]]$extra) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:Engine, '-OutputDir', $script:OutDir) + $extra
    return (($a | ForEach-Object { ConvertTo-CFArgument "$_" }) -join ' ')
}

# ---------- form ----------
$uiFont = New-Object Drawing.Font('Segoe UI', 9.5)
$bold = New-Object Drawing.Font('Segoe UI', 9.5, [Drawing.FontStyle]::Bold)
$title = New-Object Drawing.Font('Segoe UI Semibold', 15)
$script:Em = $uiFont.Height          # line height in pixels at the current DPI
$em = $script:Em

$form = New-Object Windows.Forms.Form
$form.SuspendLayout()
$form.Text = 'IcePick'
$form.Font = $uiFont
$form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::None   # sizes below already follow the font
$form.StartPosition = 'CenterScreen'
# Size from the font, but never larger than the screen.
$wa = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.ClientSize = New-Object Drawing.Size([math]::Min([int]($em * 52), $wa.Width - 40), [math]::Min([int]($em * 47), $wa.Height - 60))
$form.MinimumSize = New-Object Drawing.Size([math]::Min([int]($em * 46), $wa.Width - 40), [math]::Min([int]($em * 40), $wa.Height - 60))
try { $form.Icon = New-CFLogoIcon } catch { $form.Icon = [Drawing.SystemIcons]::Shield }

# Header
$titleLabel = New-Label 'IcePick' $title
$logoSize = [int]($em * 2.4)
$logoBox = New-Object Windows.Forms.PictureBox
$logoBox.Size = New-Object Drawing.Size($logoSize, $logoSize); $logoBox.Anchor = 'Left'
try { $logoBox.Image = New-CFLogoBitmap -Size $logoSize } catch { }
$titleRow = New-Row $logoBox $titleLabel
$descLabel = New-Label 'Finds out why this PC freezes or crashes. Scans event logs, hardware health, drivers, dumps and recent changes. Read-only.' $null 46
$adminLabel = New-Label '' $bold
$adminLabel.AutoSize = $false; $adminLabel.Dock = 'Fill'; $adminLabel.AutoEllipsis = $true; $adminLabel.TextAlign = 'MiddleLeft'
$elevate = New-Button 'Restart as administrator'
$adminStrip = New-Strip @(0) $adminLabel $elevate
if ($script:IsAdmin) {
    $adminLabel.Text = 'Running as administrator: all checks are available.'
    $adminLabel.ForeColor = [Drawing.Color]::FromArgb(0, 110, 0)
    $elevate.Visible = $false
} else {
    $adminLabel.Text = 'Not administrator: SMART, some logs and dumps will be skipped.'
    $adminLabel.ForeColor = [Drawing.Color]::FromArgb(170, 90, 0)
}

# 1. Scan
$days = New-Object Windows.Forms.NumericUpDown
$days.Minimum = 1; $days.Maximum = 365; $days.Value = 30; $days.Width = [int]($em * 3.5); $days.Anchor = 'Left'
$quick = New-Check 'Quick scan (skip the slowest checks)'
$includeDumps = New-Check 'Include crash dumps in the output folder'
$openWhenDone = New-Check 'Open the report when finished'
$openWhenDone.Checked = $true
$scanBtn = New-Button 'Scan now'
$scanBtn.Font = $bold
$progress = New-Object Windows.Forms.ProgressBar
$progress.Style = 'Marquee'; $progress.MarqueeAnimationSpeed = 0; $progress.Anchor = 'Left'
$progress.Size = New-Object Drawing.Size([int]($em * 9), [int]($em * 0.9))
$scanBox = New-Group '1. Scan for the cause' `
    (New-Row (New-Label 'Look back') $days (New-Label 'days')) $quick $includeDumps $openWhenDone (New-Row $scanBtn $progress)

# 2. Freeze monitor
$interval = New-Object Windows.Forms.NumericUpDown
$interval.Minimum = 5; $interval.Maximum = 300; $interval.Value = 10; $interval.Width = [int]($em * 3.5); $interval.Anchor = 'Left'
$monStatus = New-Label 'Checking...' $bold
$monStart = New-Button 'Start monitor'
$monStop = New-Button 'Stop'
$monTask = New-Button 'Start at logon'
$monBox = New-Group '2. Freeze monitor (for freezes that leave no trace)' `
    (New-Label "Logs CPU, memory, disk, GPU and temperature.`nAfter the next freeze, scan again.") `
    (New-Row (New-Label 'Every') $interval (New-Label 'seconds')) $monStatus (New-Row $monStart $monStop $monTask)

$groups = New-Object Windows.Forms.TableLayoutPanel
$groups.AutoSize = $true; $groups.AutoSizeMode = 'GrowAndShrink'; $groups.Dock = 'Fill'; $groups.ColumnCount = 2; $groups.RowCount = 1
[void]$groups.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 50)))
[void]$groups.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 50)))
[void]$groups.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize')))
$groups.Controls.Add($scanBox, 0, 0); $groups.Controls.Add($monBox, 1, 0)

# 3. Freeze time entry
$ftPicker = New-Object Windows.Forms.DateTimePicker
$ftPicker.Format = 'Custom'; $ftPicker.CustomFormat = 'yyyy-MM-dd HH:mm'; $ftPicker.Width = [int]($em * 9); $ftPicker.Anchor = 'Left'
$ftAdd = New-Button 'Add'
$ftList = New-Object Windows.Forms.TextBox
$ftList.ReadOnly = $true; $ftList.Anchor = 'Left, Right'
$ftClear = New-Button 'Clear'
# This group holds a table directly (not a stack) so the list box can stretch.
$ftBox = New-Object Windows.Forms.GroupBox
$ftBox.Text = '3. When did it freeze? (optional, makes the report more precise)'
$ftBox.AutoSize = $true; $ftBox.AutoSizeMode = 'GrowAndShrink'; $ftBox.Dock = 'Fill'
$ftBox.Padding = New-Object Windows.Forms.Padding([int]($em * 0.4))
$ftBox.Controls.Add((New-Strip @(3) (New-Label 'I noticed a freeze at') $ftPicker $ftAdd $ftList $ftClear))

# Results
$resultsLabel = New-Label 'Highest-priority things to check (from the latest report)' $bold
$results = New-Object Windows.Forms.ListView
$results.Dock = 'Fill'
$results.View = 'Details'; $results.FullRowSelect = $true; $results.HeaderStyle = 'Nonclickable'
foreach ($c in @(@('#', 2), @('Possible cause', 18), @('Priority', 5), @('Score', 4), @('Top evidence', 40))) { [void]$results.Columns.Add($c[0], [int]($em * $c[1])) }

$summaryLabel = New-Label 'No scan yet.'
$summaryLabel.AutoSize = $false; $summaryLabel.Dock = 'Fill'; $summaryLabel.AutoEllipsis = $true; $summaryLabel.TextAlign = 'MiddleLeft'
$openReport = New-Button 'Open report'
$openFolder = New-Button 'Open folder'
$openReport.Enabled = $false
$summaryStrip = New-Strip @(0) $summaryLabel $openReport $openFolder

$log = New-Object Windows.Forms.TextBox
$log.Multiline = $true; $log.ReadOnly = $true; $log.ScrollBars = 'Vertical'; $log.WordWrap = $false
$log.Font = New-Object Drawing.Font('Consolas', 9)
$log.Dock = 'Fill'
$log.BackColor = [Drawing.Color]::White

# Root: one column, rows stacked; the results list and the log share the spare height.
$root = New-Object Windows.Forms.TableLayoutPanel
$root.Dock = 'Fill'; $root.ColumnCount = 1
$root.Padding = New-Object Windows.Forms.Padding([int]($em * 0.6))
[void]$root.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
$rows = @(
    @($titleRow, 'AutoSize'), @($descLabel, 'AutoSize'), @($adminStrip, 'AutoSize'), @($groups, 'AutoSize'), @($ftBox, 'AutoSize'),
    @($resultsLabel, 'AutoSize'), @($results, 40), @($summaryStrip, 'AutoSize'), @($log, 60)
)
$root.RowCount = $rows.Count
for ($i = 0; $i -lt $rows.Count; $i++) {
    if ($rows[$i][1] -eq 'AutoSize') { [void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize'))) }
    else { [void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', $rows[$i][1]))) }
    $root.Controls.Add($rows[$i][0], 0, $i)
}
$form.Controls.Add($root)
$form.ResumeLayout($true)

# ---------- results loading ----------
function Show-Results([string]$reportPath) {
    $results.Items.Clear()
    if (-not $reportPath -or -not (Test-Path $reportPath)) { return }
    $script:ReportPath = $reportPath
    $openReport.Enabled = $true
    $json = Join-Path (Split-Path $reportPath) 'raw\summary.json'
    if (-not (Test-Path $json)) { return }
    try { $s = Get-Content $json -Raw | ConvertFrom-Json } catch { return }
    $i = 0
    foreach ($f in @($s.Findings)) {
        $i++
        $prio = if ($null -ne $f.PSObject.Properties['Priority']) { $f.Priority } else { $f.Score }
        $level = if ($f.PSObject.Properties['PriorityLevel']) { $f.PriorityLevel } else { $f.Severity }
        $evidence = ''
        $first = @($f.Items)[0]
        if ($first) { $evidence = $first.Title; if (@($first.Evidence).Count) { $evidence += ' - ' + @($first.Evidence)[0] } }
        $item = New-Object Windows.Forms.ListViewItem("$i")
        [void]$item.SubItems.Add($f.Name)
        [void]$item.SubItems.Add($level)
        [void]$item.SubItems.Add("$prio")
        [void]$item.SubItems.Add($evidence)
        switch ($level) {
            'High' { $item.ForeColor = [Drawing.Color]::FromArgb(180, 30, 30); $item.Font = $bold }
            'Medium' { $item.ForeColor = [Drawing.Color]::FromArgb(170, 90, 0) }
        }
        [void]$results.Items.Add($item)
    }
    if (-not $i) { [void]$results.Items.Add((New-Object Windows.Forms.ListViewItem(@('', 'Nothing suspicious found in the data that could be read', '', '', 'Try the freeze monitor, then scan again after the next freeze.')))) }
    $st = $s.Stats
    $when = (Get-Item $reportPath).LastWriteTime.ToString('MMM d HH:mm')
    $count = if ($st.IncidentsUnavailable) { 'unknown number of' } else { "$($st.Incidents)" }
    $summaryLabel.Text = "${when}: $count unexpected shutdown(s), $($st.Bugchecks) blue screen(s), $($st.WithPrecursors) with warnings"
}

function Get-LatestReport {
    if (-not (Test-Path $script:OutDir)) { return $null }
    Get-ChildItem $script:OutDir -Recurse -Filter 'IcePick-*.html' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
}

# ---------- freeze times ----------
function Update-FreezeList { $ftList.Text = ($script:FreezeTimes | Sort-Object | ForEach-Object { $_.ToString('yyyy-MM-dd HH:mm') }) -join '; ' }
$ftAdd.Add_Click({
        $t = $ftPicker.Value
        $t = New-Object DateTime($t.Year, $t.Month, $t.Day, $t.Hour, $t.Minute, 0)
        if ($t -gt (Get-Date)) { Add-LogText "That time is in the future.`n"; return }
        if (-not $script:FreezeTimes.Contains($t)) { $script:FreezeTimes.Add($t) }
        Update-FreezeList
    })
$ftClear.Add_Click({ $script:FreezeTimes.Clear(); Update-FreezeList })

# ---------- scan ----------
$scanTimer = New-Object Windows.Forms.Timer
$scanTimer.Interval = 400

function Read-ScanOutput {
    if (-not $script:ScanLog -or -not (Test-Path $script:ScanLog)) { return '' }
    try {
        $fs = [IO.File]::Open($script:ScanLog, 'Open', 'Read', 'ReadWrite')
        [void]$fs.Seek($script:ScanOffset, 'Begin')
        $sr = New-Object IO.StreamReader($fs)
        $txt = $sr.ReadToEnd()
        $script:ScanOffset = $fs.Position
        $sr.Dispose()
        return $txt
    } catch { return '' }
}

$scanBtn.Add_Click({
        $log.Clear()
        $results.Items.Clear()
        New-Item -ItemType Directory -Path $script:OutDir -Force | Out-Null
        $script:ScanLog = Join-Path $env:TEMP "icepick-scan-$PID.log"
        $errLog = "$($script:ScanLog).err"
        Remove-Item $script:ScanLog, $errLog -ErrorAction SilentlyContinue
        $script:ScanOffset = 0
        $extra = @('-Days', [int]$days.Value, '-NoOpen')
        if ($quick.Checked) { $extra += '-SkipSlow' }
        if ($includeDumps.Checked) { $extra += '-IncludeDumps' }
        if ($script:FreezeTimes.Count) { $extra += @('-FreezeTime', (($script:FreezeTimes | ForEach-Object { $_.ToString('yyyy-MM-ddTHH:mm:ss') }) -join ';')) }
        try {
            $script:ScanProc = Start-Process -FilePath $script:PsExe -ArgumentList (Get-EngineArgs $extra) -WindowStyle Hidden -PassThru `
                -RedirectStandardOutput $script:ScanLog -RedirectStandardError $errLog
            $null = $script:ScanProc.Handle   # keep the handle so ExitCode is available later
        } catch {
            Add-LogText "Could not start the scan: $($_.Exception.Message)`n"; return
        }
        $scanBtn.Enabled = $false; $days.Enabled = $false; $quick.Enabled = $false; $includeDumps.Enabled = $false
        $progress.MarqueeAnimationSpeed = 30
        $summaryLabel.Text = 'Scanning... this usually takes under two minutes.'
        $scanTimer.Start()
    })

$scanTimer.Add_Tick({
        Add-LogText (Read-ScanOutput)
        if ($script:ScanProc -and $script:ScanProc.HasExited) {
            $scanTimer.Stop()
            $script:ScanProc.WaitForExit()
            Add-LogText (Read-ScanOutput)
            $errLog = "$($script:ScanLog).err"
            if (Test-Path $errLog) { $err = Get-Content $errLog -Raw; if ($err) { Add-LogText "`n$err" } }
            $progress.MarqueeAnimationSpeed = 0
            $scanBtn.Enabled = $true; $days.Enabled = $true; $quick.Enabled = $true; $includeDumps.Enabled = $true
            $exit = $script:ScanProc.ExitCode
            $line = Get-Content $script:ScanLog -ErrorAction SilentlyContinue | Where-Object { $_ -like 'REPORT: *' } | Select-Object -Last 1
            $path = if ($line) { $line.Substring(8).Trim() } else { $null }
            if ($exit -eq 0 -and $path -and (Test-Path $path)) {
                Show-Results $path
                if ($openWhenDone.Checked) { Start-Process $path }
            } else {
                $results.Items.Clear()
                $summaryLabel.Text = "The scan FAILED (exit code $exit). See the log below."
                $summaryLabel.ForeColor = [Drawing.Color]::FromArgb(180, 30, 30)
                return
            }
            $summaryLabel.ForeColor = [Drawing.SystemColors]::ControlText
        }
    })

# ---------- monitor ----------
function Get-MonitorTaskAction {
    $arg = '-NoProfile -WindowStyle Hidden ' + (Get-EngineArgs @('-Monitor', '-IntervalSec', [int]$interval.Value))
    New-ScheduledTaskAction -Execute $script:PsExe -Argument $arg
}
function Update-MonitorStatus {
    # File checks only: no WMI/CIM on the UI thread.
    $st = Get-CFMonitorState -HeartbeatDir $script:HeartbeatDir
    if ($st.Running -and $st.Stale) {
        $age = if ($null -ne $st.AgeSec) { "$([int]$st.AgeSec) s" } else { 'a while' }
        $monStatus.Text = "Running, but no reading for $age"
        $monStatus.ForeColor = [Drawing.Color]::FromArgb(170, 90, 0)
    } elseif ($st.Running) {
        $last = if ($st.LastRow) { " - last reading $($st.LastRow.ToString('HH:mm:ss'))" } else { '' }
        $monStatus.Text = "Running$last"
        $monStatus.ForeColor = [Drawing.Color]::FromArgb(0, 110, 0)
    } else {
        $monStatus.Text = 'Not running'
        $monStatus.ForeColor = [Drawing.Color]::FromArgb(110, 110, 110)
    }
    # Fallback: if a stop was requested and the monitor is still running after 5 s, end it.
    if ($script:StopRequestedAt) {
        if (-not $st.Running) { $script:StopRequestedAt = $null }
        elseif (((Get-Date) - $script:StopRequestedAt).TotalSeconds -gt 5 -and $st.Pid) {
            Stop-Process -Id $st.Pid -Force -ErrorAction SilentlyContinue
            Add-LogText "The monitor did not stop by itself; it was ended.`n"
            $script:StopRequestedAt = $null
        }
    }
    $monStart.Enabled = -not $st.Running
    $monStop.Enabled = $st.Running
}
# Scheduled-task lookups use CIM, so they run only on start-up and after a click, not on the timer.
# Also finds the task made by versions released under the old name, so it can be removed.
function Get-MonitorTasks {
    @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -in $script:TaskName, 'Crash-Finder Monitor' })
}
function Update-TaskButton {
    $monTask.Text = if ((Get-MonitorTasks).Count) { 'Remove from logon' } else { 'Start at logon' }
    $monTask.Enabled = $script:IsAdmin
}

$monStart.Add_Click({
        Start-Process -FilePath $script:PsExe -ArgumentList (Get-EngineArgs @('-Monitor', '-IntervalSec', [int]$interval.Value)) -WindowStyle Hidden | Out-Null
        Add-LogText "Freeze monitor started (every $([int]$interval.Value)s). It keeps running after this window closes; use Stop to end it.`n"
        Start-Sleep -Milliseconds 1500
        Update-MonitorStatus
        if (-not (Get-CFMonitorState -HeartbeatDir $script:HeartbeatDir).Running) { Add-LogText "The monitor did not start. If another monitor was already running, only one is allowed.`n" }
    })
$monStop.Add_Click({
        Request-CFMonitorStop -HeartbeatDir $script:HeartbeatDir
        $script:StopRequestedAt = Get-Date
        Add-LogText "Asked the freeze monitor to stop.`n"
    })
$monTask.Add_Click({
        try {
            $existing = Get-MonitorTasks
            if ($existing.Count) {
                foreach ($t in $existing) {
                    Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false -ErrorAction Stop
                    Add-LogText "Removed the '$($t.TaskName)' logon task.`n"
                }
            } else {
                $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
                Register-ScheduledTask -TaskName $script:TaskName -Action (Get-MonitorTaskAction) -Trigger (New-ScheduledTaskTrigger -AtLogOn) `
                    -Settings $settings -RunLevel Highest -Description 'IcePick heartbeat logger for diagnosing freezes' -ErrorAction Stop | Out-Null
                Add-LogText "Created the '$script:TaskName' task: the monitor now starts at every logon. Click 'Remove from logon' once the problem is solved.`n"
            }
        } catch { Add-LogText "Scheduled task change failed: $($_.Exception.Message)`n" }
        Update-TaskButton
    })

$monTimer = New-Object Windows.Forms.Timer
$monTimer.Interval = 2000
$monTimer.Add_Tick({ Update-MonitorStatus })

# ---------- misc buttons ----------
$openReport.Add_Click({ if ($script:ReportPath -and (Test-Path $script:ReportPath)) { Start-Process $script:ReportPath } })
$openFolder.Add_Click({
        New-Item -ItemType Directory -Path $script:OutDir -Force | Out-Null
        $target = if ($script:ReportPath) { Split-Path $script:ReportPath } else { $script:OutDir }
        Start-Process explorer.exe "`"$target`""
    })
$results.Add_DoubleClick({ if ($script:ReportPath) { Start-Process $script:ReportPath } })
$elevate.Add_Click({
        try {
            Start-Process -FilePath $script:PsExe -Verb RunAs -WindowStyle Hidden -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File ' + (ConvertTo-CFArgument $PSCommandPath))
            $form.Close()
        } catch { Add-LogText "Elevation was cancelled.`n" }
    })

$form.Add_Shown({
        Update-MonitorStatus
        Update-TaskButton
        $monTimer.Start()
        $latest = Get-LatestReport
        if ($latest) { Show-Results $latest } else { Add-LogText "Click 'Scan now' to start. Tip: if the PC freezes without leaving any trace, start the freeze monitor and scan again after the next freeze.`r`n" }
        # Test hook: ICEPICK_SNAPSHOT=<png> runs a quick scan, saves a screenshot of the window and exits.
        # With ICEPICK_SNAPSHOT_SCAN=0 it skips the scan and captures the latest report as loaded.
        if ($env:ICEPICK_SNAPSHOT) {
            $openWhenDone.Checked = $false; $quick.Checked = $true
            if ($env:ICEPICK_SNAPSHOT_SCAN -ne '0') { $scanBtn.PerformClick() }
            $snap = New-Object Windows.Forms.Timer; $snap.Interval = 1000
            $snap.Add_Tick({
                    if ($scanBtn.Enabled) {
                        $this.Stop()
                        $bmp = New-Object Drawing.Bitmap($form.Width, $form.Height)
                        $form.DrawToBitmap($bmp, (New-Object Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
                        $bmp.Save($env:ICEPICK_SNAPSHOT); $bmp.Dispose(); $form.Close()
                    }
                })
            $snap.Start()
        }
    })
$form.Add_FormClosing({
        $scanTimer.Stop(); $monTimer.Stop()
        if ($script:ScanProc -and -not $script:ScanProc.HasExited) { try { $script:ScanProc.Kill() } catch { } }
    })

[void]$form.ShowDialog()
