# WR710N Transparent Proxy Setup

## Overview

OpenWrt 19.07.10 on TP-Link WR710N acting as a transparent TCP proxy with:
- China/foreign split routing (China IPs go direct, foreign IPs go through SS)
- Encrypted DNS via DoH (no DNS pollution)

```
Phone/Laptop → WiFi (OpenWrt-WR710N)
  ├─ China IP traffic → direct (bypassed via chnroute ipset)
  ├─ Foreign IP traffic → ss-redir → SS Server → Internet
  └─ DNS → dnsmasq → https-dns-proxy (DoH) → Alibaba DNS (encrypted, clean)
```

## Hardware

- Model: TP-Link WR710N (ar71xx/generic, MIPS 24Kc 400MHz)
- RAM: 64MB
- Flash: 8MB (overlay ~4MB)
- LAN: 192.168.2.1/24 (br-lan)
- WAN: DHCP (eth1)
- WiFi SSID: `OpenWrt-WR710N`

## Components

| Component | Role | Port |
|-----------|------|------|
| ss-redir | Transparent TCP proxy | 12345 |
| https-dns-proxy | DNS-over-HTTPS client | 5053 (UDP) |
| dnsmasq | LAN DNS + DHCP | 53 |
| ipset (chnroute) | China IP bypass list (~7500 CIDRs) | — |
| iptables | Traffic hijack (REDIRECT) + split routing | — |

## Config Files

### `/etc/shadowsocks-libev/config.json` (single source of truth)

```json
{
    "server": "<SS_SERVER_IP>",
    "server_port": <SS_SERVER_PORT>,
    "password": "<PASSWORD>",
    "method": "chacha20-ietf-poly1305",
    "timeout": 300
}
```

### `/etc/rc.local`

```sh
SS_CONFIG="/etc/shadowsocks-libev/config.json"

# Shadowsocks transparent proxy (TCP only)
ss-redir -c "$SS_CONFIG" -l 12345 -b 0.0.0.0 -f /var/run/ss-redir.pid

exit 0
```

### `/etc/firewall.user`

```sh
SS_SERVER=<SS_SERVER_IP>
REDIR_PORT=12345

# === Load China IP list into ipset ===
ipset create chnroute hash:net -exist
ipset flush chnroute
if [ -f /etc/shadowsocks-libev/chnroute.txt ]; then
    while read cidr; do
        ipset add chnroute "$cidr" 2>/dev/null
    done < /etc/shadowsocks-libev/chnroute.txt
fi

# === LAN traffic (PREROUTING) ===
iptables -t nat -N SS_REDIR 2>/dev/null
iptables -t nat -F SS_REDIR
iptables -t nat -A SS_REDIR -d $SS_SERVER -j RETURN
iptables -t nat -A SS_REDIR -d 0.0.0.0/8 -j RETURN
iptables -t nat -A SS_REDIR -d 10.0.0.0/8 -j RETURN
iptables -t nat -A SS_REDIR -d 127.0.0.0/8 -j RETURN
iptables -t nat -A SS_REDIR -d 169.254.0.0/16 -j RETURN
iptables -t nat -A SS_REDIR -d 172.16.0.0/12 -j RETURN
iptables -t nat -A SS_REDIR -d 192.168.0.0/16 -j RETURN
iptables -t nat -A SS_REDIR -d 224.0.0.0/4 -j RETURN
iptables -t nat -A SS_REDIR -m set --match-set chnroute dst -j RETURN
iptables -t nat -A SS_REDIR -p tcp -j REDIRECT --to-ports $REDIR_PORT
iptables -t nat -A PREROUTING -i br-lan -p tcp -j SS_REDIR

# === Router own traffic (OUTPUT) ===
iptables -t nat -A OUTPUT -p tcp -d $SS_SERVER -j RETURN
iptables -t nat -A OUTPUT -p tcp -d 127.0.0.0/8 -j RETURN
iptables -t nat -A OUTPUT -p tcp -d 10.0.0.0/8 -j RETURN
iptables -t nat -A OUTPUT -p tcp -d 172.16.0.0/12 -j RETURN
iptables -t nat -A OUTPUT -p tcp -d 192.168.0.0/16 -j RETURN
iptables -t nat -A OUTPUT -p tcp -d 224.0.0.0/4 -j RETURN
iptables -t nat -A OUTPUT -p tcp -m set --match-set chnroute dst -j RETURN
iptables -t nat -A OUTPUT -p tcp -j REDIRECT --to-ports $REDIR_PORT

# === DNS hijack (force all LAN DNS to router) ===
iptables -t nat -I PREROUTING -i br-lan -p udp --dport 53 -j REDIRECT --to-ports 53
iptables -t nat -I PREROUTING -i br-lan -p tcp --dport 53 -j REDIRECT --to-ports 53

# === Block DoT (prevent DNS leak via port 853) ===
iptables -I FORWARD -i br-lan -p tcp --dport 853 -j REJECT

# === Block IPv6 forwarding (force IPv4 through proxy) ===
ip6tables -I FORWARD -i br-lan -j DROP
```

### `/etc/shadowsocks-libev/chnroute.txt`

China IP CIDR list (~7500 entries). Source: https://github.com/17mon/china_ip_list

Downloaded during firmware build (CI) or manually:
```sh
curl -sL https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt \
  -o /etc/shadowsocks-libev/chnroute.txt
```

### UCI: https-dns-proxy

```
https-dns-proxy.@https-dns-proxy[0].resolver_url='https://dns.alidns.com/dns-query'
https-dns-proxy.@https-dns-proxy[0].bootstrap_dns='223.5.5.5'
https-dns-proxy.@https-dns-proxy[0].listen_addr='127.0.0.1'
https-dns-proxy.@https-dns-proxy[0].listen_port='5053'
```

