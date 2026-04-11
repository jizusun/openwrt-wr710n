# OpenWrt for TP-Link TL-WR710N v1 搭建透明代理方案

## 1. 硬件规格与限制

TL-WR710N v1 存在多个子版本，硬件差异很大：

| 子版本 | Flash | RAM | OpenWrt 兼容性 |
|--------|-------|-----|---------------|
| v1.0 (US) | **2MB** | **16MB** | ❌ 不支持 OpenWrt |
| v1.1 / v1.2 (EU/UK) | **8MB** | **32MB** | ⚠️ 有限支持 |

共同规格：
- CPU: Atheros AR9331 (MIPS 24Kc, 400MHz)
- 网口: 2x 100Mbps (WAN/LAN)
- WiFi: 2.4GHz 802.11b/g/n (150Mbps)
- USB: 1x USB 2.0
- 电源: AC 供电

> ⚠️ **重要提示**: v1.0 (US) 仅 2MB/16MB，无法运行 OpenWrt。以下内容仅适用于 8MB/32MB 版本（v1.1/v1.2）。

## 2. OpenWrt 版本选择

| 版本 | 适用性 | 说明 |
|------|--------|------|
| 19.07.x | ✅ 推荐 | 最后一个对 8/32 设备有良好支持的版本 |
| 21.02.x / 22.03.x | ⚠️ 勉强可用 | 需自行编译精简固件，空间极其紧张 |
| 23.05+ | ❌ 不推荐 | 基本无法塞入 8MB flash |

**推荐**: 使用 OpenWrt 19.07.10，target 为 `ath79/tiny`。

固件下载地址：
```
https://archive.openwrt.org/releases/19.07.10/targets/ath79/tiny/
```

## 3. 透明代理方案对比

在 8MB Flash / 32MB RAM 的极端限制下，可选方案如下：

| 方案 | 占用空间 | 协议支持 | 复杂度 | 推荐度 |
|------|---------|---------|--------|--------|
| **redsocks** | ~30KB | SOCKS5/HTTP | 低 | ⭐⭐⭐ 首选 |
| **shadowsocks-libev (ss-redir)** | ~200KB | Shadowsocks | 中 | ⭐⭐ |
| **tinyproxy + redsocks** | ~80KB | HTTP + SOCKS5 | 中 | ⭐⭐ |

## 4. 方案一：Redsocks（推荐，最轻量）

Redsocks 将 TCP 流量透明转发到上游 SOCKS5 或 HTTP 代理，体积极小，适合资源受限设备。

### 4.1 安装

```bash
opkg update
opkg install redsocks iptables iptables-mod-nat-extra
```

### 4.2 配置 `/etc/redsocks.conf`

```conf
base {
    log_debug = off;
    log_info = on;
    log = "syslog:daemon";
    daemon = on;
    redirector = iptables;
}

redsocks {
    local_ip = 127.0.0.1;
    local_port = 12345;

    // 上游代理地址（替换为你的代理服务器）
    ip = <PROXY_SERVER_IP>;
    port = <PROXY_PORT>;
    type = socks5;
    // 如需认证，取消注释：
    // login = "<USERNAME>";
    // password = "<PASSWORD>";
}
```

`type` 可选值：`socks5`、`socks4`、`http-connect`、`http-relay`。

### 4.3 配置 iptables 透明转发

创建 `/etc/firewall.user`（或追加内容）：

```bash
# 创建 REDSOCKS 链
iptables -t nat -N REDSOCKS 2>/dev/null
iptables -t nat -F REDSOCKS

# 排除本地/私有地址
iptables -t nat -A REDSOCKS -d 0.0.0.0/8 -j RETURN
iptables -t nat -A REDSOCKS -d 10.0.0.0/8 -j RETURN
iptables -t nat -A REDSOCKS -d 127.0.0.0/8 -j RETURN
iptables -t nat -A REDSOCKS -d 169.254.0.0/16 -j RETURN
iptables -t nat -A REDSOCKS -d 172.16.0.0/12 -j RETURN
iptables -t nat -A REDSOCKS -d 192.168.0.0/16 -j RETURN
iptables -t nat -A REDSOCKS -d 224.0.0.0/4 -j RETURN
iptables -t nat -A REDSOCKS -d 240.0.0.0/4 -j RETURN

# 排除代理服务器自身（避免回环）
iptables -t nat -A REDSOCKS -d <PROXY_SERVER_IP> -j RETURN

# TCP 流量重定向到 redsocks
iptables -t nat -A REDSOCKS -p tcp -j REDIRECT --to-ports 12345

# 对 LAN 口入站流量应用
iptables -t nat -A PREROUTING -i br-lan -p tcp -j REDSOCKS
```

