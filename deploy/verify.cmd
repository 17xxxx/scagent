@echo off
REM  deploy\verify.cmd -- 部署自检（中文报告）
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scagent.ps1" verify %*
set RC=%ERRORLEVEL%
echo.
pause
exit /b %RC%