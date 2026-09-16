@echo off
REM  deploy\refdata.cmd -- 获取参考数据集（celldex；默认小鼠，-Species human 切换）
REM  说明：临时容器联网下载，写入 <SCAGENT_BIODATA>\celldex\；生产容器仍离线只读挂载。
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scagent.ps1" refdata %*
set RC=%ERRORLEVEL%
echo.
pause
exit /b %RC%