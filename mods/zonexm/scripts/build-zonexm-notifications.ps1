[CmdletBinding()]
param([switch]$Register, [string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\ZoneXM.Notifications'
$stage = if ($OutputDirectory) { [IO.Path]::GetFullPath($OutputDirectory) } else { Join-Path $root 'build\zonexm-notifications' }
dotnet publish "$source\ZoneXM.Notifications.csproj" -c Release -o $stage --self-contained true
if ($LASTEXITCODE -ne 0) { throw 'Notification companion publish failed' }
# The SDK's external-packaging publish names the PRI after the assembly.
# A registered MSIX loads the package index from resources.pri.
Move-Item "$stage\ZoneXM.Notifications.pri" "$stage\resources.pri" -Force
if (-not (Test-Path "$stage\App.xbf")) { throw 'Compiled WinUI application resources were not published' }
Copy-Item "$source\AppxManifest.xml" "$stage\AppxManifest.xml" -Force
$null = New-Item -ItemType Directory -Path "$stage\Assets" -Force
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ZoneXMIcon {
  [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr icon);
}
'@
$original = [Drawing.Image]::FromFile((Join-Path $PSScriptRoot 'zonexm.png'))
try {
  foreach ($item in @(@('StoreLogo', 50), @('Square44x44Logo', 44), @('Square150x150Logo', 150))) {
    $bitmap = [Drawing.Bitmap]::new($original, [int]$item[1], [int]$item[1])
    try { $bitmap.Save("$stage\Assets\$($item[0]).png", [Drawing.Imaging.ImageFormat]::Png) }
  finally { $bitmap.Dispose() }
  }
}
finally { $original.Dispose() }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'make-zonexm-background.ps1') -OutputDirectory "$stage\Assets"
if ($LASTEXITCODE -ne 0) { throw 'Background art generation failed' }
$trayArt = [Drawing.Image]::FromFile("$stage\Assets\RadiationIcon.png")
try {
  $bitmap = [Drawing.Bitmap]::new(32, 32)
  try {
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
      $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
      $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
      $graphics.DrawImage($trayArt, 0, 0, 32, 32)
    }
    finally { $graphics.Dispose() }
    $handle = $bitmap.GetHicon()
    try {
      $icon = [Drawing.Icon]::FromHandle($handle)
      $stream = [IO.File]::Create("$stage\Assets\Tray.ico")
      try { $icon.Save($stream) } finally { $stream.Dispose(); $icon.Dispose() }
    }
    finally { $null = [ZoneXMIcon]::DestroyIcon($handle) }
  }
  finally { $bitmap.Dispose() }
}
finally { $trayArt.Dispose() }
$sdk = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Directory |
  Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' -and (Test-Path "$($_.FullName)\x64\makeappx.exe") } |
  Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
if (-not $sdk) { throw 'Windows SDK MakeAppx is required to validate/package the companion' }
$packOutput = & "$($sdk.FullName)\x64\makeappx.exe" pack /d $stage /p "$stage.msix" /o 2>&1
if ($LASTEXITCODE -ne 0) { $packOutput | Write-Host; throw 'MSIX validation/packaging failed' }
Write-Host "Built and validated $stage.msix (unsigned development package)."
if ($Register) {
  Add-AppxPackage -Register "$stage\AppxManifest.xml"
  Write-Host 'Registered ZoneXM Notifications. Launch it from Start, then grant access in its window.'
}
else {
  Write-Host 'To register for this user, rerun with -Register. Windows may require Developer Mode.'
}
