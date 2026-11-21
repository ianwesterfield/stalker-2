# Pre-launch sync: rebuild ZoneAtlas_P when the installed map mods changed (added, removed or
# updated, from any source), then make sure the current build is what ~mods holds. Never blocks
# the launch: on any error it logs, pauses briefly and returns so the game still starts.
# Run by zoneatlas-launch.cmd (Steam launch option); safe to run by hand with the game closed.
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\..\..\..\shared\scripts\paths.ps1"

$Out = Join-Path $BuildDir 'zoneatlas\out'
$Log = Join-Path $BuildDir 'zoneatlas\sync.log'
New-Item -ItemType Directory -Force (Split-Path $Log) | Out-Null

function Test-Deployed {
  foreach ($f in Get-ChildItem $Out -File -Filter 'ZoneAtlas_P.*') {
    $d = Get-Item (Join-Path $ModsDir $f.Name) -ErrorAction SilentlyContinue
    if (-not $d -or $d.Length -ne $f.Length -or $d.LastWriteTimeUtc -ne $f.LastWriteTimeUtc) { return $false }
  }
  $live = Join-Path $GameDir 'Stalker2\Binaries\Win64\ue4ss\Mods\ZoneAtlas\Scripts\atlas_manifest.lua'
  (Test-Path $live) -and (Get-FileHash $live).Hash -eq (Get-FileHash (Join-Path $Out 'atlas_manifest.lua')).Hash
}

Start-Transcript -Path $Log -Force | Out-Null
try {
  if (Get-Process -Name 'Stalker2-Win64-Shipping' -ErrorAction SilentlyContinue) {
    Write-Warning 'The game is already running; ZoneAtlas sync skipped.'
    return
  }
  Write-Host 'ZoneAtlas: checking installed map mods...'
  & (Join-Path $PSScriptRoot 'build-zoneatlas.ps1') -IfChanged
  if (Test-Deployed) { Write-Host 'ZoneAtlas: deployed build is current.' }
  else { & (Join-Path $PSScriptRoot 'deploy-zoneatlas.ps1') -ContainerOnly }
}
catch {
  Write-Warning "ZoneAtlas sync failed: $_  (the game will start with the previous build; details in $Log)"
  Start-Sleep -Seconds 8
}
finally {
  Stop-Transcript | Out-Null
}
