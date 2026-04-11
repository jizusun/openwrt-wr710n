# OpenWrt for TP-Link TL-WR710N v1

通过 GitHub Actions 使用 OpenWrt ImageBuilder 构建精简固件，预装 shadowsocks-libev，支持国内外分流，适合作为透明代理网关使用。

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
| `full` | ✅ 最小化 | ✅ | ✅ | 功能最全，空间可能不够 |
| `no-luci` | ❌ | ✅ | ✅ | 推荐，纯 SSH 管理 |
| `minimal` | ❌ | ❌ | ✅ | 最精简，一定能构建成功 |

三个版本都包含：
- `shadowsocks-libev-ss-redir` — 透明代理
- `shadowsocks-libev-ss-tunnel` — DNS 隧道，防 DNS 污染
- `iptables-mod-tproxy` / `ip-full` / `ipset` — 透明转发和国内外分流
- chnroute 中国 IP 列表（构建时自动拉取最新）

三个版本都去掉了 PPP / PPPoE（WAN 口使用 DHCP）。

## 国内外分流

基于 [china_ip_list](https://github.com/17mon/china_ip_list) 的 chnroute 方案：

| 流量类型 | 处理方式 |
|----------|----------|
| 中国 IP（约 8000+ CIDR） | 直连 |
| 私有地址（192.168.x.x 等） | 直连 |
| SS 服务器自身 | 直连（避免回环） |
| 其他所有流量 | 走 ss-redir 代理 |
| DNS 查询 | 通过 ss-tunnel 转发到 8.8.8.8 |

chnroute 列表在每次 CI 构建时拉取最新版并打包进固件。需要更新时重新跑一次 workflow 即可。

## 构建方法

1. 进入仓库的 [Actions](../../actions) 页面
2. 选择 "Build OpenWrt for TL-WR710N v1" workflow
3. 点击 "Run workflow" 手动触发
4. 等待构建完成（约 3-5 分钟）
5. 下载 artifact，选择构建成功且功能最丰富的版本

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

以下功能已自动配置，无需手动操作：
- ss-redir 透明代理（TCP + UDP）
- ss-tunnel DNS 隧道（转发到 8.8.8.8，防 DNS 污染）
- iptables + chnroute 国内外分流
- dnsmasq 指向 ss-tunnel
- 开机自启动

## 网络拓扑

```
互联网 ← 主路由 (DHCP) ← [WAN] WR710N [LAN/WiFi] ← 你的设备
                                  ↕
                          shadowsocks-libev
                        ┌─────────┴─────────┐
                    中国 IP → 直连      其他 → 代理
```

WR710N 的 WAN 口接主路由 LAN 口，通过 DHCP 自动获取上游网络。连接到 WR710N LAN 口或 WiFi 的设备流量会自动按国内外分流。
