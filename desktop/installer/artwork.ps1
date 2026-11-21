param([Parameter(Mandatory = $true)][string]$Destination)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$surface = [Drawing.Color]::FromArgb(21, 25, 22)
$border = [Drawing.Color]::FromArgb(49, 66, 51)
$accent = [Drawing.Color]::FromArgb(193, 225, 147)

function New-SonderArtwork {
    param([int]$Width, [int]$Height, [switch]$Banner)
    $bitmap = [Drawing.Bitmap]::new($Width, $Height)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear($surface)
    $graphics.TranslateTransform($Width / 2.0, $Height / 2.0)
    $scale = [Math]::Min($Width, $Height) / 100.0
    $graphics.ScaleTransform($scale, $scale)
    $ring = [Drawing.Pen]::new($border, 1.6)
    $radii = if ($Banner) { @(28, 36, 45, 55, 66) } else { @(37, 45) }
    foreach ($radius in $radii) {
        $graphics.DrawEllipse($ring, -$radius, -$radius, 2 * $radius, 2 * $radius)
    }
    $pen = [Drawing.Pen]::new($accent, 6)
    $pen.StartCap = $pen.EndCap = [Drawing.Drawing2D.LineCap]::Round
    $length = if ($Banner) { 18 } else { 25 }
    for ($spoke = 0; $spoke -lt 8; $spoke++) {
        $graphics.DrawLine($pen, 0, 0, 0, $length)
        $graphics.RotateTransform(45)
    }
    $pen.Dispose()
    $ring.Dispose()
    $graphics.Dispose()
    return $bitmap
}

$banner = New-SonderArtwork -Width 164 -Height 314 -Banner
$small = New-SonderArtwork -Width 64 -Height 64
$banner.Save((Join-Path $Destination 'Wizard.bmp'), [Drawing.Imaging.ImageFormat]::Bmp)
$small.Save((Join-Path $Destination 'WizardSmall.bmp'), [Drawing.Imaging.ImageFormat]::Bmp)
$banner.Dispose()
$small.Dispose()

$sizes = @(16, 32, 48, 256)
$iconImages = foreach ($size in $sizes) {
    $iconBitmap = New-SonderArtwork -Width $size -Height $size
    $png = [IO.MemoryStream]::new()
    $iconBitmap.Save($png, [Drawing.Imaging.ImageFormat]::Png)
    ,$png.ToArray()
    $png.Dispose()
    $iconBitmap.Dispose()
}
$stream = [IO.File]::Create((Join-Path $Destination 'Sonder.ico'))
$writer = [IO.BinaryWriter]::new($stream)
try {
    $writer.Write([uint16]0)
    $writer.Write([uint16]1)
    $writer.Write([uint16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $dimension = [byte]($sizes[$i] % 256)
        $writer.Write($dimension)
        $writer.Write($dimension)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]32)
        $writer.Write([uint32]$iconImages[$i].Length)
        $writer.Write([uint32]$offset)
        $offset += $iconImages[$i].Length
    }
    foreach ($image in $iconImages) {
        $writer.Write([byte[]]$image)
    }
} finally {
    $writer.Dispose()
}
