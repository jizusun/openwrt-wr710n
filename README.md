# OpenWrt for TP-Link TL-WR710N v1

通过 GitHub Actions 使用 OpenWrt ImageBuilder 构建精简固件，预装 shadowsocks-libev 透明代理，支持国内外分流、DNS 去广告，适合作为翻墙网关使用。

## 设备信息

| 项目 | 参数 |
|------|------|
| 型号 | TP-Link TL-WR710N v1 |
| SoC | Atheros AR9330 (MIPS 24Kc @ 400MHz) |
| RAM | 64MB |
| Flash | 8MB |
| WiFi | 2.4GHz 802.11b/g/n |
| USB | 1x USB 2.0 |
| 以太网 | 1x LAN, 1x WAN |

## 固件版本

通过 matrix 并行构建三个版本：

| 版本 | LuCI | IPv6 | Shadowsocks | 说明 |
|------|------|------|-------------|------|
| `full-luci` | ✅ 完整 | ✅ | ✅ | 功能最全，含防火墙/opkg 管理页面 |
| `mini-luci` | ✅ 最小化 | ✅ | ✅ | 精简 LuCI，去掉扩展模块 |
| `no-luci` | ❌ | ✅ | ✅ | 纯 SSH 管理，最省空间 |

所有版本都去掉了 PPP / PPPoE（WAN 口使用 DHCP）。

## 功能特性

### 透明代理

- `ss-redir` 透明代理（TCP + UDP）
- `ss-tunnel` DNS 隧道（转发到 8.8.8.8，防 DNS 污染）
- 开机自启动

### 国内外分流

基于 [china_ip_list](https://github.com/17mon/china_ip_list) 的 chnroute 方案：

| 流量类型 | 处理方式 |
|----------|----------|
| 中国 IP（约 8000+ CIDR） | 直连 |
| 私有地址（192.168.x.x 等） | 直连 |
| SS 服务器自身 | 直连（避免回环） |
| 其他所有流量 | 走 ss-redir 代理 |
| DNS 查询 | 通过 ss-tunnel 转发到 8.8.8.8 |

### DNS 去广告

构建时从 [StevenBlack/hosts](https://github.com/StevenBlack/hosts) 拉取广告域名黑名单（约 10 万条），通过 dnsmasq 的 `addnhosts` 加载，匹配的域名解析到 `0.0.0.0`。

### 自动维护

- **定时重启** — 每天凌晨 4:30 自动重启，防止小内存设备长时间运行内存不足
- **进程监控** — 每 5 分钟检查 ss-redir 进程，挂了自动重启并记录 syslog

### 数据更新

chnroute 和广告黑名单在每次 CI 构建时拉取最新版并打包进固件。需要更新时重新 push 触发构建即可。

## 构建方法

1. 进入仓库的 [Actions](../../actions) 页面
2. 每次 push 到 main 分支会自动触发构建
3. 等待构建完成（约 3-5 分钟）
4. 下载 artifact，选择构建成功且功能最丰富的版本

## 刷入固件

```bash
# 上传固件到路由器
scp openwrt-*-sysupgrade.bin root@192.168.2.1:/tmp/

# 刷入（-n 表示不保留旧配置）
ssh root@192.168.2.1 "sysupgrade -n /tmp/openwrt-*-sysupgrade.bin"
```

刷入后路由器会自动重启，等待约 1 分钟后重新 SSH 连接。

## 刷入后配置

只需编辑一个文件，填入你的服务器信息：

```bash
ssh root@192.168.2.1
vi /etc/shadowsocks-libev/config.json
```

把 `YOUR_SERVER` 和 `YOUR_PASSWORD` 改成你的实际值，然后启动：

```bash
/etc/init.d/shadowsocks start
```

其他功能（分流、去广告、定时重启、进程监控）均已自动配置，无需手动操作。

## 网络拓扑

```
互联网 ← 主路由 (DHCP) ← [WAN] WR710N [LAN/WiFi] ← 你的设备
                                  ↕
                          shadowsocks-libev
                        ┌─────────┴─────────┐
                    中国 IP → 直连      其他 → 代理
                        DNS 去广告 (dnsmasq)
```

WR710N 的 WAN 口接主路由 LAN 口，通过 DHCP 自动获取上游网络。连接到 WR710N LAN 口或 WiFi 的设备流量会自动按国内外分流，并过滤广告域名。

## 文件说明

```
files/
├── etc/
│   ├── init.d/shadowsocks          # init 脚本（启停 ss-redir/ss-tunnel/iptables）
│   ├── uci-defaults/99-shadowsocks # 首次启动配置（DNS、cron、广告过滤）
│   └── shadowsocks-libev/
│       ├── config.json             # SS 配置（需手动编辑）
│       ├── chnroute.txt            # 中国 IP 列表（CI 构建时生成）
│       ├── adblock.hosts           # 广告域名黑名单（CI 构建时生成）
│       └── watchdog.sh             # 进程监控脚本
```
