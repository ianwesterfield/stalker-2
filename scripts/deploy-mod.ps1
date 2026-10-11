# Copy the packed mod into the game's ~mods folder. -Remove to uninstall.
param([switch]$Remove)

. "$PSScriptRoot\paths.ps1"

$target = Join-Path $ModsDir (Split-Path $ModPak -Leaf)

if ($Remove) {
    if (Test-Path $target) { Remove-Item $target; Write-Host "Removed $target" }
    else { Write-Host "Not deployed." }
    return
}

if (-not (Test-Path $ModPak)) { throw "Run pack-mod.ps1 first" }
New-Item -ItemType Directory -Force -Path $ModsDir | Out-Null
Copy-Item $ModPak $target -Force
Write-Host "Deployed -> $target"
