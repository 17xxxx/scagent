@echo off
REM ============================================================================
REM  deploy\install.cmd -- 双击入口：完整安装
REM  只用 ASCII，避免 cmd.exe 代码页问题；中文提示由 scagent.ps1 输出。
REM ============================================================================
chcp 65001 >nul
setlocal
echo.
echo   scAgent 安装向导（Windows / Docker Desktop）
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scagent.ps1" install %*
set RC=%ERRORLEVEL%
echo.
if not "%RC%"=="0" echo   安装未成功完成（退出码 %RC%）—— 请看上面的提示。
echo.
pause
exit /b %RC%