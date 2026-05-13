#!/bin/bash

# ============================================================================
# DEPRECATED / ARCHIVE ONLY
# ============================================================================
# This script is NO LONGER USED in the production installation workflow.
# It is preserved here for safekeeping to document the environment setup
# required to compile Asterisk from source on Debian 12 (ARM64).
# ============================================================================

# --- 1. CONFIGURATION ---
DB_ROOT_PASS="armbianpbx" # Default SQL root password
LOG_FILE="/var/log/pbx_legacy_install.log"
DEBIAN_FRONTEND=noninteractive

# Output Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}" | tee -a "$LOG_FILE"
    exit 1
}

# Root Check
if [[ $EUID -ne 0 ]]; then
   echo "Run as root!" 
   exit 1
fi

# --- 2. SYSTEM UPDATE ---
log "Updating system repositories..."
apt-get update && apt-get upgrade -y || error "System update failed"

# --- 3. BUILD DEPENDENCIES ---
log "Installing build dependencies and essential tools..."
# Updated with: pkg-config (vital for configure), subversion (for mp3 sources),
# libicu-dev (for UCP/Intl), and libedit-dev (for Asterisk CLI).
apt-get install -y \
    git curl wget vim htop sox build-essential \
    pkg-config subversion \
    libncurses5-dev libncursesw5-dev libxml2-dev libsqlite3-dev \
    libssl-dev uuid-dev libjansson-dev libedit-dev libxslt1-dev \
    libicu-dev \
    libsrtp2-dev libopus-dev libvorbis-dev libspeex-dev \
    libspeexdsp-dev libgsm1-dev portaudio19-dev \
    unixodbc unixodbc-dev odbcinst libltdl-dev \
    || error "Failed to install build dependencies"

# --- 4. LAMP STACK (Linux, Apache, MariaDB, PHP) ---
log "Installing Web Server and Database..."

# Apache & MariaDB
apt-get install -y apache2 mariadb-server mariadb-client || error "Failed to install Apache/MariaDB"

# PHP 8.2 (Debian 12 Default)
# Includes all extensions required by FreePBX 17
log "Installing PHP 8.2 and extensions..."
apt-get install -y \
    php php-cli php-common php-curl php-gd php-mbstring \
    php-mysql php-soap php-xml php-intl php-zip php-bcmath \
    php-ldap php-pear libapache2-mod-php \
    || error "Failed to install PHP"

# --- 5. NODE.JS & PM2 ---
# FreePBX 17 requires Node 18+ and PM2 process manager.
log "Installing Node.js and NPM..."
apt-get install -y nodejs npm || error "Failed to install Node.js"
log "Node version installed: $(node -v)"

log "Installing PM2 (Process Manager)..."
npm install -g pm2@latest || error "Failed to install PM2"

# --- 6. PRELIMINARY CONFIGURATION ---

# Enable Apache Rewrite module (Critical for FreePBX)
a2enmod rewrite
systemctl restart apache2

# Basic MariaDB Setup
# Sets root password if not already set (simulates secure installation)
# Force start required in some environments
systemctl start mariadb
if mysqladmin -u root password "$DB_ROOT_PASS" 2>/dev/null; then
    log "MariaDB root password set."
else
    log "MariaDB root password already set or non-critical error."
fi

log "Environment preparation complete. Ready for manual compilation."
