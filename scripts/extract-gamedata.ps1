# Extract gameplay cfgs from the game paks and decode cfg.bin -> plain text.
# Usage: .\extract-gamedata.ps1 [-All]
#   default: just the prototype files the molotov mod needs
#   -All:    every GameData cfg/cfg.bin in pakchunk0
param([switch]$All)

. "$PSScriptRoot\paths.ps1"

$pak = Join-Path $PaksDir "pakchunk0-Windows.pak"

$includes = @(
  "Stalker2/Content/GameLite/GameData/ItemPrototypes.cfg.bin",
  "Stalker2/Content/GameLite/GameData/ExplosionPrototypes.cfg.bin",
  "Stalker2/Content/GameLite/GameData/EffectPrototypes.cfg.bin",
  "Stalker2/Content/GameLite/GameData/MeshPrototypes.cfg.bin",
  "Stalker2/Content/GameLite/GameData/MeshGeneratorPrototypes.cfg.bin",
  "Stalker2/Content/GameLite/GameData/ItemGeneratorPrototypes.cfg.bin",
  "Stalker2/Content/GameLite/GameData/LocalizationPrototypes.cfg.bin",
  "Stalker2/Content/GameLite/GameData/CoreVariables.cfg.bin"
)

New-Item -ItemType Directory -Force -Path $VanillaDir, $DecodedDir | Out-Null

if ($All) {
  & $Repak unpack -o $VanillaDir -i "Stalker2/Content/GameLite/GameData/**" -f $pak
}
else {
  $args = $includes | ForEach-Object { @("-i", $_) }
  & $Repak unpack -o $VanillaDir @args -f $pak
}
if ($LASTEXITCODE -ne 0) { throw "repak unpack failed" }

# Decode every cfg.bin into extracted/decoded (mirrors tree, drops .bin suffix)
$src = Join-Path $VanillaDir "Stalker2\Content\GameLite\GameData"
python $Bin2Cfg $src -o $DecodedDir
if ($LASTEXITCODE -ne 0) { throw "bin2cfg failed" }

# Plain .cfg files need no decode; copy them alongside
Get-ChildItem $src -Recurse -Filter *.cfg | ForEach-Object {
  $rel = $_.FullName.Substring($src.Length + 1)
  $dest = Join-Path $DecodedDir $rel
  New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
  Copy-Item $_.FullName $dest -Force
}

Write-Host "Decoded cfgs in $DecodedDir"
