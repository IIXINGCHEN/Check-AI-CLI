@echo off
REM 中文注释: CMD 入口, 让 PATH 下可以直接执行 check-ai-cli
REM 中文注释: 文件已移动到 bin 目录, PATH 建议指向 bin
setlocal
set "SCRIPT_DIR=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%check-ai-cli.ps1" %*
