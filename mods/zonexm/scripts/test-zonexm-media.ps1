$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\zonexm-media.ps1"

function Assert($Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}
function New-Session([string]$Id, [string]$Status) {
  $session = [pscustomobject]@{ SourceAppUserModelId = $Id; Status = $Status }
  $session | Add-Member ScriptMethod GetPlaybackInfo { [pscustomobject]@{ PlaybackStatus = $this.Status } }
  return $session
}
$pandora = New-Session 'Pandora' 'Playing'
$itunes = New-Session 'iTunes' 'Playing'
$manager = [pscustomobject]@{ Current = $itunes; Sessions = @($pandora, $itunes) }
$manager | Add-Member ScriptMethod GetCurrentSession { $this.Current }
$manager | Add-Member ScriptMethod GetSessions { $this.Sessions }
Assert ((Select-PlayingSession $manager) -eq $itunes) 'Did not prefer Windows current playing session'
$itunes.Status = 'Paused'
Assert ((Select-PlayingSession $manager) -eq $pandora) 'Did not fall back from paused preferred session'
$pandora.Status = 'Stopped'
Assert ($null -eq (Select-PlayingSession $manager)) 'Stopped media was selected'
$manager.Current = $null
$manager.Sessions = @()
Assert ($null -eq (Select-PlayingSession $manager)) 'Empty session list was not handled'
Write-Host 'PASS: app-agnostic current-session selection and playing-only fallback'

$path = Join-Path ([IO.Path]::GetTempPath()) ("zonexm-test-" + [Guid]::NewGuid().ToString() + '.txt')
$worker = $null
try {
  $unicode = [string][char]0x00e9 + [char]0x97f3
  Write-MediaSnapshot $path "App`r`nId" "Title`n$unicode" "Artist`tName"
  $bytes = [IO.File]::ReadAllBytes($path)
  Assert ($bytes[0] -eq 90) 'UTF-8 BOM was written'
  $lines = [IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8)
  Assert ($lines.Count -eq 5 -and $lines[0] -ceq 'ZoneXM/1') 'Invalid wire format'
  Assert ($lines[2] -ceq 'App  Id' -and $lines[3] -ceq "Title $unicode") 'Control characters/Unicode corrupted'
  Assert ($lines[4] -ceq 'Artist Name') 'Artist controls not sanitized'
  Assert ([math]::Abs([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [long]$lines[1]) -le 2) 'Heartbeat is not current UTC'
  Write-MediaSnapshot $path 'OtherApp' 'Next song' ''
  $lines = [IO.File]::ReadAllLines($path)
  Assert ($lines.Count -eq 5 -and $lines[3] -ceq 'Next song' -and $lines[4] -eq '') 'Atomic replacement or empty artist failed'
  Write-MediaSnapshot $path '' '' ''
  $lines = [IO.File]::ReadAllLines($path)
  Assert ($lines.Count -eq 5 -and $lines[2] -eq '' -and $lines[3] -eq '') 'Inactive snapshot invalid'
  $long = ('x' * 239) + [char]0xd83c + [char]0xdfb5
  Assert ((ConvertTo-MediaLine $long).Length -eq 239) 'Truncation split a surrogate pair'
  Write-Host 'PASS: atomic snapshots, UTF-8, sanitization, heartbeat, empty fields, and bounded text'
  & "$PSHOME\powershell.exe" -NoProfile -File "$PSScriptRoot\zonexm-media.ps1" -Once -OutputPath $path
  Assert ($LASTEXITCODE -eq 0) 'Live bridge entry point failed'
  $lines = [IO.File]::ReadAllLines($path)
  Assert ($lines.Count -eq 5 -and $lines[0] -ceq 'ZoneXM/1') 'Live bridge did not write its snapshot'
  Write-Host 'PASS: live one-shot bridge publishes the reader protocol'
  [IO.File]::Delete($path)
  $worker = Start-Process "$PSHOME\powershell.exe" -WindowStyle Hidden -PassThru `
    -ArgumentList @('-NoProfile', '-NonInteractive', '-File', "`"$PSScriptRoot\zonexm-media.ps1`"",
      '-ParentProcessId', $PID, '-OutputPath', "`"$path`"") `
    -RedirectStandardOutput "$path.log" -RedirectStandardError "$path.err"
  $deadline = (Get-Date).AddSeconds(10)
  while (-not [IO.File]::Exists($path) -and -not $worker.HasExited -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 100
  }
  Assert (-not $worker.HasExited -and [IO.File]::Exists($path)) 'Supervised bridge did not become ready'
  $firstBeat = [long]([IO.File]::ReadAllLines($path)[1])
  Start-Sleep -Milliseconds 1500
  Assert ([long]([IO.File]::ReadAllLines($path)[1]) -gt $firstBeat) 'Bridge heartbeat did not advance'
  Write-Host 'PASS: supervised hidden bridge stays responsive and refreshes its heartbeat'
}
finally {
  if ($worker) {
    if (-not $worker.HasExited) { Stop-Process -Id $worker.Id }
    $worker.WaitForExit()
    $worker.Dispose()
  }
  if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
  foreach ($log in @("$path.log", "$path.err")) {
    if ([IO.File]::Exists($log)) { [IO.File]::Delete($log) }
  }
}

Initialize-Media
$manager = Get-MediaManager
Assert ($null -ne $manager) 'Live Windows media manager unavailable'
Write-Host 'PASS: live WinRT manager request (Windows PowerShell 5.1)'
