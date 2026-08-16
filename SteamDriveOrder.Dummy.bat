@echo off
setlocal
cd /d "%~dp0"
title SteamDriveOrder Dummy
echo Starting SteamDriveOrder in DUMMY mode.
echo Steam will stay open. No library files will be written.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0SteamDriveOrder.ps1" -Dummy %*
if errorlevel 1 pause
endlocal
