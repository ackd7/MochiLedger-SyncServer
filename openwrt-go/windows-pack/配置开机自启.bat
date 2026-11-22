@echo off
chcp 65001 >nul
title 墨记同步服务端 - 开机自启配置
cd /d "%~dp0"

set "STARTUP_DIR=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
set "VBS_PATH=%STARTUP_DIR%\MochiLedger-SyncServer.vbs"
set "EXE_PATH=%~dp0mochiledger-sync.exe"

if exist "%VBS_PATH%" (
    del /f /q "%VBS_PATH%"
    echo [完成] 已取消 墨记同步服务端 的 Windows 后台开机自启！
    pause
    exit /b 0
)

(
    echo Set WshShell = CreateObject("WScript.Shell"^)
    echo WshShell.CurrentDirectory = "%~dp0"
    echo WshShell.Run """%EXE_PATH%""", 0, False
) > "%VBS_PATH%"

echo [完成] 已开启 墨记同步服务端 Windows 静默开机自启（后台无黑框运行）！
echo 如需取消开机自启，再次双击本脚本即可。
echo.
echo 配置文件位置：%~dp0config.json
echo 数据目录位置：%~dp0data
pause
