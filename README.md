# OpenWrt TL-WR710N v1 with Shadowsocks

精简版 OpenWrt 固件，预装 shadowsocks-libev，去掉 LuCI/PPP/IPv6 以节省空间。

## 构建

进入 Actions 页面，手动触发 workflow，完成后下载 artifact。

## 刷入

```bash
scp openwrt-*-sysupgrade.bin root@192.168.2.1:/tmp/
ssh root@192.168.2.1 "sysupgrade -n /tmp/openwrt-*-sysupgrade.bin"
```

## 刷入后配置

SSH 进路由器后自行配置 `/etc/shadowsocks-libev/config.json` 和 iptables 转发规则。
