@echo off
REM check-ai-cli entrypoint (CMD)
setlocal
set "SCRIPT_DIR=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%check-ai-cli.ps1" %*
