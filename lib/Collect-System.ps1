# System inventory: OS, firmware, CPU/GPU/RAM, power and crash-dump settings.

function Get-CFSystemInfo {
    $info = [ordered]@{}

    $os = Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 30 -ErrorAction SilentlyContinue
    $cs = Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec 30 -ErrorAction SilentlyContinue
    $bios = Get-CimInstance Win32_BIOS -OperationTimeoutSec 30 -ErrorAction SilentlyContinue
    $board = Get-CimInstance Win32_BaseBoard -OperationTimeoutSec 30 -ErrorAction SilentlyContinue

    $info.ComputerName = $env:COMPUTERNAME
    if ($os) {
        $info.OS = '{0} (build {1})' -f $os.Caption, $os.BuildNumber
        $info.LastBoot = $os.LastBootUpTime
        $info.Uptime = (Get-Date) - $os.LastBootUpTime
        $info.InstallDate = $os.InstallDate
        $info.TotalRamGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
        $info.FreeRamGB = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
    }
    if ($cs) {
        $info.Manufacturer = $cs.Manufacturer
        $info.Model = $cs.Model
        $info.AutoPagefile = $cs.AutomaticManagedPagefile
    }
    if ($board) { $info.Motherboard = '{0} {1}' -f $board.Manufacturer, $board.Product }
    if ($bios) {
        $info.BiosVersion = '{0} {1}' -f $bios.Manufacturer, $bios.SMBIOSBIOSVersion
        $info.BiosDate = $bios.ReleaseDate
    }

    $info.CPU = @(Get-CimInstance Win32_Processor -OperationTimeoutSec 30 -ErrorAction SilentlyContinue | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name.Trim(); Cores = $_.NumberOfCores; Threads = $_.NumberOfLogicalProcessors; MaxMHz = $_.MaxClockSpeed }
        })

    $info.GPU = @(Get-CimInstance Win32_VideoController -OperationTimeoutSec 30 -ErrorAction SilentlyContinue | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; DriverVersion = $_.DriverVersion; DriverDate = $_.DriverDate; Status = $_.Status }
        })

    # SMBIOSMemoryType: 26 = DDR4, 34 = DDR5
    $info.Memory = @(Get-CimInstance Win32_PhysicalMemory -OperationTimeoutSec 30 -ErrorAction SilentlyContinue | ForEach-Object {
            $type = switch ($_.SMBIOSMemoryType) { 26 { 'DDR4' } 34 { 'DDR5' } 24 { 'DDR3' } default { "type $($_.SMBIOSMemoryType)" } }
            [pscustomobject]@{
                Slot            = $_.DeviceLocator
                Manufacturer    = $_.Manufacturer
                PartNumber      = ("$($_.PartNumber)").Trim()
                CapacityGB      = [math]::Round($_.Capacity / 1GB, 0)
                Type            = $type
                RatedMHz        = $_.Speed
                ConfiguredMHz   = $_.ConfiguredClockSpeed
            }
        })

    # Power plan (read-only query)
    try {
        $scheme = (powercfg /getactivescheme 2>$null) -join ' '
        if ($scheme -match '\((.+)\)') { $info.PowerPlan = $Matches[1] } else { $info.PowerPlan = $scheme }
    } catch { }

    $info.FastStartup = $null
    try {
        $v = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -ErrorAction Stop
        $info.FastStartup = [bool]$v.HiberbootEnabled
    } catch { }

    # Crash dump configuration. 0 = none, 1 = complete, 2 = kernel, 3 = small, 7 = automatic
    try {
        $cc = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -ErrorAction Stop
        $info.CrashDumpEnabled = $cc.CrashDumpEnabled
        $info.CrashDumpType = switch ($cc.CrashDumpEnabled) {
            0 { 'None' } 1 { 'Complete' } 2 { 'Kernel' } 3 { 'Small (minidump)' } 7 { 'Automatic' } default { "$($cc.CrashDumpEnabled)" }
        }
        $info.AutoReboot = $cc.AutoReboot
    } catch { }

    $info.Pagefiles = @(Get-CimInstance Win32_PageFileUsage -OperationTimeoutSec 30 -ErrorAction SilentlyContinue | ForEach-Object {
            [pscustomobject]@{ Path = $_.Name; AllocatedMB = $_.AllocatedBaseSize; PeakMB = $_.PeakUsage }
        })

    return [pscustomobject]$info
}
