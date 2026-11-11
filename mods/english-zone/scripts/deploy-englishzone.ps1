# Install the ZoneKit-recooked "English Zone" identity-override mod (re-cook of Workshop 3526187391).
# Source = build\EnglishZone-zk\idmod-out (cook -> to-legacy -> EzRename /EnglishZone->/Game -> to-zen UE5_5).
# Identity collision via vanilla /Game package IDs from ~mods (_P = high mount order) — the MoreMapMarkers
# pattern. Plugin OverrideContent redirects crash 2.1 when redirected packages stream bulk data.
# Usage: .\deploy-englishzone.ps1 [-Remove]
param([switch]$Remove)

. "$PSScriptRoot\..\..\..\shared\scripts\paths.ps1"

$Out = Join-Path $BuildDir 'EnglishZone-zk\idmod-out'
$PluginDir = Join-Path $GameDir 'Stalker2\Mods\EnglishZone'

if (Get-Process -Name 'Stalker2-Win64-Shipping' -ErrorAction SilentlyContinue) {
  throw 'Close the game first - mounted paks are locked.'
}

# The plugin-layout deployment (redirect container) crashes 2.1 - always clear it.
if (Test-Path $PluginDir) { Remove-Item $PluginDir -Recurse -Force; Write-Host "Removed plugin layout $PluginDir" }

if ($Remove) {
  Get-ChildItem $ModsDir -File -Filter 'EnglishZone_P.*' -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-Item $_.FullName -Force; Write-Host "Removed $($_.FullName)"
  }
  return
}

$utoc = Join-Path $Out 'EnglishZone_P.utoc'
if (-not (Test-Path $utoc)) { throw "No built container at $Out - run the idmod build first" }

New-Item -ItemType Directory -Force -Path $ModsDir | Out-Null
Copy-Item (Join-Path $Out 'EnglishZone_P.*') $ModsDir -Force
Get-ChildItem $ModsDir -File -Filter 'EnglishZone_P.*' | ForEach-Object { Write-Host "Deployed -> $($_.FullName) ($($_.Length) B)" }
Write-Host 'Launch, then check Stalker2.log: EnglishZone_P should mount at elevated order with NumPackages = plugin asset count.'
