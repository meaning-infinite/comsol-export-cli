@echo off
chcp 65001 >nul
setlocal
title COMSOL export CLI
rem 先把窗口拉成单屏大小，免得 PowerShell 启动前闪一下默认的 80x25；
rem 精确宽度与"高度拉满"由 cli.ps1 的 Initialize-ConsoleWindow 按像素定。
mode con cols=88 lines=45 >nul 2>nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0cli.ps1" %*
echo.
pause
