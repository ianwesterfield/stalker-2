[CmdletBinding()]
param([switch]$InstallLoader, [switch]$Remove)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\..\shared\scripts\paths.ps1"
$win64 = Join-Path $GameDir 'Stalker2\Binaries\Win64'
$plugin = Join-Path $win64 'ZoneStash.asi'
if (Get-Process -Name Stalker2-Win64-Shipping -ErrorAction SilentlyContinue) {
    throw 'Close the game before installing or removing ZoneStash.'
}
if ($Remove) {
    if (Test-Path $plugin) { Remove-Item -LiteralPath $plugin }
    Write-Host 'ZoneStash removed. The shared ASI loader and other mods were left untouched.'
    return
}
$source = Join-Path $BuildDir 'zonestash\ZoneStash.asi'
if (-not (Test-Path $source)) { throw 'Run build-zonestash.ps1 first.' }
$expected = '2BD3F115B959A8EEE7E5C4B42B0142DD0025BD437E1014F92DFC60B9AFEE5479'
if ((Get-FileHash (Join-Path $win64 'Stalker2-Win64-Shipping.exe')).Hash -ne $expected) {
    throw 'This prototype supports only the verified Steam 2.1.0 executable. No files were installed.'
}
$loader = Join-Path $win64 'winhttp.dll'
if (-not (Test-Path $loader)) {
    if (-not $InstallLoader) { throw 'ASI loader missing. Rerun with -InstallLoader to install the official pinned x64 loader.' }
    $cache = Join-Path $BuildDir 'zonestash-loader'
    New-Item -ItemType Directory -Force -Path $cache | Out-Null
    $zip = Join-Path $cache 'Ultimate-ASI-Loader-v10.0.2-x64.zip'
    if (-not (Test-Path $zip)) {
        Invoke-WebRequest 'https://github.com/ThirteenAG/Ultimate-ASI-Loader/releases/download/v10.0.2/Ultimate-ASI-Loader_x64.zip' -OutFile $zip
    }
    if ((Get-FileHash $zip).Hash -ne 'A99E188E1F40D7AAC9DB9C0339990332152D372E0359FAA06A52FA339E8B218F') {
        throw 'ASI loader archive hash mismatch; nothing installed.'
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        $entry = $archive.GetEntry('dinput8.dll')
        if (-not $entry) { throw 'Pinned ASI loader archive lacks dinput8.dll.' }
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $loader, $false)
    }
    finally { $archive.Dispose() }
    Write-Host 'Installed official Ultimate ASI Loader 10.0.2 as winhttp.dll; existing UE4SS dwmapi.dll unchanged.'
}
else {
    Write-Host 'Keeping existing winhttp.dll. It must support ASI loading; ZoneStash.log confirms startup.'
}
Copy-Item -LiteralPath $source -Destination $plugin -Force
if ((Get-FileHash $source).Hash -ne (Get-FileHash $plugin).Hash) { throw 'Installed plugin hash does not match the build.' }
Write-Host 'ZoneStash installed. Restart and test on a separate manual save; see ZoneStash.log beside the game executable.'
