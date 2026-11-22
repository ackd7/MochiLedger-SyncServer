@echo off
chcp 65001 >nul
title 墨记同步服务端 - 开机自启配置
cd /d "%~dp0"

set "STARTUP_DIR=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
set "VBS_PATH=%STARTUP_DIR%\MochiLedger-SyncServer.vbs"
set "WORK_DIR=%~dp0"
set "EXE_PATH=%~dp0mochiledger-sync.exe"

if exist "%VBS_PATH%" (
    del /f /q "%VBS_PATH%"
    echo [完成] 已取消 墨记同步服务端 的 Windows 后台开机自启！
    pause
    exit /b 0
)

powershell -NoProfile -Command "$dir = $env:WORK_DIR.TrimEnd('\'); $exe = $env:EXE_PATH; $vbs = @('Set WshShell = CreateObject(\"WScript.Shell\")', ('WshShell.CurrentDirectory = \"' + $dir + '\"'), ('WshShell.Run \"\"\"' + $exe + '\"\"\", 0, False')); Set-Content -Path $env:VBS_PATH -Value $vbs -Encoding Unicode"

if exist "%VBS_PATH%" (
    echo [完成] 已开启 墨记同步服务端 Windows 静默开机自启（后台无黑框运行，支持中文路径）！
    echo 如需取消开机自启，再次双击本脚本即可。
    echo.
    echo 配置文件位置：%~dp0config.json
    echo 数据目录位置：%~dp0data
) else (
    echo [错误] 写入启动项失败，请尝试右键「以管理员身份运行」。
)
pause