### 4.4 启动服务

```bash
service redsocks start
service redsocks enable    # 开机自启
/etc/init.d/firewall restart
```

## 5. 方案二：Shadowsocks-libev (ss-redir)

适用于你有 Shadowsocks 服务端的场景。`ss-redir` 是专为透明代理设计的组件。

### 5.1 安装

```bash
opkg update
opkg install shadowsocks-libev-ss-redir iptables iptables-mod-tproxy
```

> 如果空间不足，可只装 `shadowsocks-libev-ss-redir`，不装 LuCI 界面。

### 5.2 配置 `/etc/shadowsocks-libev/redir.json`

```json
{
    "server": "<SS_SERVER_IP>",
    "server_port": 8388,
    "local_address": "0.0.0.0",
    "local_port": 1088,
    "password": "<SS_PASSWORD>",
    "timeout": 300,
    "method": "aes-256-gcm"
}
```

### 5.3 配置 iptables

创建 `/etc/firewall.user`：

```bash
SS_REDIR_PORT=1088
SS_SERVER=<SS_SERVER_IP>

iptables -t nat -N SS_REDIR 2>/dev/null
iptables -t nat -F SS_REDIR

# 排除私有地址和服务器地址
iptables -t nat -A SS_REDIR -d $SS_SERVER -j RETURN
iptables -t nat -A SS_REDIR -d 0.0.0.0/8 -j RETURN
iptables -t nat -A SS_REDIR -d 10.0.0.0/8 -j RETURN
iptables -t nat -A SS_REDIR -d 127.0.0.0/8 -j RETURN
iptables -t nat -A SS_REDIR -d 169.254.0.0/16 -j RETURN
iptables -t nat -A SS_REDIR -d 172.16.0.0/12 -j RETURN
iptables -t nat -A SS_REDIR -d 192.168.0.0/16 -j RETURN
iptables -t nat -A SS_REDIR -d 224.0.0.0/4 -j RETURN

# 重定向 TCP 到 ss-redir
iptables -t nat -A SS_REDIR -p tcp -j REDIRECT --to-ports $SS_REDIR_PORT

iptables -t nat -A PREROUTING -i br-lan -p tcp -j SS_REDIR
```

### 5.4 启动

```bash
ss-redir -c /etc/shadowsocks-libev/redir.json -u &
/etc/init.d/firewall restart
```

## 6. DNS 防污染（可选但推荐）

透明代理场景下 DNS 查询可能被污染，建议配合处理：

### 方案 A：使用代理转发 DNS（最简单）

在 `/etc/config/dhcp` 中将 DNS 指向可信服务器：

```uci
config dnsmasq
    list server '8.8.8.8'
    list server '1.1.1.1'
    option noresolv '1'
```

### 方案 B：DNS over TCP（配合 redsocks）

DNS 查询走 TCP 后会被 redsocks 透明转发：

```bash
opkg install dns-forwarder
# 或使用 dnsmasq 的 --server 配合 TCP 模式
```

## 7. 节省空间的技巧

8MB flash 非常紧张，以下措施可释放空间：

```bash
# 查看剩余空间
df -h

# 删除不需要的语言文件
rm -rf /usr/lib/lua/luci/i18n/*

# 不安装 LuCI（纯 SSH 管理，节省约 1MB）
# 在编译时去掉 luci 相关包

# 删除 opkg 列表缓存
rm -rf /tmp/opkg-lists/

# 使用 stripped 版本的包
# 编译时启用 CONFIG_STRIP_KERNEL_EXPORTS
```

