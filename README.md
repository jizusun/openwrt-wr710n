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
- LuCI（网页管理界面，全部通过 SSH 配置）
- PPP / PPPoE（WAN 口使用 DHCP，不需要拨号）

**保留的基础功能：**
- SSH (dropbear)
- WiFi (wpad-basic-wolfssl, kmod-ath9k)
- DHCP/DNS (dnsmasq)
- 防火墙 (firewall4, nftables)
- USB 支持 (kmod-usb-chipidea2)
- 包管理 (opkg)

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

```bash
# 创建配置文件
cat > /etc/shadowsocks-libev/config.json << 'EOF'
{
    "server": "你的服务器地址",
    "server_port": 端口,
    "local_address": "0.0.0.0",
    "local_port": 1080,
    "password": "你的密码",
    "method": "aes-128-gcm",
    "mode": "tcp_and_udp"
}
EOF

# 启动 ss-redir 透明代理
ss-redir -c /etc/shadowsocks-libev/config.json -l 1080 -u -f /var/run/ss-redir.pid

# 启动 ss-tunnel DNS 隧道（防 DNS 污染）
ss-tunnel -c /etc/shadowsocks-libev/config.json -l 5353 -L 8.8.8.8:53 -u -f /var/run/ss-tunnel.pid

# 配置 iptables 透明转发（按需调整）
iptables -t nat -N SS_REDIR
iptables -t nat -A SS_REDIR -d 0.0.0.0/8 -j RETURN
iptables -t nat -A SS_REDIR -d 10.0.0.0/8 -j RETURN
iptables -t nat -A SS_REDIR -d 127.0.0.0/8 -j RETURN
iptables -t nat -A SS_REDIR -d 172.16.0.0/12 -j RETURN
iptables -t nat -A SS_REDIR -d 192.168.0.0/16 -j RETURN
iptables -t nat -A SS_REDIR -p tcp -j REDIRECT --to-ports 1080
iptables -t nat -A PREROUTING -p tcp -j SS_REDIR

# 将 DNS 指向 ss-tunnel
uci set dhcp.@dnsmasq[0].noresolv='1'
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5353'
uci commit dhcp
/etc/init.d/dnsmasq restart
```

## 网络拓扑

```
互联网 ← 主路由 (DHCP) ← [WAN] WR710N [LAN] ← 你的设备
                                  ↕
                          shadowsocks-libev
                          (透明代理 + DNS 隧道)
```

WR710N 的 WAN 口接主路由 LAN 口，通过 DHCP 自动获取上游网络。连接到 WR710N LAN 口或 WiFi 的设备流量会自动经过 shadowsocks 代理。
