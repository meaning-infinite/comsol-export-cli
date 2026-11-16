@echo off
chcp 65001 >nul
cd /d D:\Users\dyt\script

echo ========================================
echo [1/3] 正在检测 Git 环境...
git --version >nul 2>&1
if errorlevel 1 (
    echo [错误] 未安装 Git，请先安装！
    pause
    exit
)
echo Git 已就绪。

echo.
echo [2/3] 正在从 GitHub 拉取最新代码...
if not exist .git (
    git init
    git remote add origin https://github.com/meaning-infinite/comsol-export-cli.git
)

:: 强制拉取最新内容
git fetch --all
if errorlevel 1 (
    echo.
    echo [错误] 网络连接失败，无法访问 GitHub！
    pause
    exit
)

echo.
echo [3/3] 正在覆盖本地文件...
git reset --hard origin/main

echo.
echo [成功] 代码已成功更新至最新版本！
pause