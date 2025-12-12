@echo off
REM Legacy entrypoint (CMD)
setlocal
set "ROOT=%~dp0"
call "%ROOT%bin\check-ai-cli.cmd" %*
