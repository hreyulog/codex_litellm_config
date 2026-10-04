@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-codex-litellm.ps1" %*
set "SETUP_RESULT=%ERRORLEVEL%"
echo.
pause
exit /b %SETUP_RESULT%
