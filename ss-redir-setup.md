# Shadowsocks Redir Setup — OpenWrt WR710

## How It Works

Understanding the moving parts makes troubleshooting much easier. Here is a full walkthrough of what happens when a client device on the LAN sends a TCP request, and how DNS is handled separately.

### Architecture Overview

```
Client device (192.168.2.x)
    │
    │  TCP connection to, e.g., google.com:443
    ▼
[TL-WR710N — OpenWrt]
    │
    ├─ iptables NAT PREROUTING  ← intercepts the packet before routing
    │       │
    │       └─ SS_REDIR chain
    │               ├─ RETURN if dst = SS server (avoid infinite loop)
    │               ├─ RETURN if dst = private/reserved IP (LAN traffic stays local)
    │               └─ REDIRECT → 127.0.0.1:12345  (everything else)
    │
    ├─ ss-redir  (listening on :12345)
    │       │  reads original destination via SO_ORIGINAL_DST socket option
    │       │  encrypts payload with aes-128-gcm
    │       └─► SS server (192.168.1.14:444)  ──►  google.com:443
    │
    └─ DNS path (UDP, handled separately)
            │
            dnsmasq  ──► 127.0.0.1:5353
                              │
                         ss-tunnel  ──► SS server ──► 8.8.8.8:53
```

### Component Roles

| Component | What it does |
|-----------|-------------|
| **iptables NAT REDIRECT** | Intercepts TCP packets at the kernel level and rewrites their destination to a local port. The application (client) never knows this happened. |
| **ss-redir** | A transparent TCP proxy built into shadowsocks-libev. Receives redirected connections, recovers the *original* destination with `SO_ORIGINAL_DST`, then forwards the data through an encrypted Shadowsocks tunnel. |
| **ss-tunnel** | Forwards UDP traffic (DNS queries) through the same Shadowsocks tunnel. Required because `iptables REDIRECT` only works for TCP; DNS is UDP. |
| **dnsmasq** | OpenWrt's DNS/DHCP server. Configured to send all DNS queries to `ss-tunnel` instead of a plain upstream server, so DNS lookups are also encrypted and not polluted. |

### TCP Traffic — Step by Step

1. A client device sends a `SYN` packet destined for `google.com:443`.
2. The packet arrives at the router's `br-lan` bridge (LAN + WiFi combined interface).
3. **iptables PREROUTING** processes the packet before the kernel decides where to route it.
4. The packet enters the `SS_REDIR` chain:
   - If the destination is the SS server IP → `RETURN` (skip proxying, send it directly — prevents a routing loop).
   - If the destination is a private/reserved range (`10.x`, `127.x`, `192.168.x`, etc.) → `RETURN` (LAN traffic never needs proxying).
   - Otherwise → `REDIRECT --to-ports 12345` (kernel rewrites destination to `127.0.0.1:12345`).
5. The kernel delivers the packet to `ss-redir` listening on port `12345`.
6. `ss-redir` calls `getsockopt(SO_ORIGINAL_DST)` on the accepted socket to recover the real destination IP and port that iptables hid.
7. `ss-redir` wraps the data in a Shadowsocks envelope encrypted with `aes-128-gcm` and opens a TCP connection to the SS server (`192.168.1.14:444`).
8. The SS server decrypts the envelope and opens a connection to the original destination (`google.com:443`).
9. Data flows back through the same path, fully encrypted between the router and the SS server.

### DNS Traffic — Step by Step

DNS uses UDP, which `iptables REDIRECT` cannot intercept in the same way, so a separate path is needed:

1. A client device sends a DNS query (UDP, port 53) to the router (`192.168.2.1`).
2. `dnsmasq` receives the query (it is the DNS server for the LAN).
3. `dnsmasq` is configured with `server=127.0.0.1#5353`, so it forwards the query to `ss-tunnel` on port `5353`.
4. `ss-tunnel` wraps the UDP DNS query in a TCP Shadowsocks connection to the SS server, tunneling it to `8.8.8.8:53`.
5. The SS server forwards the query to Google's DNS, gets the answer, and sends it back through the tunnel.
6. `ss-tunnel` delivers the answer to `dnsmasq`, which replies to the original client.

This prevents DNS poisoning because queries never travel in plaintext to a potentially monitored upstream resolver.

### Why SO_ORIGINAL_DST Matters

When iptables performs a `REDIRECT`, it changes the packet's destination IP/port to `127.0.0.1:12345`. Without extra information, the receiving process (`ss-redir`) would only see "a connection from the client" with no idea where the client actually wanted to go. Linux saves the original destination in the connection-tracking state. `ss-redir` retrieves it with:

```c
getsockopt(fd, SOL_IP, SO_ORIGINAL_DST, &addr, &addrlen);
```

This is the key mechanism that makes transparent proxying work — `ss-redir` can forward traffic to the correct server without the client having configured a proxy at all.

### Why ss-redir Instead of ss-local?

| | `ss-local` | `ss-redir` |
|-|-----------|-----------|
| Protocol exposed | SOCKS5 | none (transparent) |
| Client config needed | Yes (set SOCKS5 proxy) | No |
| Works for all apps | No (app must support SOCKS5) | Yes |
| Uses SO_ORIGINAL_DST | No | Yes |
| Purpose | Per-app proxy | Router-level transparent proxy |

### iptables Rules — Annotated

```sh
# Create a new chain in the NAT table for our rules
iptables -t nat -N SS_REDIR

# --- Bypass rules (RETURN = skip this chain, continue normal routing) ---

# Do NOT redirect traffic going to the SS server itself.
# Without this, ss-redir's own outbound connection would get redirected
# back into ss-redir → infinite loop → connection refused.
iptables -t nat -A SS_REDIR -d 192.168.1.14 -j RETURN

# Skip loopback and private/reserved address ranges.
# These should be delivered locally, not proxied.
iptables -t nat -A SS_REDIR -d 0.0.0.0/8    -j RETURN   # "this" network
iptables -t nat -A SS_REDIR -d 10.0.0.0/8   -j RETURN   # RFC1918 private
iptables -t nat -A SS_REDIR -d 127.0.0.0/8  -j RETURN   # loopback
iptables -t nat -A SS_REDIR -d 169.254.0.0/16 -j RETURN # link-local
iptables -t nat -A SS_REDIR -d 172.16.0.0/12  -j RETURN # RFC1918 private
iptables -t nat -A SS_REDIR -d 192.168.0.0/16 -j RETURN # RFC1918 private
iptables -t nat -A SS_REDIR -d 224.0.0.0/4    -j RETURN # multicast

# --- Redirect rule ---

# All remaining TCP traffic → redirect to ss-redir on port 12345.
# The kernel saves the original destination so ss-redir can retrieve it.
iptables -t nat -A SS_REDIR -p tcp -j REDIRECT --to-ports 12345

# --- Hook the chain into traffic flow ---

# Apply SS_REDIR to every TCP packet arriving on the LAN bridge.
# br-lan = all wired LAN ports + Wi-Fi clients combined.
# PREROUTING runs before the routing decision, so we catch
# traffic destined for external IPs before the kernel routes it.
iptables -t nat -A PREROUTING -i br-lan -p tcp -j SS_REDIR
```

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
