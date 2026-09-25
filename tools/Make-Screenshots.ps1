# Regenerates the README screenshots in assets\screenshots\ from synthetic demo
# data (a made-up PC called DEMO-PC), so no real machine details are published.
#   gui.png     the IcePick window showing the demo results
#   report.png  the top of the demo HTML report
# Needs Microsoft Edge (for the report screenshot).
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
foreach ($f in 'Common', 'Collect-Events', 'Collect-Changes', 'Monitor', 'Analyze', 'Evidence', 'Logo', 'Report') { . (Join-Path $root "lib\$f.ps1") }
. (Join-Path $root 'tests\Fixtures.ps1')
$shots = Join-Path $root 'assets\screenshots'
New-Item -ItemType Directory -Path $shots -Force | Out-Null

# Demo data: the known crash sequence (GPU hang, then power button), plus a few
# background signals so the ranking has more than one entry.
$data = New-KnownCrashData
$data.System = [pscustomobject]@{
    ComputerName = 'DEMO-PC'; Manufacturer = 'Contoso'; Model = 'Gaming Desktop'; OS = 'Microsoft Windows 11 Pro (build 26100)'
    Memory = @(); Pagefiles = @(); AutoPagefile = $true; CPU = @(); GPU = @(); FastStartup = $true; CrashDumpEnabled = 7
    BiosVersion = 'Contoso 1.20'; BiosDate = $T0.AddYears(-3)
}
$data.Events = @($data.Events) + @(
    New-FakeEvent -Time $T0.AddDays(-3) -Key 'Throttle' -Category 'Thermal' -Provider 'Microsoft-Windows-Kernel-Processor-Power' -Id 37 -Summary 'The speed of processor 0 in group 0 is being limited by system firmware.'
    New-FakeEvent -Time $T0.AddDays(-1) -Key 'Throttle' -Category 'Thermal' -Provider 'Microsoft-Windows-Kernel-Processor-Power' -Id 37 -Summary 'The speed of processor 0 in group 0 is being limited by system firmware.'
) | Sort-Object Time
$data.Incidents = @(ConvertTo-CFIncidents -Events $data.Events -Heartbeat $data.Heartbeat -LastAlive $data.LastAlive)
foreach ($s in 'Event log: TDR', 'System log history', 'Drive health', 'Minidumps') { Set-CFSourceStatus -Source $s -Status Complete }
Set-CFSourceStatus -Source 'Temperature sensors' -Status Unavailable -Detail 'this PC does not report temperatures to Windows; overheating cannot be ruled out from here'
$analysis = Invoke-CFAnalysis -Data $data -Since $Since

# The GUI loads the newest report under IcePick-Output next to the script, so
# put the demo report there, screenshot, then remove it again.
$outRoot = Join-Path $root 'IcePick-Output'
$hadOutput = Test-Path $outRoot
$runDir = Join-Path $outRoot 'DEMO-PC-demo'
New-Item -ItemType Directory -Path $runDir -Force | Out-Null
$report = Join-Path $runDir 'IcePick-DEMO-PC.html'
[void](Write-CFReport -Data $data -Analysis $analysis -Since $Since -Until $T0.AddHours(2) -Days 30 -Path $report -IsAdmin $true)
[void](Export-CFRawData -Data $data -Analysis $analysis -Dir $runDir -Params @{ Days = 30; Since = $Since })
try {
    $env:ICEPICK_SNAPSHOT = Join-Path $shots 'gui.png'; $env:ICEPICK_SNAPSHOT_SCAN = '0'
    $p = Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $root 'IcePick-GUI.ps1')`"" -PassThru
    [void]$p.WaitForExit(120000)

    $edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    & $edge --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 --window-size=1150,1180 "--screenshot=$(Join-Path $shots 'report.png')" ('file:///' + $report.Replace('\', '/')) 2>$null
    Start-Sleep 3
} finally {
    Remove-Item Env:\ICEPICK_SNAPSHOT, Env:\ICEPICK_SNAPSHOT_SCAN -ErrorAction SilentlyContinue
    if ($hadOutput) { Remove-Item $runDir -Recurse -Force } else { Remove-Item $outRoot -Recurse -Force }
}
Get-ChildItem $shots | ForEach-Object { '{0,-12} {1,9:N0} bytes' -f $_.Name, $_.Length }
