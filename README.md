# OpenWrt for TP-Link TL-WR710N v1

通过 GitHub Actions 使用 OpenWrt ImageBuilder 构建精简固件，预装 shadowsocks-libev，适合作为透明代理网关使用。

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

## 固件说明

基于 OpenWrt 22.03.7 (ath79/generic)，为节省 Flash 空间做了以下调整：

**预装的额外包：**
- `shadowsocks-libev-ss-redir` — 透明代理
- `shadowsocks-libev-ss-tunnel` — DNS 隧道，防止 DNS 污染
- `iptables-mod-tproxy` / `ip-full` / `ipset` — iptables 透明转发所需

**去掉的包（省空间）：**
- LuCI 扩展模块（luci-app-firewall, luci-app-opkg, luci-proto-ppp 等）
- PPP / PPPoE（WAN 口使用 DHCP，不需要拨号）

**保留的基础功能：**
- SSH (dropbear)
- WiFi (wpad-basic-wolfssl, kmod-ath9k)
- DHCP/DNS (dnsmasq)
- 防火墙 (firewall4, nftables)
- USB 支持 (kmod-usb-chipidea2)
- 包管理 (opkg)
- LuCI 最小化 Web 界面（luci-base, luci-mod-admin-full, luci-theme-bootstrap）
- IPv6

## 构建方法

1. 进入仓库的 [Actions](../../actions) 页面
2. 选择 "Build OpenWrt for TL-WR710N v1" workflow
3. 点击 "Run workflow" 手动触发
4. 等待构建完成（约 3-5 分钟），下载 artifact 中的 sysupgrade.bin

## 刷入固件

```bash
# 上传固件到路由器
scp openwrt-*-sysupgrade.bin root@192.168.2.1:/tmp/

# 刷入（-n 表示不保留旧配置）
ssh root@192.168.2.1 "sysupgrade -n /tmp/openwrt-*-sysupgrade.bin"
```

刷入后路由器会自动重启，等待约 1 分钟后重新 SSH 连接。

## 刷入后配置 Shadowsocks

只需编辑一个文件，填入你的服务器信息：

```bash
ssh root@192.168.2.1
vi /etc/shadowsocks-libev/config.json
```

把 `YOUR_SERVER` 和 `YOUR_PASSWORD` 改成你的实际值，然后启动：

```bash
/etc/init.d/shadowsocks start
```

固件已预配置好以下自动化：
- `ss-redir` 透明代理（TCP + UDP）
- `ss-tunnel` DNS 隧道（转发到 8.8.8.8，防 DNS 污染）
- iptables 规则自动设置（私有地址段绕过代理）
- dnsmasq 自动指向 ss-tunnel
- 开机自启动

## 网络拓扑

```
互联网 ← 主路由 (DHCP) ← [WAN] WR710N [LAN] ← 你的设备
                                  ↕
                          shadowsocks-libev
                          (透明代理 + DNS 隧道)
```

WR710N 的 WAN 口接主路由 LAN 口，通过 DHCP 自动获取上游网络。连接到 WR710N LAN 口或 WiFi 的设备流量会自动经过 shadowsocks 代理。
