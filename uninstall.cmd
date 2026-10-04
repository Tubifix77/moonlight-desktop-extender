@echo off
rem Double-click to uninstall. Add -RemoveDriver to also remove the Virtual Display Driver.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\uninstall.ps1" %*
echo.
pause
