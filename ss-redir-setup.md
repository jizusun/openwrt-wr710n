# Shadowsocks Redir Setup — OpenWrt WR710

## Device Info

| Item | Value |
|------|-------|
| Model | TP-Link WR710 (ar71xx/generic) |
| OpenWrt | 19.07.10 |
| Kernel | 4.14.275 (mips_24kc) |
| RAM | ~60MB |
| Overlay free | ~2.3MB |
| LAN IP | 192.168.2.1/24 |
| SS server | 192.168.1.14:444 (aes-128-gcm) |

## Current State

- `ss-local` running manually (SOCKS5 on port 1088) — not useful for transparent proxy
- `ss-redir`, `ss-tunnel` installed but not running
- `SS_REDIR` iptables chain exists, redirects TCP → port 12345 (nothing listening)
- UCI ss_redir configs exist but disabled, pointing to old server
- DNS redirect rules on port 53 exist
- No default gateway configured on the router

## Plan

### 1. Stop ss-local

```sh
kill 1172
# or
killall ss-local
```

### 2. Start ss-redir

Use the existing config (`/etc/shadowsocks-libev/config.json`) with redir port 12345 to match the existing iptables `SS_REDIR` chain.

```sh
ss-redir -c /etc/shadowsocks-libev/config.json -l 12345 -f /var/run/ss-redir.pid
```

Verify it's listening:

```sh
netstat -tlnp | grep 12345
```

### 3. Set up DNS via ss-tunnel

DNS is UDP, so it won't go through ss-redir. Use `ss-tunnel` to tunnel DNS queries to 8.8.8.8 over the SS connection.

```sh
ss-tunnel -c /etc/shadowsocks-libev/config.json -l 5353 -L 8.8.8.8:53 -u -f /var/run/ss-tunnel.pid
```

Then point dnsmasq upstream to it:

```sh
uci set dhcp.@dnsmasq[0].noresolv='1'
uci delete dhcp.@dnsmasq[0].server 2>/dev/null
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5353'
uci commit dhcp
/etc/init.d/dnsmasq restart
```

### 4. Verify routing to SS server

The router must be able to reach `192.168.1.14`. Check:

```sh
ip route
ping -c 2 192.168.1.14
```

If no route exists, add one (assuming the upstream gateway is reachable via WAN):

```sh
ip route add 192.168.1.0/24 via <upstream_gateway> dev <wan_interface>
```

### 5. Verify iptables

The existing `SS_REDIR` chain should already be correct:

```sh
iptables -t nat -L SS_REDIR -n -v
```

Expected rules:
- RETURN for SS server IP (192.168.1.14) — prevents loops
- RETURN for private/reserved ranges (10.0.0.0/8, 127.0.0.0/8, 192.168.0.0/16, etc.)
- REDIRECT remaining TCP → 12345

### 6. Client device setup

On devices that want to use the proxy, set:

- **Gateway**: `192.168.2.1`
- **DNS**: `192.168.2.1`

Or configure DHCP to push these automatically (if this router runs DHCP for the 192.168.2.0/24 subnet).

## Persist across reboot

Add to `/etc/rc.local` (before `exit 0`):

```sh
# Start ss-redir
ss-redir -c /etc/shadowsocks-libev/config.json -l 12345 -f /var/run/ss-redir.pid

# Start ss-tunnel for DNS
ss-tunnel -c /etc/shadowsocks-libev/config.json -l 5353 -L 8.8.8.8:53 -u -f /var/run/ss-tunnel.pid
```

## Limitations

- **TCP only** — UDP traffic (gaming, QUIC, etc.) is not proxied
- **No default route** — must ensure route to SS server exists
- **Low resources** — 60MB RAM, monitor with `free -m`
- **Old OpenWrt** — 19.07.10 is EOL, no security updates

## Quick test

```sh
# From a client device with gateway set to 192.168.2.1:
curl -I https://www.google.com

# From the router itself (test ss-tunnel DNS):
nslookup google.com 127.0.0.1#5353
```
