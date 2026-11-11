[CmdletBinding()]
param([string]$OutputPath = (Join-Path $PSScriptRoot 'zonexm.png'))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

function New-RoundRect([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
  $p = [Drawing.Drawing2D.GraphicsPath]::new()
  $d = 2 * $r
  $p.AddArc($x, $y, $d, $d, 180, 90)
  $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
  $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
  $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
  $p.CloseFigure()
  $p
}

$size = 512
$ink = [Drawing.Color]::FromArgb(255, 28, 28, 28)
$bmp = [Drawing.Bitmap]::new($size, $size, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [Drawing.Graphics]::FromImage($bmp)
try {
  $g.SmoothingMode = 'AntiAlias'
  $g.PixelOffsetMode = 'HighQuality'
  $g.Clear([Drawing.Color]::Transparent)
  $inkBrush = [Drawing.SolidBrush]::new($ink)
  $outline = [Drawing.Pen]::new($ink, 18)
  $outline.LineJoin = 'Round'
  # Mid-gray hardware with a light rim stays visible on both dark and light taskbars.
  $partBrush = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(255, 72, 72, 72))
  $partRim = [Drawing.Pen]::new([Drawing.Color]::FromArgb(255, 150, 150, 150), 8)

  $antenna = New-RoundRect 330 8 52 170 26
  $g.FillPath($partBrush, $antenna); $g.DrawPath($partRim, $antenna)
  $knob = New-RoundRect 132 70 84 92 18
  $g.FillPath($partBrush, $knob); $g.DrawPath($partRim, $knob)
  $knobGrip = [Drawing.Pen]::new([Drawing.Color]::FromArgb(255, 150, 150, 150), 10)
  foreach ($x in 156, 174, 192) { $g.DrawLine($knobGrip, $x, 88, $x, 140) }

  $ptt = New-RoundRect 44 220 52 140 16
  $g.FillPath($partBrush, $ptt); $g.DrawPath($partRim, $ptt)

  $body = New-RoundRect 76 130 360 372 56
  $bodyFill = [Drawing.Drawing2D.LinearGradientBrush]::new(
    [Drawing.PointF]::new(76, 130), [Drawing.PointF]::new(436, 502),
    [Drawing.Color]::FromArgb(255, 255, 210, 50), [Drawing.Color]::FromArgb(255, 228, 152, 0))
  $g.FillPath($bodyFill, $body)
  $g.DrawPath($outline, $body)

  # Bevel highlight down the left edge for a little depth at large sizes.
  $shine = [Drawing.Pen]::new([Drawing.Color]::FromArgb(110, 255, 255, 255), 14)
  $shine.StartCap = 'Round'; $shine.EndCap = 'Round'
  $g.DrawLine($shine, 112, 200, 112, 440)

  $screen = New-RoundRect 136 176 240 112 18
  $g.FillPath([Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(255, 24, 44, 34)), $screen)
  $lcd = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(255, 120, 255, 150))
  $bars = @(30, 52, 74, 42, 62)
  for ($i = 0; $i -lt $bars.Count; $i++) {
    $h = $bars[$i]
    $g.FillRectangle($lcd, 166 + $i * 38, 264 - $h, 24, $h)
  }

  # Speaker grille: few, bold slots so it still reads as a radio at 16-32 px.
  for ($i = 0; $i -lt 4; $i++) {
    $slot = New-RoundRect 136 (316 + $i * 42) 240 22 11
    $g.FillPath($inkBrush, $slot)
  }
}
finally { $g.Dispose() }
try { $bmp.Save($OutputPath, [Drawing.Imaging.ImageFormat]::Png) } finally { $bmp.Dispose() }
Write-Host "Wrote $OutputPath"
