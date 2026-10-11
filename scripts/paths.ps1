# Central config for all stalker-2 mod scripts. Dot-source from any script:
#   . "$PSScriptRoot\paths.ps1"

$GameDir = "C:\Program Files (x86)\Steam\steamapps\common\S.T.A.L.K.E.R. 2 Heart of Chornobyl"
$PaksDir = Join-Path $GameDir "Stalker2\Content\Paks"
$ModsDir = Join-Path $PaksDir "~mods"

$RepoRoot = Split-Path $PSScriptRoot -Parent
$ExtractedDir = Join-Path $RepoRoot "extracted"
$VanillaDir = Join-Path $ExtractedDir "vanilla"   # raw unpack (cfg.bin + plain cfg)
$DecodedDir = Join-Path $ExtractedDir "decoded"   # bin2cfg output (plain text)
$ModDir = Join-Path $RepoRoot "mod"           # payload source tree (committed)
$BuildDir = Join-Path $RepoRoot "build"

$ModName = "MolotovCocktail"
$ModPak = Join-Path $BuildDir "$ModName`_P.pak"

$Repak = "C:\Tools\repak\repak.exe"
$Bin2Cfg = Join-Path $RepoRoot "tools\bin2cfg.py"

foreach ($t in @($Repak)) {
  if (-not (Test-Path $t)) { throw "Missing tool: $t" }
}
if (-not (Test-Path $PaksDir)) { throw "Game not found at $GameDir" }
