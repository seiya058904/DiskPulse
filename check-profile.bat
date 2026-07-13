@echo off
rem ============================================================
rem DiskPulse performance diagnostics launcher
rem This is a DEVELOPER tool, not for regular users.
rem
rem It shows a terminal window and generates runtime\last-profile.json.
rem Regular users should run DiskPulse.vbs instead.
rem ============================================================
set "DISKPULSE_PROFILE=1"
set "DISKPULSE_ROOT=%~dp0"
set "DISKPULSE_SCRIPT_PATH=%~dp0check.bat"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-Content -Raw -LiteralPath $env:DISKPULSE_SCRIPT_PATH -Encoding UTF8 | Invoke-Expression"
pause
