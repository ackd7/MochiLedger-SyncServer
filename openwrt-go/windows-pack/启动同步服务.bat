@echo off
chcp 65001 >nul
title 墨记 MochiLedger 同步服务端
cd /d "%~dp0"
echo 正在启动 墨记 MochiLedger 同步服务端...
echo 提示：首次运行会自动生成 config.json，可用记事本修改端口和同步密钥 (token)。
echo.
mochiledger-sync.exe
echo.
echo 服务已停止。
pause
