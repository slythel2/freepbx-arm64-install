#!/bin/bash
DYN_SOCKET=$(find /run /var/run -name mysqld.sock 2>/dev/null | head -n 1)
[ -n "$DYN_SOCKET" ] && ln -sf "$DYN_SOCKET" /tmp/mysql.sock
mkdir -p /var/run/asterisk /var/log/asterisk
chown -R asterisk:asterisk /var/run/asterisk /var/log/asterisk /var/lib/asterisk /etc/asterisk
if [ -x /usr/sbin/fwconsole ]; then
    /usr/sbin/fwconsole chown &>/dev/null
fi
exit 0
