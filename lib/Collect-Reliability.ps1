# Reliability Monitor data (the same source as "View reliability history").

function Get-CFReliability {
    param([datetime]$Since, [switch]$SkipSlow)
    $r = [ordered]@{ Records = @(); Stability = @() }
    if ($SkipSlow) { Add-CFSkipped 'Reliability Monitor' 'quick scan'; return [pscustomobject]$r }

    $dmtf = [Management.ManagementDateTimeConverter]::ToDmtfDateTime($Since)
    try {
        $r.Records = @(Get-CimInstance Win32_ReliabilityRecords -OperationTimeoutSec 30 -Filter "TimeGenerated >= '$dmtf'" -ErrorAction Stop |
                Sort-Object TimeGenerated -Descending | Select-Object -First 400 | ForEach-Object {
                    $msg = "$($_.Message)"
                    $first = ($msg -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
                    if ($first.Length -gt 200) { $first = $first.Substring(0, 197) + '...' }
                    [pscustomobject]@{ Time = $_.TimeGenerated; Source = $_.SourceName; EventId = $_.EventIdentifier; Product = $_.ProductName; Message = $first }
                })
        Set-CFSourceStatus -Source 'Reliability Monitor' -Status Complete
    } catch { Set-CFSourceStatus -Source 'Reliability Monitor' -Status Unavailable -Detail $_.Exception.Message }

    try {
        # Hourly index 1-10; keep the last reading of each day.
        $r.Stability = @(Get-CimInstance Win32_ReliabilityStabilityMetrics -OperationTimeoutSec 30 -Filter "TimeGenerated >= '$dmtf'" -ErrorAction Stop |
                Group-Object { $_.TimeGenerated.Date } | ForEach-Object {
                    $lastReading = $_.Group | Sort-Object TimeGenerated | Select-Object -Last 1
                    [pscustomobject]@{ Day = $lastReading.TimeGenerated.Date; Index = [math]::Round($lastReading.SystemStabilityIndex, 2) }
                } | Sort-Object Day)
    } catch { Set-CFSourceStatus -Source 'Stability index' -Status Unavailable -Detail $_.Exception.Message }

    return [pscustomobject]$r
}
