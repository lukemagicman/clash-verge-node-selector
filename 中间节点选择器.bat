@echo off
setlocal
chcp 65001 >nul
title Clash Verge Node Selector

set "SCRIPT=%~dp0中间节点选择器.ps1"
if not exist "%SCRIPT%" (
    echo [ERROR] 找不到中间节点选择器.ps1。请保持它与本文件在同一文件夹。
    pause
    exit /b 1
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "RESULT=%ERRORLEVEL%"
if not "%RESULT%"=="0" (
    echo.
    echo [ERROR] 操作未完成。请查看上方错误信息；配置文件没有被确认写入。
)
echo.
pause
exit /b %RESULT%
