@echo off
chcp 65001 >nul
setlocal
title COMSOL export CLI
rem Pre-size the console so PowerShell does not flash the default 80x25.
rem Exact width and full height are set later by Initialize-ConsoleWindow.
mode con cols=88 lines=45 >nul 2>nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0cli.ps1" %*
echo.
pause
