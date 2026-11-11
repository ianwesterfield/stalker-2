# Windows PowerShell 5.1 supplies the WinRT projection missing from PowerShell 7.
# Read-only GSMTC bridge: no playback commands, streaming APIs, or app automation.
[CmdletBinding()]
param(
  [switch]$Probe,
  [switch]$Once,
  [int]$ParentProcessId = 0,
  [string]$OutputPath = "$env:LOCALAPPDATA\ZoneXM\now-playing.txt"
)
$ErrorActionPreference = 'Stop'

function Initialize-Media {
  Add-Type -AssemblyName System.Runtime.WindowsRuntime
  $null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
  $script:asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and
    $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
  } | Select-Object -First 1
  if (-not $script:asTask) { throw 'WinRT AsTask adapter is unavailable' }
}

function Wait-Media($Operation, [type]$ResultType) {
  $task = $script:asTask.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
  if (-not $task.Wait(3000)) {
    $Operation.Cancel()
    throw 'Windows media request timed out after 3 seconds'
  }
  return $task.Result
}

function Get-MediaManager {
  Wait-Media ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) `
    ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
}

function Select-PlayingSession($Manager) {
  $current = $Manager.GetCurrentSession()
  if ($current -and $current.GetPlaybackInfo().PlaybackStatus.ToString() -eq 'Playing') {
    return $current
  }
  # Windows' preferred session can be paused while another app is playing.
  foreach ($session in @($Manager.GetSessions() | Sort-Object SourceAppUserModelId)) {
    if ($session.GetPlaybackInfo().PlaybackStatus.ToString() -eq 'Playing') { return $session }
  }
}

function ConvertTo-MediaLine([string]$Text) {
  $text = ($Text -replace '[\x00-\x1f\x7f-\x9f\u2028\u2029]', ' ').Trim()
  if ($text.Length -gt 240) {
    $length = 240
    if ([char]::IsHighSurrogate($text[$length - 1])) { $length-- }
    $text = $text.Substring(0, $length)
  }
  return $text
}

function Write-MediaSnapshot([string]$Path, [string]$Source, [string]$Title, [string]$Artist) {
  $lines = @('ZoneXM/1', [DateTimeOffset]::UtcNow.ToUnixTimeSeconds().ToString(),
    (ConvertTo-MediaLine $Source), (ConvertTo-MediaLine $Title), (ConvertTo-MediaLine $Artist))
  $temp = "$Path.$PID.tmp"
  try {
    [IO.File]::WriteAllText($temp, ($lines -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
    if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp, $Path, [NullString]::Value) }
    else { [IO.File]::Move($temp, $Path) }
  }
  finally {
    if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
  }
}

if ($MyInvocation.InvocationName -eq '.') { return }
Initialize-Media
$manager = Get-MediaManager
if ($Probe) {
  $sessions = @($manager.GetSessions())
  if (-not $sessions.Count) { Write-Host 'No Windows media sessions exposed. Start playback in a compatible player and probe again.' }
  foreach ($session in $sessions) {
    $properties = Wait-Media ($session.TryGetMediaPropertiesAsync()) `
      ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
    [pscustomobject]@{
      AppId = $session.SourceAppUserModelId
      Status = $session.GetPlaybackInfo().PlaybackStatus
      HasTitle = -not [string]::IsNullOrWhiteSpace($properties.Title)
    }
  }
  return
}

$created = $false
$mutex = [Threading.Mutex]::new($true, 'ZoneXM.Media.Singleton', [ref]$created)
if (-not $created) { $mutex.Dispose(); throw 'ZoneXM media bridge is already running' }
$parent = if ($ParentProcessId) { Get-Process -Id $ParentProcessId }
$null = New-Item -ItemType Directory -Path (Split-Path $OutputPath) -Force
$lastError = $null
$lastSource = $null
try {
  do {
    if ($parent -and $parent.HasExited) { break }
    try {
      $session = Select-PlayingSession $manager
      $source, $title, $artist = '', '', ''
      if ($session) {
        $properties = Wait-Media ($session.TryGetMediaPropertiesAsync()) `
          ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
        if ($session.GetPlaybackInfo().PlaybackStatus.ToString() -eq 'Playing') {
          $source = $session.SourceAppUserModelId
          $title = $properties.Title
          $artist = $properties.Artist
        }
      }
      Write-MediaSnapshot $OutputPath $source $title $artist
      if ($source -ne $lastSource) {
        Write-Host "ZoneXM media source: $(if ($source) { $source } else { '(none playing)' })"
        $lastSource = $source
      }
      if ($lastError) { Write-Host 'ZoneXM media bridge recovered'; $lastError = $null }
    }
    catch {
      if ($_.Exception.Message -ne $lastError) {
        $lastError = $_.Exception.Message
        [Console]::Error.WriteLine("ZoneXM media: $lastError")
      }
      if ($Once) { throw }
      # Never leave an old song looking live after a failed media request.
      Write-MediaSnapshot $OutputPath '' '' ''
    }
    if (-not $Once) { Start-Sleep -Milliseconds 1000 }
  } while (-not $Once)
}
finally {
  if (-not $Once) { Write-MediaSnapshot $OutputPath '' '' '' }
  if ($parent) { $parent.Dispose() }
  $mutex.ReleaseMutex()
  $mutex.Dispose()
}
