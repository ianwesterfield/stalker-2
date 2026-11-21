$ErrorActionPreference = 'Stop'

Add-Type -Path (Join-Path $PSScriptRoot 'AudioSessions.cs')
$sessions = [ZoneXM.Audio.AudioSessions]::EnumerateVolumes()

try {
    foreach ($volume in $sessions.Values) {
        $level = [ZoneXM.Audio.AudioSessions]::GetVolume($volume)

        if ($level -lt 0 -or $level -gt 1) {
            throw "CoreAudio returned an invalid session volume: $level"
        }
    }

    Write-Host "PASS: legacy interop compiled and read $($sessions.Count) sessions without changing volume"
}
finally {
    foreach ($volume in $sessions.Values) {
        $null = [Runtime.InteropServices.Marshal]::Release($volume)
    }
}