如果空间实在不够，考虑自行编译固件，将 redsocks 编入 squashfs，参考：
- [Ultimate Guide for 4MB flash devices](https://forum.openwrt.org/t/ultimate-guide-for-4mb-flash-devices-expert-only/81860)
- [Saving Space on OpenWrt](https://openwrt.org/docs/guide-user/additional-software/saving_space)

## 8. 自编译精简固件（进阶）

对于空间极度紧张的情况，建议从源码编译：

```bash
git clone https://git.openwrt.org/openwrt/openwrt.git
cd openwrt
git checkout v19.07.10

# 更新 feeds
./scripts/feeds update -a
./scripts/feeds install -a

make menuconfig
# Target: ath79 → Subtarget: tiny
# Target Profile: TP-Link TL-WR710N
# 去掉 LuCI、IPv6、PPP 等不需要的包
# 加入 redsocks 或 shadowsocks-libev-ss-redir

make -j$(nproc)
```

关键的 menuconfig 精简选项：
- 禁用 `IPv6`（节省大量空间）
- 禁用 `PPP` / `PPPoE`（如果不需要拨号）
- 禁用 `opkg`（包已编入固件）
- 禁用 `LuCI`（纯 CLI 管理）
- 启用 `MIPS16 user mode`（压缩用户态代码）

## 9. 网络拓扑示例

```
[互联网] ──── [上级路由/光猫]
                    │
              [TL-WR710N WAN口]
              (OpenWrt + redsocks)
              [TL-WR710N LAN口/WiFi]
                    │
         ┌─────────┼─────────┐
      [手机]    [电脑]    [平板]
      
      所有设备流量 → 透明经过代理 → 无需单独配置
```

## 10. 注意事项

1. **安全风险**: OpenWrt 19.07 已停止安全更新，存在已知漏洞，不建议暴露在公网
2. **性能瓶颈**: AR9331 (400MHz MIPS) 处理加密流量能力有限，Shadowsocks 吞吐约 5-15Mbps
3. **仅支持 TCP**: redsocks 仅转发 TCP，UDP 流量（如部分游戏、视频通话）不会经过代理
4. **RAM 紧张**: 32MB RAM 运行 OpenWrt + 代理后剩余很少，避免同时运行过多服务
5. **硬件版本确认**: 刷机前务必确认你的设备是 8MB flash 版本（v1.1/v1.2），2MB 版本无法使用

## 参考博客与教程

### 📌 TL-WR710N 刷机与基础配置

| 资源 | 说明 |
|------|------|
| [Use a TP-Link TL-WR710N Router as a Repeater with OpenWRT](https://www.stefanproell.at/2014/06/29/use-a-tp-link-tl-wr710n-router-as-a-repeater-with-openwrt/) | 详细的 WR710N (EU v1.2, 8MB/32MB) 刷 OpenWrt 及中继配置教程 |
| [OpenWrt on WR710N (heavyberry.com)](https://perso.heavyberry.com/articles/2014-06/misc_openwrt-wr710n) | WR710N 刷机实践记录 |
| [Upgrading OpenWrt on a TL-WR710N](https://www.schauenburg.nl/blog/2018/03/24-upgrading-openwrt-on-a-tl-wr710n/) | WR710N 升级 OpenWrt 版本的经验 |
| [OpenWrt Wiki: TL-WR710N 设备页](https://openwrt.org/toh/tp-link/tl-wr710n) | 官方设备支持信息 |

### 📌 Redsocks 透明代理

| 资源 | 说明 |
|------|------|
| [Redsocks-OpenWRT (GitHub)](https://github.com/emonbhuiyan/Redsocks-OpenWRT) | 一键安装脚本 + 完整配置教程，最易上手 |
| [在 OpenWrt 上配置 redsocks2 (GitHub Gist)](https://gist.github.com/leafsummer/563d0ae8603399cf15b7) | 中文，redsocks2 配合 shadowsocks 实现智能分流 |
| [Setup iptables for RedSocks in OpenWRT (GitHub Gist)](https://gist.github.com/afriza/1097210) | 经典的 redsocks.conf + iptables 规则模板 |
| [Escape proxy hell with Redsocks (blog.jmkhael.io)](https://blog.jmkhael.io/escape-proxy-hell-with-redsocks/) | 英文博客，redsocks 原理讲解 + 配置步骤 |
| [redsocks 配合 iptables 设置全局 SOCKS5 代理 (博客园)](https://www.cnblogs.com/cmsd/p/4363631.html) | 中文，redsocks + iptables 全局代理详解 |
| [OpenWrt 论坛: Setup transparent redirect of local traffic to proxy](https://forum.openwrt.org/t/setup-transparent-redirect-of-local-traffic-to-proxy/235219) | 2025 年最新讨论，含 nftables 和 iptables 两种写法 |
| [OpenWrt 论坛: Configuring Redsocks to work with LAN Proxy](https://forum.openwrt.org/t/configuring-redsocks-to-work-with-lan-proxy/73845) | 含完整 redsocks.conf 和 iptables 脚本示例 |

### 📌 Shadowsocks 透明代理

| 资源 | 说明 |
|------|------|
| [OpenWRT 下安装和配置 shadowsocks (douxinchun)](https://douxinchun.github.io/posts/install-shadowsocks-on-openwrt/) | 中文博客，涵盖透明代理、分流、防 DNS 污染 |
| [刷 OpenWRT 路由器安装 ShadowSocks 透明代理 + DNS 防污染 (logcg.com)](http://www.logcg.com/en/archives/860.html) | 中文，从刷机到 ss-redir 配置的完整流程 |
| [ShadowSocks 高级配置 (logcg.com)](https://www.logcg.com/en/archives/868.html) | 上篇的进阶版，含 ipset 分流等 |
| [How to Run Shadowsocks in a Router With OpenWRT (ding.dev)](https://ding.dev/run-shadowsocks-on-openwrt/) | 英文博客，简洁清晰的 ss-redir 配置指南 |
| [Shadowsocks ss-redir on OpenWrt (blog.jejer.net)](http://blog.jejer.net/2016/08/shadowsocks-ss-redir-on-openwrt.html) | ss-redir 透明代理实战 |
| [OpenWrt 论坛: Shadowsocks setup for beginners](https://forum.openwrt.org/t/guide-shadowsocks-setup-on-openwrt-for-beginners/77026) | 官方论坛新手指南，含 LuCI 界面配置 |
| [iptables transparent proxy script for ss-redir (GitHub Gist)](https://gist.github.com/hsupu/6a731a064d140b85e776ac0cda90508f) | 可直接复用的 iptables 脚本 |
| [OpenWrt ShadowSocks Traffic Redirection Rules (GitHub Gist)](https://gist.github.com/aa65535/7b4d83112c36e74b5b5a) | 经典的 ss-redir iptables 规则集 |

### 📌 综合教程 / 电子书

| 资源 | 说明 |
|------|------|
| [openwrt-fanqiang (GitHub)](https://github.com/softwaredownload/openwrt-fanqiang) | ⭐ 最全面的中文 OpenWrt 透明代理电子书，含 shadowsocks 全套配置 |
| [Shadowsocks on OpenWRT (btwiusearch.net)](http://btwiusearch.net/posts/openwrt-shadowsocks/) | Shadowsocks-libev + 硬件交换机配置 |
| [OpenWrt on VMware 透明代理 (GitHub)](https://github.com/luoqeng/OpenWrt-on-VMware) | 虚拟机方案，适合先在 VM 里练手再刷实体路由 |

### 📌 小内存设备优化

| 资源 | 说明 |
|------|------|
| [Ultimate Guide for 4MB flash devices (OpenWrt 论坛)](https://forum.openwrt.org/t/ultimate-guide-for-4mb-flash-devices-expert-only/81860) | 极限压缩固件的进阶技巧 |
| [Saving Space on OpenWrt (官方 Wiki)](https://openwrt.org/docs/guide-user/additional-software/saving_space) | 官方节省空间指南 |
| [Build image for devices with only 4MB flash (官方 Wiki)](https://openwrt.org/faq/build_image_for_devices_with_only_4mb_flash) | 4MB 设备编译指南 |
| [8/64 设备警告 (官方 Wiki)](https://openwrt.org/supported_devices/864_warning) | 8MB flash / 64MB RAM 设备的限制说明 |
