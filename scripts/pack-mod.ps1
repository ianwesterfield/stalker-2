# Pack mod/ into build/MolotovCocktail_P.pak (V11, mount ../../../ — matches game paks).
. "$PSScriptRoot\paths.ps1"

if (-not (Test-Path (Join-Path $ModDir "Stalker2"))) { throw "mod/ payload tree missing" }
New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
if (Test-Path $ModPak) { Remove-Item $ModPak }

& $Repak pack --version V11 --mount-point "../../../" $ModDir $ModPak
if ($LASTEXITCODE -ne 0) { throw "repak pack failed" }

& $Repak info $ModPak
& $Repak list $ModPak
