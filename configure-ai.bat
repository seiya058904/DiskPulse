@echo off
setlocal
chcp 65001 >nul
set "DISKPULSE_SILENT=1"
set "DISKPULSE_AI_CONFIGURE=1"
set "DISKPULSE_NO_OPEN=1"
"%~dp0check.bat"
exit /b %ERRORLEVEL%
