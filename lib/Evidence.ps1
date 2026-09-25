# Complete, versioned evidence export (raw\evidence.json) and re-import, so a
# report can be reproduced on another machine with -ReplayFrom.

$script:CFEvidenceSchema = 2
$script:CFIsoPattern = '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})?$'
$script:CFSpanFields = @('Uptime', 'Gap')

# Turns any object graph into plain hashtables/arrays with ISO dates, which
# ConvertTo-Json round-trips reliably on Windows PowerShell 5.1.
function ConvertTo-CFPlain {
    param($Value, [int]$Depth = 0)
    if ($null -eq $Value) { return $null }
    if ($Depth -gt 12) { return "$Value" }
    if ($Value -is [string] -or $Value -is [bool] -or $Value -is [char]) { return $Value }
    if ($Value -is [datetime]) { return $Value.ToString('o') }
    if ($Value -is [timespan]) { return $Value.ToString('c') }
    if ($Value -is [enum]) { return "$Value" }
    if ($Value -is [ValueType]) { return $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        $h = [ordered]@{}
        foreach ($k in $Value.Keys) { $h["$k"] = ConvertTo-CFPlain $Value[$k] ($Depth + 1) }
        return $h
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        return , @($Value | ForEach-Object { ConvertTo-CFPlain $_ ($Depth + 1) })
    }
    $h = [ordered]@{}
    foreach ($p in $Value.PSObject.Properties) {
        if ($p.MemberType -notin 'NoteProperty', 'Property') { continue }
        $h[$p.Name] = ConvertTo-CFPlain $p.Value ($Depth + 1)
    }
    return $h
}

# Reverses ConvertTo-CFPlain after ConvertFrom-Json: ISO strings become
# DateTime, known duration fields become TimeSpan, event Data becomes an
# ordered dictionary again.
function ConvertFrom-CFPlain {
    param($Value, [string]$Name = '')
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) {
        if ($Name -in $script:CFSpanFields) { $ts = [timespan]::Zero; if ([timespan]::TryParse($Value, [ref]$ts)) { return $ts } }
        if ($Value -match $script:CFIsoPattern) { return [datetime]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) }
        return $Value
    }
    if ($Value -is [array]) { return , @($Value | ForEach-Object { ConvertFrom-CFPlain $_ }) }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        if ($Name -eq 'Data') {
            $d = [ordered]@{}
            foreach ($p in $Value.PSObject.Properties) { $d[$p.Name] = $p.Value }
            return $d
        }
        $o = [ordered]@{}
        foreach ($p in $Value.PSObject.Properties) { $o[$p.Name] = ConvertFrom-CFPlain $p.Value $p.Name }
        return [pscustomobject]$o
    }
    return $Value
}

function Export-CFEvidence {
    param($Data, [hashtable]$Params, [string]$Path)
    $artifacts = $Data.Artifacts
    if ($artifacts -and $artifacts.PSObject.Properties['DumpAnalysis']) {
        # Raw debugger output is saved as separate text files; keep the JSON lean.
        $artifacts = $artifacts | Select-Object * -ExcludeProperty DumpAnalysis
        $artifacts | Add-Member -NotePropertyName DumpAnalysis -NotePropertyValue @($Data.Artifacts.DumpAnalysis | Select-Object * -ExcludeProperty RawOutput) -Force
    }
    $incidents = @($Data.Incidents | Select-Object * -ExcludeProperty Precursors, HeartbeatTail, Context)
    $evidence = [ordered]@{
        SchemaVersion        = $script:CFEvidenceSchema
        Generated            = (Get-Date)
        Computer             = $env:COMPUTERNAME
        Params               = $Params
        System               = $Data.System
        Coverage             = $Data.Coverage
        Events               = @($Data.Events)
        LastAlive            = @($Data.LastAlive)
        Heartbeat            = @($Data.Heartbeat)
        Incidents            = $incidents
        IncidentsUnavailable = [bool]$Data.IncidentsUnavailable
        Hardware             = $Data.Hardware
        Artifacts            = $artifacts
        Changes              = $Data.Changes
        Reliability          = $Data.Reliability
        SourceStatus         = $script:CFSourceStatus.ToArray()
        StageStatus          = $script:CFStageStatus.ToArray()
    }
    $json = (ConvertTo-CFPlain $evidence) | ConvertTo-Json -Depth 20 -Compress
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding $false))
}

# Loads evidence.json and restores the collection state (data, source and
# stage status) so analysis and the report can run offline.
function Import-CFEvidence {
    param([string]$Path)
    $raw = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
    if ($raw.SchemaVersion -ne $script:CFEvidenceSchema) { throw "Unsupported evidence schema $($raw.SchemaVersion) (expected $script:CFEvidenceSchema)" }
    $ev = ConvertFrom-CFPlain $raw
    $script:CFSourceStatus.Clear(); foreach ($s in @($ev.SourceStatus)) { if ($s) { $script:CFSourceStatus.Add($s) } }
    $script:CFStageStatus.Clear(); foreach ($s in @($ev.StageStatus)) { if ($s) { $script:CFStageStatus.Add($s) } }
    return $ev
}
