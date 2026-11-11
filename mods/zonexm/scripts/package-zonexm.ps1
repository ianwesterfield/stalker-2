[CmdletBinding()]
param([string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$modRoot = Split-Path $PSScriptRoot -Parent
$repoRoot = Split-Path (Split-Path $modRoot -Parent) -Parent
$lua = Join-Path $modRoot 'ue4ss\ZoneXM\Scripts\main.lua'
$version = [regex]::Match((Get-Content $lua -Raw), 'local VERSION = "([^"]+)"').Groups[1].Value
if (-not $version) { throw "VERSION not found in $lua" }
$out = if ($OutputDirectory) { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory) }
       else { Join-Path $repoRoot 'build\release' }
$null = New-Item -ItemType Directory -Path $out -Force

$readme = @"
ZoneXM $version - conversation awareness for your own music in S.T.A.L.K.E.R. 2

Play your own music over the game. ZoneXM lowers it when gunfire, dialogue, nearby voices
or mutants need your ears, and brings it back when the dust settles. It can also show
now-playing and notification banners in the game's subtitle style.

REQUIREMENTS
- UE4SS for S.T.A.L.K.E.R. 2 (install it first, from its own Nexus page).
- ZoneXM Companion from the Microsoft Store (free). The companion does the actual audio
  ducking and optional notification forwarding; the mod only senses what's happening in game.

INSTALL
Extract this archive into the game's install folder (the one that contains the Stalker2
folder) and allow it to merge. The mod lands in
  Stalker2\Binaries\{0}\ue4ss\Mods\ZoneXM
Then start ZoneXM Companion and launch the game.

UNINSTALL
Delete Stalker2\Binaries\{0}\ue4ss\Mods\ZoneXM. Shared files live in %LOCALAPPDATA%\ZoneXM.

Source, issues and privacy policy: https://github.com/ianwesterfield/stalker-2
License: MIT (see LICENSE.txt)
"@

foreach ($edition in @(@{ Name = 'Steam'; Binaries = 'Win64' }, @{ Name = 'GamePass'; Binaries = 'WinGDK' })) {
  $stage = Join-Path ([IO.Path]::GetTempPath()) "zonexm-$($edition.Name)-$([guid]::NewGuid().ToString('N'))"
  try {
    $dest = Join-Path $stage "Stalker2\Binaries\$($edition.Binaries)\ue4ss\Mods\ZoneXM"
    $null = New-Item -ItemType Directory -Path $dest -Force
    Copy-Item (Join-Path $modRoot 'ue4ss\ZoneXM\*') $dest -Recurse -Force
    Set-Content (Join-Path $dest 'enabled.txt') '' -NoNewline
    Copy-Item (Join-Path $modRoot 'LICENSE') (Join-Path $dest 'LICENSE.txt')
    Set-Content (Join-Path $dest 'README.txt') ($readme -f $edition.Binaries) -Encoding utf8
    $zip = Join-Path $out "ZoneXM-$version-$($edition.Name).zip"
    if (Test-Path $zip) { Remove-Item $zip }
    Compress-Archive -Path (Join-Path $stage 'Stalker2') -DestinationPath $zip
    Write-Host "Wrote $zip"
  }
  finally { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue }
}
