#!/bin/bash

# ============================================================================
# uninstall.sh (v0.4.0) — full removal of Asterisk, FreePBX, LAMP stack
# designed to never break networking or system integrity
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${RED}========================================================${NC}"
echo -e "${RED}      WARNING: FREEPBX UNINSTALLATION SCRIPT            ${NC}"
echo -e "${RED}========================================================${NC}"
echo "This script will delete EVERYTHING related to PBX."
echo ""
read -p "Are you SURE? (type 'yes' to confirm): " confirm

if [[ "$confirm" != "yes" ]]; then
    echo "Cancelled."
    exit 1
fi

# ============================================================================
# STEP 0: safety — detect network interface and set up fallback
# ============================================================================
echo ""
echo -e "${YELLOW}[0/7] safety checks and network fallback...${NC}"

if ! systemctl is-active --quiet dbus 2>/dev/null; then
    echo -e "${RED}ERROR: D-Bus is not running. Aborting.${NC}"
    exit 1
fi
echo "✓ d-bus is running"

# detect primary network interface (not lo)
NET_IF=$(ip -o link show | awk -F': ' '!/lo/{print $2; exit}')
NET_IP=$(ip -4 addr show "$NET_IF" 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1)
NET_GW=$(ip route show default 2>/dev/null | awk '{print $3; exit}')

echo "✓ detected interface: $NET_IF (ip: ${NET_IP:-none}, gw: ${NET_GW:-none})"

# write a static fallback in /etc/network/interfaces so we never lose connectivity
if [ -n "$NET_IF" ] && [ -n "$NET_IP" ] && [ -n "$NET_GW" ]; then
    NET_MASK=$(ip -4 addr show "$NET_IF" 2>/dev/null | grep -oP 'inet [\d.]+/\K\d+' | head -1)
    # only add if not already configured
    if ! grep -q "$NET_IF" /etc/network/interfaces 2>/dev/null; then
        cat >> /etc/network/interfaces << EOF

# fallback added by uninstall.sh — safe to remove after reboot
auto $NET_IF
iface $NET_IF inet static
    address $NET_IP/${NET_MASK:-24}
    gateway $NET_GW
    dns-nameservers 8.8.8.8 1.1.1.1
EOF
        echo "✓ static fallback written to /etc/network/interfaces"
    fi
fi

# backup NetworkManager config
if [ -d /etc/NetworkManager ]; then
    mkdir -p /tmp/nm_backup
    cp -r /etc/NetworkManager /tmp/nm_backup/ 2>/dev/null || true
    echo "✓ NetworkManager config backed up to /tmp/nm_backup"
fi

# protect system-critical packages from being touched
apt-mark manual network-manager dbus libdbus-1-3 wpasupplicant \
    isc-dhcp-client systemd systemd-sysv 2>/dev/null || true

# ============================================================================
# STEP 1: stop services
# ============================================================================
echo -e "${YELLOW}[1/7] stopping services...${NC}"

fwconsole stop &>/dev/null || true

for svc in asterisk freepbx apache2 mariadb fail2ban; do
    systemctl stop "$svc" &>/dev/null || true
done

killall -9 asterisk safe_asterisk mysqld mariadbd mysqld_safe &>/dev/null || true
pkill -u asterisk &>/dev/null || true
pkill -u mysql &>/dev/null || true
pm2 kill &>/dev/null || true

# ============================================================================
# STEP 2: disable custom systemd units
# ============================================================================
echo -e "${YELLOW}[2/7] removing custom systemd services...${NC}"

systemctl disable asterisk &>/dev/null || true
systemctl disable free-perm-fix.service &>/dev/null || true
rm -f /etc/systemd/system/asterisk.service
rm -f /etc/systemd/system/free-perm-fix.service
rm -f /usr/local/bin/fix_free_perm.sh
systemctl daemon-reload

# ============================================================================
# STEP 3: purge PBX packages (apt handles config removal)
# ============================================================================
echo -e "${YELLOW}[3/7] purging PBX packages...${NC}"

# detect php version before removing it
PHP_VER=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "")

PHP_PKGS="php php-cli php-common php-curl php-gd php-mbstring php-mysql \
    php-soap php-xml php-intl php-zip php-bcmath php-ldap php-pear \
    libapache2-mod-php"

if [ -n "$PHP_VER" ]; then
    for mod in cli common curl gd mbstring mysql xml soap intl zip bcmath ldap opcache readline; do
        PHP_PKGS="$PHP_PKGS php${PHP_VER}-${mod}"
    done
    PHP_PKGS="$PHP_PKGS libapache2-mod-php${PHP_VER} php${PHP_VER}"
fi

DEBIAN_FRONTEND=noninteractive apt-get purge -y \
    apache2 apache2-bin apache2-data apache2-utils \
    mariadb-server mariadb-client mariadb-common mysql-common \
    galera-4 \
    $PHP_PKGS \
    fail2ban \
    unixodbc unixodbc-dev odbcinst odbc-mariadb \
    2>&1 | grep -v "unable to locate" || true

# autoremove WITHOUT --purge (safer: leaves config files, prevents breakage)
apt-get autoremove -y 2>/dev/null || true

# fix any half-configured packages
dpkg --configure -a 2>/dev/null || true
apt-get -f install -y 2>/dev/null || true

# ============================================================================
# STEP 4: verify network survived the purge
# ============================================================================
echo -e "${YELLOW}[4/7] verifying network integrity...${NC}"

