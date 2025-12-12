@echo off
REM 中文注释: CMD 入口, 让 PATH 下可以直接执行 check-ai-cli
setlocal
set "SCRIPT_DIR=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%check-ai-cli.ps1"

