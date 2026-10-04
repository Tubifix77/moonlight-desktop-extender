@echo off
rem Double-click to install. Extra options: install.cmd -Position right
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\install.ps1" %*
echo.
pause
