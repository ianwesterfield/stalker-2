# Install ZoneCodex into an existing UE4SS: the Lua mod plus the generated codex_data.lua.
# Only ue4ss\Mods\ZoneCodex is touched - UE4SS itself, its signatures, and other mods are not.
# Usage: .\deploy-zonecodex.ps1 [-Remove]
param([switch]$Remove)
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\..\..\..\shared\scripts\paths.ps1"

$ue4ssMods = Join-Path $GameDir 'Stalker2\Binaries\Win64\ue4ss\Mods'
$target = Join-Path $ue4ssMods 'ZoneCodex'

if (Get-Process -Name 'Stalker2-Win64-Shipping' -ErrorAction SilentlyContinue) {
  throw 'Close the game first - a running UE4SS keeps the old ZoneCodex scripts loaded.'
}

if ($Remove) {
  if (Test-Path $target) { Remove-Item $target -Recurse -Force; Write-Host "Removed $target" }
  return
}

if (-not (Test-Path $ue4ssMods)) {
  throw "UE4SS is not installed at $ue4ssMods - run shared\scripts\deploy-ue4ss.ps1 (or install it via Vortex) first"
}

$data = Join-Path $BuildDir 'zonecodex\codex_data.lua'
if (-not (Test-Path $data)) { throw "No $data - run .\build-zonecodex.ps1 first" }

$source = Join-Path $RepoRoot 'mods\zonecodex\ue4ss\ZoneCodex'
New-Item -ItemType Directory -Force -Path $target | Out-Null
Copy-Item "$source\*" $target -Recurse -Force
Copy-Item $data (Join-Path $target 'Scripts\codex_data.lua') -Force
Set-Content (Join-Path $target 'enabled.txt') ''
Write-Host "Deployed ZoneCodex -> $target"
Write-Host 'Lua mods load at game start. Open the PDA and use Q/E (or click) to reach the Archive tab; check ue4ss\UE4SS.log for [ZoneCodex] lines.'
