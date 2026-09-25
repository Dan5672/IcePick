# IcePick logo: a pick driven into a cracked ice cube.
# The shapes are defined once on a 64x64 grid and drawn two ways: as SVG (the
# HTML report) and with GDI+ (the window icon and .ico file). Both renderers
# read the tables below, so they stay in sync.

$script:CFLogoColors = @{
    Navy      = '#1E3A5F'   # outlines, pick handle, cracks
    Groove    = '#4F7FB3'   # handle grooves
    Ferrule   = '#C3CED9'
    CubeTop   = '#E6F6FF'
    CubeRight = '#4AA3E0'
    FrontFrom = '#EAF7FF'   # front face gradient, top-left to bottom-right
    FrontTo   = '#7CC3F0'
    SteelFrom = '#F2F6FA'   # spike gradient, across its width
    SteelTo   = '#8FA0B2'
}

# Cube on the 64 grid: two faces as polygons, the front face as a rounded rect.
$script:CFLogoCube = @{
    Top   = @(@(8, 22), @(18, 12), @(54, 12), @(44, 22))
    Right = @(@(44, 22), @(54, 12), @(54, 48), @(44, 58))
    Front = @{ X = 8; Y = 22; W = 36; H = 36; R = 3 }
}
# Highlight on the front face (two strokes from its corner point).
$script:CFLogoHighlight = @(@(@(14, 28), @(24, 28)), @(@(14, 28), @(14, 36)))
# Cracks radiating from the impact point (27,40), as polylines.
$script:CFLogoCracks = @(
    @(@(27, 40), @(22, 44), @(23, 49)),
    @(@(27, 40), @(33, 46)),
    @(@(27, 40), @(25, 33))
)
# The pick, drawn horizontally (handle butt at x=0, tip at x=50), then moved
# and rotated so the tip lands on the crack centre.
$script:CFLogoPick = @{
    TranslateX = 62.4; TranslateY = 4.6; Rotate = 135
    Handle  = @{ X = 0; Y = -5; W = 20; H = 10; R = 5 }
    Grooves = @(6, 10, 14); GrooveHalf = 2.8
    Ferrule = @{ X = 19; Y = -3.6; W = 5; H = 7.2; R = 1 }
    Spike   = @(@(24, -2.6), @(50, 0), @(24, 2.6))
}

function ConvertTo-CFSvgPoints {
    param($Points, [switch]$Close)
    $d = 'M' + (($Points | ForEach-Object { "$($_[0]),$($_[1])" }) -join ' L')
    if ($Close) { $d += ' Z' }
    return $d
}

function Get-CFLogoSvg {
    param([int]$Size = 64, [string]$Id = 'cf')
    $c = $script:CFLogoColors; $cube = $script:CFLogoCube; $f = $cube.Front; $p = $script:CFLogoPick
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64' width='$Size' height='$Size' role='img' aria-label='IcePick logo'>")
    [void]$sb.Append("<defs><linearGradient id='$Id-steel' x1='0' y1='0' x2='0' y2='1'><stop offset='0' stop-color='$($c.SteelFrom)'/><stop offset='1' stop-color='$($c.SteelTo)'/></linearGradient>")
    [void]$sb.Append("<linearGradient id='$Id-iceSoft' x1='0' y1='0' x2='1' y2='1'><stop offset='0' stop-color='$($c.FrontFrom)'/><stop offset='1' stop-color='$($c.FrontTo)'/></linearGradient></defs>")
    # cube: top face, right face, front face
    [void]$sb.Append("<path d='$(ConvertTo-CFSvgPoints $cube.Top -Close)' fill='$($c.CubeTop)' stroke='$($c.Navy)' stroke-width='2.5' stroke-linejoin='round'/>")
    [void]$sb.Append("<path d='$(ConvertTo-CFSvgPoints $cube.Right -Close)' fill='$($c.CubeRight)' stroke='$($c.Navy)' stroke-width='2.5' stroke-linejoin='round'/>")
    [void]$sb.Append("<rect x='$($f.X)' y='$($f.Y)' width='$($f.W)' height='$($f.H)' rx='$($f.R)' fill='url(#$Id-iceSoft)' stroke='$($c.Navy)' stroke-width='2.5'/>")
    # highlight, then cracks
    [void]$sb.Append("<path d='$(($script:CFLogoHighlight | ForEach-Object { ConvertTo-CFSvgPoints $_ }) -join ' ')' stroke='#FFFFFF' stroke-width='2' stroke-linecap='round' opacity='.8'/>")
    [void]$sb.Append("<path d='$(($script:CFLogoCracks | ForEach-Object { ConvertTo-CFSvgPoints $_ }) -join ' ')' stroke='$($c.Navy)' stroke-width='1.5' stroke-linecap='round' fill='none'/>")
    # the pick, on top
    $h = $p.Handle; $fe = $p.Ferrule
    [void]$sb.Append("<g transform='translate($($p.TranslateX),$($p.TranslateY)) rotate($($p.Rotate))'>")
    [void]$sb.Append("<rect x='$($h.X)' y='$($h.Y)' width='$($h.W)' height='$($h.H)' rx='$($h.R)' fill='$($c.Navy)'/>")
    [void]$sb.Append("<g stroke='$($c.Groove)' stroke-width='1.3' stroke-linecap='round'>")
    foreach ($gx in $p.Grooves) { [void]$sb.Append("<line x1='$gx' y1='-$($p.GrooveHalf)' x2='$gx' y2='$($p.GrooveHalf)'/>") }
    [void]$sb.Append('</g>')
    [void]$sb.Append("<rect x='$($fe.X)' y='$($fe.Y)' width='$($fe.W)' height='$($fe.H)' rx='$($fe.R)' fill='$($c.Ferrule)' stroke='$($c.Navy)' stroke-width='1'/>")
    [void]$sb.Append("<path d='$(ConvertTo-CFSvgPoints $p.Spike -Close)' fill='url(#$Id-steel)' stroke='$($c.Navy)' stroke-width='1' stroke-linejoin='round'/>")
    [void]$sb.Append('</g></svg>')
    return $sb.ToString()
}

