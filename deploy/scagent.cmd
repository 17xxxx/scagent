@echo off
REM  deploy\scagent.cmd -- 通用入口：scagent.cmd ^<verb^> [args]
REM    verb: install up down restart status logs verify secrets help
chcp 65001 >nul
if "%~1"=="" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scagent.ps1" help
  exit /b %ERRORLEVEL%
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scagent.ps1" %*
exit /b %ERRORLEVEL%