# restart NM if it's installed
systemctl restart NetworkManager &>/dev/null || true
sleep 2

if ping -c 1 -W 3 8.8.8.8 &>/dev/null; then
    echo -e "${GREEN}✓ network connectivity OK${NC}"
else
    echo -e "${YELLOW}⚠ network lost — attempting recovery...${NC}"
    # bring interface up manually
    if [ -n "$NET_IF" ]; then
        ip link set "$NET_IF" up 2>/dev/null || true
        # try dhcp first
        dhclient "$NET_IF" 2>/dev/null || true
        sleep 2
        if ! ping -c 1 -W 3 8.8.8.8 &>/dev/null; then
            # dhcp failed, use saved static config
            if [ -n "$NET_IP" ] && [ -n "$NET_GW" ]; then
                ip addr add "$NET_IP/${NET_MASK:-24}" dev "$NET_IF" 2>/dev/null || true
                ip route add default via "$NET_GW" 2>/dev/null || true
                echo "nameserver 8.8.8.8" > /etc/resolv.conf
            fi
        fi
    fi
    # reinstall NM if something went wrong
    if ping -c 1 -W 3 8.8.8.8 &>/dev/null; then
        echo "✓ network recovered — reinstalling NetworkManager..."
        apt-get install --reinstall -y network-manager 2>/dev/null || true
        systemctl restart NetworkManager &>/dev/null || true
    else
        echo -e "${RED}✗ could not restore network. Manual intervention needed.${NC}"
        echo "  try: ip link set $NET_IF up && dhclient $NET_IF"
    fi
fi

# ============================================================================
# STEP 5: clean asterisk/freepbx directories (not managed by apt)
# ============================================================================
echo -e "${YELLOW}[5/7] cleaning asterisk and freepbx directories...${NC}"

rm -rf /etc/asterisk
rm -rf /var/lib/asterisk
rm -rf /var/log/asterisk
rm -rf /var/spool/asterisk
rm -rf /var/run/asterisk
rm -rf /usr/lib/asterisk
rm -rf /usr/sbin/asterisk
rm -rf /home/asterisk
rm -rf /usr/src/freepbx*

# freepbx webroot only
rm -rf /var/www/html/admin
rm -rf /var/www/html/recordings
rm -f /var/www/html/index.php

# nodejs/pm2
npm uninstall -g pm2 &>/dev/null || true
rm -rf /usr/lib/node_modules/pm2 2>/dev/null || true

# user
deluser --remove-home asterisk &>/dev/null || true
delgroup asterisk &>/dev/null || true

# ============================================================================
# STEP 6: residual files (only AFTER apt purge is done)
# ============================================================================
echo -e "${YELLOW}[6/7] cleaning residual files...${NC}"

rm -rf /etc/mysql 2>/dev/null || true
rm -rf /etc/apache2 2>/dev/null || true
rm -f /etc/odbcinst.ini /etc/odbc.ini 2>/dev/null || true
rm -f /etc/my.cnf ~/.my.cnf 2>/dev/null || true

rm -rf /var/lib/mysql 2>/dev/null || true
rm -rf /var/lib/mysql-files 2>/dev/null || true
rm -rf /var/lib/mysql-keyring 2>/dev/null || true
rm -rf /var/lib/php 2>/dev/null || true
rm -rf /var/log/mysql 2>/dev/null || true
rm -rf /var/log/apache2 2>/dev/null || true
rm -rf /var/lib/apache2 2>/dev/null || true
rm -rf /usr/share/mysql 2>/dev/null || true

rm -rf /tmp/pbx_installer_files
rm -rf /var/log/pbx
rm -f /etc/update-motd.d/99-pbx-status
rm -f /etc/tmpfiles.d/mariadb.conf
rm -f /etc/fail2ban/filter.d/asterisk-pjsip.conf
rm -f /etc/fail2ban/jail.d/asterisk.local

apt-get clean &>/dev/null

# ============================================================================
# STEP 7: final verification
# ============================================================================
echo -e "${YELLOW}[7/7] final checks...${NC}"

FAIL=0

if systemctl is-active --quiet dbus 2>/dev/null; then
    echo -e "${GREEN}✓ d-bus OK${NC}"
else
    echo -e "${RED}✗ d-bus FAILED${NC}"
    FAIL=1
fi

if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    echo -e "${GREEN}✓ NetworkManager OK${NC}"
elif ping -c 1 -W 3 8.8.8.8 &>/dev/null; then
    echo -e "${YELLOW}⚠ NetworkManager not running but network is up (static fallback)${NC}"
else
    echo -e "${RED}✗ no network connectivity${NC}"
    FAIL=1
fi

echo ""
if [ $FAIL -eq 0 ]; then
    echo -e "${GREEN}========================================================${NC}"
    echo -e "${GREEN}                    SYSTEM CLEANED                      ${NC}"
    echo -e "${GREEN}========================================================${NC}"
else
    echo -e "${RED}========================================================${NC}"
    echo -e "${RED}   CLEANUP DONE BUT SOME SERVICES NEED ATTENTION        ${NC}"
    echo -e "${RED}========================================================${NC}"
fi

echo ""
echo -e "${GREEN}reboot recommended to complete cleanup.${NC}"
if [ -f /tmp/nm_backup/NetworkManager/NetworkManager.conf ]; then
    echo "NetworkManager backup available at: /tmp/nm_backup"
fi
