param(
  [string]$Plugin = 'EnglishZone'
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\..\shared\scripts\paths.ps1"

if (Get-Process -Name 'Stalker2ModEditor*' -ErrorAction SilentlyContinue) { throw 'ZoneKit editor is running - close it first' }

$zk = 'C:\Program Files\Epic Games\STALKER2ZoneKit'
$log = Join-Path $BuildDir "EnglishZone-zk\cook-$Plugin.log"

& "$zk\Engine\Build\BatchFiles\RunUAT.bat" GSCCookModOverrideContent `
  "-Project=$zk\Stalker2\Stalker2.uproject" `
  "-PluginPath=$zk\Stalker2\Mods\$Plugin\$Plugin.uplugin" `
  -TargetPlatform=Win64 -CustomConfig=ModCookOverrideContent -nocompile -nocompileuat `
  "-unrealexe=$zk\Stalker2\Binaries\Win64\Stalker2ModEditor-Win64-Shipping-Cmd.exe" *>&1 |
  Tee-Object -FilePath $log | Select-String -Pattern 'BUILD (SUCCESSFUL|FAILED)|AutomationTool exiting|Error:' | ForEach-Object Line | Select-Object -First 30

"=== translation check (must be empty):"
Select-String -Path $log -Pattern 'Failed to translate|translation failed' | ForEach-Object Line
"=== staged output:"
Get-ChildItem "$zk\Stalker2\SavedMods\Staged\$Plugin" -Recurse -File -ErrorAction SilentlyContinue |
  Select-Object FullName, Length | Format-Table -AutoSize | Out-String -Width 220
