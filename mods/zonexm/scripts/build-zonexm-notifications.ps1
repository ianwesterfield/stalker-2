[CmdletBinding()]
param(
  [switch]$Register,
  [string]$OutputDirectory,
  # Values from Partner Center > Product identity; omit for a local development build.
  [string]$IdentityName,
  [string]$Publisher,
  [string]$PublisherDisplayName,
  [version]$Version
)
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
if ($IdentityName -or $Publisher -or $PublisherDisplayName -or $Version) {
  $manifest = [xml](Get-Content "$stage\AppxManifest.xml" -Raw)
  if ($IdentityName) { $manifest.Package.Identity.Name = $IdentityName }
  if ($Publisher) { $manifest.Package.Identity.Publisher = $Publisher }
  if ($PublisherDisplayName) { $manifest.Package.Properties.PublisherDisplayName = $PublisherDisplayName }
  if ($Version) {
    if ($Version.Revision -ne 0) { throw 'The Store requires the fourth version part to be 0' }
    $manifest.Package.Identity.Version = $Version.ToString(4)
  }
  $manifest.Save("$stage\AppxManifest.xml")
}
$null = New-Item -ItemType Directory -Path "$stage\Assets" -Force
$assets = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets'
Copy-Item "$assets\companion\*" "$stage\Assets" -Force
$null = New-Item -ItemType Directory -Path "$stage\Assets\Fonts" -Force
foreach ($family in @('BarlowCondensed', 'IBMPlexSans', 'IBMPlexMono')) {
  Copy-Item "$assets\fonts\$family" "$stage\Assets\Fonts" -Recurse -Force
}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'make-zonexm-headings.ps1') -OutputDirectory "$stage\Assets\Headings"
if ($LASTEXITCODE -ne 0) { throw 'Heading artwork generation failed' }
Add-Type -AssemblyName System.Drawing
foreach ($item in @(@('StoreLogo', 50, 64), @('Square44x44Logo', 44, 48), @('Square150x150Logo', 150, 256))) {
  $original = [Drawing.Image]::FromFile("$assets\companion\Icon-$($item[2]).png")
  try {
    $size = [int]$item[1]
    $bitmap = [Drawing.Bitmap]::new($size, $size)
    try {
      $graphics = [Drawing.Graphics]::FromImage($bitmap)
      try {
        $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.DrawImage($original, 0, 0, $size, $size)
      }
      finally { $graphics.Dispose() }
      $bitmap.Save("$stage\Assets\$($item[0]).png", [Drawing.Imaging.ImageFormat]::Png)
    }
    finally { $bitmap.Dispose() }
  }
  finally { $original.Dispose() }
}
foreach ($size in @(16, 20, 24, 32, 40, 48, 64, 96, 128, 256)) {
  Copy-Item "$assets\companion\Icon-$size.png" "$stage\Assets\Square44x44Logo.targetsize-$size.png" -Force
  Copy-Item "$assets\companion\Icon-$size.png" "$stage\Assets\Square44x44Logo.targetsize-${size}_altform-unplated.png" -Force
}
$sdk = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Directory |
Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' -and (Test-Path "$($_.FullName)\x64\makeappx.exe") } |
Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
if (-not $sdk) { throw 'Windows SDK MakeAppx is required to validate/package the companion' }
$packOutput = & "$($sdk.FullName)\x64\makeappx.exe" pack /d $stage /p "$stage.msix" /o 2>&1
if ($LASTEXITCODE -ne 0) { $packOutput | Write-Host; throw 'MSIX validation/packaging failed' }
Write-Host "Built and validated $stage.msix (unsigned development package)."
if ($Register) {
  Add-AppxPackage -Register "$stage\AppxManifest.xml"
  Write-Host 'Registered ZoneXM Companion. Launch it from Start, then grant access in its window.'
}
else {
  Write-Host 'To register for this user, rerun with -Register. Windows may require Developer Mode.'
}
