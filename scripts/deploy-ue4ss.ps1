# Install/refresh UE4SS (experimental) + repo Lua mods into the game.
# -Remove uninstalls everything UE4SS-related. -Mods limits which mods deploy (default: all).
param([switch]$Remove, [string[]]$Mods)

. "$PSScriptRoot\paths.ps1"

$win64 = Join-Path $GameDir "Stalker2\Binaries\Win64"
$ue4ssDir = Join-Path $win64 "ue4ss"
$proxy = Join-Path $win64 "dwmapi.dll"

if ($Remove) {
  if (Test-Path $proxy) { Remove-Item $proxy }
  if (Test-Path $ue4ssDir) { Remove-Item $ue4ssDir -Recurse }
  Write-Host "UE4SS removed."
  return
}

$staged = Join-Path $BuildDir "ue4ss\ue4ss"      # extracted release zip (dwmapi.dll + ue4ss\)
$profile = Join-Path $BuildDir "ue4ss\configs\Stalker2\steam"
if (-not (Test-Path "$staged\dwmapi.dll")) { throw "Run the UE4SS download step first (see README)" }

if (-not (Test-Path $proxy)) {
  Copy-Item "$staged\dwmapi.dll" $proxy
  Copy-Item "$staged\ue4ss" $win64 -Recurse -Force
  # Stalker2 steam profile: tuned settings, signatures, vtable layout
  Copy-Item "$profile\UE4SS-settings.ini" $ue4ssDir -Force
  Copy-Item "$profile\VTableLayout.ini" $ue4ssDir -Force
  Copy-Item "$profile\UE4SS_Signatures" $ue4ssDir -Recurse -Force
  Write-Host "UE4SS installed with Stalker2 steam profile."
}
else {
  Write-Host "UE4SS already present."
}

# Deploy Lua mods from the repo (repo = source of truth)
$srcMods = Join-Path $RepoRoot "ue4ss-mods"
Get-ChildItem $srcMods -Directory |
Where-Object { -not $Mods -or $_.Name -in $Mods } |
ForEach-Object {
  $dest = Join-Path $ue4ssDir "Mods\$($_.Name)"
  New-Item -ItemType Directory -Force -Path $dest | Out-Null
  Copy-Item "$($_.FullName)\*" $dest -Recurse -Force
  Set-Content (Join-Path $dest "enabled.txt") ""
  Write-Host "Deployed UE4SS mod: $($_.Name)"
}
