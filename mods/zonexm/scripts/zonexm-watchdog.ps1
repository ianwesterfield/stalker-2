# Zone XM watchdog — conversation awareness for music while playing Stalker 2.
#
# Watches the alert flag written by the ZoneXM UE4SS mod and ducks the output mix
# while it exists — per-app session volumes on the default device. Restores
# each app's pre-duck volume on clear, on exit, and if the flag goes stale
# (game killed mid-alert). Sessions appearing mid-duck (app restarted during
# combat) get ducked on the next poll.
#
#   .\zonexm-watchdog.ps1                                   # duck EVERYTHING except the game (default)
#   .\zonexm-watchdog.ps1 -ProcessName Pandora,msedge       # narrow: duck only these
#   .\zonexm-watchdog.ps1 -AllButProcess Stalker2-Win64-Shipping,Discord
#   .\zonexm-watchdog.ps1 -DuckLevel 0.15 -PollMs 500
# Run it hidden at logon; needs PowerShell 7+ (pure COM, no modules).

[CmdletBinding()]
param(
    [string[]]$ProcessName, # If passed: narrow mode.
    [string[]]$AllButProcess = @("Stalker2-Win64-Shipping"),
    [double]$DuckLevel = 0.15, # Fraction of pre-duck volume.
    [int]$PollMs = 500,
    [int]$StaleAfterSec = 8, # Older flags indicate a dead game.
    [int]$DuckFadeMs = 350,
    [int]$RestoreFadeMs = 1500,
    [switch]$NoBanner
)
$ErrorActionPreference = 'Stop'

# Stacked watchdogs race their volume baselines.
$isMutexCreated = $false
$script:instanceMutex = New-Object System.Threading.Mutex($true, "ZoneXM.Watchdog.Singleton", [ref]$isMutexCreated)
if (-not $isMutexCreated) {
    Write-Host "ZoneXM watchdog already running — exiting"
    exit 0
}

$alertPath = Join-Path $env:USERPROFILE "ZoneXM\alert.flag"
# The Lua reader must not shell out: a console flash steals game input focus.
$null = New-Item -ItemType Directory -Path (Split-Path $alertPath) -Force

try {
    Add-Type -Path (Join-Path $PSScriptRoot 'AudioSessions.cs')
}
catch {
    Write-Host "ZoneXM: interop compile failed: $($_.Exception.Message)"
    throw
}

if (-not ('ZoneXM.Audio.AudioSessions' -as [type])) {
    throw 'ZoneXM: audio session interop type missing after compile'
}

# returns pid -> ISimpleAudioVolume for the sessions this run is targeting
function Find-TargetVolumes {
    $sessions = [ZoneXM.Audio.AudioSessions]::EnumerateVolumes()
    $targetVolumes = @{}

    if ($PSBoundParameters.ContainsKey('ProcessName')) {
        $includedProcessIds = @{}

        foreach ($name in $ProcessName) {
            Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object { $includedProcessIds[$_.Id] = $true }
        }

        foreach ($session in $sessions.GetEnumerator()) {
            if ($includedProcessIds.ContainsKey($session.Key)) {
                $targetVolumes[$session.Key] = $session.Value
            }
        }
    }
    else {
        $excludedProcessIds = @{}

        foreach ($name in $AllButProcess) {
            Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object { $excludedProcessIds[$_.Id] = $true }
        }

        foreach ($session in $sessions.GetEnumerator()) {
            if (-not $excludedProcessIds.ContainsKey($session.Key)) {
                $targetVolumes[$session.Key] = $session.Value
            }
        }
    }

    return $targetVolumes
}

# Each process restores to its own pre-duck volume.
$script:baselines = @{}
$script:isDucked = $false

function Restore-Duck {
    foreach ($session in $script:baselines.GetEnumerator()) {
        try {
            [ZoneXM.Audio.AudioSessions]::SetVolume($session.Value.Volume, $session.Value.Level)
        }

        catch {
            Write-Warning "ZoneXM could not restore process $($session.Key): $($_.Exception.Message)"
        }
    }
    $script:baselines = @{}
}

# apply baseline*factor to every tracked session (factor 1.0 = untouched)
function Set-DuckFactor([double]$Factor) {
    foreach ($session in $script:baselines.GetEnumerator()) {
        try {
            [ZoneXM.Audio.AudioSessions]::SetVolume($session.Value.Volume, [float]($session.Value.Level * $Factor))
        }
        catch {
            Write-Warning "ZoneXM could not update process $($session.Key): $($_.Exception.Message)"
        }
    }
}

# smoothstep ease between duck factors; DoEvents keeps the tray alive mid-fade
function Start-Fade([double]$From, [double]$To, [int]$DurationMs) {
    $steps = [math]::Max(1, [int]($DurationMs / 33))

    for ($stepIndex = 1; $stepIndex -le $steps; $stepIndex++) {
        $progress = $stepIndex / $steps
        $easedProgress = $progress * $progress * (3 - 2 * $progress)
        Set-DuckFactor ($From + ($To - $From) * $easedProgress)
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 33
    }
}

if ($PSBoundParameters.ContainsKey('ProcessName')) {
    Write-Host "ZoneXM watchdog armed: duck [$($ProcessName -join ', ')] x$DuckLevel on alert (flag: $alertPath)"
}
else {
    Write-Host "ZoneXM watchdog armed: duck ALL except [$($AllButProcess -join ', ')] x$DuckLevel on alert (flag: $alertPath)"
}

