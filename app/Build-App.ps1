<#
.SYNOPSIS
    Builds SundaySort.exe with the C# compiler that ships with Windows. Nothing to install.
    The app icon is drawn in code, so the repo contains no binary files.
.EXAMPLE
    .\app\Build-App.ps1                       # builds app\bin\SundaySort.exe
    .\app\Build-App.ps1 -OutDir C:\somewhere  # builds into another folder
#>
[CmdletBinding()]
param([string]$OutDir)
$ErrorActionPreference = 'Stop'
# (Set here, not as the parameter default: $PSScriptRoot is empty in parameter defaults under "powershell -File".)
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot 'bin' }
Add-Type -AssemblyName System.Drawing

$fw  = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
if (-not (Test-Path "$fw\csc.exe")) { $fw = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319' }
$csc = Join-Path $fw 'csc.exe'
if (-not (Test-Path $csc)) { throw "The .NET Framework 4 C# compiler wasn't found ($csc)." }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$work = Join-Path ([IO.Path]::GetTempPath()) ('sundaysort-build-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work | Out-Null

# ---------------------------------------------------------------- icon: a blue tile with a white folder and a sparkle
function New-LogoBitmap([int]$size) {
    $bmp = New-Object Drawing.Bitmap $size, $size
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.InterpolationMode = 'HighQualityBicubic'; $g.PixelOffsetMode = 'HighQuality'
    $s = $size / 256.0
    function RoundRect([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
        $p = New-Object Drawing.Drawing2D.GraphicsPath
        $p.AddArc($x, $y, 2 * $r, 2 * $r, 180, 90); $p.AddArc($x + $w - 2 * $r, $y, 2 * $r, 2 * $r, 270, 90)
        $p.AddArc($x + $w - 2 * $r, $y + $h - 2 * $r, 2 * $r, 2 * $r, 0, 90); $p.AddArc($x, $y + $h - 2 * $r, 2 * $r, 2 * $r, 90, 90)
        $p.CloseFigure(); $p
    }
    $tile = RoundRect (8 * $s) (8 * $s) (240 * $s) (240 * $s) (56 * $s)
    $grad = New-Object Drawing.Drawing2D.LinearGradientBrush (New-Object Drawing.PointF 0, 0), (New-Object Drawing.PointF $size, $size),
        ([Drawing.Color]::FromArgb(255, 124, 151, 255)), ([Drawing.Color]::FromArgb(255, 52, 86, 230))
    $g.FillPath($grad, $tile)
    $white = New-Object Drawing.SolidBrush ([Drawing.Color]::White)
    $soft  = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(215, 255, 255, 255))
    # folder: back tab + body
    $g.FillPath($soft, (RoundRect (52 * $s) (70 * $s) (70 * $s) (40 * $s) (12 * $s)))
    $g.FillPath($soft, (RoundRect (52 * $s) (88 * $s) (152 * $s) (106 * $s) (16 * $s)))
    $g.FillPath($white, (RoundRect (52 * $s) (106 * $s) (152 * $s) (96 * $s) (16 * $s)))
    # three tidy lines on the folder
    $line = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(255, 70, 104, 240))
    foreach ($i in 0..2) { $g.FillPath($line, (RoundRect (76 * $s) ((128 + 22 * $i) * $s) ((104 - 26 * $i) * $s) (10 * $s) (5 * $s))) }
    # sparkle (4-point star) top right
    if ($size -ge 32) {
        $cx = 196 * $s; $cy = 62 * $s; $R = 30 * $s; $r = 8 * $s
        $pts = @()
        for ($k = 0; $k -lt 8; $k++) {
            $ang = [Math]::PI / 4 * $k - [Math]::PI / 2
            $rad = if ($k % 2 -eq 0) { $R } else { $r }
            $pts += New-Object Drawing.PointF ([float]($cx + $rad * [Math]::Cos($ang))), ([float]($cy + $rad * [Math]::Sin($ang)))
        }
        $g.FillPolygon($white, [Drawing.PointF[]]$pts)
    }
    $g.Dispose()
    $bmp
}

$pngs = @{}
foreach ($size in 16, 24, 32, 48, 64, 256) {
    $b = New-LogoBitmap $size
    $ms = New-Object IO.MemoryStream
    $b.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
    $pngs[$size] = $ms.ToArray()
    if ($size -eq 256) { [IO.File]::WriteAllBytes((Join-Path $work 'logo.png'), $pngs[$size]) }
    $b.Dispose()
}
# .ico file with PNG images inside (supported since Windows Vista)
$sizes = $pngs.Keys | Sort-Object
$ico = New-Object IO.MemoryStream
$w = New-Object IO.BinaryWriter $ico
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
foreach ($sz in $sizes) {
    $dim = if ($sz -ge 256) { 0 } else { $sz }
    $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$pngs[$sz].Length); $w.Write([uint32]$offset)
    $offset += $pngs[$sz].Length
}
foreach ($sz in $sizes) { $w.Write($pngs[$sz]) }
$w.Flush()
[IO.File]::WriteAllBytes((Join-Path $work 'app.ico'), $ico.ToArray())

# ---------------------------------------------------------------- compile
$out = Join-Path $OutDir 'SundaySort.exe'
$refs = 'PresentationFramework.dll', 'PresentationCore.dll', 'WindowsBase.dll', 'System.Xaml.dll', 'System.Windows.Forms.dll',
        'System.Drawing.dll', 'Microsoft.VisualBasic.dll', 'Microsoft.CSharp.dll', 'System.Core.dll'
$args = @('/nologo', '/target:winexe', '/optimize+', '/platform:anycpu', "/out:$out",
          "/lib:$fw", "/lib:$fw\WPF",
          "/win32icon:$(Join-Path $work 'app.ico')",
          "/win32manifest:$(Join-Path $PSScriptRoot 'app.manifest')",
          "/resource:$(Join-Path $PSScriptRoot 'MainWindow.xaml'),MainWindow.xaml",
          "/resource:$(Join-Path $work 'logo.png'),logo.png") +
        ($refs | ForEach-Object { "/reference:$_" }) +
        @((Join-Path $PSScriptRoot 'SundaySort.cs'))
$result = & $csc @args 2>&1
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
if ($LASTEXITCODE -ne 0) { $result | ForEach-Object { Write-Warning "$_" }; throw "Build failed." }
$result | Where-Object { $_ -match 'warning' } | ForEach-Object { Write-Verbose "$_" }
Write-Output "Built $out ($([math]::Round((Get-Item $out).Length / 1KB)) KB)"