### UCI: dnsmasq

```
dhcp.@dnsmasq[0].noresolv='1'
dhcp.@dnsmasq[0].server='127.0.0.1#5053'
```

## How It Works

### Split Routing (China bypass)

1. On boot, `/etc/firewall.user` loads `chnroute.txt` into an ipset
2. iptables checks destination IP against the ipset
3. If destination is a China IP → RETURN (direct connection, no proxy)
4. If destination is foreign → REDIRECT to ss-redir (proxied)

### TCP Proxy (Redir mode)

1. LAN device sends TCP packet to a foreign IP (e.g., google.com)
2. iptables PREROUTING → SS_REDIR chain → not in chnroute → REDIRECT to port 12345
3. ss-redir receives the packet, connects to SS server, forwards through encrypted tunnel
4. SS server connects to the real destination and relays data back

Router's own TCP traffic is also split-routed via the OUTPUT chain.

### DNS (DoH via https-dns-proxy)

1. LAN device sends DNS query to 192.168.2.1:53
2. iptables DNS hijack ensures all port 53 traffic goes to dnsmasq
3. dnsmasq forwards to 127.0.0.1#5053 (https-dns-proxy)
4. https-dns-proxy makes HTTPS request to `dns.alidns.com`
5. This HTTPS connection (TCP 443) is a China IP → goes direct (fast!)
6. Response comes back with clean, unpoisoned IP

### Why DoH via Alibaba?

- Plain DNS (UDP 53) gets poisoned by GFW for blocked domains (e.g., twitter.com)
- DoH encrypts DNS inside HTTPS — GFW can't see or tamper with queries
- Alibaba DoH is a China IP so it goes direct (no proxy needed), yet returns correct unpoisoned results
- Foreign DoH providers (Cloudflare, Google, Quad9) are blocked from China-based servers
- 360 DoH (`doh.360.cn`) actively censors (returns 127.0.0.1 for twitter.com) — do NOT use

## DNS Provider Comparison (from China)

| Provider | Protocol | twitter.com result | Trustworthy? |
|----------|----------|-------------------|---|
| 114.114.114.114 | Plain UDP | ❌ poisoned | No for blocked domains |
| 223.5.5.5 (Alibaba) | Plain UDP | ❌ poisoned | No for blocked domains |
| dns.alidns.com | DoH (HTTPS) | ✅ `104.244.42.197` | Yes |
| doh.pub (Tencent) | DoH (HTTPS) | ✅ `162.159.140.229` | Yes |
| doh.360.cn | DoH (HTTPS) | ❌ `127.0.0.1` | No — censors |
| 1.1.1.1 (Cloudflare) | DoH | ❌ blocked from China | N/A |
| dns.google | DoH | ❌ blocked from China | N/A |
| dns.quad9.net | DoH | ❌ blocked from China | N/A |

## Post-Flash Setup

After flashing the firmware, configure SS credentials:

```sh
./scripts/configure-ss.sh <server_ip> <port> <password> [method]
```

Or manually:
1. Edit `/etc/shadowsocks-libev/config.json`
2. Update `SS_SERVER=` in `/etc/firewall.user`
3. Reboot or restart services

## Switching SS Server

```sh
# 1. Edit config
vi /etc/shadowsocks-libev/config.json

# 2. Update firewall
sed -i 's/^SS_SERVER=.*/SS_SERVER=<NEW_IP>/' /etc/firewall.user

# 3. Restart
killall ss-redir
sh /etc/rc.local
/etc/init.d/firewall restart
```

### When switching to a foreign SS server

Foreign DoH providers become reachable. Optionally switch to Quad9 for better privacy:

```sh
uci set https-dns-proxy.@https-dns-proxy[0].resolver_url='https://dns.quad9.net/dns-query'
uci set https-dns-proxy.@https-dns-proxy[0].bootstrap_dns='9.9.9.9'
uci commit https-dns-proxy
/etc/init.d/https-dns-proxy restart
```

## Updating chnroute

The China IP list changes over time. Update periodically:

```sh
# From a machine that can access GitHub:
curl -sL https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt \
  | ssh wr710n 'cat > /etc/shadowsocks-libev/chnroute.txt'
ssh wr710n '/etc/init.d/firewall restart'
```

## Limitations

- **TCP only** — UDP traffic (QUIC, gaming, VoIP) is not proxied
- **~5-15 Mbps throughput** — limited by MIPS CPU doing chacha20 encryption
- **No hardware crypto** — chacha20-ietf-poly1305 is the fastest option for this CPU
- **8MB flash** — very limited space for additional packages
- **OpenWrt 19.07 EOL** — no security updates
- **ipset loading takes ~10s on boot** — 7500 entries on slow CPU

## Troubleshooting

```sh
# Check processes
ps | grep -E "ss-redir|https-dns" | grep -v grep

# Test DNS (should resolve)
ping -c1 google.com

# Test proxy (foreign IP → should show SS server IP)
wget -qO- http://ipinfo.io/ip

# Test China bypass (should be fast, direct)
wget -qO- --timeout=3 http://www.baidu.com > /dev/null && echo "baidu OK"

# Check ipset loaded
ipset list chnroute | head -5

# Check iptables counters
iptables -t nat -L SS_REDIR -n -v

# Restart everything
killall ss-redir
sh /etc/rc.local
/etc/init.d/firewall restart
/etc/init.d/https-dns-proxy restart
/etc/init.d/dnsmasq restart
```

## SSH Access

```sh
ssh wr710n
```

`~/.ssh/config`:
```
Host wr710n
    HostName 192.168.2.1
    User root
    HostKeyAlgorithms +ssh-rsa
    PubkeyAcceptedAlgorithms +ssh-rsa
```
