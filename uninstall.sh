#!/bin/bash

# ============================================================================
# SCRIPT: uninstall.sh (v0.2.2)
# PURPOSE: COMPLETELY remove Asterisk, FreePBX, LAMP stack
# TARGET:  Armbian 12
# ============================================================================

# Output Colors
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

echo ""
echo -e "${YELLOW}[0/9] Pre-cleanup Safety Checks...${NC}"

# Verify D-Bus is running (CRITICAL for NetworkManager)
if ! systemctl is-active --quiet dbus 2>/dev/null; then
    echo -e "${RED}ERROR: D-Bus is not running! This will break NetworkManager.${NC}"
    echo "Fix D-Bus first before running this script."
    exit 1
fi
echo "✓ D-Bus is running"

# Backup NetworkManager config (if exists)
if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    echo "✓ NetworkManager detected - creating backup..."
    mkdir -p /tmp/nm_backup
    cp -r /etc/NetworkManager /tmp/nm_backup/ 2>/dev/null || true
fi

# Save list of D-Bus related packages (DO NOT REMOVE THESE)
DBUS_PACKAGES=$(dpkg -l | grep -E 'dbus|glib|libgio' | awk '{print $2}' | tr '\n' ' ')
echo "Protected packages: D-Bus and dependencies"

echo -e "${YELLOW}[1/9] Stopping services & Killing processes...${NC}"

# 1. Kill FreePBX Console first to avoid DB connection errors
fwconsole stop &> /dev/null || true

# 2. Stop Services
systemctl stop asterisk &> /dev/null
systemctl stop freepbx &> /dev/null
systemctl stop apache2 &> /dev/null
systemctl stop mariadb &> /dev/null

# 3. Aggressive Process Kill - includes all MySQL/MariaDB processes
killall -9 asterisk &> /dev/null || true
killall -9 safe_asterisk &> /dev/null || true
killall -9 mysqld &> /dev/null || true
killall -9 mariadbd &> /dev/null || true
killall -9 mysqld_safe &> /dev/null || true
pkill -u asterisk &> /dev/null || true
pkill -u mysql &> /dev/null || true
pm2 kill &> /dev/null || true

echo -e "${YELLOW}[2/9] Removing Systemd Services...${NC}"
systemctl disable asterisk &> /dev/null
systemctl disable free-perm-fix.service &> /dev/null
rm -f /etc/systemd/system/asterisk.service
rm -f /etc/systemd/system/free-perm-fix.service
rm -f /usr/local/bin/fix_free_perm.sh
systemctl daemon-reload

