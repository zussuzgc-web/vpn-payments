@echo off
REM Double-click this file to run the installer.
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1"
echo.
echo Exit code: %errorlevel%
pause
