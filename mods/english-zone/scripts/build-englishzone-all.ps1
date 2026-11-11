# End-to-end English Zone port: export -> manifest -> ZoneKit import -> cook -> identity container
# -> validate [-> deploy]. Resume with -From <step>. Steps:
#   export-mod, export-vanilla, manifest, import, cook, idmod, validate, deploy (only with -Deploy)
param(
  [ValidateSet('export-mod', 'export-vanilla', 'manifest', 'import', 'cook', 'idmod', 'validate', 'deploy')]
  [string]$From = 'export-mod',
  [switch]$Deploy
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\..\shared\scripts\paths.ps1"

$Zk = Join-Path $BuildDir 'EnglishZone-zk'
$Exp = Join-Path $Zk 'export'
$ModUsmap = 'C:\Tools\FModel\Output\.data\mappings\Mappings.usmap'
$PluginContent = 'C:\Program Files\Epic Games\STALKER2ZoneKit\Stalker2\Mods\EnglishZone\Content'
$Steps = 'export-mod', 'export-vanilla', 'manifest', 'import', 'cook', 'idmod', 'validate', 'deploy'
$start = [array]::IndexOf($Steps, $From)
function Want([string]$s) { [array]::IndexOf($Steps, $s) -ge $start }
function Step([string]$s) { Write-Host "`n===== $s =====" -ForegroundColor Cyan }
function Check-Done([object[]]$lines, [string]$what) {
  $d = $lines | Select-String 'done: (\d+) ok, (\d+) failed' | Select-Object -Last 1
  if (-not $d -or [int]$d.Matches[0].Groups[2].Value -gt 0) { throw "$what failed: $($d.Line)" }
  $d.Line
}

if (Want 'export-mod') {
  Step 'export-mod'
  $tex = Join-Path $Exp 'mod'
  Remove-Item $tex -Recurse -Force -ErrorAction SilentlyContinue
  $r = & "$PSScriptRoot\export-englishzone.ps1" -Source mod -Game GAME_UE5_1 -Usmap $ModUsmap `
    -Filter '^Stalker2/Content/.*/T_[^/]*\.uasset$' -Out $tex 2>&1
  Check-Done $r 'mod texture export'
  $mb = Join-Path $Exp 'mod-batch'
  Remove-Item $mb -Recurse -Force -ErrorAction SilentlyContinue
  $r = & "$PSScriptRoot\export-englishzone.ps1" -Source mod -Game GAME_UE5_1 -Usmap $ModUsmap `
    -Filter '^Stalker2/Content/.*/(SM|MI)_[^/]*\.uasset$' -Mesh -Names -Out $mb 2>&1
  Check-Done $r 'mod mesh/MI export'
}

if (Want 'export-vanilla') {
  Step 'export-vanilla'
  $modTex = Join-Path $Exp 'mod'
  $pf = Join-Path $Zk 'vanilla-textures.txt'
  Get-ChildItem $modTex -Recurse -Filter *.png |
    ForEach-Object { ($_.FullName.Substring($modTex.Length + 1) -replace '\\', '/') -replace '\.png$', '.uasset' } |
    Set-Content $pf
  $vb = Join-Path $Exp 'vanilla-batch'
  Remove-Item $vb -Recurse -Force -ErrorAction SilentlyContinue
  Check-Done (& "$PSScriptRoot\export-englishzone.ps1" -Source vanilla -PathsFile $pf -JsonOnly -Out $vb 2>&1) 'vanilla texture export'
  $vm = Join-Path $Exp 'vanilla-mi'
  Remove-Item $vm -Recurse -Force -ErrorAction SilentlyContinue
  Check-Done (& "$PSScriptRoot\export-englishzone.ps1" -Source vanilla -Filter '/props/sign/Materials/MI_[^/]*\.uasset$' -Names -Out $vm 2>&1) 'vanilla MI export'
}

if (Want 'manifest') {
  Step 'manifest'
  & "$PSScriptRoot\make-englishzone-batch-manifest.ps1"
}

if (Want 'import') {
  Step 'import'
  & "$PSScriptRoot\run-import-englishzone-batch.ps1"
}

if (Want 'cook') {
  Step 'cook'
  $r = & "$PSScriptRoot\cook-englishzone.ps1" 2>&1
  $r | Select-Object -First 40
  if (-not ($r | Select-String 'BUILD SUCCESSFUL')) { throw 'cook failed (no BUILD SUCCESSFUL)' }
  if ($r | Select-String 'Failed to translate|translation failed') { throw 'cook reported translation failures' }
}

if (Want 'idmod') {
  Step 'idmod'
  & "$PSScriptRoot\build-englishzone-idmod.ps1"
}

if (Want 'validate') {
  Step 'validate'
  $expected = @(Get-ChildItem $PluginContent -Recurse -Filter '*.uasset').Count
  $vdir = Join-Path $Zk 'validate'
  Remove-Item $vdir -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path $vdir | Out-Null
  Copy-Item (Join-Path $Zk 'idmod-out\EnglishZone_P.*'), (Join-Path $PaksDir 'global.utoc'), (Join-Path $PaksDir 'global.ucas') $vdir
  $exe = Join-Path $PSScriptRoot '..\tools\EzExport\bin\Release\net10.0\EzExport.exe'
  $usmap = Join-Path $GameDir 'Stalker2\Binaries\Win64\ue4ss\Stalker2-5.5.4-0+UE5-5e627997.usmap'
  $r = & $exe --paks $vdir --game 84213760 --usmap $usmap --oodle 'C:\Tools\FModel\Output\.data\oodle-data-shared.dll' `
    --out (Join-Path $vdir 'out') --filter '\.uasset$' --list 2>&1
  $m = $r | Select-String 'matched (\d+) packages' | Select-Object -Last 1
  $game = @($r | Select-String '^\s*Stalker2/Content/').Count
  "container packages: $($m.Matches[0].Groups[1].Value) (expected $expected); /Game-rooted listing lines: $game"
  if (-not $m -or [int]$m.Matches[0].Groups[1].Value -ne $expected) { throw 'package count mismatch' }
  # Every package should collide with a vanilla /Game ID except the mod's brand-new MIs.
  $vanilla = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  Get-Content (Join-Path $Exp 'mod-batch\_package-names.txt') | Where-Object { $_ -like '/Game/*' } | ForEach-Object { [void]$vanilla.Add($_) }
  $new = @($r | Select-String '^\s*Stalker2/Content/(.*)\.uasset$' | ForEach-Object { '/Game/' + $_.Matches[0].Groups[1].Value } |
      Where-Object { -not $vanilla.Contains($_) })
  "packages with no vanilla counterpart: $($new.Count)"; $new | ForEach-Object { "  NEW $_" }
  if (@($new | Where-Object { $_ -notmatch '/MI_[^/]+$' }).Count) { throw 'non-MI package without vanilla counterpart (wrong path/case?)' }
}

if ($Deploy -and (Want 'deploy')) {
  Step 'deploy'
  if (Get-Process -Name 'Stalker2-Win64-Shipping' -ErrorAction SilentlyContinue) { throw 'Close the game first.' }
  $bk = Join-Path $Zk ("backup-deployed\" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
  New-Item -ItemType Directory -Force -Path $bk | Out-Null
  Copy-Item (Join-Path $ModsDir 'EnglishZone_P.*') $bk -ErrorAction SilentlyContinue
  "backed up current deployment -> $bk"
  & "$PSScriptRoot\deploy-englishzone.ps1"
}
