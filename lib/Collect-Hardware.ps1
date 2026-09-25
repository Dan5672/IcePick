# Hardware health: disks (SMART / reliability counters), volumes, thermals, battery.
# Missing readings are recorded as unavailable, never treated as healthy.

function Get-CFHardwareHealth {
    $hw = [ordered]@{}

    $hw.Disks = @()
    $noCounters = 0
    try {
        $hw.Disks = @(Get-PhysicalDisk -ErrorAction Stop | ForEach-Object {
                $d = $_
                $rel = $null
                try { $rel = $d | Get-StorageReliabilityCounter -ErrorAction Stop } catch { }
                if (-not $rel) { $noCounters++ }
                [pscustomobject]@{
                    Name              = $d.FriendlyName
                    Media             = "$($d.MediaType)"
                    Bus               = "$($d.BusType)"
                    Size              = Format-CFBytes $d.Size
                    Firmware          = $d.FirmwareVersion
                    Health            = "$($d.HealthStatus)"
                    Operational       = ($d.OperationalStatus -join ', ')
                    TemperatureC      = if ($rel) { $rel.Temperature } else { $null }
                    TemperatureMaxC   = if ($rel) { $rel.TemperatureMax } else { $null }
                    WearPercent       = if ($rel) { $rel.Wear } else { $null }
                    ReadErrorsUncorr  = if ($rel) { $rel.ReadErrorsUncorrected } else { $null }
                    WriteErrorsUncorr = if ($rel) { $rel.WriteErrorsUncorrected } else { $null }
                    PowerOnHours      = if ($rel) { $rel.PowerOnHours } else { $null }
                }
            })
        Set-CFSourceStatus -Source 'Drive health' -Status Complete
        if ($noCounters) { Set-CFSourceStatus -Source 'Drive error/wear counters' -Status Unavailable -Detail "not readable for $noCounters drive(s) (needs administrator, or not supported by the drive)" }
        else { Set-CFSourceStatus -Source 'Drive error/wear counters' -Status Complete }
    } catch { Set-CFSourceStatus -Source 'Drive health' -Status Failed -Detail $_.Exception.Message }

    # Classic SMART predict-failure flag (admin only)
    $hw.SmartPredictFailure = @()
    try {
        $hw.SmartPredictFailure = @(Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus -OperationTimeoutSec 30 -ErrorAction Stop |
                ForEach-Object { [pscustomobject]@{ Instance = $_.InstanceName; PredictFailure = $_.PredictFailure; Reason = $_.Reason } })
        Set-CFSourceStatus -Source 'SMART failure prediction' -Status Complete
    } catch { Set-CFSourceStatus -Source 'SMART failure prediction' -Status Unavailable -Detail 'not readable (needs administrator, or not supported)' }

    $hw.Volumes = @()
    try {
        $hw.Volumes = @(Get-Volume -ErrorAction Stop | Where-Object { $_.DriveLetter -and $_.Size -gt 0 } | ForEach-Object {
                [pscustomobject]@{
                    Drive       = "$($_.DriveLetter):"
                    Label       = $_.FileSystemLabel
                    FileSystem  = $_.FileSystem
                    Size        = Format-CFBytes $_.Size
                    Free        = Format-CFBytes $_.SizeRemaining
                    FreePercent = [math]::Round(100 * $_.SizeRemaining / $_.Size, 1)
                    Health      = "$($_.HealthStatus)"
                }
            })
        Set-CFSourceStatus -Source 'Volumes' -Status Complete
    } catch { Set-CFSourceStatus -Source 'Volumes' -Status Failed -Detail $_.Exception.Message }

    # ACPI thermal zones. Many desktops do not expose these; that is normal.
    $hw.ThermalZones = @()
    try {
        $hw.ThermalZones = @(Get-CimInstance -Namespace root\wmi -ClassName MSAcpi_ThermalZoneTemperature -OperationTimeoutSec 30 -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{ Zone = $_.InstanceName; TemperatureC = [math]::Round($_.CurrentTemperature / 10 - 273.15, 1) }
            })
        Set-CFSourceStatus -Source 'Temperature sensors' -Status Complete
    } catch { }
    if (-not $hw.ThermalZones.Count) { Set-CFSourceStatus -Source 'Temperature sensors' -Status Unavailable -Detail 'this PC does not report temperatures to Windows; overheating cannot be ruled out from here' }

    $hw.Battery = @(Get-CimInstance Win32_Battery -OperationTimeoutSec 30 -ErrorAction SilentlyContinue | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; ChargePercent = $_.EstimatedChargeRemaining; Status = $_.Status }
        })

    return [pscustomobject]$hw
}
