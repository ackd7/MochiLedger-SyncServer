#!/bin/sh
# One-click installer for Cudy TR3000 (128M Flash / MT7981B ARM64 / OpenWrt)
# Supports dual-stack IPv4 + IPv6 direct connection with automatic firewall rule setup.
#
# Usage:
#   sh install-cudy-tr3000.sh [YOUR_SYNC_TOKEN] [PORT]
#   sh install-cudy-tr3000.sh uninstall

set -e

VERSION="v1.3.1"
REPO="ackd7/MochiLedger-SyncServer"
BIN_PATH="/usr/bin/mochiledger-sync"
INIT_PATH="/etc/init.d/mochiledger-sync"
DATA_DIR="/etc/mochiledger/data"

if [ "$1" = "uninstall" ]; then
    echo ">>> 正在卸载 MochiLedger SyncServer..."
    [ -x "$INIT_PATH" ] && "$INIT_PATH" stop || true
    [ -x "$INIT_PATH" ] && "$INIT_PATH" disable || true
    rm -f "$BIN_PATH" "$INIT_PATH"
    uci -q delete firewall.mochiledger_ipv6 || true
    uci commit firewall || true
    /etc/init.d/firewall reload || true
    echo ">>> 已卸载服务与防火墙规则（账本数据保留在 $DATA_DIR）"
    exit 0
fi

SYNC_TOKEN="${1:-mochi-$(cat /proc/sys/kernel/random/uuid 2>/dev/null | cut -d- -f1 || echo 'secret-token')}"
PORT="${2:-8787}"

ARCH="$(uname -m)"
if [ "$ARCH" != "aarch64" ]; then
    echo "⚠️  警告：检测到当前架构为 $ARCH，本脚本专为 Cudy TR3000 (aarch64 / MT7981B) 优化。"
fi

BIN_URL="https://github.com/${REPO}/releases/download/${VERSION}/mochiledger-sync-${VERSION}-cudy-tr3000-arm64"

echo ">>> [1/4] 正在下载 Cudy TR3000 专用超轻量二进制 (~1.8MB)..."
if command -v curl >/dev/null 2>&1; then
    curl -fL "$BIN_URL" -o "$BIN_PATH"
else
    wget -O "$BIN_PATH" "$BIN_URL"
fi
chmod +x "$BIN_PATH"

echo ">>> [2/4] 正在配置 OpenWrt procd 开机自启服务..."
mkdir -p "$DATA_DIR"
cat > "$INIT_PATH" <<EOF
#!/bin/sh /etc/rc.common

START=99
STOP=10
USE_PROCD=1

PROG="$BIN_PATH"
DATA_DIR="$DATA_DIR"
LISTEN_ADDR="[::]:$PORT"
SYNC_TOKEN="$SYNC_TOKEN"

start_service() {
	mkdir -p "\$DATA_DIR"
	procd_open_instance
	procd_set_param command "\$PROG" -addr "\$LISTEN_ADDR" -data "\$DATA_DIR" -token "\$SYNC_TOKEN"
	procd_set_param respawn 3600 5 5
	procd_set_param stdout 1
	procd_set_param stderr 1
	procd_close_instance
}
EOF
chmod +x "$INIT_PATH"
"$INIT_PATH" enable
"$INIT_PATH" restart

echo ">>> [3/4] 正在放行 OpenWrt 防火墙 IPv6 公网入站端口 TCP $PORT..."
uci -q delete firewall.mochiledger_ipv6 || true
uci set firewall.mochiledger_ipv6=rule
uci set firewall.mochiledger_ipv6.name='Allow-MochiLedger-IPv6'
uci set firewall.mochiledger_ipv6.src='wan'
uci set firewall.mochiledger_ipv6.proto='tcp'
uci set firewall.mochiledger_ipv6.dest_port="$PORT"
uci set firewall.mochiledger_ipv6.family='ipv6'
uci set firewall.mochiledger_ipv6.target='ACCEPT'
uci commit firewall
/etc/init.d/firewall reload

echo ">>> [4/4] 检测服务与公网 IPv6 地址..."
sleep 1
LAN_IP="$(uci -q get network.lan.ipaddr || echo '192.168.1.1')"
PUB_IPV6="$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/ && !/deprecated/ && !/^ *inet6 f[cd]/ {gsub(/\/.*/, "", $2); print $2; exit}')"

echo ""
echo "============================================================"
echo "  墨记 MochiLedger 同步服务端已成功部署在 Cudy TR3000！"
echo "============================================================"
echo "  同步密钥 (Bearer Token):  $SYNC_TOKEN"
echo "  数据存储目录:             $DATA_DIR"
echo "  局域网连接地址:           http://${LAN_IP}:${PORT}"
if [ -n "$PUB_IPV6" ]; then
    echo "  IPv6 外网直连地址:        http://[${PUB_IPV6}]:${PORT}"
else
    echo "  IPv6 外网直连地址:        (未检测到公网 IPv6，请确认光猫已桥接/开启 IPv6)"
fi
echo ""
echo "  提示：家用宽带 IPv6 前缀会定期变化，建议在 OpenWrt 搭配"
echo "  DDNS (ddns-scripts) 或 Lucky 绑定域名，填 http://你的域名:${PORT}"
echo "============================================================"
