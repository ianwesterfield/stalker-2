# Install ZoneAtlas: the ZoneAtlas_P container (from build-zoneatlas.ps1) into Paks\~mods and
# the ZoneAtlas UE4SS Lua mod + its generated atlas_manifest.lua into ue4ss\Mods.
# Your original map mods can stay installed (Vortex, Workshop or manual): vanilla is bundled,
# and whichever map mod wins the shadowing just becomes the game's default texture.
# Usage: .\deploy-zoneatlas.ps1 [-Remove] [-ContainerOnly]
#   -ContainerOnly  relink the container + manifest only (what the pre-launch sync uses)
param([switch]$Remove, [switch]$ContainerOnly)
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\..\..\..\shared\scripts\paths.ps1"

$Out = Join-Path $BuildDir 'zoneatlas\out'
$LuaDir = Join-Path $GameDir 'Stalker2\Binaries\Win64\ue4ss\Mods\ZoneAtlas'

$ModsTxt = Join-Path $GameDir 'Stalker2\Binaries\Win64\ue4ss\Mods\mods.txt'

function Set-ModsTxtEntry([bool]$present) {
  if (-not (Test-Path $ModsTxt)) { return }
  $lines = @(Get-Content $ModsTxt | Where-Object { $_ -notmatch '^\s*ZoneAtlas\s*:' })
  if ($present) {
    # entries must stay above the built-in Keybinds line
    $at = [Array]::FindIndex([string[]]$lines, [Predicate[string]] { param($l) $l -like '; Built-in keybinds*' })
    if ($at -lt 0) { $lines += 'ZoneAtlas : 1' }
    else { $lines = @($lines[0..($at - 1)]) + 'ZoneAtlas : 1' + @($lines[$at..($lines.Count - 1)]) }
  }
  Set-Content $ModsTxt $lines -Encoding ascii
}

if (Get-Process -Name 'Stalker2-Win64-Shipping' -ErrorAction SilentlyContinue) {
  throw 'Close the game first - mounted paks are locked.'
}

# Always clear the old container first: the build output may be hardlinked into ~mods.
Get-ChildItem $ModsDir -File -Filter 'ZoneAtlas_P.*' -ErrorAction SilentlyContinue | ForEach-Object {
  Remove-Item $_.FullName -Force; Write-Host "Removed $($_.FullName)"
}
if ($Remove) {
  if (Test-Path $LuaDir) { Remove-Item $LuaDir -Recurse -Force; Write-Host "Removed $LuaDir" }
  Set-ModsTxtEntry $false
  return
}

$manifest = Join-Path $Out 'atlas_manifest.lua'
if (-not (Test-Path (Join-Path $Out 'ZoneAtlas_P.utoc')) -or -not (Test-Path $manifest)) {
  throw "No build at $Out - run .\build-zoneatlas.ps1 first"
}

New-Item -ItemType Directory -Force -Path $ModsDir | Out-Null
foreach ($f in Get-ChildItem $Out -File -Filter 'ZoneAtlas_P.*') {
  $dest = Join-Path $ModsDir $f.Name
  # the ucas is multi-GB; hardlink when build\ and the game share a volume
  try { New-Item -ItemType HardLink -Path $dest -Target $f.FullName | Out-Null }
  catch { Copy-Item $f.FullName $dest }
  Write-Host "Deployed -> $dest ($('{0:N0}' -f $f.Length) B)"
}

if (-not $ContainerOnly -or -not (Test-Path (Join-Path $LuaDir 'Scripts\main.lua'))) {
  & (Join-Path $RepoRoot 'shared\scripts\deploy-ue4ss.ps1') -Mods ZoneAtlas
}
Copy-Item $manifest (Join-Path $LuaDir 'Scripts\atlas_manifest.lua') -Force
Set-ModsTxtEntry $true
Write-Host "Deployed manifest -> $LuaDir\Scripts\atlas_manifest.lua"
Write-Host 'Open the PDA map and press F6 (Shift+F6 = back). Check ue4ss\UE4SS.log for [ZoneAtlas] lines.'
if (-not $ContainerOnly) {
  Write-Host "Auto-sync map mods at every launch - Steam launch options:`n  `"$(Join-Path $PSScriptRoot 'zoneatlas-launch.cmd')`" %command%"
}
