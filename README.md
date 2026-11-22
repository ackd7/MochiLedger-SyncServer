# MochiLedger SyncServer

[墨记 MochiLedger](https://github.com/ackd7/MochiLedger) 的**独立自建同步服务端**仓库，支持 Windows 与 Android 多端数据双向同步、冲突合并（LWW）及账单/资产语义去重。

提供两种开箱即用的部署形态，**100% 兼容 MochiLedger 客户端**（在客户端 `设置 → 同步与备份 → 自建同步服务器` 中填写地址与 Token 即可）：

| 方案 | 目录 | 费用 / 环境 | 适用场景 |
| :--- | :--- | :--- | :--- |
| **OpenWrt 路由器单文件版** | `openwrt-go/` | **仅 ~6MB 二进制，内存 ~10MB，免 Docker/JVM** | 直接跑在家里的 OpenWrt 硬路由/软路由上，24 小时在线 |
| **Cloudflare Workers + KV** | `cloudflare-worker/` | **免费（0 元，无需服务器）** | 不想买 VPS、不想本地电脑开机，自带全球 HTTPS |
| **Ktor + Docker 服务端** | `ktor-server/` | 自有 NAS / VPS / 家庭服务器 | 数据完全落在自己硬盘里，内网/公网均可 |

---

## 方案零：部署在 OpenWrt 路由器硬件上（超轻量 Go 单文件）

专为 OpenWrt 路由器（小闪存、小内存、无 Docker/JVM）编写的零依赖静态编译程序，已预编译 **ARM64 / x86_64 / ARMv7 / MIPSLE** 四种架构：

1. **查看路由器 CPU 架构**（SSH 登录 OpenWrt）：
   ```sh
   uname -m
   # aarch64 -> 下载 openwrt-arm64（红米AX6000 / R4S / R5S / N1 / MT7986）
   # x86_64  -> 下载 openwrt-amd64（x86 软路由）
   # armv7l  -> 下载 openwrt-armv7
   # mips    -> 下载 openwrt-mipsle（MT7621 等）
   ```
2. **下载程序与开机自启脚本**（以 `arm64` 为例，从 [Releases](https://github.com/ackd7/MochiLedger-SyncServer/releases/latest) 下载对应架构）：
   ```sh
   wget -O /usr/bin/mochiledger-sync https://github.com/ackd7/MochiLedger-SyncServer/releases/latest/download/mochiledger-sync-v1.1.0-openwrt-arm64
   chmod +x /usr/bin/mochiledger-sync

   wget -O /etc/init.d/mochiledger-sync https://github.com/ackd7/MochiLedger-SyncServer/releases/latest/download/mochiledger-sync.init
   chmod +x /etc/init.d/mochiledger-sync
   ```
3. **修改同步密钥并启动开机自启**：
   ```sh
   vi /etc/init.d/mochiledger-sync   # 修改 SYNC_TOKEN 为你自己的密码
   /etc/init.d/mochiledger-sync enable
   /etc/init.d/mochiledger-sync start
   ```
4. **客户端连接**：
   - 家里局域网直连：`http://192.168.1.1:8787`（替换为你的 OpenWrt 路由器 IP）。
   - 外网手机 5G 随时同步：配合 OpenWrt 自带的 **IPv6 + DDNS**、**Lucky 反向代理（自动 HTTPS）**、**Tailscale / ZeroTier** 或 **Cloudflare Tunnel (`cloudflared`)** 即可实现全网毫秒级直连。

---

## 方案一：部署到 Cloudflare Workers（推荐 · 0 元免服务器）

### 方式 A：网页控制台 1 分钟零命令部署
1. 登录 [Cloudflare Dashboard](https://dash.cloudflare.com/)。
2. 左侧菜单进入 **Storage & Databases → KV**，点击 **Create a namespace**，名称填 `MOCHI_KV`。
3. 左侧菜单进入 **Workers & Pages → Create → Create Worker**，命名为 `mochiledger-sync`，点击 **Deploy** 后进入 **Edit code**。
4. 将本仓库 [`cloudflare-worker/worker.js`](cloudflare-worker/worker.js) 的全部代码粘贴覆盖进去，点击 **Deploy**。
5. 回到 Worker 的 **Settings**：
   - **Bindings → Add → KV namespace**：Variable name 填 `MOCHI_KV`，选择刚才创建的 KV 命名空间。
   - **Variables and Secrets → Add**：选择 **Secret**，名称填 `MOCHI_SYNC_TOKEN`，值填你自己设定的同步密码。
6. 复制你的 Worker 地址（如 `https://mochiledger-sync.你的子域.workers.dev`，建议在 **Domains & Routes** 绑定自己的自定义域名，国内直连更稳）。
7. 打开墨记 Windows / Android 客户端 → **设置 → 同步与备份 → 自建同步服务器**，填入 URL 和 `MOCHI_SYNC_TOKEN`，点击 **测试连接 → 立即双向同步**！

### 方式 B：使用 Wrangler CLI 一键部署
```bash
cd cloudflare-worker
npm install
npx wrangler login
npx wrangler kv namespace create MOCHI_KV
# 将返回的 id 填入 wrangler.toml 的 id 字段
npx wrangler secret put MOCHI_SYNC_TOKEN
npx wrangler deploy
```

---

## 方案二：自建 Docker / Ktor 服务端（NAS / VPS）

```bash
cd ktor-server
# 可先修改 docker-compose.yml 中的 MOCHI_SYNC_TOKEN
docker compose up -d
```

服务默认监听 `8787` 端口，数据持久化在 `ktor-server/data/` 目录下。

---

## 同步 API 协议

| 接口 | 方法 | 说明 |
| :--- | :--- | :--- |
| `/api/v1/health` | `GET` | 健康检查与 Bearer Token 校验 |
| `/api/v1/sync` | `POST` | 上传本地快照，服务端执行 LWW 合并 + 语义去重并返回合并后的全量快照 |
| `/api/v1/ledger/{ledgerId}` | `GET` | 读取指定账本的远端快照 |

鉴权请求头：`Authorization: Bearer <MOCHI_SYNC_TOKEN>`
