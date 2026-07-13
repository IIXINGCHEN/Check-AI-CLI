@echo off
REM check-ai-cli entrypoint (CMD)
REM Always hand off to the sibling PowerShell entrypoint so Program Files vs
REM CurrentUser shadow recovery (freshness comparison) lives in one place.
setlocal
set "SCRIPT_DIR=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%check-ai-cli.ps1" %*
