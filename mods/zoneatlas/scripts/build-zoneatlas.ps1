# Build ZoneAtlas_P: the PDA map textures of every map mod installed, relocated side by side
# (plus true vanilla) so the ZoneAtlas Lua runtime can swap between them in-game.
# Built locally from mods you already have -- nothing here redistributes another author's art.
# sync-zoneatlas.ps1 runs this with -IfChanged before every launch (see zoneatlas-launch.cmd).
#
# Map mods all shadow the same vanilla texture (T_DLCWorldMap_UDIM or T_WorldMap_UDIM), so
# only one can win at a time. Each chosen texture is converted to legacy, renamed same-length
# to /Game/ZoneAtlas/Vnn_/T_ZAnn_x_UDIM (relocate_texture.py), then packed into one zen
# container. Only Texture2D packages with those names are ever taken, so a non-map mod can't
# end up in the cycle. retoc writes ucas uncompressed: ~3.2 GB for a Topographic-size map.
#
# Usage:
#   .\build-zoneatlas.ps1 -List       # show every map mod found (Vortex, ~mods, Stalker2\Mods, Workshop)
#   .\build-zoneatlas.ps1             # bundle vanilla and every map mod found
#   .\build-zoneatlas.ps1 -IfChanged  # same, but skip when nothing changed since the last build
param(
  [switch]$List,
  [switch]$IfChanged
)
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\..\..\..\shared\scripts\paths.ps1"

$Retoc = 'C:\Tools\retoc\retoc.exe'
$Python = (Get-Command python -ErrorAction Stop).Source
$Relocate = Join-Path $PSScriptRoot 'relocate_texture.py'
$MapTextures = 'T_DLCWorldMap_UDIM', 'T_WorldMap_UDIM'
$WorkshopAppId = '1643320'
$Root = Join-Path $BuildDir 'zoneatlas'
$Work = Join-Path $Root 'work'
$Stage = Join-Path $Root 'stage'
$Out = Join-Path $Root 'out'

if (-not (Test-Path $Retoc)) { throw "Missing tool: $Retoc" }

