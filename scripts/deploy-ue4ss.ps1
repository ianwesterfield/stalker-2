# Install/refresh UE4SS (experimental) + repo Lua mods into the game.
# -Remove uninstalls everything UE4SS-related. -Mods limits which mods deploy (default: all).
# -SkipSignatures leaves the installed AOB signatures untouched.
param([switch]$Remove, [string[]]$Mods, [switch]$SkipSignatures)

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

# Signatures are byte patterns over the game exe, and a GSC patch reshuffles register
# allocation without changing the code -- the vendored patterns then miss, and a missed
# GUObjectArray is fatal: UE4SS aborts and every Lua mod silently stops existing.
# Re-derive it from whatever exe is installed right now instead of trusting the profile.
if (-not $SkipSignatures) {
  $sigDir = Join-Path $ue4ssDir "UE4SS_Signatures"
  $exe = Join-Path $win64 "Stalker2-Win64-Shipping.exe"
  $python = Get-Command python -ErrorAction SilentlyContinue

  if (-not $python) {
    Write-Warning "python not on PATH - keeping the vendored GUObjectArray signature"
  }
  else {
    New-Item -ItemType Directory -Force -Path $sigDir | Out-Null
    & $python.Source (Join-Path $RepoRoot "tools\find_guobjectarray.py") $exe `
      -o (Join-Path $sigDir "GUObjectArray.lua") |
    Select-String 'reference site|match\(es\)|^wrote'
    if ($LASTEXITCODE -ne 0) { throw "GUObjectArray signature derivation failed" }
  }

  # The vendored ProcessLocalScriptFunction pattern is also stale, and its failure is
  # fatal too. UE4SS's built-in scan covers it; the only casualty is creating custom
  # UFunctions/events for Blueprints, which no mod here does.
  $plsf = Join-Path $sigDir "ProcessLocalScriptFunction.lua"
  if (Test-Path $plsf) {
    Remove-Item $plsf
    Write-Host "Removed stale ProcessLocalScriptFunction signature (built-in scan covers it)."
  }
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
