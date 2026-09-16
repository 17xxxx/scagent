@echo off
REM  deploy\stop.cmd -- 停止服务（数据与密钥保留）
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scagent.ps1" down %*
set RC=%ERRORLEVEL%
echo.
pause
exit /b %RC%