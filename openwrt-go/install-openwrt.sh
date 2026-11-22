#!/bin/sh
# Universal one-click installer for OpenWrt / ImmortalWrt routers
# Auto-detects CPU architecture (ARM64 / x86_64 / ARMv7 / MIPSLE), uses UPX LZMA ultra-small binaries (~1.8MB)
# Tested on Cudy TR3000 128M (MT7981B), Redmi AX6000, R4S/R5S, N1, x86 soft-routers, etc.
#
# Usage:
#   sh install-openwrt.sh [YOUR_SYNC_TOKEN] [PORT] [OPTIONAL_CF_TUNNEL_TOKEN]
#   sh install-openwrt.sh uninstall

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
    echo ">>> 已卸载服务与防火墙规则（账本数据安全保留在 $DATA_DIR）"
    exit 0
fi

SYNC_TOKEN="${1:-mochi-$(cat /proc/sys/kernel/random/uuid 2>/dev/null | cut -d- -f1 || echo 'secret-token')}"
PORT="${2:-8787}"
CF_TOKEN="${3:-}"

RAW_ARCH="$(uname -m)"
case "$RAW_ARCH" in
    aarch64|arm64)
        GO_ARCH="arm64"
        ;;
    x86_64|amd64)
        GO_ARCH="amd64"
        ;;
    armv7l|armv7*|armhf)
        GO_ARCH="armv7"
        ;;
    mipsel|mips)
        GO_ARCH="mipsle"
        ;;
    *)
        echo "错误：暂不支持当前路由器 CPU 架构 ($RAW_ARCH)"
        exit 1
        ;;
esac

BIN_URL="https://github.com/${REPO}/releases/download/${VERSION}/mochiledger-sync-${VERSION}-openwrt-${GO_ARCH}"

echo ">>> [1/4] 检测到架构 $RAW_ARCH ($GO_ARCH)，正在下载 UPX 极限压缩单文件..."
[ -x "$INIT_PATH" ] && "$INIT_PATH" stop >/dev/null 2>&1 || true
if command -v curl >/dev/null 2>&1; then
    curl -fL "$BIN_URL" -o "${BIN_PATH}.tmp"
else
    wget -O "${BIN_PATH}.tmp" "$BIN_URL"
fi
mv -f "${BIN_PATH}.tmp" "$BIN_PATH"
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
LISTEN_ADDR=":$PORT"
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

echo ">>> [3/4] 正在放行 OpenWrt 防火墙 IPv6 入站端口 TCP $PORT..."
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

if [ -n "$CF_TOKEN" ]; then
    echo ">>> [附加] 检测到 Cloudflare Tunnel Token，正在配置穿透服务..."
    opkg update >/dev/null 2>&1 || true
    opkg install cloudflared >/dev/null 2>&1 || true
    if [ -x /etc/init.d/cloudflared ]; then
        uci set cloudflared.config.token="$CF_TOKEN"
        uci set cloudflared.config.enabled='1'
        uci commit cloudflared
        /etc/init.d/cloudflared enable
        /etc/init.d/cloudflared restart
        echo ">>> Cloudflare Tunnel 已配置并启动！"
    fi
fi

echo ">>> [4/4] 检测本机服务与连接地址..."
sleep 1
LAN_IP="$(uci -q get network.lan.ipaddr || echo '192.168.1.1')"
PUB_IPV6="$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/ && !/deprecated/ && !/^ *inet6 f[cd]/ {gsub(/\/.*/, "", $2); print $2; exit}')"

echo ""
echo "============================================================"
echo "  墨记 MochiLedger 同步服务端已成功部署在 OpenWrt！"
echo "============================================================"
echo "  同步密钥 (Bearer Token):  $SYNC_TOKEN"
echo "  数据存储目录:             $DATA_DIR"
echo "  局域网连接地址:           http://${LAN_IP}:${PORT}"
if [ -n "$PUB_IPV6" ]; then
    echo "  IPv6 外网直连地址:        http://[${PUB_IPV6}]:${PORT}"
else
    echo "  IPv6 外网直连地址:        (未检测到公网 IPv6)"
fi
echo ""
echo "  外网 5G 无法直连 IPv6 时（光猫路由模式拦截入站）："
echo "  推荐搭配 Cloudflare Tunnel 指向 http://127.0.0.1:${PORT}"
echo "============================================================"