# tray icon: visible proof of life, tooltip carries duck state, right-click Exit
# restores. DoEvents in the poll loop keeps the tray responsive.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$iconPath = Join-Path $PSScriptRoot 'zonexm.png'
$script:shouldQuit = $false
$script:tray = $null
$script:trayBitmap = $null

if (Test-Path $iconPath) {
    $script:trayBitmap = [System.Drawing.Bitmap]::FromFile($iconPath)
    $iconHandle = $script:trayBitmap.GetHicon()
    $script:tray = New-Object System.Windows.Forms.NotifyIcon
    $script:tray.Icon = [System.Drawing.Icon]::FromHandle($iconHandle)
    $script:tray.Text = 'ZoneXM: armed'
    $contextMenu = New-Object System.Windows.Forms.ContextMenuStrip
    [void]$contextMenu.Items.Add('Exit ZoneXM')
    $contextMenu.Items[0].add_Click({ $script:shouldQuit = $true })
    $script:tray.ContextMenuStrip = $contextMenu
    $script:tray.Visible = $true
}
else {
    Write-Host "tray icon missing ($iconPath) — running headless"
}

function Set-TrayState([string]$state) {
    if ($script:tray) {
        $script:tray.Text = "ZoneXM: $state"
    }
}

$mediaProcess = $null

try {
    if (-not $NoBanner) {
        try {
            $mediaBridgePath = Join-Path $PSScriptRoot 'zonexm-media.ps1'
            $mediaProcess = Start-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
                -ArgumentList @('-NoProfile', '-NonInteractive', '-File', "`"$mediaBridgePath`"", '-ParentProcessId', $PID) `
                -WindowStyle Hidden -PassThru `
                -RedirectStandardOutput (Join-Path (Split-Path $alertPath) 'media.log') `
                -RedirectStandardError (Join-Path (Split-Path $alertPath) 'media-error.log')
        }
        catch {
            Write-Warning "ZoneXM banners unavailable: $($_.Exception.Message). Ducking remains active."
        }
    }

    while (-not $script:shouldQuit) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds $PollMs

        if ($mediaProcess -and $mediaProcess.HasExited) {
            Write-Warning "ZoneXM media bridge exited ($($mediaProcess.ExitCode)); see media-error.log beside alert.flag. Ducking remains active."
            $mediaProcess.Dispose()
            $mediaProcess = $null
        }

        $isAlert = Test-Path $alertPath

        if ($isAlert) {
            # a flag older than the staleness window means the game died mid-alert
            try {
                if ((Get-Item $alertPath).LastWriteTime -lt (Get-Date).AddSeconds(-$StaleAfterSec)) {
                    Remove-Item $alertPath -Force
                    $isAlert = $false
                }
            }
            catch {
                Write-Warning "ZoneXM could not inspect the alert flag; restoring audio: $($_.Exception.Message)"
                $isAlert = $false
            }
        }

        if ($isAlert) {
            $currentVolumes = Find-TargetVolumes
            $newVolumesWhileDucked = @()

            foreach ($session in $currentVolumes.GetEnumerator()) {
                if (-not $script:baselines.ContainsKey($session.Key)) {
                    $originalLevel = [ZoneXM.Audio.AudioSessions]::GetVolume($session.Value)

                    if ($originalLevel -gt 0.001) {
                        $script:baselines[$session.Key] = @{
                            Level = $originalLevel
                            Volume = $session.Value
                        }

                        if ($script:isDucked) {
                            $newVolumesWhileDucked += $session.Value
                        }

                        $trackedProcessName = (Get-Process -Id $session.Key -ErrorAction SilentlyContinue).ProcessName
                        Write-Host "$(Get-Date -Format HH:mm:ss) tracking $trackedProcessName @ $([math]::Round($originalLevel, 3))"
                    }
                }
            }
            if (-not $script:isDucked -and $script:baselines.Count -gt 0) {
                Set-TrayState 'DUCKED (combat)'
                Start-Fade 1.0 $DuckLevel $DuckFadeMs
                $script:isDucked = $true
                Write-Host "$(Get-Date -Format HH:mm:ss) ducked x$DuckLevel ($($script:baselines.Count) sessions)"
            }
            elseif ($script:isDucked) {
                # latecomers conform instantly; everyone else is already down
                foreach ($volume in $newVolumesWhileDucked) {
                    try {
                        [ZoneXM.Audio.AudioSessions]::SetVolume($volume, [float]([ZoneXM.Audio.AudioSessions]::GetVolume($volume) * $DuckLevel))
                    }
                    catch {
                        Write-Warning "ZoneXM could not duck a new audio session: $($_.Exception.Message)"
                    }
                }
            }
        }
        elseif (-not $isAlert -and $isDucked) {
            Start-Fade $DuckLevel 1.0 $RestoreFadeMs
            Restore-Duck
            $script:isDucked = $false
            Set-TrayState 'armed'
            Write-Host "$(Get-Date -Format HH:mm:ss) restored all"
        }
    }
}
finally {
    Restore-Duck

    if ($mediaProcess) {
        if (-not $mediaProcess.HasExited) {
            Stop-Process -Id $mediaProcess.Id -ErrorAction Continue
        }

        $mediaProcess.Dispose()
    }

    if ($script:tray) {
        $script:tray.Visible = $false
        $script:tray.Dispose()
    }

    if ($script:trayBitmap) {
        $script:trayBitmap.Dispose()
    }

    if ($script:instanceMutex) {
        $script:instanceMutex.ReleaseMutex()
        $script:instanceMutex.Dispose()
    }
}
