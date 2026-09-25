# Builds the self-contained HTML report and the raw CSV/JSON exports.

function ConvertTo-CFHtml { param($s) [Net.WebUtility]::HtmlEncode("$s") }

function Format-CFValue {
    param($v)
    if ($null -eq $v) { return '' }
    if ($v -is [datetime]) { return $v.ToString('yyyy-MM-dd HH:mm:ss') }
    if ($v -is [timespan]) { return Format-CFSpan $v }
    if ($v -is [bool]) { if ($v) { return 'Yes' } else { return 'No' } }
    if ($v -is [array]) { return ($v -join ', ') }
    return "$v"
}

# Renders objects as an HTML table. Columns default to the first object's properties.
function ConvertTo-CFTable {
    param([object[]]$Rows, [string[]]$Columns, [string]$Empty = 'Nothing found.', [int]$Max = 500)
    $Rows = @($Rows | Where-Object { $null -ne $_ })
    if (-not $Rows.Count) { return "<p class='muted'>$(ConvertTo-CFHtml $Empty)</p>" }
    if (-not $Columns) { $Columns = @($Rows[0].PSObject.Properties | ForEach-Object { $_.Name }) }
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append("<div class='tablewrap'><table><thead><tr>")
    foreach ($c in $Columns) { [void]$sb.Append("<th>$(ConvertTo-CFHtml $c)</th>") }
    [void]$sb.Append('</tr></thead><tbody>')
    foreach ($r in ($Rows | Select-Object -First $Max)) {
        [void]$sb.Append('<tr>')
        foreach ($c in $Columns) { [void]$sb.Append("<td>$(ConvertTo-CFHtml (Format-CFValue $r.$c))</td>") }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</tbody></table></div>')
    if ($Rows.Count -gt $Max) { [void]$sb.Append("<p class='muted'>Showing $Max of $($Rows.Count) rows. See the CSV export for everything.</p>") }
    return $sb.ToString()
}

function ConvertTo-CFKeyValue {
    param([System.Collections.IDictionary]$Pairs)
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append("<dl class='kv'>")
    foreach ($k in $Pairs.Keys) {
        $v = Format-CFValue $Pairs[$k]
        if ($v -ne '') { [void]$sb.Append("<dt>$(ConvertTo-CFHtml $k)</dt><dd>$(ConvertTo-CFHtml $v)</dd>") }
    }
    [void]$sb.Append('</dl>')
    return $sb.ToString()
}

# Unexpected shutdowns per day stacked above a per-day signal heatmap, sharing one day axis.
function New-CFActivityChart {
    param($Incidents, $Events, [datetime]$Since, [datetime]$Until)
    $days = @()
    for ($d = $Since.Date; $d -le $Until.Date; $d = $d.AddDays(1)) { $days += $d }
    $n = $days.Count
    $rows = [ordered]@{
        'Hardware (WHEA)' = { param($e) $e.Category -eq 'Hardware' }
        'GPU'             = { param($e) $e.Category -eq 'GPU' -or ($e.Key -eq 'WER' -and $e.Norm.IsGpuLiveKernel) }
        'Storage'         = { param($e) $e.Category -eq 'Storage' }
        'Memory'          = { param($e) $e.Category -eq 'Memory' }
        'Thermal'         = { param($e) $e.Category -eq 'Thermal' }
        'App crash/hang'  = { param($e) $e.Category -eq 'App' }
        'Changes'         = { param($e) $e.Category -eq 'Change' }
    }
    $labelW = 118; $cell = [math]::Max(8, [math]::Min(22, [int](760 / [math]::Max($n, 1)))); $gap = 2
    $barH = 90; $rowH = 16; $top = 8
    $width = $labelW + $n * $cell + 10
    $heatTop = $top + $barH + 14
    $height = $heatTop + $rows.Count * ($rowH + $gap) + 26

    $perDay = @{}
    foreach ($i in @($Incidents | Where-Object { $_.BootTime })) { $k = $i.CrashTime.Date; if ($perDay.ContainsKey($k)) { $perDay[$k]++ } else { $perDay[$k] = 1 } }
    $maxBar = [math]::Max(1, ($perDay.Values | Measure-Object -Maximum).Maximum)

    $sb = New-Object Text.StringBuilder
    [void]$sb.Append("<svg class='chart' viewBox='0 0 $width $height' width='$width' height='$height' role='img' aria-label='Unexpected shutdowns per day and warning signals per day'>")
    $base = $top + $barH
    [void]$sb.Append("<line class='grid' x1='$labelW' x2='$($width - 10)' y1='$top' y2='$top'/><text class='tick' x='$($labelW - 6)' y='$($top + 4)' text-anchor='end'>$maxBar</text>")
    [void]$sb.Append("<line class='axis' x1='$labelW' x2='$($width - 10)' y1='$base' y2='$base'/><text class='tick' x='$($labelW - 6)' y='$($base + 4)' text-anchor='end'>0</text>")
    [void]$sb.Append("<text class='rowlabel' x='0' y='$($top + $barH / 2)'>Shutdowns / day</text>")
    for ($i = 0; $i -lt $n; $i++) {
        $day = $days[$i]; $x = $labelW + $i * $cell + $gap / 2; $w = $cell - $gap
        $c = 0; if ($perDay.ContainsKey($day)) { $c = $perDay[$day] }
        $tip = ConvertTo-CFHtml ("{0:ddd yyyy-MM-dd}: {1} unexpected shutdown(s)" -f $day, $c)
        [void]$sb.Append("<rect class='hit' x='$x' y='$top' width='$w' height='$barH' data-tip='$tip'/>")
        if ($c -gt 0) {
            $h = [math]::Max(3, [math]::Round($barH * $c / $maxBar)); $y = $base - $h; $r = [math]::Min(4, $w / 2)
            [void]$sb.Append("<path class='bar' data-tip='$tip' d='M$x,$base V$($y + $r) Q$x,$y $($x + $r),$y H$($x + $w - $r) Q$($x + $w),$y $($x + $w),$($y + $r) V$base Z'/>")
        }
    }
    $ri = 0
    foreach ($label in $rows.Keys) {
        $test = $rows[$label]
        $y = $heatTop + $ri * ($rowH + $gap)
        [void]$sb.Append("<text class='rowlabel' x='0' y='$($y + $rowH - 4)'>$(ConvertTo-CFHtml $label)</text>")
        $counts = @{}
        foreach ($e in $Events) { if (& $test $e) { $k = $e.Time.Date; if ($counts.ContainsKey($k)) { $counts[$k]++ } else { $counts[$k] = 1 } } }
        for ($i = 0; $i -lt $n; $i++) {
            $day = $days[$i]; $c = 0; if ($counts.ContainsKey($day)) { $c = $counts[$day] }
            $lvl = if ($c -eq 0) { 0 } elseif ($c -eq 1) { 1 } elseif ($c -le 3) { 2 } elseif ($c -le 9) { 3 } else { 4 }
            $tip = ConvertTo-CFHtml ("{0:ddd yyyy-MM-dd} - {1}: {2} event(s)" -f $day, $label, $c)
            [void]$sb.Append("<rect class='h$lvl' x='$($labelW + $i * $cell + $gap / 2)' y='$y' width='$($cell - $gap)' height='$rowH' rx='2' data-tip='$tip'/>")
        }
        $ri++
    }
    $ty = $heatTop + $rows.Count * ($rowH + $gap) + 14
    for ($i = 0; $i -lt $n; $i++) {
        if ($i -eq 0 -or $i -eq $n - 1 -or ($i % 7 -eq 0 -and ($n - 1 - $i) -ge 4)) {
            [void]$sb.Append("<text class='tick' x='$($labelW + $i * $cell + $cell / 2)' y='$ty' text-anchor='middle'>$($days[$i].ToString('MMM d'))</text>")
        }
    }
    [void]$sb.Append('</svg>')
    $legend = "<div class='legend'><span><i class='sw bar'></i>Unexpected shutdowns</span><span>Signal events per day:</span><span><i class='sw h0'></i>0</span><span><i class='sw h1'></i>1</span><span><i class='sw h2'></i>2-3</span><span><i class='sw h3'></i>4-9</span><span><i class='sw h4'></i>10+</span></div>"
    return "<div class='chartwrap'>$($sb.ToString())</div>$legend"
}

function Get-CFReportCss {
    return @'
:root{color-scheme:light;--page:#f9f9f7;--surface:#fcfcfb;--card:#ffffff;--ink:#0b0b0b;--ink2:#52514e;--muted:#6f6d68;--grid:#e1e0d9;--axis:#c3c2b7;--border:rgba(11,11,11,.10);
--series:#eb6834;--h0:#eeede8;--h1:#b7d3f6;--h2:#6da7ec;--h3:#2a78d6;--h4:#184f95;--crit:#d03b3b;--serious:#ec835a;--warn:#fab219;--good:#0ca30c;--accent:#2a78d6}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){color-scheme:dark;--page:#0d0d0d;--surface:#1a1a19;--card:#1a1a19;--ink:#ffffff;--ink2:#c3c2b7;--muted:#9a988f;--grid:#2c2c2a;--axis:#383835;--border:rgba(255,255,255,.10);
--series:#d95926;--h0:#262624;--h1:#184f95;--h2:#256abf;--h3:#3987e5;--h4:#86b6ef;--accent:#3987e5}}
:root[data-theme="dark"]{color-scheme:dark;--page:#0d0d0d;--surface:#1a1a19;--card:#1a1a19;--ink:#ffffff;--ink2:#c3c2b7;--muted:#9a988f;--grid:#2c2c2a;--axis:#383835;--border:rgba(255,255,255,.10);
--series:#d95926;--h0:#262624;--h1:#184f95;--h2:#256abf;--h3:#3987e5;--h4:#86b6ef;--accent:#3987e5}
*{box-sizing:border-box}
body{margin:0;background:var(--page);color:var(--ink);font:14px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif}
main{max-width:1100px;margin:0 auto;padding:24px 16px 64px}
h1{font-size:24px;margin:0 0 4px}.brand{display:flex;align-items:center;gap:12px}.brand svg{flex:none}h2{font-size:18px;margin:36px 0 12px;padding-top:8px;border-top:1px solid var(--grid)}h3{font-size:15px;margin:20px 0 8px}
.muted{color:var(--muted)}.sub{color:var(--ink2);margin:0}
nav{display:flex;flex-wrap:wrap;gap:6px 14px;margin:14px 0 0;font-size:13px}nav a{color:var(--accent);text-decoration:none}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px;margin:18px 0}
.tile{background:var(--card);border:1px solid var(--border);border-radius:10px;padding:12px 14px}.tile b{display:block;font-size:26px;line-height:1.2}.tile span{color:var(--ink2);font-size:12.5px}
.cause{background:var(--card);border:1px solid var(--border);border-radius:12px;padding:16px 18px;margin:12px 0}
.cause header{display:flex;flex-wrap:wrap;align-items:center;gap:8px 12px}.cause h3{margin:0;font-size:17px}.rank{font-weight:700;color:var(--muted)}
.badge{display:inline-flex;align-items:center;gap:6px;font-size:12px;font-weight:600;padding:2px 9px;border-radius:99px;border:1px solid var(--border);color:var(--ink)}
.badge i{width:9px;height:9px;border-radius:50%;display:inline-block}.High i{background:var(--crit)}.Medium i{background:var(--serious)}.Low i{background:var(--axis)}
.meter{flex:1 1 120px;max-width:180px;height:6px;background:var(--h0);border-radius:3px;overflow:hidden}.meter div{height:100%;background:var(--ink2)}
.item{margin:10px 0 0}.item>strong{display:block}.item ul{margin:4px 0 0;padding-left:20px;color:var(--ink2)}
.recs{margin:12px 0 0;padding:10px 14px;background:var(--page);border-radius:8px}.recs ol{margin:4px 0 0;padding-left:20px}
.tablewrap{overflow-x:auto;border:1px solid var(--border);border-radius:8px;background:var(--card);margin:6px 0}
table{border-collapse:collapse;width:100%;font-size:12.5px}th,td{text-align:left;padding:5px 9px;border-bottom:1px solid var(--grid);vertical-align:top}
th{position:sticky;top:0;background:var(--surface);color:var(--ink2);font-weight:600;white-space:nowrap}td{font-variant-numeric:tabular-nums}tr:last-child td{border-bottom:0}
details{margin:8px 0}summary{cursor:pointer;font-weight:600;padding:4px 0}
.kv{display:grid;grid-template-columns:max-content 1fr;gap:3px 16px;margin:6px 0;font-size:13px}.kv dt{color:var(--ink2)}.kv dd{margin:0}
.note{background:var(--card);border:1px solid var(--border);border-left:4px solid var(--warn);border-radius:8px;padding:10px 14px;margin:12px 0}
.note.bad{border-left-color:var(--crit)}
.chartwrap{overflow-x:auto;background:var(--surface);border:1px solid var(--border);border-radius:10px;padding:12px}
.chart .grid{stroke:var(--grid);stroke-width:1}.chart .axis{stroke:var(--axis);stroke-width:1}.chart .tick{fill:var(--muted);font-size:10.5px}
.chart .rowlabel{fill:var(--ink2);font-size:11.5px}.chart .bar{fill:var(--series)}.chart .hit{fill:transparent}
.h0{fill:var(--h0);background:var(--h0)}.h1{fill:var(--h1);background:var(--h1)}.h2{fill:var(--h2);background:var(--h2)}.h3{fill:var(--h3);background:var(--h3)}.h4{fill:var(--h4);background:var(--h4)}
.legend{display:flex;flex-wrap:wrap;gap:4px 14px;font-size:12px;color:var(--ink2);margin:8px 2px}.legend span{display:inline-flex;align-items:center;gap:5px}
.sw{width:11px;height:11px;border-radius:2px;display:inline-block}.sw.bar{background:var(--series)}
#tip{position:fixed;pointer-events:none;background:var(--ink);color:var(--page);font-size:12px;padding:4px 8px;border-radius:6px;display:none;z-index:9}
.ctx{margin:6px 0;padding-left:20px;color:var(--ink2)}
'@
}

# Returns $true only if the HTML file was written.
function Write-CFReport {
    param($Data, $Analysis, [datetime]$Since, [datetime]$Until = (Get-Date), [int]$Days, [string]$Path, [bool]$IsAdmin, [string]$ReplayOf)
    $sys = $Data.System
    $stats = $Analysis.Stats
    $findings = @($Analysis.Findings)
    $incidents = @($Data.Incidents)
    $reboots = @($incidents | Where-Object { $_.BootTime })
    $events = @($Data.Events)
    $h = { param($s) ConvertTo-CFHtml $s }
    $gaps = @($script:CFSourceStatus | Where-Object { $_.Status -notin 'Complete', 'Skipped' })
    $skipped = @($script:CFSourceStatus | Where-Object { $_.Status -eq 'Skipped' })
    $failedStages = @($script:CFStageStatus | Where-Object { $_.Status -ne 'Ok' })

    $sb = New-Object Text.StringBuilder
    $add = { param($s) [void]$sb.Append($s) }

    $favicon = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((Get-CFLogoSvg -Size 64 -Id 'fav')))
    & $add "<title>IcePick - $(& $h $sys.ComputerName)</title><meta charset='utf-8'><link rel='icon' type='image/svg+xml' href='data:image/svg+xml;base64,$favicon'><meta name='viewport' content='width=device-width,initial-scale=1'><style>$(Get-CFReportCss)</style><main>"
    & $add "<h1 class='brand'>$(Get-CFLogoSvg -Size 40 -Id 'hdr')<span>IcePick report: $(& $h $sys.ComputerName)</span></h1>"
    & $add "<p class='sub'>$(& $h $sys.Manufacturer) $(& $h $sys.Model) &middot; $(& $h $sys.OS) &middot; data up to $($Until.ToString('yyyy-MM-dd HH:mm')) &middot; looking back $Days days (since $($Since.ToString('yyyy-MM-dd')))</p>"
    if ($ReplayOf) { & $add "<p class='sub'>Replayed offline from $(& $h $ReplayOf) on $((Get-Date).ToString('yyyy-MM-dd HH:mm')).</p>" }
    & $add "<nav><a href='#verdict'>Possible causes</a><a href='#activity'>Activity</a><a href='#freezes'>Unexpected shutdowns</a><a href='#coverage'>Data coverage</a><a href='#system'>System</a><a href='#hardware'>Hardware</a><a href='#changes'>Changes</a><a href='#apps'>App crashes</a><a href='#artifacts'>Dumps &amp; reports</a><a href='#reliability'>Reliability</a><a href='#raw'>All events</a></nav>"

    if ($stats.IncidentsUnavailable) {
        & $add "<div class='note bad'><strong>Unexpected shutdowns could not be reconstructed.</strong> The count below is unknown, not zero. See the run log at the bottom, and please report the problem.</div>"
    }
    foreach ($s in $failedStages) { & $add "<div class='note bad'><strong>$(& $h $s.Name) failed:</strong> $(& $h $s.Error)</div>" }
    if (-not $IsAdmin -or $gaps.Count) {
        & $add "<div class='note'>"
        if (-not $IsAdmin) { & $add '<strong>Not run as administrator.</strong> Some sources could not be read. Launch it with IcePick.cmd for the full picture.<br>' }
        if ($gaps.Count) { & $add "$($gaps.Count) data source(s) were incomplete or unavailable, so the absence of evidence there proves nothing. <a href='#coverage'>See Data coverage</a>." }
        & $add '</div>'
    }

    # Stat tiles
    $count = if ($stats.IncidentsUnavailable) { 'n/a' } else { "$($stats.Incidents)" }
    $median = if ($null -ne $stats.MedianUptimeH) { "$($stats.MedianUptimeH) h" } else { '-' }
    $last = if ($stats.LastIncident) { $stats.LastIncident.ToString('MMM d, HH:mm') } else { '-' }
    & $add "<div class='tiles'>"
    & $add "<div class='tile'><b>$count</b><span>unexpected shutdowns</span></div>"
    & $add "<div class='tile'><b>$($stats.Bugchecks)</b><span>ended in a blue screen</span></div>"
    & $add "<div class='tile'><b>$($stats.PowerButton)</b><span>turned off with the power button (consistent with a hang)</span></div>"
    & $add "<div class='tile'><b>$($stats.WithPrecursors)</b><span>had warnings in the 15 min before</span></div>"
    & $add "<div class='tile'><b>$median</b><span>median uptime before a shutdown</span></div>"
    & $add "<div class='tile'><b>$(& $h $last)</b><span>most recent</span></div>"
    & $add '</div>'
    if (@($stats.Kinds).Count) { & $add "<p class='muted'>Kinds: $(& $h ((@($stats.Kinds) | ForEach-Object { "$($_.Count) $($_.Kind)" }) -join ', ')). Kernel-Power 41 alone does not prove a freeze: it is also logged after power loss and forced shutdowns.</p>" }
    if ($stats.UserReported) { & $add "<p class='muted'>Plus $($stats.UserReported) hang(s) you reported that did not end in an unclean reboot.</p>" }

    # Verdict
    & $add "<h2 id='verdict'>Possible causes, highest priority first</h2><p class='muted'>The priority score (0-100) ranks what is worth checking first based on the evidence found. It is a heuristic, not a probability.</p>"
    if (-not $stats.IncidentsUnavailable -and -not $incidents.Count) {
        & $add "<div class='note'>No unexpected shutdowns were found in the last $Days days. If the PC froze and you held the power button, Windows normally logs Kernel-Power 41 at the next boot. Try a longer window (<code>-Days 90</code>), or enter the time you noticed a freeze. Findings below are still worth reviewing.</div>"
    }
    if (-not $findings.Count) {
        & $add "<p class='muted'>No problems were detected in the data that could be read. If the freezes continue, start the freeze monitor (in IcePick, or Run-Monitor.cmd) and leave it running until the next one, then run this report again.</p>"
    }
    $rank = 0
    foreach ($f in $findings) {
        $rank++
        if ($rank -eq 4) { & $add "<details><summary>Other findings ($($findings.Count - 3))</summary>" }
        & $add "<section class='cause'><header><span class='rank'>#$rank</span><h3>$(& $h $f.Name)</h3><span class='badge $($f.Severity)'><i></i>$($f.Severity) priority</span><span class='meter' title='Priority score $($f.Score)/100'><div style='width:$($f.Score)%'></div></span></header>"
        foreach ($it in $f.Items) {
            & $add "<div class='item'><strong>$(& $h $it.Title)</strong>"
            if (@($it.Evidence).Count) { & $add '<ul>'; foreach ($e in $it.Evidence) { & $add "<li>$(& $h $e)</li>" }; & $add '</ul>' }
            & $add '</div>'
        }
        if (@($f.Recommendation).Count) {
            & $add "<div class='recs'><strong>What to try</strong><ol>"
            foreach ($r in $f.Recommendation) { & $add "<li>$(& $h $r)</li>" }
            & $add '</ol></div>'
        }
        & $add '</section>'
    }
    if ($rank -ge 4) { & $add '</details>' }

    # Activity chart
    & $add "<h2 id='activity'>Activity over time</h2><p class='muted'>Unexpected shutdowns per day (top) against warning signals per day (bottom). Look for signal rows that light up on the same days. Hover over the chart for exact counts.</p>"
    & $add (New-CFActivityChart -Incidents $incidents -Events $events -Since $Since -Until $Until)

    # Incidents
    & $add "<h2 id='freezes'>Unexpected shutdowns</h2>"
    & $add "<p class='muted'>Windows cannot record the moment a PC freezes. IcePick shows the last moment it was known to be alive (the latest of: heartbeat log, EventLog 6008, last logged event) and when it rebooted. The problem happened somewhere in between: the shorter that gap, the higher the timing confidence. A time you enter overrides the estimate.</p>"
    & $add (ConvertTo-CFTable -Rows ($incidents | ForEach-Object {
                [pscustomobject]@{
                    '#' = $_.Number; 'Kind' = $_.Kind; 'Last known alive' = $_.CrashTime; 'From' = $_.CrashSource; 'Rebooted at' = $_.BootTime
                    'Gap' = $_.Gap; 'Timing confidence' = $_.TimingConfidence; 'Uptime before' = $_.Uptime
                    'Blue screen' = if ($_.Bugcheck) { (Get-CFBugcheckInfo $_.Bugcheck | ForEach-Object { "$($_.Code) $($_.Name)" }) } else { 'No' }
                    'Warnings before' = @($_.Precursors).Count
                }
            }) -Empty $(if ($stats.IncidentsUnavailable) { 'Unavailable: reconstruction failed.' } else { "No unexpected shutdowns in the last $Days days." }))
    foreach ($inc in ($incidents | Sort-Object CrashTime -Descending)) {
        & $add "<details><summary>#$($inc.Number) $(& $h $inc.Kind) - $($inc.CrashTime.ToString('ddd yyyy-MM-dd HH:mm')) - $(@($inc.Precursors).Count) event(s) in the 15 min before</summary>"
        if ($inc.TimingConfidence -eq 'Low') { & $add "<p class='muted'>Timing uncertain: nothing was logged for $(& $h (Format-CFSpan $inc.Gap)) before the reboot, so the events below are from before the last sign of life, which may be well before the actual failure.</p>" }
        if ($inc.Note) { & $add "<p class='muted'>$(& $h $inc.Note)</p>" }
        if (@($inc.Context).Count) { & $add "<ul class='ctx'>"; foreach ($c in $inc.Context) { & $add "<li>$(& $h $c)</li>" }; & $add '</ul>' }
        & $add (ConvertTo-CFTable -Rows $inc.Precursors -Columns Time, Category, Provider, Id, Summary -Empty 'Nothing suspicious was logged in the 15 minutes before.')
        if (@($inc.HeartbeatTail).Count) {
            & $add '<h3>Heartbeat readings in the last 5 minutes</h3>'
            & $add (ConvertTo-CFTable -Rows $inc.HeartbeatTail)
        }
        & $add '</details>'
    }

    # Coverage
    & $add "<h2 id='coverage'>Data coverage</h2><p class='muted'>What could and could not be read. Anything not marked Complete means &quot;no evidence found&quot; there is not the same as &quot;no problem&quot;.</p>"
    $covRows = @($script:CFSourceStatus | Sort-Object @{ e = { $script:CFStatusRank[$_.Status] }; Descending = $true }, Source | Select-Object Source, Status, Detail, @{ n = 'Covers from'; e = { $_.CoverageFrom } })
    & $add (ConvertTo-CFTable -Rows $covRows -Max 200)
    if ($failedStages.Count) { & $add (ConvertTo-CFTable -Rows $failedStages -Columns Name, Status, Error) }

    # System
    & $add "<h2 id='system'>System</h2>"
    $biosDate = $null; if ($sys.BiosDate) { $biosDate = ([datetime]$sys.BiosDate).ToString('yyyy-MM-dd') }
    & $add (ConvertTo-CFKeyValue ([ordered]@{
                'Computer' = $sys.ComputerName; 'Model' = "$($sys.Manufacturer) $($sys.Model)"; 'Motherboard' = $sys.Motherboard; 'OS' = $sys.OS
                'Last boot' = $sys.LastBoot; 'Current uptime' = $sys.Uptime; 'BIOS' = $sys.BiosVersion; 'BIOS date' = $biosDate
                'CPU' = (@($sys.CPU) | ForEach-Object { "$($_.Name) ($($_.Cores)C/$($_.Threads)T)" }) -join '; '
                'RAM' = "$($sys.TotalRamGB) GB ($($sys.FreeRamGB) GB free at scan time)"; 'GPU' = (@($sys.GPU) | ForEach-Object { "$($_.Name) (driver $($_.DriverVersion))" }) -join '; '
                'Power plan' = $sys.PowerPlan; 'Fast Startup' = $sys.FastStartup; 'Crash dump type' = $sys.CrashDumpType
                'Dump locations' = if ($Data.Artifacts.DumpPaths) { "$($Data.Artifacts.DumpPaths.MinidumpDir); $($Data.Artifacts.DumpPaths.DumpFile)" } else { $null }
                'Page file' = if ($sys.AutoPagefile) { 'System managed' } else { (@($sys.Pagefiles) | ForEach-Object { "$($_.Path) $($_.AllocatedMB) MB" }) -join '; ' }
            }))

    # Hardware
    & $add "<h2 id='hardware'>Hardware health</h2><h3>Drives</h3>"
    & $add (ConvertTo-CFTable -Rows $Data.Hardware.Disks -Empty 'Drive information unavailable (needs administrator).')
    & $add '<h3>Volumes</h3>'
    & $add (ConvertTo-CFTable -Rows $Data.Hardware.Volumes)
    & $add '<h3>Memory modules</h3>'
    & $add (ConvertTo-CFTable -Rows $sys.Memory)
    & $add '<h3>Graphics</h3>'
    & $add (ConvertTo-CFTable -Rows $sys.GPU)
    & $add '<h3>Temperatures</h3>'
    & $add (ConvertTo-CFTable -Rows $Data.Hardware.ThermalZones -Empty 'This PC does not report temperatures to Windows (common on desktops), so overheating cannot be ruled out here. Use HWiNFO64 to read CPU/GPU temperatures.')

    # Changes
    & $add "<h2 id='changes'>Recent changes</h2><p class='muted'>Completed driver installs, updates and program installs in the window, newest first. Compare these dates with the first unexpected shutdown.</p>"
    & $add (ConvertTo-CFTable -Rows (Get-CFChangeTimeline -Changes $Data.Changes -Events $events) -Columns Time, Kind, Name -Max 300)
    if (@($Data.Changes.FailedUpdates).Count) {
        & $add "<details><summary>Updates that failed or did not finish ($(@($Data.Changes.FailedUpdates).Count)). Not counted as changes.</summary>"
        & $add (ConvertTo-CFTable -Rows $Data.Changes.FailedUpdates)
        & $add '</details>'
    }
    if (@($Data.Changes.ThirdPartyDrivers).Count) {
        & $add "<details><summary>Installed third-party drivers ($(@($Data.Changes.ThirdPartyDrivers).Count))</summary>"
        & $add (ConvertTo-CFTable -Rows $Data.Changes.ThirdPartyDrivers)
        & $add '</details>'
    }

    # Apps
    & $add "<h2 id='apps'>Application crashes and hangs</h2>"
    $appRows = $events | Where-Object { $_.Category -eq 'App' } | ForEach-Object {
        $mod = if ($_.Key -eq 'AppHang') { '(hang)' } else { $_.Norm.Module }
        [pscustomobject]@{ App = $_.Norm.App; Module = $mod; Time = $_.Time }
    } | Group-Object App, Module | Sort-Object Count -Descending | ForEach-Object {
        [pscustomobject]@{ Count = $_.Count; App = $_.Group[0].App; 'Faulting module' = $_.Group[0].Module; Latest = ($_.Group | Sort-Object Time | Select-Object -Last 1).Time }
    }
    & $add (ConvertTo-CFTable -Rows $appRows -Max 60)
    & $add '<h3>Service failures</h3>'
    & $add (ConvertTo-CFTable -Rows ($events | Where-Object { $_.Category -eq 'Service' } | Group-Object { $_.Norm.Service } | Sort-Object Count -Descending | ForEach-Object {
                [pscustomobject]@{ Count = $_.Count; Service = $_.Name; Example = $_.Group[0].Summary }
            }))

    # Artifacts
    $mini = @($Data.Artifacts.Minidumps)
    & $add "<h2 id='artifacts'>Dumps and error reports</h2><h3>Minidumps (blue screens) in the scan window</h3>"
    & $add (ConvertTo-CFTable -Rows ($mini | Where-Object { $_.InWindow }) -Columns Name, Time, Size -Empty 'No minidumps in the scan window. Normal for freezes, since a hard hang never reaches the blue screen.')
    $old = @($mini | Where-Object { -not $_.InWindow })
    if ($old.Count) {
        & $add "<details><summary>Older minidumps outside the scan window ($($old.Count)). Not used in the findings.</summary>"
        & $add (ConvertTo-CFTable -Rows $old -Columns Name, Time, Size)
        & $add '</details>'
    }
    if ($Data.Artifacts.MemoryDump) { & $add "<p>Full memory dump present: $(& $h $Data.Artifacts.MemoryDump.Path), $(([datetime]$Data.Artifacts.MemoryDump.Time).ToString('yyyy-MM-dd HH:mm')), $($Data.Artifacts.MemoryDump.Size)</p>" }
    if (@($Data.Artifacts.DumpAnalysis).Count) {
        & $add '<h3>Debugger analysis</h3>'
        & $add (ConvertTo-CFTable -Rows $Data.Artifacts.DumpAnalysis -Columns Dump, DumpTime, Status, BUGCHECK_STR, MODULE_NAME, IMAGE_NAME, FAILURE_BUCKET_ID, Error)
    } elseif (@($mini | Where-Object { $_.InWindow }).Count -and -not $Data.Artifacts.DebuggerFound) {
        & $add "<p class='muted'>Tip: install the Windows SDK Debugging Tools (cdb.exe) and run again, and IcePick will analyse the minidumps automatically. Or tick &quot;Include crash dumps&quot; and bring the output folder back for analysis.</p>"
    }
    & $add '<h3>LiveKernelReports (problems Windows recovered from)</h3>'
    & $add (ConvertTo-CFTable -Rows $Data.Artifacts.LiveKernelReports -Columns Time, Class, Type, Name, Size)
    & $add '<h3>Windows Error Reporting</h3>'
    & $add (ConvertTo-CFTable -Rows $Data.Artifacts.WerReports -Max 100)

    # Reliability
    & $add "<h2 id='reliability'>Reliability Monitor</h2>"
    $stab = @($Data.Reliability.Stability)
    if ($stab.Count) { & $add "<p>Stability index (1-10): $(& $h (($stab | Select-Object -Last 1).Index)) at the end of the window, lowest $(& $h (($stab | Measure-Object Index -Minimum).Minimum)).</p>" }
    & $add "<details><summary>Reliability records ($(@($Data.Reliability.Records).Count))</summary>"
    & $add (ConvertTo-CFTable -Rows $Data.Reliability.Records -Max 400)
    & $add '</details>'

    # Raw
    & $add "<h2 id='raw'>All collected events</h2><details><summary>$($events.Count) events</summary>"
    & $add (ConvertTo-CFTable -Rows ($events | Sort-Object Time -Descending) -Columns Time, Category, Log, Provider, Id, Level, Summary -Max 2000)
    & $add '</details>'
    & $add "<details><summary>Run log</summary><pre>$(& $h ($script:CFLogLines -join "`n"))</pre></details>"
    & $add "<p class='muted'>IcePick scans are read-only: they change no settings. Raw CSV/JSON exports, including evidence.json for offline replay, are in the raw folder next to this report.</p></main><div id='tip'></div>"
    & $add @'
<script>
(function(){var t=document.getElementById('tip');document.addEventListener('mousemove',function(e){var el=e.target.closest&&e.target.closest('[data-tip]');if(!el){t.style.display='none';return}t.textContent=el.getAttribute('data-tip');t.style.display='block';var x=e.clientX+12,y=e.clientY+14;if(x+t.offsetWidth>innerWidth-8)x=e.clientX-t.offsetWidth-12;t.style.left=x+'px';t.style.top=y+'px'});})();
</script>
'@

    $html = "<!doctype html><html lang='en'><head>" + $sb.ToString().Replace('<main>', '</head><body><main>') + '</body></html>'
    [IO.File]::WriteAllText($Path, $html, (New-Object Text.UTF8Encoding $false))
    return (Test-Path $Path)
}

# Writes CSVs, summary.json, evidence.json, debugger output and (optionally)
# copies of the in-window dumps. Returns $true only if the required files exist.
function Export-CFRawData {
    param($Data, $Analysis, [string]$Dir, [hashtable]$Params, [switch]$IncludeDumps)
    $raw = Join-Path $Dir 'raw'
    New-Item -ItemType Directory -Path $raw -Force -ErrorAction Stop | Out-Null
    $csv = { param($rows, $name) $r = @($rows | Where-Object { $_ }); if ($r.Count) { $r | Export-Csv (Join-Path $raw "$name.csv") -NoTypeInformation -Encoding UTF8 } }

    & $csv ($Data.Events | Select-Object Time, Category, Key, Log, Provider, Id, Level, Summary, @{ n = 'Data'; e = { (@($_.Data.GetEnumerator()) | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; ' } }, Message) 'events'
    & $csv ($Data.Incidents | Select-Object Number, Kind, CrashTime, CrashSource, BootTime, @{ n = 'GapMinutes'; e = { if ($_.Gap) { [math]::Round($_.Gap.TotalMinutes, 1) } } }, TimingConfidence, @{ n = 'UptimeHours'; e = { if ($_.Uptime) { [math]::Round($_.Uptime.TotalHours, 2) } } }, Bugcheck, PowerButton, LongPress, SleepInProgress, WheaBootErrors, @{ n = 'Precursors'; e = { @($_.Precursors).Count } }) 'shutdowns'
    & $csv ($Analysis.Findings | ForEach-Object { $f = $_; $f.Items | ForEach-Object { [pscustomobject]@{ Category = $f.Category; CategoryPriority = $f.Score; Title = $_.Title; ItemScore = $_.Score; Evidence = ($_.Evidence -join ' | ') } } }) 'findings'
    & $csv (Get-CFChangeTimeline -Changes $Data.Changes -Events $Data.Events) 'changes'
    & $csv $Data.Changes.FailedUpdates 'failed-updates'
    & $csv $Data.Changes.ThirdPartyDrivers 'drivers'
    & $csv $Data.Hardware.Disks 'disks'
    & $csv $Data.Artifacts.LiveKernelReports 'livekernelreports'
    & $csv $Data.Artifacts.WerReports 'wer-reports'
    & $csv $Data.Reliability.Records 'reliability'
    & $csv $Data.Heartbeat 'heartbeat'
    & $csv $script:CFSourceStatus 'data-coverage'

    foreach ($a in @($Data.Artifacts.DumpAnalysis | Where-Object { $_.PSObject.Properties['RawOutput'] -and $_.RawOutput })) {
        $dbg = Join-Path $raw 'debugger'
        New-Item -ItemType Directory -Path $dbg -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $dbg "$($a.Dump).txt"), $a.RawOutput)
    }
    if ($IncludeDumps) {
        $dumps = @($Data.Artifacts.Minidumps | Where-Object { $_.InWindow -and $_.Path })
        if ($dumps.Count) {
            $dd = Join-Path $raw 'dumps'
            New-Item -ItemType Directory -Path $dd -Force | Out-Null
            foreach ($d in $dumps) { try { Copy-Item $d.Path $dd -ErrorAction Stop } catch { Write-CFLog "Could not copy $($d.Name): $($_.Exception.Message)" 'WARN' } }
        }
    }

    $summary = [pscustomobject]@{
        Generated = (Get-Date).ToString('o'); System = $Data.System; Stats = $Analysis.Stats
        Findings  = @($Analysis.Findings | Select-Object Category, Name, @{ n = 'Priority'; e = { $_.Score } }, @{ n = 'PriorityLevel'; e = { $_.Severity } }, @{ n = 'Items'; e = { @($_.Items | Select-Object Title, Score, Evidence) } }, Recommendation)
    }
    $summaryPath = Join-Path $raw 'summary.json'
    # ConvertTo-CFPlain first: on PowerShell 5.1, arrays built in calculated properties
    # would otherwise serialise as {"value": [...], "Count": n} instead of a list.
    (ConvertTo-CFPlain $summary) | ConvertTo-Json -Depth 10 | Set-Content $summaryPath -Encoding UTF8 -ErrorAction Stop
    $evidencePath = Join-Path $raw 'evidence.json'
    Export-CFEvidence -Data $Data -Params $Params -Path $evidencePath
    ($script:CFLogLines -join "`r`n") | Set-Content (Join-Path $raw 'run.log') -Encoding UTF8
    return ((Test-Path $summaryPath) -and (Test-Path $evidencePath))
}
