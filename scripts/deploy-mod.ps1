# Copy the packed mod into the game's ~mods folder. -Remove to uninstall.
param([switch]$Remove)

. "$PSScriptRoot\paths.ps1"

$target = Join-Path $ModsDir (Split-Path $ModPak -Leaf)
# generator overrides go in loose — engine reads GameLite overlay above all paks
$looseSrc = Join-Path $ModDir "Stalker2\Content\GameLite\GameData\ItemGeneratorPrototypes"
$looseDst = Join-Path $GameDir "Stalker2\Content\GameLite\GameData\ItemGeneratorPrototypes"

if ($Remove) {
    if (Test-Path $target) { Remove-Item $target; Write-Host "Removed $target" }
    Get-ChildItem $looseSrc -Filter *.cfg -ErrorAction SilentlyContinue | ForEach-Object {
        $f = Join-Path $looseDst $_.Name
        if (Test-Path $f) { Remove-Item $f; Write-Host "Removed loose $f" }
    }
    return
}

if (-not (Test-Path $ModPak)) { throw "Run pack-mod.ps1 first" }
New-Item -ItemType Directory -Force -Path $ModsDir | Out-Null
Copy-Item $ModPak $target -Force
Write-Host "Deployed -> $target"

New-Item -ItemType Directory -Force -Path $looseDst | Out-Null
Get-ChildItem $looseSrc -Filter *.cfg | ForEach-Object {
    Copy-Item $_.FullName $looseDst -Force
    Write-Host "Deployed loose -> $looseDst\$($_.Name)"
}
