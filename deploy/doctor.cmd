@echo off
REM  deploy\doctor.cmd -- 部署体检（中文报告 + 修复建议）
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scagent.ps1" doctor %*
set RC=%ERRORLEVEL%
echo.
pause
exit /b %RC%