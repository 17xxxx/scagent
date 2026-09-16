@echo off
REM  deploy\rollback.cmd -- 回滚到 :prev（-List 列出本地镜像版本）
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scagent.ps1" rollback %*
set RC=%ERRORLEVEL%
echo.
pause
exit /b %RC%