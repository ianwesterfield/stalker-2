param(
  [ValidateSet('vanilla', 'mod')] [string]$Source = 'vanilla',
  [string]$Filter = 'sign_rostok|plywood_rostok',
  [string]$PathsFile = '',
  [string]$Game = '84213760',
  [string]$Ver = '',
  [string]$Usmap = '',
  [string]$Out = '',
  [switch]$List,
  [switch]$JsonOnly,
  [switch]$Mesh,
  # Resolve imports of unmounted (vanilla) packages by ID against the game's containers.
  [switch]$Names
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\..\shared\scripts\paths.ps1"

$exe = Join-Path $PSScriptRoot '..\tools\EzExport\bin\Release\net10.0\EzExport.exe'
if (-not $Usmap) { $Usmap = Join-Path $GameDir 'Stalker2\Binaries\Win64\ue4ss\Stalker2-5.5.4-0+UE5-5e627997.usmap' }
$oodle = 'C:\Tools\FModel\Output\.data\oodle-data-shared.dll'
$paks = if ($Source -eq 'vanilla') { $PaksDir } else {
  # Mod IoStore packages need the game's global container for script objects; stage both together.
  $ws = 'C:\Program Files (x86)\Steam\steamapps\workshop\content\1643320\3526187391\Stalker2\Mods\EnglishZone\Content\Paks\Windows'
  $stage = Join-Path $BuildDir 'EnglishZone-zk\mod-paks'
  $archive = $env:ENGLISHZONE_ARCHIVE
  New-Item -ItemType Directory -Force -Path $stage | Out-Null
  # Workshop item is unsubscribed; fall back to an archived copy of the payload.
  if (Test-Path $ws) { Copy-Item "$ws\*" $stage -Force }
  elseif (-not (Test-Path (Join-Path $stage 'EnglishZoneStalker2-Windows.utoc'))) {
    if (-not $archive -or -not (Test-Path (Join-Path $archive 'EnglishZoneStalker2-Windows.utoc'))) { throw "Workshop payload gone; set ENGLISHZONE_ARCHIVE to the archived payload folder (got '$archive')" }
    Copy-Item "$archive\EnglishZoneStalker2-Windows.*" $stage -Force
  }
  Copy-Item (Join-Path $PaksDir 'global.utoc'), (Join-Path $PaksDir 'global.ucas') $stage -Force
  $stage
}
if (-not $Out) { $Out = Join-Path $BuildDir "EnglishZone-zk\export\$Source" }

$a = @('--paks', $paks, '--game', $Game, '--usmap', $Usmap, '--oodle', $oodle, '--out', $Out)
$a += if ($PathsFile) { @('--paths', $PathsFile) } else { @('--filter', $Filter) }
if ($Ver) { $a += @('--ver', $Ver) }
if ($List) { $a += '--list' }
if ($JsonOnly) { $a += '--json-only' }
if ($Mesh) { $a += @('--mesh', '--nanite') }
if ($Names) { $a += @('--names', $PaksDir) }
& $exe @a
