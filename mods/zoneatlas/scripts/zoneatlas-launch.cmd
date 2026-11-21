@echo off
rem Steam > S.T.A.L.K.E.R. 2 > Properties > Launch options:
rem   "C:\Code\westerfield.cloud\Gaming\stalker-2\mods\zoneatlas\scripts\zoneatlas-launch.cmd" %command%
rem Syncs ZoneAtlas with whatever map mods are installed, then runs the game command Steam passes.
title ZoneAtlas sync
set "ZA_PS=powershell.exe"
where pwsh.exe >nul 2>&1 && set "ZA_PS=pwsh.exe"
%ZA_PS% -NoProfile -ExecutionPolicy Bypass -File "%~dp0sync-zoneatlas.ps1"
if "%~1"=="" exit /b 0
start "" %*