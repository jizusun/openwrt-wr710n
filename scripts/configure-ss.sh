#!/bin/sh
# Configure SS credentials on the router after flashing.
# Usage: ./configure-ss.sh <server_ip> <server_port> <password> [method]
#
# Example:
#   ./configure-ss.sh 1.2.3.4 8388 mypassword chacha20-ietf-poly1305

set -e

SERVER="${1:?Usage: $0 <server_ip> <server_port> <password> [method]}"
PORT="${2:?Missing server_port}"
PASSWORD="${3:?Missing password}"
METHOD="${4:-chacha20-ietf-poly1305}"

ROUTER="wr710n"

echo ">>> Configuring SS: $SERVER:$PORT ($METHOD)"

ssh "$ROUTER" "cat > /etc/shadowsocks-libev/config.json << EOF
{
    \"server\": \"$SERVER\",
    \"server_port\": $PORT,
    \"password\": \"$PASSWORD\",
    \"method\": \"$METHOD\",
    \"timeout\": 300
}
EOF"

echo ">>> Updating firewall.user SS_SERVER..."
ssh "$ROUTER" "sed -i 's/^SS_SERVER=.*/SS_SERVER=$SERVER/' /etc/firewall.user"

echo ">>> Restarting services..."
ssh "$ROUTER" "killall ss-redir 2>/dev/null; sh /etc/rc.local & /etc/init.d/firewall restart"

echo ">>> Verifying..."
sleep 3
IP=$(ssh "$ROUTER" "wget -qO- --timeout=10 http://ipinfo.io/ip 2>/dev/null")
echo ">>> External IP: $IP"

if [ "$IP" = "$SERVER" ]; then
    echo ">>> SUCCESS: traffic is proxied through $SERVER"
else
    echo ">>> WARNING: expected $SERVER, got $IP"
fi