function Get-ScanRoots {
  $roots = [ordered]@{}
  $roots['Vortex'] = Join-Path $env:APPDATA 'Vortex\stalker2heartofchornobyl\mods'
  $roots['~mods'] = $ModsDir
  $roots['Stalker2\Mods'] = Join-Path $GameDir 'Stalker2\Mods'
  $steamapps = Split-Path (Split-Path $GameDir -Parent) -Parent

  $vdf = Join-Path $steamapps 'libraryfolders.vdf'
  $libraries = @($steamapps)
  if (Test-Path $vdf) {
    $libraries += Select-String -Path $vdf -Pattern '"path"\s+"([^"]+)"' |
    ForEach-Object { Join-Path ($_.Matches[0].Groups[1].Value -replace '\\\\', '\') 'steamapps' }
  }
  $n = 0
  foreach ($lib in $libraries | Select-Object -Unique) {
    $n++

    $roots["Workshop$(if ($n -gt 1) { $n })"] = Join-Path $lib "workshop\content\$WorkshopAppId"
  }
  $roots
}

function Get-MapTexture([string[]]$listing) {
  foreach ($line in $listing) {
    foreach ($t in $MapTextures) { if ($line -match "/$t\.uasset\s*$") { return $t } }
  }
}

function Get-DisplayName([string]$container) {
  $base = $container -replace '(Stalker2)?-Windows.*$', '' -replace '_P$', ''
  (($base -creplace '(?<=[a-z0-9])(?=[A-Z])', ' ') -replace '[_\-]+', ' ').Trim()
}

function Find-MapMods {
  $seen = @{}

  foreach ($scanRoot in (Get-ScanRoots).GetEnumerator()) {
    if (-not (Test-Path $scanRoot.Value)) { continue }

    foreach ($container in Get-ChildItem $scanRoot.Value -Recurse -File -Include *.utoc, *.pak -ErrorAction SilentlyContinue) {
      if ($container.BaseName -eq 'ZoneAtlas_P') { continue }

      # Vortex deploys hardlinks of its staging files into ~mods: same mod, list once.
      $key = "$($container.Name)|$($container.Length)"
      if ($seen.ContainsKey($key)) { continue }

      $kind, $texture = $null, $null

      if ($container.Extension -eq '.utoc') {
        $texture, $kind = (Get-MapTexture (& $Retoc list --path $container.FullName 2>$null)), 'zen'
      }
      elseif (-not (Test-Path ([IO.Path]::ChangeExtension($container.FullName, '.utoc')))) {
        $texture, $kind = (Get-MapTexture (& $Repak list $container.FullName 2>$null)), 'pak'
      }

      if (-not $texture) { continue }

      $seen[$key] = $true
      [pscustomobject]@{
        File = $container
        Kind = $kind
        Match = $container.BaseName
        Name = Get-DisplayName $container.BaseName
        Texture = $texture
        Where = $scanRoot.Key
      }
    }
  }
}

function Find-ContainerWith([string[]]$utocs, [string]$texture) {
  foreach ($u in $utocs) {
    if ((& $Retoc list --path $u 2>$null) -match "/$texture\.uasset\s*$") { return Get-Item $u }
  }
}

function Get-VanillaSource {
  $dlc = Find-ContainerWith @(Get-ChildItem (Join-Path $GameDir 'DLC1') -Filter '*.utoc' -ErrorAction SilentlyContinue | ForEach-Object FullName) 'T_DLCWorldMap_UDIM'
  if ($dlc) { return [pscustomobject]@{ Texture = 'T_DLCWorldMap_UDIM'; Kind = 'zen'; File = $dlc } }
  $base = Find-ContainerWith @(Get-ChildItem $PaksDir -Filter 'pakchunk*.utoc' | ForEach-Object FullName) 'T_WorldMap_UDIM'
  if (-not $base) { throw 'Vanilla map texture not found in DLC1 or base paks' }
  [pscustomobject]@{ Texture = 'T_WorldMap_UDIM'; Kind = 'zen'; File = $base }
}

function Add-Link([string]$target, [string]$path) {
  if (Test-Path $path) { Remove-Item $path -Force }
  try { New-Item -ItemType HardLink -Path $path -Target $target | Out-Null }
  catch { Copy-Item $target $path }
}

function Export-LegacyTexture($source, [string]$dir) {
  $legacy = Join-Path $dir 'legacy'
  if ($source.Kind -eq 'zen') {
    $src = Join-Path $dir 'src'
    New-Item -ItemType Directory -Force $src | Out-Null
    foreach ($e in 'utoc', 'ucas') { Add-Link (Join-Path $PaksDir "global.$e") (Join-Path $src "global.$e") }
    foreach ($e in '.utoc', '.ucas', '.pak') {
      $p = [IO.Path]::ChangeExtension($source.File.FullName, $e)
      if (Test-Path $p) { Add-Link $p (Join-Path $src ([IO.Path]::GetFileName($p))) }
    }
    & $Retoc to-legacy --no-shaders --version UE5_5 -f $source.Texture $src $legacy 2>&1 | Select-Object -Last 1 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "to-legacy failed for $($source.File.Name)" }
  }
  else {
    & $Repak unpack -q -o $legacy $source.File.FullName
    if ($LASTEXITCODE -ne 0) { throw "unpack failed for $($source.File.Name)" }
  }
  $asset = Get-ChildItem $legacy -Recurse -File -Filter "$($source.Texture).uasset" | Select-Object -First 1
  if (-not $asset) { throw "No $($source.Texture).uasset extracted from $($source.File.Name)" }
  $scriptObjects = Join-Path $legacy 'scriptobjects.bin'
  if ((Test-Path $scriptObjects) -and -not (Test-Path "$Stage\scriptobjects.bin")) { Copy-Item $scriptObjects $Stage }
  $asset
}

# --- discover ------------------------------------------------------------------------
$candidates = @(Find-MapMods)
if ($List) {
  if (-not $candidates) { Write-Host 'No map mods found.'; return }
  $candidates | Format-Table Name, Where, Texture, Match, @{ n = 'Folder'; e = { $_.File.DirectoryName } } -AutoSize -Wrap | Out-Host
  return
}

# Every map mod found is bundled; in-game, MCM picks which of them F6 cycles.
$picked = @(
  [pscustomobject]@{ Name = 'Vanilla'; Source = Get-VanillaSource; Vanilla = $true }

  foreach ($candidate in $candidates | Sort-Object Name) {
    [pscustomobject]@{ Name = $candidate.Name; Source = $candidate; Vanilla = $false }
  }
)

# Names are the MCM setting IDs and the saved selection, so they must be unique.
$takenNames = @{}

foreach ($entry in $picked) {
  $baseName, $suffix = $entry.Name, 1

  while ($takenNames.ContainsKey($entry.Name)) {
    $suffix++
    $entry.Name = "$baseName ($suffix)"
  }

  $takenNames[$entry.Name] = $true
}

$fingerprint = @(
  foreach ($p in $picked) { '{0}|{1}|{2}|{3}' -f $p.Name, $p.Source.File.FullName, $p.Source.File.Length, $p.Source.File.LastWriteTimeUtc.Ticks }
  foreach ($s in $PSCommandPath, $Relocate) { (Get-FileHash $s).Hash }
)
$fingerprintFile = Join-Path $Out 'fingerprint.txt'
if ($IfChanged -and (Test-Path (Join-Path $Out 'ZoneAtlas_P.utoc')) -and (Test-Path (Join-Path $Out 'atlas_manifest.lua')) -and
  (Test-Path $fingerprintFile) -and ((Get-Content $fingerprintFile) -join "`n") -eq ($fingerprint -join "`n")) {
  Write-Host 'ZoneAtlas is up to date (no map mod added, removed or updated).'
  return
}
Write-Host "Bundling $($picked.Count) map(s): $(($picked | ForEach-Object Name) -join ', ')"

# --- convert + relocate --------------------------------------------------------------
foreach ($d in $Work, $Stage, $Out) { if (Test-Path $d) { Remove-Item $d -Recurse -Force } }
New-Item -ItemType Directory -Force $Work, $Stage, $Out | Out-Null

$variants = @()
$i = 0
foreach ($p in $picked) {
  $i++
  Write-Host "[$i] $($p.Name)  <- $($p.Source.File.Name) ($($p.Source.Texture))"
  # Index by successes so a skipped mod leaves no gap in the V01_, V02_... paths.
  $index = $variants.Count + 1
  try {
    $asset = Export-LegacyTexture $p.Source (Join-Path $Work $i)
    $objectPath = (& $Python $Relocate $asset.FullName $Stage $index | Select-Object -Last 1)
    if ($LASTEXITCODE -ne 0) { throw "relocate failed for $($p.Source.File.Name)" }
  }
  catch {
    if ($p.Vanilla) { throw }
    # e.g. a container packed for an older game version that retoc can't read with this one
    Write-Warning "Skipping $($p.Name): $_"
    continue
  }
  $variants += [pscustomobject]@{ Name = $p.Name; Texture = $objectPath; Replaces = $p.Source.Texture; Source = $p.Source.File.Name; Vanilla = $p.Vanilla }
}
if (-not $variants) { throw 'Nothing to build: every map mod failed to convert' }
$vanilla = $variants | Where-Object Vanilla | Select-Object -First 1
if ($vanilla) {
  $variants | Where-Object { -not $_.Vanilla -and $_.Replaces -ne $vanilla.Replaces } | ForEach-Object {
    Write-Warning "$($_.Name) replaces $($_.Replaces) but this install's PDA shows $($vanilla.Replaces); its layout may not line up."
  }
}

# --- pack ----------------------------------------------------------------------------
$utoc = Join-Path $Out 'ZoneAtlas_P.utoc'
& $Retoc to-zen --version UE5_5 $Stage $utoc 2>&1 | Select-Object -Last 1 | Out-Host
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $utoc)) { throw 'to-zen failed' }
$packed = @(& $Retoc list --path $utoc | Select-String 'ExportBundleData')
if ($packed.Count -ne $variants.Count) { throw "Container has $($packed.Count) packages, expected $($variants.Count)" }

function ConvertTo-LuaString([string]$s) { "'" + ($s -replace '\\', '\\\\' -replace "'", "\'") + "'" }
$lua = @('-- Generated by build-zoneatlas.ps1 -- do not edit; rebuild instead.', 'return {')
foreach ($v in $variants) {
  $lua += "    { name = $(ConvertTo-LuaString $v.Name), texture = $(ConvertTo-LuaString $v.Texture), " +
  "replaces = $(ConvertTo-LuaString $v.Replaces), vanilla = $($v.Vanilla.ToString().ToLower()), source = $(ConvertTo-LuaString $v.Source) },"
}
$lua += '}'
[IO.File]::WriteAllLines((Join-Path $Out 'atlas_manifest.lua'), [string[]]$lua, [Text.UTF8Encoding]::new($false))

Remove-Item $Work, $Stage -Recurse -Force
[IO.File]::WriteAllLines($fingerprintFile, [string[]]$fingerprint)
Get-ChildItem $Out -Filter 'ZoneAtlas_P.*' | ForEach-Object { Write-Host ("  {0,-24} {1,14:N0} B" -f $_.Name, $_.Length) }
Write-Host "Built $($variants.Count) map(s). Deploy with .\deploy-zoneatlas.ps1"
