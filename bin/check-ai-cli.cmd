@echo off
REM check-ai-cli entrypoint (CMD)
setlocal
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..") do set "INSTALL_ROOT=%%~fI"
if /I "%CHECK_AI_CLI_TEST_INSTALL_ROOT%" NEQ "" set "INSTALL_ROOT=%CHECK_AI_CLI_TEST_INSTALL_ROOT%"
set "PF=%ProgramFiles%"
if defined PF if /I "%INSTALL_ROOT:~0,%=;%"=="" rem noop
if defined PF if /I "%INSTALL_ROOT:~0,-0%"=="" rem noop
if defined PF (
  call set "INSTALL_PREFIX=%%INSTALL_ROOT:~0,%ProgramFiles:~0,0%%"
)
set "IS_PROGRAM_FILES=0"
if defined PF (
  echo %INSTALL_ROOT%| findstr /B /I /C:"%PF%" >nul && set "IS_PROGRAM_FILES=1"
)
if "%IS_PROGRAM_FILES%"=="1" (
  set "USER_INSTALL_ROOT=%LOCALAPPDATA%\Programs\Tools\Check-AI-CLI"
  set "USER_ENTRY=%USER_INSTALL_ROOT%\bin\check-ai-cli.ps1"
  if exist "%USER_ENTRY%" (
    if /I not "%USER_ENTRY%"=="%SCRIPT_DIR%check-ai-cli.ps1" (
      powershell -NoProfile -ExecutionPolicy Bypass -File "%USER_ENTRY%" %*
      exit /b %ERRORLEVEL%
    )
  )
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%check-ai-cli.ps1" %*
