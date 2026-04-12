#!/bin/sh
# Setup Shadowsocks transparent proxy (Redir mode) on OpenWrt WR710
# Usage: scp this to router then run as root, or execute via ssh

set -e

# === Config ===
SS_CONFIG="/etc/shadowsocks-libev/config.json"
SS_SERVER="192.168.1.14"
REDIR_PORT=12345
DNS_TUNNEL_PORT=5353
DNS_UPSTREAM="8.8.8.8:53"

# === Stop existing ss processes ===
echo ">>> Stopping existing shadowsocks processes..."
killall ss-local 2>/dev/null || true
killall ss-redir 2>/dev/null || true
killall ss-tunnel 2>/dev/null || true
sleep 1

# === Start ss-redir ===
echo ">>> Starting ss-redir on port $REDIR_PORT..."
ss-redir -c "$SS_CONFIG" -l "$REDIR_PORT" -f /var/run/ss-redir.pid
sleep 1
if netstat -tlnp 2>/dev/null | grep -q ":$REDIR_PORT"; then
    echo "    ss-redir OK"
else
    echo "    ERROR: ss-redir not listening on $REDIR_PORT" >&2
    exit 1
fi

# === Start ss-tunnel for DNS ===
echo ">>> Starting ss-tunnel (DNS) on port $DNS_TUNNEL_PORT..."
ss-tunnel -c "$SS_CONFIG" -l "$DNS_TUNNEL_PORT" -L "$DNS_UPSTREAM" -u -f /var/run/ss-tunnel.pid
sleep 1
if netstat -tlnp 2>/dev/null | grep -q ":$DNS_TUNNEL_PORT"; then
    echo "    ss-tunnel OK"
else
    echo "    WARNING: ss-tunnel may not show in netstat (UDP), continuing..."
fi

# === Configure dnsmasq to use ss-tunnel ===
echo ">>> Configuring dnsmasq to use local DNS tunnel..."
uci set dhcp.@dnsmasq[0].noresolv='1'
uci delete dhcp.@dnsmasq[0].server 2>/dev/null || true
uci add_list dhcp.@dnsmasq[0].server="127.0.0.1#$DNS_TUNNEL_PORT"
uci commit dhcp
/etc/init.d/dnsmasq restart
echo "    dnsmasq OK"

# === Setup iptables SS_REDIR chain ===
echo ">>> Setting up iptables rules..."
iptables -t nat -N SS_REDIR 2>/dev/null || iptables -t nat -F SS_REDIR

# Bypass SS server (prevent loops)
iptables -t nat -A SS_REDIR -d "$SS_SERVER" -j RETURN
# Bypass private/reserved ranges
iptables -t nat -A SS_REDIR -d 0.0.0.0/8 -j RETURN
iptables -t nat -A SS_REDIR -d 10.0.0.0/8 -j RETURN
iptables -t nat -A SS_REDIR -d 127.0.0.0/8 -j RETURN
iptables -t nat -A SS_REDIR -d 169.254.0.0/16 -j RETURN
iptables -t nat -A SS_REDIR -d 172.16.0.0/12 -j RETURN
iptables -t nat -A SS_REDIR -d 192.168.0.0/16 -j RETURN
iptables -t nat -A SS_REDIR -d 224.0.0.0/4 -j RETURN
# Redirect remaining TCP
iptables -t nat -A SS_REDIR -p tcp -j REDIRECT --to-ports "$REDIR_PORT"

# Hook into PREROUTING (skip if already hooked)
if ! iptables -t nat -C PREROUTING -i br-lan -p tcp -j SS_REDIR 2>/dev/null; then
    iptables -t nat -A PREROUTING -i br-lan -p tcp -j SS_REDIR
fi
echo "    iptables OK"

# === Persist in rc.local ===
echo ">>> Adding to /etc/rc.local for boot persistence..."
if ! grep -q "ss-redir" /etc/rc.local; then
    sed -i '/^exit 0$/d' /etc/rc.local
    cat >> /etc/rc.local << 'EOF'

# Shadowsocks transparent proxy
ss-redir -c /etc/shadowsocks-libev/config.json -l 12345 -f /var/run/ss-redir.pid
ss-tunnel -c /etc/shadowsocks-libev/config.json -l 5353 -L 8.8.8.8:53 -u -f /var/run/ss-tunnel.pid

exit 0
EOF
    echo "    rc.local updated"
else
    echo "    rc.local already configured, skipping"
fi

# === Verify ===
echo ""
echo "=== Status ==="
echo "ss-redir:  $(ps | grep ss-redir | grep -v grep | awk '{print "PID "$1" listening on port '$REDIR_PORT'"}')"
echo "ss-tunnel: $(ps | grep ss-tunnel | grep -v grep | awk '{print "PID "$1" tunneling DNS via port '$DNS_TUNNEL_PORT'"}')"
echo ""
echo "=== Test DNS ==="
nslookup google.com 127.0.0.1#$DNS_TUNNEL_PORT 2>/dev/null && echo "DNS OK" || echo "DNS FAILED (may need a moment to connect)"
echo ""
echo "Done. Set client devices gateway & DNS to 192.168.2.1"
