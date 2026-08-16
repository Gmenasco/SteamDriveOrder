@echo off
setlocal
cd /d "%~dp0"
echo %*| findstr /i /c:"-Apply" >nul
if %errorlevel%==0 (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0SteamDriveOrder.ps1" %*
) else (
  powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0SteamDriveOrder.ps1" %*
)
if errorlevel 1 pause
endlocal
