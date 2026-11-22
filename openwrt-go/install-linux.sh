#!/bin/sh
# Universal one-click installer for Linux servers / VPS / NAS / Raspberry Pi / Armbian
# Auto-detects CPU architecture (amd64 / arm64 / armv7) and sets up a systemd background service.
#
# Usage:
#   sudo sh install-linux.sh [YOUR_SYNC_TOKEN] [PORT]
#   sudo sh install-linux.sh uninstall

set -e

VERSION="v1.3.1"
REPO="ackd7/MochiLedger-SyncServer"
BIN_PATH="/usr/local/bin/mochiledger-sync"
SERVICE_PATH="/etc/systemd/system/mochiledger-sync.service"
DATA_DIR="/var/lib/mochiledger"

if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 或 sudo 运行此脚本：sudo sh install-linux.sh [密码] [端口]"
    exit 1
fi

if [ "$1" = "uninstall" ]; then
    echo ">>> 正在卸载 MochiLedger SyncServer..."
    systemctl stop mochiledger-sync 2>/dev/null || true
    systemctl disable mochiledger-sync 2>/dev/null || true
    rm -f "$SERVICE_PATH" "$BIN_PATH"
    systemctl daemon-reload 2>/dev/null || true
    echo ">>> 已卸载服务（账本数据安全保留在 $DATA_DIR）"
    exit 0
fi

SYNC_TOKEN="${1:-mochi-$(cat /proc/sys/kernel/random/uuid 2>/dev/null | cut -d- -f1 || echo 'secret-token')}"
PORT="${2:-8787}"

RAW_ARCH="$(uname -m)"
case "$RAW_ARCH" in
    x86_64|amd64)
        GO_ARCH="amd64"
        ;;
    aarch64|arm64)
        GO_ARCH="arm64"
        ;;
    armv7l|armv7*|armhf)
        GO_ARCH="armv7"
        ;;
    *)
        echo "错误：暂不支持当前 Linux CPU 架构 ($RAW_ARCH)"
        exit 1
        ;;
esac

BIN_URL="https://github.com/${REPO}/releases/download/${VERSION}/mochiledger-sync-${VERSION}-linux-${GO_ARCH}"

echo ">>> [1/3] 检测到架构 $RAW_ARCH ($GO_ARCH)，正在下载服务端程序..."
systemctl stop mochiledger-sync 2>/dev/null || true
if command -v curl >/dev/null 2>&1; then
    curl -fL "$BIN_URL" -o "${BIN_PATH}.tmp"
else
    wget -O "${BIN_PATH}.tmp" "$BIN_URL"
fi
mv -f "${BIN_PATH}.tmp" "$BIN_PATH"
chmod +x "$BIN_PATH"

echo ">>> [2/3] 正在配置 systemd 后台守护与开机自启..."
mkdir -p "$DATA_DIR"
cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=MochiLedger Sync Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_PATH} -addr :${PORT} -data ${DATA_DIR} -token ${SYNC_TOKEN}
Restart=always
RestartSec=5
WorkingDirectory=${DATA_DIR}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mochiledger-sync
systemctl restart mochiledger-sync

echo ">>> [3/3] 检查运行状态..."
sleep 1
LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo ""
echo "============================================================"
echo "  墨记 MochiLedger 同步服务端已在 Linux 成功运行！"
echo "============================================================"
echo "  同步密钥 (Bearer Token):  $SYNC_TOKEN"
echo "  数据存储目录:             $DATA_DIR"
[ -n "$LAN_IP" ] && echo "  内网连接地址:             http://${LAN_IP}:${PORT}"
echo "  查看运行状态:             systemctl status mochiledger-sync"
echo "  查看实时日志:             journalctl -u mochiledger-sync -f"
echo "  一键卸载命令:             sudo sh install-linux.sh uninstall"
echo "============================================================"
