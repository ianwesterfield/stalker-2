# Pack pak/ into build/MolotovCocktail_P.pak (V11, mount ../../../ — matches game paks).
. "$PSScriptRoot\..\..\..\shared\scripts\paths.ps1"
$ModDir = Join-Path (Split-Path $PSScriptRoot -Parent) "pak"
$ModPak = Join-Path $BuildDir "MolotovCocktail_P.pak"

if (-not (Test-Path (Join-Path $ModDir "Stalker2"))) { throw "pak/ payload tree missing" }
if (-not (Get-ChildItem $ModDir -Recurse -Filter Game.locres)) { throw "No Game.locres in pak/ - run build-locres.ps1 first" }
New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
if (Test-Path $ModPak) { Remove-Item $ModPak }

& $Repak pack --version V11 --mount-point "../../../" $ModDir $ModPak
if ($LASTEXITCODE -ne 0) { throw "repak pack failed" }

& $Repak info $ModPak
& $Repak list $ModPak