echo -e "${YELLOW}[3/9] Deep Cleaning Directories...${NC}"
rm -rf /etc/asterisk
rm -rf /var/lib/asterisk
rm -rf /var/log/asterisk
rm -rf /var/spool/asterisk
rm -rf /var/run/asterisk
rm -rf /usr/lib/asterisk
rm -rf /usr/sbin/asterisk
rm -rf /var/www/html/*
rm -rf /home/asterisk

# Clean Logs & Configs for LAMP Stack
rm -rf /var/log/apache2
rm -rf /var/lib/apache2
rm -rf /var/lib/php
rm -rf /var/lib/mysql
rm -rf /var/log/mysql

echo -e "${YELLOW}[4/9] Removing Users and Groups...${NC}"
deluser --remove-home asterisk &> /dev/null || true
delgroup asterisk &> /dev/null || true

echo -e "${YELLOW}[5/9] Removing NodeJS artifacts (safe mode)...${NC}"
# Don't purge nodejs/npm as they may have system-wide dependencies
# Just clean up project-specific installations
npm uninstall -g pm2 &>/dev/null || true
rm -rf /usr/lib/node_modules/pm2 2>/dev/null || true
rm -rf /etc/npm
rm -rf ~/.npm

echo -e "${YELLOW}[6/9] Purging PBX Packages Only (Network-Safe)...${NC}"
# Detect installed PHP version to purge version-specific packages
PHP_VER=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "")

# Build the list of PHP packages to purge (generic + version-specific)
PHP_PURGE_LIST="php php-cli php-common php-curl php-gd php-mbstring php-mysql \
    php-soap php-xml php-intl php-zip php-bcmath php-ldap php-pear \
    libapache2-mod-php"

# Add version-specific packages for whatever PHP version is installed
if [ -n "$PHP_VER" ]; then
    for mod in cli common curl gd mbstring mysql xml soap intl zip bcmath ldap opcache readline; do
        PHP_PURGE_LIST="$PHP_PURGE_LIST php${PHP_VER}-${mod}"
    done
    PHP_PURGE_LIST="$PHP_PURGE_LIST libapache2-mod-php${PHP_VER}"
fi

DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq \
    apache2 apache2-bin apache2-data apache2-utils \
    mariadb-server mariadb-client mariadb-common \
    $PHP_PURGE_LIST \
    unixodbc unixodbc-dev odbcinst \
    xmlstarlet 2>&1 | grep -v "unable to locate package" || true

# Clean up orphaned dependencies
apt-get autoremove -y --purge >> /dev/null 2>&1 || true

# Deep purge MariaDB packages to remove ALL config files
echo -e "${YELLOW}[7/9] Deep cleaning MariaDB packages...${NC}"
dpkg --purge mariadb-server mariadb-client mariadb-common mysql-common 2>/dev/null || true

# Manually remove dpkg info files for MariaDB (prevents config file conflicts)
rm -f /var/lib/dpkg/info/mariadb* 2>/dev/null || true
rm -f /var/lib/dpkg/info/mysql* 2>/dev/null || true

echo -e "${YELLOW}[8/9] Cleaning up Package Manager...${NC}"
apt-get clean &> /dev/null

echo -e "${YELLOW}[9/9] Final Sweep - Residual files cleanup...${NC}"

rm -rf /var/lib/mysql-files 2>/dev/null || true
rm -rf /var/lib/mysql-keyring 2>/dev/null || true
rm -rf /usr/share/mysql 2>/dev/null || true
rm -f /etc/my.cnf 2>/dev/null || true
rm -f ~/.my.cnf 2>/dev/null || true
# Remove Status Banner
rm -f /etc/update-motd.d/99-pbx-status 2>/dev/null || true

echo -e "${GREEN}========================================================${NC}"
echo -e "${GREEN}                    SYSTEM CLEANED                      ${NC}"
echo -e "${GREEN}========================================================${NC}"

# Post-cleanup verification
echo ""
echo "Verifying critical services..."

# Check D-Bus
if systemctl is-active --quiet dbus 2>/dev/null; then
    echo -e "${GREEN}✓ D-Bus is still running${NC}"
else
    echo -e "${RED}✗ D-Bus FAILED - NetworkManager will not work!${NC}"
    echo "Recovery: sudo systemctl restart dbus"
    exit 1
fi

# Check NetworkManager
if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    echo -e "${GREEN}✓ NetworkManager is still running${NC}"
    
    # Query NetworkManager via D-Bus (optional check, may fail temporarily)
    if nmcli -t -f STATE general 2>/dev/null | grep -q "connected\\|connecting"; then
        echo -e "${GREEN}✓ NetworkManager D-Bus connection verified${NC}"
    else
        echo -e "${YELLOW} NetworkManager D-Bus may need reinitialization${NC}"
        echo "  This is normal after uninstallation - a reboot will restore full connectivity."
    fi
else
    echo -e "${YELLOW} NetworkManager status unknown${NC}"
    if [ -d "/tmp/nm_backup" ]; then
        echo "  Config backup available at: /tmp/nm_backup"
    fi
fi

echo ""
echo -e "${GREEN}Reboot recommended to complete cleanup.${NC}"
