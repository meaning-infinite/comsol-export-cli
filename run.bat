@echo off
chcp 65001 >nul
setlocal
title COMSOL export CLI
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0cli.ps1" %*
echo.
pause
