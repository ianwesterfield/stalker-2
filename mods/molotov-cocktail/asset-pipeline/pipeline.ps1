# One-entry molotov asset pipeline: Blender build -> FBX checks -> previews ->
# headless editor import/fix -> cook -> deploy to game. CI/CD-ready: every
# stage gates on real success signals (UE commandlet exit codes lie — boot
# noise like S2_DLC1 sets them — so editor/cook stages gate on log sentinels).
# Usage: .\pipeline.ps1 [-SkipBlender] [-SkipPreviews] [-SkipEditor] [-SkipCook] [-SkipDeploy] [-Force]
[CmdletBinding()]
param(
  [switch]$SkipBlender,
  [switch]$SkipPreviews,
  [switch]$SkipEditor,
  [switch]$SkipCook,
  [switch]$SkipDeploy,
  # run even while the GUI editor is open — contention is file-level, not
  # session-level, so this is safe IF: (1) SK/SM assets aren't dirty in the GUI
  # (Save All would roll back the import; materials are fine), (2) the GUI
  # isn't RESTARTED mid-run (startup with the junction present double-mounts
  # the plugin), (3) you accept the cook sees disk state, not unsaved edits
  [switch]$Force
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

$Blender = 'C:\Program Files\Blender Foundation\Blender 5.2\blender.exe'
$ZoneKit = 'C:\Program Files\Epic Games\STALKER2ZoneKit'
$Uproject = "$ZoneKit\Stalker2\Stalker2.uproject"
$EditorCmd = "$ZoneKit\Stalker2\Binaries\Win64\Stalker2ModEditor-Win64-Shipping-Cmd.exe"
$RunUAT = "$ZoneKit\Engine\Build\BatchFiles\RunUAT.bat"
$PluginDir = "$ZoneKit\Stalker2\Mods\MolotovBottle"
$Junction = "$ZoneKit\Stalker2\Plugins\MolotovBottle"
$Staged = @('NewContent', 'OverrideContent') | ForEach-Object {
  "$ZoneKit\Stalker2\SavedMods\Staged\MolotovBottle\Windows\$_\Windows\Stalker2\Mods\MolotovBottle\Content\Paks\Windows"
}
$CookedRoot = "$ZoneKit\Stalker2\SavedMods\Cooked\MolotovBottle\Windows"
$Classified = "$here\out\classifier"
$GamePaks = 'C:\Program Files (x86)\Steam\steamapps\common\S.T.A.L.K.E.R. 2 Heart of Chornobyl\Stalker2\Mods\MolotovBottle\Content\Paks\Windows'

function Stage([string]$name) { Write-Host "`n=== $name ===" -ForegroundColor Cyan }
function Fail([string]$msg) { Write-Host "PIPELINE FAILED: $msg" -ForegroundColor Red; exit 1 }
function Assert-EditorClosed([string]$why) {
  if (-not (Get-Process -Name 'Stalker2ModEditor-Win64-Shipping' -ErrorAction SilentlyContinue)) { return }
  if (-not $Force) { Fail "Zone Kit editor is open — $why (or re-run with -Force; see caveats at top of script)" }
  Write-Host "WARNING: editor open + -Force: don't Save All stale SK/SM, don't restart the editor mid-run, reload assets when prompted" -ForegroundColor Yellow
}

if (-not $SkipBlender) {
  Stage 'BLENDER BUILD'
  & $Blender -b -P "$here\build_molotov.py" 2>&1 | Tee-Object "$here\out\pipeline_blender.log" |
  Select-String -Pattern 'TRACE|final mesh|Error|Traceback' | ForEach-Object Line
  if ($LASTEXITCODE -ne 0) { Fail "blender build exit $LASTEXITCODE (out\pipeline_blender.log)" }

  Stage 'FBX CHECKS'
  & $Blender -b -P "$here\check_fbx.py" 2>&1 | Tee-Object "$here\out\pipeline_check.log" |
  Select-String -Pattern 'CHECK|Error|Traceback' | ForEach-Object Line
  if ($LASTEXITCODE -ne 0) { Fail "check_fbx exit $LASTEXITCODE (out\pipeline_check.log)" }
  if (-not (Select-String -Path "$here\out\pipeline_check.log" -Pattern 'CHECK_DONE' -Quiet)) {
    Fail 'check_fbx did not reach CHECK_DONE'
  }
}

if (-not $SkipPreviews) {
  Stage 'PREVIEWS'
  & $Blender -b "$here\out\molotov_bottle.blend" -P "$here\preview_render.py" 2>&1 |
  Select-String -Pattern 'Saved:|Error|Traceback' | ForEach-Object Line
  if ($LASTEXITCODE -ne 0) { Fail "preview render exit $LASTEXITCODE" }
}

if (-not $SkipEditor) {
  Stage 'HEADLESS EDITOR IMPORT'
  Assert-EditorClosed 'headless import saves SK/SM assets the GUI may hold dirty'
  $log = "$here\out\pipeline_editor.log"
  # stale physics asset is removed on DISK before boot: EditorAssetLibrary
  # delete_asset in the Shipping commandlet AV'd inside Force Delete (2026-11-02)
  $stalePA = "$PluginDir\Content\SK_MolotovBottle_PhysicsAsset.uasset"
  if (Test-Path $stalePA) {
    Remove-Item $stalePA
    Write-Host "pre-deleted stale physics asset (in-session delete crashes the commandlet)"
  }
  # commandlet can't see Mods\ plugins: GSC's mod mount is GUI-only, so stage
  # the plugin the way GSC's own cook does — junction into Plugins\
  if (-not (Test-Path $Junction)) {
    New-Item -ItemType Junction -Path $Junction -Target $PluginDir | Out-Null
  }
  try {
    & $EditorCmd $Uproject -run=pythonscript -script="$here\editor_headless_all.py" `
      -stdout -FullStdOutLogOutput -unattended -nopause -nosplash *> $log
  }
  finally {
    cmd /c rmdir $Junction  # junction left behind = duplicate plugin at next GUI start
  }
  Select-String -Path $log -Pattern 'HEADLESS_STEP|REIMPORT_QUEUED|Interchange import|slot \d|SLOTS_FIXED|\[fixsm\]|TEXT_IMPORT_DONE|HEADLESS_ALL_DONE' |
  ForEach-Object Line
  if (Select-String -Path $log -Pattern 'Python script executed with errors' -Quiet) {
    Fail "editor python errored (see $log)"
  }
  if (-not (Select-String -Path $log -Pattern 'HEADLESS_ALL_DONE' -Quiet)) {
    Fail "editor run ended without HEADLESS_ALL_DONE (see $log)"
  }
  foreach ($sentinel in 'SLOTS_FIXED saved=True', 'SM_FIXED saved=True', 'PHYS_DONE', 'TEXT_IMPORT_DONE saved=True') {
    if (-not (Select-String -Path $log -Pattern $sentinel -SimpleMatch -Quiet)) {
      Fail "missing '$sentinel' (see $log)"
    }
  }
}

if (-not $SkipCook) {
  Stage 'COOK'
  Assert-EditorClosed 'cook reads disk state — unsaved GUI edits will be missing from the pak'
  if (Test-Path $Junction) { cmd /c rmdir $Junction }  # cook mounts via -PluginPath; junction would double-mount
  $cookLog = "$here\out\pipeline_cook.log"
  $cookStart = Get-Date
  # Same split as the GUI's "Package mod": the game only merges a mod's
  # *_LocalizationDatabase from the OverrideContent container (remapped to /Game),
  # so it is classified as an override and everything else as new content.
  New-Item -ItemType Directory -Path $Classified -Force | Out-Null
  $packages = Get-ChildItem "$PluginDir\Content" -Recurse -Filter *.uasset | ForEach-Object {
    '/MolotovBottle/' + $_.FullName.Substring("$PluginDir\Content\".Length).Replace('\', '/') -replace '\.uasset$'
  }
  $overrides = $packages | Where-Object { $_ -like '*_LocalizationDatabase' }
  if (@($overrides).Count -ne 1) { Fail "expected one *_LocalizationDatabase, found: $($overrides -join ', ')" }
  $overrides | Set-Content "$Classified\OverridePackages.txt"
  $packages | Where-Object { $_ -notin $overrides } | Set-Content "$Classified\NewPackages.txt"
  & $RunUAT GSCCookMod "-Project=$Uproject" "-PluginPath=$PluginDir\MolotovBottle.uplugin" `
    "-PackageClassifierOutputDir=$Classified" -TargetPlatform=Win64 -nocompile -nocompileuat `
    "-unrealexe=$EditorCmd" *> $cookLog
  if ($LASTEXITCODE -ne 0) { Fail "cook exit $LASTEXITCODE (see $cookLog)" }
  # a material that compiles in-editor can still fail cook translation — pak
  # builds anyway with checkerboard fallback, so grep is the only gate
  $bad = Select-String -Path $cookLog -Pattern 'Failed to translate|translation failed'
  if ($bad) { $bad | Select-Object -First 5 | ForEach-Object Line; Fail 'material cook translation failure' }
  # item names/descriptions ship in the mod's own localization database (merged over
  # vanilla text by the game), not Game.locres. It must land in OverrideContent only.
  $dbFilter = 'Autogenerated_*_LocalizationDatabase.uexp'
  $cookedDb = Get-ChildItem "$CookedRoot\OverrideContent" -Recurse -Filter $dbFilter -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -ge $cookStart }
  if (-not $cookedDb) { Fail 'OverrideContent cook produced no mod localization database (run the editor step)' }
  if (Get-ChildItem "$CookedRoot\NewContent" -Recurse -Filter $dbFilter -ErrorAction SilentlyContinue) {
    Fail 'localization database was also cooked into NewContent (classifier lists not applied)'
  }
  $dbText = [IO.File]::ReadAllText($cookedDb[0].FullName, [Text.Encoding]::ASCII)
  $csvKeys = (Import-Csv "$here\..\localization\localization.en.csv").key
  $missing = $csvKeys | Where-Object { -not $dbText.Contains($_) }
  if ($missing) { Fail "cooked localization database lacks: $($missing -join ', ')" }
  Write-Host "localization database: $($cookedDb[0].FullName.Substring($CookedRoot.Length)) ($($csvKeys.Count) keys)"
  Get-ChildItem $Staged | Select-Object Name, Length, LastWriteTime | Format-Table | Out-String | Write-Host
}

if (-not $SkipDeploy) {
  Stage 'DEPLOY'
  $fresh = Get-ChildItem $Staged -File | Where-Object LastWriteTime -gt (Get-Date).AddHours(-1)
  foreach ($container in 'NewContent', 'OverrideContent') {
    if (-not ($fresh | Where-Object Name -like "*-$container.utoc")) { Fail "no freshly staged $container container" }
  }
  New-Item -ItemType Directory -Path $GamePaks -Force | Out-Null
  $fresh | Copy-Item -Destination $GamePaks -Force
  Get-ChildItem $GamePaks | Select-Object Name, Length, LastWriteTime | Format-Table | Out-String | Write-Host
}

Write-Host "`nPIPELINE OK" -ForegroundColor Green
