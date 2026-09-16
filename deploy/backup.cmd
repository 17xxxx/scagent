@echo off
REM  deploy\backup.cmd -- 备份（.env 脱敏、默认排除密钥与 .rds）
REM  可选参数： -WithRds -IncludeSecrets -Out D:\backups
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scagent.ps1" backup %*
set RC=%ERRORLEVEL%
echo.
pause
exit /b %RC%