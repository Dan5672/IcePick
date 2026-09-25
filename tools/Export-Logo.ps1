# Regenerates the logo files in assets\ from lib\Logo.ps1:
#   icepick.ico  (multi-size Windows icon, e.g. for a desktop shortcut)
#   logo.svg         (vector, e.g. for the README / GitHub)
#   logo-256.png
Add-Type -AssemblyName System.Drawing
$root = Split-Path $PSScriptRoot
. (Join-Path $root 'lib\Logo.ps1')
$assets = Join-Path $root 'assets'
New-Item -ItemType Directory -Path $assets -Force | Out-Null

[IO.File]::WriteAllBytes((Join-Path $assets 'icepick.ico'), (Get-CFLogoIcoBytes))
[IO.File]::WriteAllText((Join-Path $assets 'logo.svg'), (Get-CFLogoSvg -Size 256), (New-Object Text.UTF8Encoding $false))
$png = New-CFLogoBitmap -Size 256
$png.Save((Join-Path $assets 'logo-256.png'), [Drawing.Imaging.ImageFormat]::Png)
$png.Dispose()
Get-ChildItem $assets | ForEach-Object { '{0,-16} {1,8:N0} bytes' -f $_.Name, $_.Length }
