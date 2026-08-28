<# :
@echo off
setlocal
chcp 65001 >nul
set "DISKPULSE_SCRIPT_PATH=%~f0"
set "DISKPULSE_ROOT=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-Content -Raw -LiteralPath $env:DISKPULSE_SCRIPT_PATH -Encoding UTF8 | Invoke-Expression"
exit /b %ERRORLEVEL%
#>
