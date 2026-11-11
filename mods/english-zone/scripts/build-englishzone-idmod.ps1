# Builds the deployable English Zone identity-override container from the ZoneKit cook output.
# Chain: staged OverrideContent trio -> retoc to-legacy (game global staged alongside) ->
# drop cook anchor + scriptobjects -> EzRename /EnglishZone->/Game -> retoc to-zen UE5_5 ->
# build\EnglishZone-zk\idmod-out\EnglishZone_P.{pak,ucas,utoc}. Deploy with deploy-englishzone.ps1.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\..\shared\scripts\paths.ps1"

$Retoc = 'C:\Tools\retoc\retoc.exe'
$Usmap = Join-Path $GameDir 'Stalker2\Binaries\Win64\ue4ss\Stalker2-5.5.4-0+UE5-5e627997.usmap'
$Staged = 'C:\Program Files\Epic Games\STALKER2ZoneKit\Stalker2\SavedMods\Staged\EnglishZone\Windows\OverrideContent\Windows\Stalker2\Mods\EnglishZone\Content\Paks\Windows'
$Zk = Join-Path $BuildDir 'EnglishZone-zk'
$CookedPaks = Join-Path $Zk 'cooked-paks'
$Legacy = Join-Path $Zk 'cooked-legacy'
$Stage = Join-Path $Zk 'idmod-stage'
$Out = Join-Path $Zk 'idmod-out'
$EzRename = Join-Path $PSScriptRoot '..\tools\EzRename\bin\Release\net10.0\EzRename.exe'

if (-not (Test-Path $EzRename)) { throw "Build EzRename first: dotnet build mods\english-zone\tools\EzRename -c Release" }

# 1. Stage cooked trio + the game's global container (to-legacy needs ScriptObjects; pass the DIR).
# Vanilla containers holding packages our assets import (e.g. material instances) must be staged
# too, or to-legacy can't resolve the import package-ID hashes back to names and nulls the refs
# (symptom: gray WorldGridMaterial checkerboard in-game). Stage them all (hardlinks keep it cheap;
# a filtered to-legacy pass over everything measured ~1 s per asset).
$PluginContent = 'C:\Program Files\Epic Games\STALKER2ZoneKit\Stalker2\Mods\EnglishZone\Content'
Remove-Item $CookedPaks, $Legacy, $Stage, $Out -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $CookedPaks, $Out | Out-Null
Copy-Item "$Staged\EnglishZoneStalker2-Windows-OverrideContent.*" $CookedPaks -Force
Copy-Item "$PaksDir\global.*" $CookedPaks -Force
foreach ($f in Get-ChildItem $PaksDir -File | Where-Object { $_.Extension -in '.utoc', '.ucas', '.pak' -and $_.BaseName -ne 'global' }) {
  New-Item -ItemType HardLink -Path (Join-Path $CookedPaks $f.Name) -Target $f.FullName | Out-Null
}

# 2. To legacy cooked assets, one filtered pass per asset so the reference containers only extract
# same-named collisions. Where mod and vanilla share a path the mod copy wins (deterministic with
# --no-parallel). The asset list is whatever the plugin holds (the cook's source of truth).
$Assets = @(Get-ChildItem $PluginContent -Recurse -Filter '*.uasset' | ForEach-Object BaseName | Sort-Object -Unique)
$dupes = @(Get-ChildItem $PluginContent -Recurse -Filter '*.uasset' | Group-Object BaseName | Where-Object Count -gt 1)
if ($dupes) { throw "duplicate asset names in plugin (to-legacy -f is name-based): $($dupes.Name -join ', ')" }
"plugin assets: $($Assets.Count)"
$i = 0
foreach ($name in $Assets) {
  $i++
  if ($i % 50 -eq 0) { "  to-legacy $i/$($Assets.Count)" }
  & $Retoc to-legacy --no-parallel -f $name $CookedPaks $Legacy | Out-Null
  if ($LASTEXITCODE) { throw "to-legacy failed for ${name}: $LASTEXITCODE" }
}

# 3. Keep only our packages: drop scriptobjects/anchor, then any asset without /EnglishZone names
# (= vanilla extras that matched the filter) along with its uexp/ubulk siblings.
New-Item -ItemType Directory -Force -Path $Stage | Out-Null
Copy-Item "$Legacy\*" $Stage -Recurse -Force
Get-ChildItem $Stage -Recurse -File |
Where-Object { $_.Name -match '__ModKitWwiseCookAnchor|^scriptobjects\.bin$' } |
Remove-Item -Force
foreach ($ua in Get-ChildItem $Stage -Recurse -Filter '*.uasset') {
  $txt = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($ua.FullName))
  if ($txt -notmatch '/EnglishZone') {
    $base = [IO.Path]::Combine($ua.DirectoryName, [IO.Path]::GetFileNameWithoutExtension($ua.Name))
    Remove-Item "$base.uasset", "$base.uexp", "$base.ubulk" -Force -ErrorAction SilentlyContinue
  }
}
Get-ChildItem $Stage -Recurse -Directory | Sort-Object FullName -Descending |
Where-Object { -not (Get-ChildItem $_.FullName -Recurse -File) } | Remove-Item -Recurse -Force
$kept = @(Get-ChildItem $Stage -Recurse -Filter '*.uasset')
"kept packages: $($kept.Count)"
if ($kept.Count -ne $Assets.Count) {
  $keptNames = $kept | ForEach-Object BaseName
  throw "expected $($Assets.Count) packages, got $($kept.Count); missing: $(($Assets | Where-Object { $_ -notin $keptNames }) -join ', ')"
}

# 4. Rename internal package names /EnglishZone/* -> /Game/* (identity collision with vanilla).
& $EzRename --in $Stage --usmap $Usmap --from /EnglishZone --to /Game
if ($LASTEXITCODE) { throw "EzRename failed: $LASTEXITCODE" }

# 5. Rebuild as a 5.5 zen container.
& $Retoc to-zen --version UE5_5 $Stage (Join-Path $Out 'EnglishZone_P.utoc')
if ($LASTEXITCODE) { throw "to-zen failed: $LASTEXITCODE" }

Get-ChildItem $Out -File | Select-Object Name, Length
& $Retoc list (Join-Path $Out 'EnglishZone_P.utoc') | Measure-Object -Line | ForEach-Object { "chunks: $($_.Lines)" }
