# Pack pak/ into build/MolotovCocktail_P.pak (V11, mount ../../../ — matches game paks).
# Item text is NOT in this pak: it ships in the MolotovBottle plugin's localization
# database (asset-pipeline/editor_import_text.py), so it layers over vanilla text.
. "$PSScriptRoot\..\..\..\shared\scripts\paths.ps1"
$ModDir = Join-Path (Split-Path $PSScriptRoot -Parent) "pak"
$ModPak = Join-Path $BuildDir "MolotovCocktail_P.pak"

if (-not (Test-Path (Join-Path $ModDir "Stalker2"))) { throw "pak/ payload tree missing" }
# a locres here replaces the game's whole string table and goes stale on every patch
if (Get-ChildItem $ModDir -Recurse -Filter *.locres) { throw "pak/ contains a .locres - add text to localization/*.csv instead" }
New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
if (Test-Path $ModPak) { Remove-Item $ModPak }

& $Repak pack --version V11 --mount-point "../../../" $ModDir $ModPak
if ($LASTEXITCODE -ne 0) { throw "repak pack failed" }

& $Repak info $ModPak
& $Repak list $ModPak
