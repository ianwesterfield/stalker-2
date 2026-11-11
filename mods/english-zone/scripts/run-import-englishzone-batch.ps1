# Runs import-englishzone-batch.py in the ZoneKit commandlet against batch-manifest.json.
# -Phases / -Filter narrow the run (e.g. a smoke test on a few assets before the full batch).
param(
  [string[]]$Phases = @('textures', 'materials', 'meshes'),
  [string]$Filter = '',
  [string]$Manifest = ''
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\..\shared\scripts\paths.ps1"

if (Get-Process -Name 'Stalker2ModEditor*' -ErrorAction SilentlyContinue) { throw 'ZoneKit editor is running - close it first' }

$zk = 'C:\Program Files\Epic Games\STALKER2ZoneKit'
$cmd = "$zk\Stalker2\Binaries\Win64\Stalker2ModEditor-Win64-Shipping-Cmd.exe"
if (-not $Manifest) { $Manifest = Join-Path $BuildDir 'EnglishZone-zk\batch-manifest.json' }
if (-not (Test-Path $Manifest)) { throw "manifest missing: $Manifest (run make-englishzone-batch-manifest.ps1)" }

$env:EZ_BATCH_MANIFEST = $Manifest
$env:EZ_BATCH_PHASES = $Phases -join ','
$env:EZ_BATCH_FILTER = $Filter
$log = Join-Path $BuildDir 'EnglishZone-zk\import-batch.log'
# Mesh slot/collision edits need StaticMeshEditorSubsystem, which only exists in the full editor
# (GEditor); the -Cmd commandlet can't host it. Run the GUI binary, which quits itself when done.
$gui = $Phases -contains 'meshes'
try {
  if ($gui) {
    $env:EZ_BATCH_GUI = '1'
    Remove-Item $log -ErrorAction SilentlyContinue
    $p = Start-Process "$zk\Stalker2\Binaries\Win64\Stalker2ModEditor-Win64-Shipping.exe" -PassThru -Wait -ArgumentList @(
      "`"$zk\Stalker2\Stalker2.uproject`"", "-ExecutePythonScript=`"$PSScriptRoot\import-englishzone-batch.py`"",
      '-unattended', '-nosplash', '-nop4', "-ABSLOG=`"$log`"")
    $global:LASTEXITCODE = $p.ExitCode
    Select-String -Path $log -Pattern 'EZ_BATCH_(FAIL|WARN|DONE)|Traceback|Error: .*\.py' | ForEach-Object { $_.Line }
  }
  else {
    & $cmd "$zk\Stalker2\Stalker2.uproject" -run=pythonscript -script="$PSScriptRoot\import-englishzone-batch.py" -stdout -unattended -nosplash *>&1 |
    Tee-Object -FilePath $log | Select-String -Pattern 'EZ_BATCH_(FAIL|WARN|DONE)|Traceback|Error: .*\.py' | ForEach-Object { $_.Line }
  }
}
finally {
  Remove-Item Env:EZ_BATCH_MANIFEST, Env:EZ_BATCH_PHASES, Env:EZ_BATCH_FILTER, Env:EZ_BATCH_GUI -ErrorAction SilentlyContinue
}
$okCount = @(Select-String -Path $log -Pattern 'EZ_BATCH_OK').Count
"ok lines=$okCount  exit=$LASTEXITCODE  log=$log"
$done = Select-String -Path $log -Pattern 'EZ_BATCH_DONE ok=(\d+) fail=(\d+)' | Select-Object -Last 1
if (-not $done) { throw 'import did not reach EZ_BATCH_DONE' }
if ([int]$done.Matches[0].Groups[2].Value -gt 0) { throw "import had $($done.Matches[0].Groups[2].Value) failure(s)" }
