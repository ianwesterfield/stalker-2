[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

$modDir = Split-Path $PSScriptRoot -Parent
$repoRoot = Split-Path (Split-Path $modDir -Parent) -Parent
$buildDir = Join-Path $repoRoot 'build\quest-stash'
$sourceDir = Join-Path $modDir 'src'

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"

if (-not (Test-Path $vswhere)) {
    throw 'Visual Studio C++ build tools are required.'
}

$visualStudioDir = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath

if (-not $visualStudioDir) {
    throw 'Install the Visual Studio x64 C++ tools.'
}

$vcvars = Join-Path $visualStudioDir 'VC\Auxiliary\Build\vcvars64.bat'
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

# The compiler environment must remain in the same cmd.exe process as the build.
$commands = @(
    "call `"$vcvars`" >nul",
    "cd /d `"$buildDir`"",
    "cl /nologo /std:c++20 /W4 /WX /O2 /MT /EHsc `"$sourceDir\PolicyTests.cpp`" /Fe:PolicyTests.exe",
    'PolicyTests.exe',
    "cl /nologo /std:c++20 /W4 /WX /O2 /MT /EHsc `"$sourceDir\MenuTests.cpp`" /Fe:MenuTests.exe /link bcrypt.lib",
    'MenuTests.exe',
    "cl /nologo /std:c++20 /W4 /WX /O2 /MT /EHsc /LD `"$sourceDir\QuestStash.cpp`" /link /OUT:QuestStash.asi bcrypt.lib"
)
& $env:ComSpec /d /c ($commands -join ' && ')

if ($LASTEXITCODE -ne 0) {
    throw 'QuestStash build or tests failed.'
}

Write-Host "Built $buildDir\QuestStash.asi. Not installed; requires an ASI loader and a game restart."
