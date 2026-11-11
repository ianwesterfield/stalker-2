[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$stage = Join-Path $root 'build\zonestash'
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { throw 'Visual Studio C++ build tools are required.' }
$vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw 'Install the Visual Studio x64 C++ tools.' }
$vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'
New-Item -ItemType Directory -Force -Path $stage | Out-Null
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'src'
$commands = @(
    "call `"$vcvars`" >nul",
    "cd /d `"$stage`"",
    "cl /nologo /std:c++20 /W4 /WX /O2 /MT /EHsc `"$source\PolicyTests.cpp`" /Fe:PolicyTests.exe",
    'PolicyTests.exe',
    "cl /nologo /std:c++20 /W4 /WX /O2 /MT /EHsc `"$source\MenuTests.cpp`" /Fe:MenuTests.exe /link bcrypt.lib",
    'MenuTests.exe',
    "cl /nologo /std:c++20 /W4 /WX /O2 /MT /EHsc /LD `"$source\ZoneStash.cpp`" /link /OUT:ZoneStash.asi bcrypt.lib"
)
& $env:ComSpec /d /c ($commands -join ' && ')
if ($LASTEXITCODE -ne 0) { throw 'ZoneStash build or tests failed.' }
Write-Host "Built $stage\ZoneStash.asi. Not installed; requires an ASI loader and a game restart."
