#!/bin/sh
# Watchdog: restart shadowsocks if ss-redir is not running
if ! pidof ss-redir >/dev/null && ! grep -q "YOUR_SERVER" /etc/shadowsocks-libev/config.json; then
    logger -t ss-watchdog "ss-redir not running, restarting"
    /etc/init.d/shadowsocks restart
fi
