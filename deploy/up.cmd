@echo off
REM  deploy\up.cmd -- 启动 / 更新服务
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scagent.ps1" up %*
set RC=%ERRORLEVEL%
echo.
pause
exit /b %RC%