@echo off
REM 中文注释: 兼容入口, 实际命令入口在 bin 目录
setlocal
set "ROOT=%~dp0"
call "%ROOT%bin\check-ai-cli.cmd" %*