function ConvertFrom-CFHexColor { param([string]$Hex) [Drawing.ColorTranslator]::FromHtml($Hex) }

function New-CFRoundRectPath {
    param([float]$X, [float]$Y, [float]$W, [float]$H, [float]$R)
    $d = 2 * $R
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $path.AddArc($X, $Y, $d, $d, 180, 90)
    $path.AddArc($X + $W - $d, $Y, $d, $d, 270, 90)
    $path.AddArc($X + $W - $d, $Y + $H - $d, $d, $d, 0, 90)
    $path.AddArc($X, $Y + $H - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    return , $path
}

function ConvertTo-CFPointArray {
    param($Points)
    return , [Drawing.PointF[]]@($Points | ForEach-Object { New-Object Drawing.PointF([float]$_[0], [float]$_[1]) })
}

function New-CFPen {
    param([string]$Hex, [float]$Width, [string]$Join = 'Miter', [switch]$RoundCaps, [int]$Alpha = 255)
    $col = ConvertFrom-CFHexColor $Hex
    $pen = New-Object Drawing.Pen([Drawing.Color]::FromArgb($Alpha, $col.R, $col.G, $col.B), $Width)
    $pen.LineJoin = $Join
    if ($RoundCaps) { $pen.StartCap = 'Round'; $pen.EndCap = 'Round' }
    return $pen
}

function New-CFLogoBitmap {
    param([int]$Size = 64)
    Add-Type -AssemblyName System.Drawing
    $c = $script:CFLogoColors; $cube = $script:CFLogoCube; $f = $cube.Front; $p = $script:CFLogoPick
    $bmp = New-Object Drawing.Bitmap($Size, $Size, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = 'AntiAlias'
        $g.PixelOffsetMode = 'HighQuality'
        $g.Clear([Drawing.Color]::Transparent)
        $g.ScaleTransform($Size / 64, $Size / 64)
        $navy = ConvertFrom-CFHexColor $c.Navy

        # cube: top face, right face, front face
        $outline = New-CFPen $c.Navy 2.5 -Join Round
        foreach ($face in @(@($cube.Top, $c.CubeTop), @($cube.Right, $c.CubeRight))) {
            $pts = ConvertTo-CFPointArray $face[0]
            $g.FillPolygon((New-Object Drawing.SolidBrush (ConvertFrom-CFHexColor $face[1])), $pts)
            $g.DrawPolygon($outline, $pts)
        }
        $front = New-CFRoundRectPath $f.X $f.Y $f.W $f.H $f.R
        $frontBrush = New-Object Drawing.Drawing2D.LinearGradientBrush((New-Object Drawing.PointF($f.X, $f.Y)), (New-Object Drawing.PointF(($f.X + $f.W + 0.01), ($f.Y + $f.H + 0.01))), (ConvertFrom-CFHexColor $c.FrontFrom), (ConvertFrom-CFHexColor $c.FrontTo))
        $g.FillPath($frontBrush, $front)
        $g.DrawPath((New-CFPen $c.Navy 2.5), $front)

        # highlight (80% white), then cracks
        $hl = New-CFPen '#FFFFFF' 2 -RoundCaps -Alpha 204
        foreach ($line in $script:CFLogoHighlight) { $g.DrawLines($hl, (ConvertTo-CFPointArray $line)) }
        $crack = New-CFPen $c.Navy 1.5 -RoundCaps
        foreach ($line in $script:CFLogoCracks) { $g.DrawLines($crack, (ConvertTo-CFPointArray $line)) }

        # the pick, on top, in its own rotated coordinates
        $state = $g.Save()
        $g.TranslateTransform($p.TranslateX, $p.TranslateY)
        $g.RotateTransform($p.Rotate)
        $h = $p.Handle
        $g.FillPath((New-Object Drawing.SolidBrush $navy), (New-CFRoundRectPath $h.X $h.Y $h.W $h.H $h.R))
        $groove = New-CFPen $c.Groove 1.3 -RoundCaps
        foreach ($gx in $p.Grooves) { $g.DrawLine($groove, [float]$gx, [float](-$p.GrooveHalf), [float]$gx, [float]$p.GrooveHalf) }
        $fe = $p.Ferrule
        $ferrule = New-CFRoundRectPath $fe.X $fe.Y $fe.W $fe.H $fe.R
        $g.FillPath((New-Object Drawing.SolidBrush (ConvertFrom-CFHexColor $c.Ferrule)), $ferrule)
        $g.DrawPath((New-CFPen $c.Navy 1), $ferrule)
        $spike = ConvertTo-CFPointArray $p.Spike
        $steel = New-Object Drawing.Drawing2D.LinearGradientBrush((New-Object Drawing.PointF(0, -2.6)), (New-Object Drawing.PointF(0, 2.61)), (ConvertFrom-CFHexColor $c.SteelFrom), (ConvertFrom-CFHexColor $c.SteelTo))
        $g.FillPolygon($steel, $spike)
        $g.DrawPolygon((New-CFPen $c.Navy 1 -Join Round), $spike)
        $g.Restore($state)
    } finally { $g.Dispose() }
    return $bmp
}

# Builds a multi-size .ico in memory: 32-bit DIB frames for the small sizes
# (best supported by Windows and .NET) and a PNG frame for 256 px.
function Get-CFLogoIcoBytes {
    param([int[]]$Sizes = @(16, 20, 24, 32, 40, 48, 64, 128, 256))
    $frames = foreach ($s in $Sizes) {
        $bmp = New-CFLogoBitmap -Size $s
        try {
            $ms = New-Object IO.MemoryStream
            if ($s -ge 256) {
                $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
            } else {
                $bw = New-Object IO.BinaryWriter($ms)
                $maskRow = [int][math]::Ceiling($s / 32) * 4
                $bw.Write([int]40); $bw.Write([int]$s); $bw.Write([int]($s * 2)); $bw.Write([int16]1); $bw.Write([int16]32)
                $bw.Write([int]0); $bw.Write([int]($s * $s * 4 + $maskRow * $s)); $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0)
                for ($y = $s - 1; $y -ge 0; $y--) {
                    for ($x = 0; $x -lt $s; $x++) { $px = $bmp.GetPixel($x, $y); $bw.Write([byte[]]@($px.B, $px.G, $px.R, $px.A)) }
                }
                $bw.Write((New-Object byte[] ($maskRow * $s)))   # alpha channel carries transparency
                $bw.Flush()
            }
            , $ms.ToArray()
        } finally { $bmp.Dispose() }
    }
    $out = New-Object IO.MemoryStream
    $w = New-Object IO.BinaryWriter($out)
    $w.Write([int16]0); $w.Write([int16]1); $w.Write([int16]$Sizes.Count)
    $offset = 6 + 16 * $Sizes.Count
    for ($i = 0; $i -lt $Sizes.Count; $i++) {
        $dim = if ($Sizes[$i] -ge 256) { 0 } else { $Sizes[$i] }
        $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
        $w.Write([int16]1); $w.Write([int16]32); $w.Write([int]$frames[$i].Length); $w.Write([int]$offset)
        $offset += $frames[$i].Length
    }
    foreach ($f in $frames) { $w.Write($f) }
    $w.Flush()
    return , $out.ToArray()
}

function New-CFLogoIcon {
    $bytes = Get-CFLogoIcoBytes
    return New-Object Drawing.Icon((New-Object IO.MemoryStream(, $bytes)))
}
