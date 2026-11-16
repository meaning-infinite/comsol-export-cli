@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
title COMSOL Export CLI - Update
if not exist "update.ps1" (
    echo [ERROR] update.ps1 not found in this folder.
    pause & exit /b 2
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0update.ps1" %*
set RC=%errorlevel%
echo.
pause
exit /b %RC%
