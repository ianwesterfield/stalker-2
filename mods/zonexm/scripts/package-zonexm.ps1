[CmdletBinding()]
param([string]$OutputDirectory)
$ErrorActionPreference = 'Stop'

$modRoot = Split-Path $PSScriptRoot -Parent
$lua = Join-Path $modRoot 'ue4ss\ZoneXM\Scripts\main.lua'
$repoRoot = Split-Path (Split-Path $modRoot -Parent) -Parent
$version = [regex]::Match((Get-Content $lua -Raw), 'local VERSION = "([^"]+)"').Groups[1].Value

if (-not $version) {
    throw "VERSION not found in $lua"
}

$outputPath = if ($OutputDirectory) {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
}
else {
    Join-Path $repoRoot 'build\release'
}
$null = New-Item -ItemType Directory -Path $outputPath -Force

$readme = @"
ZoneXM $version - conversation awareness for your own music in S.T.A.L.K.E.R. 2

Play your own music over the game. ZoneXM lowers it when gunfire, dialogue, nearby voices
or mutants need your ears, and brings it back when the dust settles. It can also show
notifications from selected apps as in-game banners.

REQUIREMENTS
- A UE4SS build compatible with your S.T.A.L.K.E.R. 2 version and game edition.
- ZoneXM Companion 1.3.1 or later from the Microsoft Store (free):
  https://apps.microsoft.com/detail/9pcw3mjw0zwl
- In-game subtitles enabled for speech detection.

The companion ducks other apps on the default Windows audio device. It automatically
excludes the Steam game process only; game audio in other editions may also be ducked.

INSTALL WITH VORTEX
Install and enable this archive with the S.T.A.L.K.E.R. 2 Vortex game extension, then deploy.
If the UE4SS Load Order page is enabled, make sure ZoneXM is enabled there too.

INSTALL MANUALLY
Extract this archive into the game's install folder (the one that contains the Stalker2
folder) and allow it to merge. The mod lands in
  Stalker2\Binaries\{0}\ue4ss\Mods\ZoneXM

For either installation method, start ZoneXM Companion and keep it running while playing.
To show notifications in-game, turn on Windows notifications, click Allow notification
access / Start in the companion, approve the Windows prompt, and select the apps to forward.
Only new notifications from selected apps that use Notification Center are forwarded.
Notification access is not needed for audio ducking.

Version 1.0.1 and later require Companion 1.3.1 or later: both use
  %USERPROFILE%\ZoneXM
Older mod/companion versions use a different folder and cannot be mixed.

UNINSTALL
Disable and remove ZoneXM in Vortex, or, for a manual installation, delete
Stalker2\Binaries\{0}\ue4ss\Mods\ZoneXM. Shared files live in %USERPROFILE%\ZoneXM.

Source, issues and privacy policy: https://github.com/ianwesterfield/stalker-2
License: MIT (see LICENSE.txt)
"@

foreach ($edition in @(@{ Binaries = 'Win64'; Name = 'Steam' }, @{ Binaries = 'WinGDK'; Name = 'GamePass' })) {
    $stage = Join-Path ([IO.Path]::GetTempPath()) "zonexm-$($edition.Name)-$([guid]::NewGuid().ToString('N'))"

    try {
        $destination = Join-Path $stage "Stalker2\Binaries\$($edition.Binaries)\ue4ss\Mods\ZoneXM"
        $null = New-Item -ItemType Directory -Path $destination -Force
        Copy-Item (Join-Path $modRoot 'ue4ss\ZoneXM\*') $destination -Recurse -Force
        Set-Content (Join-Path $destination 'enabled.txt') '' -NoNewline
        Copy-Item (Join-Path $modRoot 'LICENSE') (Join-Path $destination 'LICENSE.txt')
        Set-Content (Join-Path $destination 'README.txt') ($readme -f $edition.Binaries) -Encoding utf8

        $archivePath = Join-Path $outputPath "ZoneXM-$version-$($edition.Name).zip"

        if (Test-Path $archivePath) {
            Remove-Item $archivePath
        }

        Compress-Archive -Path (Join-Path $stage 'Stalker2') -DestinationPath $archivePath
        Write-Host "Wrote $archivePath"
    }
    finally {
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
}
