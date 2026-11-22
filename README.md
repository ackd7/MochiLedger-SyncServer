# MochiLedger SyncServer

[墨记 MochiLedger](https://github.com/ackd7/MochiLedger) 的**独立自建同步服务端**，采用纯 Go 零依赖编译，支持 **Windows / Linux / OpenWrt 路由器 / Cloudflare Workers / Docker** 全平台部署。

所有平台 100% 协议互通，支持 Windows 与 Android 多端双向同步、冲突自动合并（LWW）以及账单/资产语义去重。

---

## 平台方案速览（按需任选其一）

| 平台 | 体积 / 内存 | 操作难度 | 适用场景 |
| :--- | :--- | :--- | :--- |
| **Windows 绿色版** | ~6MB / ~10MB | ⭐ **双击即用** | 直接跑在家里常开电脑或 Windows 小主机上 |
| **Linux 一键版** | ~6MB / ~10MB | ⭐ **1 行命令** | VPS 云服务器、Ubuntu/Debian、树莓派、Armbian、NAS |
| **OpenWrt 路由器版** | **~1.8MB (UPX)** / ~10MB | ⭐ **1 行命令** | 直接跑在家里的硬路由/软路由（如 Cudy TR3000 128M），24 小时低功耗在线 |
| **Cloudflare Workers** | 0 服务器 | ⭐⭐ 网页粘贴 | 0 元免服务器，自带全球 HTTPS，适合不想折腾本地设备 |
| **Docker / Ktor** | 容器部署 | ⭐⭐ Compose | 已有 Docker 环境的 NAS（群晖 / 飞牛 / 极空间 / 威联通） |

---

## 一、Windows 端部署教程（最简单 · 3 步搞定）

1. **下载压缩包**：前往 [Releases 最新版](https://github.com/ackd7/MochiLedger-SyncServer/releases/latest) 下载 `MochiLedger-SyncServer-v1.3.0-windows-amd64.zip` 并解压到任意文件夹（如 `D:\MochiSync`）。
2. **启动服务**：双击 **`启动同步服务.bat`**。
   - 首次运行会自动在同目录生成 `config.json` 配置文件并分配随机密钥，黑框里会直接打印出你的 **局域网地址**（如 `http://192.168.1.100:8787`）和 **同步密钥（Token）**。
   - 如需自定义密码或端口，用记事本打开 `config.json` 修改 `token` 或 `addr` 后重启即可。
3. **开启开机自启（可选）**：双击 **`配置开机自启.bat`**，即可一键设置 Windows **后台静默开机自启**（无黑框弹窗；再次双击可取消自启）。
4. **客户端连接**：在墨记 App → **设置 → 同步与备份 → 自建同步服务器** 填入刚才打印的地址与 Token，点击 **测试连接 → 立即双向同步**！

> **防火墙提示**：首次运行时 Windows 弹窗询问网络权限，请勾选「专用网络」并点击「允许访问」。

---

## 二、Linux 服务器 / VPS / 树莓派一键部署（1 行命令）

支持 Ubuntu / Debian / CentOS / Rocky / Armbian / 树莓派（自动识别 `x86_64` / `arm64` / `armv7` 架构，并自动配置 `systemd` 后台守护与开机自启）：

```bash
# 将 MySecretToken 替换为你自己设定的同步密码，8787 可改为任意端口
curl -fsSL https://github.com/ackd7/MochiLedger-SyncServer/releases/latest/download/install-linux.sh -o /tmp/install-linux.sh && sudo sh /tmp/install-linux.sh MySecretToken 8787
```

安装完成后终端会自动打印连接地址与密钥。

**常用运维命令：**
```bash
systemctl status mochiledger-sync     # 查看服务运行状态
journalctl -u mochiledger-sync -f     # 查看实时同步日志
ls -lh /var/lib/mochiledger/          # 查看备份账本文件大小
sudo sh /tmp/install-linux.sh uninstall   # 一键卸载（保留账本数据）
```

> **云服务器注意**：如部署在阿里云/腾讯云等 VPS 上，请记得在云厂商「安全组 / 防火墙」中放行 TCP `8787` 端口（或配合 Nginx / Caddy 反代 HTTPS）。

---

## 三、OpenWrt / ImmortalWrt 路由器一键部署（1 行命令）

所有 OpenWrt 架构（`arm64` / `amd64` / `armv7` / `mipsle`）均采用与 **Cudy TR3000 128M** 相同的 **UPX LZMA 极限压缩**（体积仅约 **1.8 MB**，运行内存约 **10 MB**，零 Docker/JVM 依赖），专为小闪存硬路由打造！

### 1. 一键安装（自动识别路由器架构）
SSH 登录你的 OpenWrt / ImmortalWrt 路由器后，直接粘贴运行（把 `MySecretToken` 换成你的密码）：

```sh
wget -O /tmp/install-openwrt.sh https://github.com/ackd7/MochiLedger-SyncServer/releases/latest/download/install-openwrt.sh && sh /tmp/install-openwrt.sh MySecretToken 8787
```

脚本会自动完成以下全部工作：
1. 自动识别路由器 CPU 架构（如 Cudy TR3000 / 红米 AX6000 / R4S / N1 识别为 `arm64`，x86 软路由识别为 `amd64`，MT7621 识别为 `mipsle`）；
2. 下载对应的 UPX 极限压缩单文件到 `/usr/bin/mochiledger-sync`；
3. 自动生成 `procd` 开机自启与崩溃守护服务（`/etc/init.d/mochiledger-sync`）；
4. 自动放行 OpenWrt 防火墙 IPv6 入站规则；
5. 直接打印出**局域网地址**、**IPv6 地址**和**同步密钥**。

### 2. 常用维护命令
```sh
/etc/init.d/mochiledger-sync status   # 查看运行状态
/etc/init.d/mochiledger-sync restart  # 重启同步服务
ls -lh /etc/mochiledger/data/         # 查看账本备份文件大小
df -h /overlay                        # 查看路由器剩余闪存空间
sh /tmp/install-openwrt.sh uninstall  # 一键卸载（账本数据保留在 /etc/mochiledger/data）
```

---

## 四、手机 5G 外网同步穿透教程（解决光猫防火墙拦截）

如果家里光猫是**路由模式**（例如光猫下接了多台路由器，无法改桥接），运营商光猫通常会默认拦截外部 IPv6 入站，导致家里 WiFi 能同步但手机切 5G 超时。

最稳、完全免费且免改光猫的方案是 **Cloudflare Tunnel（免费 HTTPS 穿透）**：

### 第 1 步：准备一个域名并接入 Cloudflare
- 可以使用已有域名，或在 [DigitalPlat (dpdns.org)](https://domain.digitalplat.org/) 免费申请一个 `你的名字.dpdns.org` 域名。
- 在 [Cloudflare Dashboard](https://dash.cloudflare.com/) 点击 **添加站点** → 输入你的域名 → 选择 **Free（免费）** → 将 Cloudflare 给出的 2 条 `NS` 地址填回域名商后台保存，等 1~2 分钟激活。

### 第 2 步：创建隧道并绑定路由器
1. 进入 Cloudflare 左侧 **网络（Networks）→ 隧道（Tunnels）**（或 Zero Trust → Networks → Tunnels），点击 **创建隧道** → 选择 **Cloudflared**，取名如 `MochiLedger`。
2. 复制页面上安装命令里 `eyJhIjoi...` 开头的那一长串 **Tunnel Token**。
3. 在 OpenWrt 路由器终端安装并运行 `cloudflared`（如遇到版本过旧提示，可直接用官方最新版覆盖）：
   ```sh
   opkg update && opkg install cloudflared
   uci set cloudflared.config.token='粘贴你的eyJhIjoi...长串Token'
   uci set cloudflared.config.enabled='1'
   uci commit cloudflared
   /etc/init.d/cloudflared enable
   /etc/init.d/cloudflared restart
   ```
   *(若 Cloudflare 提示版本过旧，执行下方一键更新：)*
   ```sh
   /etc/init.d/cloudflared stop && \
   curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 -o /tmp/cloudflared && \
   mv /tmp/cloudflared /usr/bin/cloudflared && \
   chmod +x /usr/bin/cloudflared && \
   /etc/init.d/cloudflared start
   ```
   *(Windows / Linux 服务器同样直接运行 Cloudflare 页面提供的 `cloudflared` 命令即可)*

### 第 3 步：添加隧道路由
1. 看到隧道状态变成绿色 **「健康」** 后，点击 **添加路由（Public Hostname）**：
   - **子域**：`sync`
   - **域**：选择你的域名（如 `example.dpdns.org`）
   - **Service URL**：填入 **`http://127.0.0.1:8787`**
2. 点击 **保存**。

### 第 4 步：手机 5G 与电脑客户端配置
打开墨记 → **设置 → 同步与备份 → 自建同步服务器**：
- **服务器地址**：`https://sync.你的域名`（注意是 `https://`，**不要加 `:8787`**）
- **Bearer Token**：你安装服务端时设定的密码
- **账本 ID**：`default`
- 点击 **测试连接 → 立即双向同步**，无论在 5G 还是全球任意网络均可秒连！

---

## 五、Cloudflare Workers + KV（0 元免服务器方案）

不想在本地电脑或路由器上跑任何服务时，可以直接部署到 Cloudflare 免费边缘节点：

1. 登录 [Cloudflare Dashboard](https://dash.cloudflare.com/) → **存储和数据库 → KV** → 创建命名空间 `MOCHI_KV`。
2. 进入 **Workers 和 Pages → 创建 Worker**（命名 `mochiledger-sync`）→ 部署后点 **编辑代码** → 将 [`cloudflare-worker/worker.js`](cloudflare-worker/worker.js) 全部粘贴覆盖并部署。
3. 进入 Worker **设置**：
   - **绑定**：添加 KV 命名空间，变量名填 `MOCHI_KV`，绑定刚建的 KV。
   - **变量和机密**：添加 Secret `MOCHI_SYNC_TOKEN`，值为你的同步密码。
   - **域和路由**：绑定你的自定义域名（如 `sync.你的域名`）。

---

## 六、Docker / Ktor 部署（NAS 推荐）

```bash
cd ktor-server
# 修改 docker-compose.yml 中的 MOCHI_SYNC_TOKEN
docker compose up -d
```

数据默认持久化在 `ktor-server/data/` 目录，监听 `8787` 端口。

---

## 同步 API 协议

| 接口 | 方法 | 说明 |
| :--- | :--- | :--- |
| `/api/v1/health` | `GET` | 健康检查与 Bearer Token 校验 |
| `/api/v1/sync` | `POST` | 上传本地快照，服务端执行 LWW 合并 + 语义去重并返回合并后的全量快照 |
| `/api/v1/ledger/{ledgerId}` | `GET` | 读取指定账本的远端快照 |

鉴权请求头：`Authorization: Bearer <MOCHI_SYNC_TOKEN>`
