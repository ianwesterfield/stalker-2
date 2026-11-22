# Generate ZoneCodex's codex_data.lua from the decoded game data (extract-gamedata.ps1).
# The output embeds vanilla text, so it stays under build\ and is never committed.
# Usage: .\build-zonecodex.ps1
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\..\..\..\shared\scripts\paths.ps1"

foreach ($required in 'ItemPrototypes.cfg', 'EffectPrototypes.cfg', 'ObjPrototypes.cfg', 'RelationPrototypes.cfg', 'Game.en.csv') {
  if (-not (Test-Path (Join-Path $DecodedDir $required))) {
    throw "Missing $required in $DecodedDir - run shared\scripts\extract-gamedata.ps1 first"
  }
}

# Faction badges come from the game's FactionIconsDataTable; without it factions just show no badge.
$styleExport = Join-Path $BuildDir 'zonecodex\style-export'
$factionIcons = Join-Path $styleExport 'Stalker2\Content\GameLite\FPS_Game\UIRemaster\StyleManager\FactionIconsDataTable.json'
if (-not (Test-Path $factionIcons)) {
  & (Join-Path $PSScriptRoot '..\..\english-zone\scripts\export-englishzone.ps1') `
    -Source vanilla -Filter 'StyleManager/FactionIconsDataTable' -JsonOnly -Out $styleExport
  if (-not (Test-Path $factionIcons)) { Write-Warning "FactionIconsDataTable export failed; factions will have no badges" }
}

$output = Join-Path $BuildDir 'zonecodex\codex_data.lua'
& python (Join-Path $PSScriptRoot 'build_codex.py') $DecodedDir $output $factionIcons
if ($LASTEXITCODE -ne 0) { throw "build_codex.py failed ($LASTEXITCODE)" }
