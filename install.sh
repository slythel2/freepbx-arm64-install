#!/bin/bash

# ============================================================================
# PROJECT:   Freepbx 17 for Debian 12 ARM64 Installer (Asterisk 22 + LAMP)
# LICENSE:   Apache-2.0
# REPO:      https://github.com/slythel2/FreePBX-17-for-Armbian-12-Bookworm-test
# ============================================================================

set -e
SCRIPTVER="0.7.0"

# --- CONFIGURATION ---
REPO_OWNER="slythel2"
REPO_NAME="FreePBX-17-for-Armbian-12-Bookworm-test"
REPO_RAW="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main"
FALLBACK_ARTIFACT="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/1.0/asterisk-22-current-arm64-debian12-v2.tar.gz"

DB_ROOT_PASS="armbianpbx"
LOG_FOLDER="/var/log/pbx"
LOG_FILE="${LOG_FOLDER}/freepbx17-install-$(date '+%Y.%m.%d-%H.%M.%S').log"
FILES_DIR="/tmp/pbx_installer_files"
export DEBIAN_FRONTEND=noninteractive
SANE_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Global state
currentStep=""

# ============================================================================
# LOGGING & ERROR HANDLING
# ============================================================================

echo_ts() { echo "$(date +"%Y-%m-%d %T") - $*"; }
log() { echo_ts "$*" >> "$LOG_FILE"; }
message() { echo_ts "$*" | tee -a "$LOG_FILE"; }
setCurrentStep() { currentStep="$1"; message "${currentStep}"; }
warn() { echo -e "${YELLOW}[WARNING] $1${NC}" | tee -a "$LOG_FILE"; }

error() {
	echo -e "${RED}[ERROR] $1${NC}" | tee -a "$LOG_FILE"
	exit 1
}

errorHandler() {
	log "****** INSTALLATION FAILED *****"
	echo_ts "Installation failed at step ${currentStep}. Please check log ${LOG_FILE} for details."
	log "Error at line: $1 exiting with code $2 (last command was: $3)"
	exit "$2"
}

terminate() {
	local exit_code=$?
	if [ $exit_code -ne 0 ]; then
		echo ""
		echo -e "${RED}>>> Installation failed. Last 10 log entries:${NC}"
		tail -n 10 "$LOG_FILE" 2>/dev/null || true
		echo ""
	fi
	message "Exiting script"
}

# ============================================================================
# PACKAGE MANAGEMENT
# ============================================================================

isinstalled() {
	PKG_OK=$(dpkg-query -W --showformat='${Status}\n' "$@" 2>/dev/null | grep "install ok installed")
	[ -n "$PKG_OK" ]
}

pkg_install() {
	log "############################### "
	PKG=("$@")
	if isinstalled "${PKG[@]}"; then
		log "${PKG[*]} already present ...."
	else
		message "Installing ${PKG[*]} ...."
		apt-get -y --ignore-missing -o DPkg::Options::="--force-confnew" -o Dpkg::Options::="--force-overwrite" install "${PKG[@]}" >> "$LOG_FILE"
		if isinstalled "${PKG[@]}"; then
			message "${PKG[*]} installed successfully...."
		else
			message "${PKG[*]} failed to install ...."
			terminate
		fi
	fi
	log "############################### "
}

# ============================================================================
# SYSTEM PREPARATION
# ============================================================================

check_root_privileges() {
	if [[ $EUID -ne 0 ]]; then
		echo "This script must be run as root"
		exit 1
	fi
}

check_architecture() {
	ARCH=$(dpkg --print-architecture)
	if [ "$ARCH" != "arm64" ] && [ "$ARCH" != "amd64" ]; then
		message "This installer supports arm64 and amd64 architectures."
		message "Current System's Architecture: $ARCH"
		exit 1
	fi
	message "Architecture check passed: $ARCH"
}

setup_logging() {
	mkdir -p "${LOG_FOLDER}"
	touch "${LOG_FILE}"
	exec 2>>"${LOG_FILE}"
}

download_config_files() {
	setCurrentStep "Downloading configuration files from repository..."
	mkdir -p "$FILES_DIR"

	local config_files=(
		"asterisk.conf" "asterisk.service" "dbus-fix.conf"
		"mariadb-tmpfiles.conf" "99-freepbx.cnf" "index.php"
		"fix_free_perm.sh" "free-perm-fix.service"
		"asterisk-pjsip.conf" "asterisk-jail.local" "99-pbx-status"
		"odbcinst.ini.tpl" "odbc.ini.tpl"
	)

	for f in "${config_files[@]}"; do
		if ! wget -q "${REPO_RAW}/files/${f}" -O "${FILES_DIR}/${f}"; then
			error "Failed to download config file: ${f}"
		fi
	done
	log "All configuration files downloaded successfully."
}

system_upgrade() {
	setCurrentStep "Making sure installation is sane"
	apt-get -y --fix-broken install >> "$LOG_FILE"
	apt-get autoremove -y >> "$LOG_FILE"

	if grep -q "^deb cdrom" /etc/apt/sources.list 2>/dev/null; then
		sed -i '/^deb cdrom/s/^/#/' /etc/apt/sources.list
		message "Commented out CD-ROM repository in sources.list"
	fi

	setCurrentStep "System upgrade and core dependencies..."
	apt-get update >> "$LOG_FILE" 2>&1
	# upgrade can fail on problematic packages, catch and fix
	if ! apt-get upgrade -y >> "$LOG_FILE" 2>&1; then
		warn "apt-get upgrade had errors, attempting fix..."
		apt-get -y --fix-broken install >> "$LOG_FILE" 2>&1 || true
		dpkg --configure -a >> "$LOG_FILE" 2>&1 || true
	fi
}

install_dependencies() {
	setCurrentStep "Installing required packages"

	apt-get install -y \
		git curl wget vim htop subversion sox pkg-config sngrep \
		jq acl haveged isc-dhcp-client dnsutils bind9-dnsutils bind9-host \
		apache2 mariadb-server mariadb-client odbc-mariadb \
		php php-cli php-common php-curl php-gd php-mbstring \
		php-mysql php-soap php-xml php-intl php-zip php-bcmath \
		php-ldap php-pear libapache2-mod-php \
		libxml2 libsqlite3-0 libjansson4 libedit2 libxslt1.1 \
		libopus0 libvorbis0a libspeex1 libspeexdsp1 libgsm1 \
		unixodbc unixodbc-dev odbcinst libltdl7 libicu-dev \
		liburiparser1 libjwt-dev liblua5.4-0 libtinfo6 \
		libsrtp2-1 libportaudio2 nodejs npm fail2ban

	# fallback: install versioned php packages if generic ones didn't create the apache sapi
	PHP_VER=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "8.2")
	if [ ! -f "/etc/php/${PHP_VER}/apache2/php.ini" ]; then
		message "PHP ${PHP_VER} apache2 SAPI not found, installing version-specific packages..."
		apt-get install -y "php${PHP_VER}-cli" "php${PHP_VER}-common" "php${PHP_VER}-curl" \
			"php${PHP_VER}-gd" "php${PHP_VER}-mbstring" "php${PHP_VER}-mysql" \
			"php${PHP_VER}-soap" "php${PHP_VER}-xml" "php${PHP_VER}-intl" \
			"php${PHP_VER}-zip" "php${PHP_VER}-bcmath" "php${PHP_VER}-ldap" \
			"libapache2-mod-php${PHP_VER}" >> "$LOG_FILE" 2>&1 || true
	fi
}

# ============================================================================
# PHP CONFIGURATION
# ============================================================================

configure_php() {
	setCurrentStep "Configuring PHP settings"

	# detect php version
	PHP_VER=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "8.2")
	message "Detected PHP version: ${PHP_VER}"

	for INI in /etc/php/${PHP_VER}/apache2/php.ini /etc/php/${PHP_VER}/cli/php.ini; do
		if [ -f "$INI" ]; then
			# performance tuning
			sed -i 's/^memory_limit = .*/memory_limit = 512M/' "$INI"
			sed -i 's/^upload_max_filesize = .*/upload_max_filesize = 120M/' "$INI"
			sed -i 's/^post_max_size = .*/post_max_size = 120M/' "$INI"
			sed -i 's/^;date.timezone =.*/date.timezone = UTC/' "$INI"
			# opcache
			sed -i 's/^;opcache.enable=.*/opcache.enable=1/' "$INI"
			sed -i 's/^;opcache.memory_consumption=.*/opcache.memory_consumption=128/' "$INI"
			sed -i 's/^;opcache.interned_strings_buffer=.*/opcache.interned_strings_buffer=8/' "$INI"
			sed -i 's/^;opcache.max_accelerated_files=.*/opcache.max_accelerated_files=10000/' "$INI"
			# mysql socket paths
			sed -i "s|^;*pdo_mysql.default_socket.*|pdo_mysql.default_socket = /run/mysqld/mysqld.sock|" "$INI"
			sed -i "s|^;*mysqli.default_socket.*|mysqli.default_socket = /run/mysqld/mysqld.sock|" "$INI"
			sed -i "s|^;*mysql.default_socket.*|mysql.default_socket = /run/mysqld/mysqld.sock|" "$INI"
		else
			warn "PHP ini not found: $INI"
		fi
	done
}

install_ioncube_loader() {
	setCurrentStep "Installing ionCube Loader for PHP..."
	IONCUBE_DIR="/tmp/ioncube_install"
	rm -rf "$IONCUBE_DIR" && mkdir -p "$IONCUBE_DIR"
	cd "$IONCUBE_DIR"

	if wget -q https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_aarch64.tar.gz; then
		tar xzf ioncube_loaders_lin_aarch64.tar.gz

		PHP_EXT_DIR=$(php -i 2>/dev/null | grep "^extension_dir" | awk '{print $3}')
		if [ -z "$PHP_EXT_DIR" ]; then
			PHP_EXT_DIR="/usr/lib/php/20220829"
		fi

		PHP_VER=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "8.2")
		# make sure php dirs exist
		mkdir -p "/etc/php/${PHP_VER}/mods-available"
		mkdir -p "/etc/php/${PHP_VER}/apache2/conf.d"
		mkdir -p "/etc/php/${PHP_VER}/cli/conf.d"
		if [ -f "ioncube/ioncube_loader_lin_${PHP_VER}.so" ]; then
			cp ioncube/ioncube_loader_lin_${PHP_VER}.so "$PHP_EXT_DIR/"
			echo "zend_extension = $PHP_EXT_DIR/ioncube_loader_lin_${PHP_VER}.so" > "/etc/php/${PHP_VER}/mods-available/ioncube.ini"
			ln -sf /etc/php/${PHP_VER}/mods-available/ioncube.ini /etc/php/${PHP_VER}/apache2/conf.d/00-ioncube.ini
			ln -sf /etc/php/${PHP_VER}/mods-available/ioncube.ini /etc/php/${PHP_VER}/cli/conf.d/00-ioncube.ini
			log "âœ“ ionCube Loader installed successfully"
		else
			warn "ionCube Loader file not found, FreePBX commercial modules may not work"
		fi
	else
		warn "Failed to download ionCube Loader"
	fi

	cd /
	rm -rf "$IONCUBE_DIR"
}

configure_networkmanager() {
	log "Configuring NetworkManager systemd override..."
	mkdir -p /etc/systemd/system/NetworkManager.service.d
	cp "${FILES_DIR}/dbus-fix.conf" /etc/systemd/system/NetworkManager.service.d/dbus-fix.conf
	systemctl daemon-reload
}

# ============================================================================
# ASTERISK USER & DOWNLOAD
# ============================================================================

create_asterisk_user() {
	setCurrentStep "Configuring Asterisk user..."
	getent group asterisk > /dev/null || groupadd asterisk
	if ! getent passwd asterisk > /dev/null; then
		useradd -r -d /var/lib/asterisk -s /bin/bash -g asterisk asterisk
		usermod -aG audio,dialout,www-data asterisk
	fi
}

download_asterisk_artifact() {
	setCurrentStep "Fetching latest Asterisk 22 release..."

	LATEST_URL=$(curl -s "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/releases/latest" \
		| jq -r '.assets[] | select(.name | contains("asterisk")) | .browser_download_url' | head -n 1)

	if [ -z "$LATEST_URL" ]; then
		warn "Could not fetch latest release from GitHub API, using fallback URL."
		ASTERISK_ARTIFACT_URL="$FALLBACK_ARTIFACT"
	else
		log "Latest release found: $LATEST_URL"
		ASTERISK_ARTIFACT_URL="$LATEST_URL"
	fi

	log "Downloading Asterisk artifact..."
	DOWNLOAD_SUCCESS=0
	for attempt in {1..3}; do
		if wget --show-progress -O /tmp/asterisk.tar.gz "$ASTERISK_ARTIFACT_URL"; then
			if tar -tzf /tmp/asterisk.tar.gz > /dev/null 2>&1; then
				DOWNLOAD_SUCCESS=1
				log "Asterisk artifact downloaded and verified successfully."
				break
			else
				warn "Downloaded file is corrupted. Attempt $attempt/3"
				rm -f /tmp/asterisk.tar.gz
			fi
		else
			warn "Download failed. Attempt $attempt/3"
			rm -f /tmp/asterisk.tar.gz
		fi
		sleep 2
	done

	if [ $DOWNLOAD_SUCCESS -eq 0 ]; then
		error "Failed to download Asterisk artifact after 3 attempts."
	fi
}

install_asterisk_artifact() {
	setCurrentStep "Installing Asterisk from artifact..."

	tar -xzf /tmp/asterisk.tar.gz -C /
	rm /tmp/asterisk.tar.gz

	mkdir -p /var/run/asterisk /var/log/asterisk /var/lib/asterisk /var/spool/asterisk /etc/asterisk /usr/lib/asterisk/modules
	chown -R asterisk:asterisk /var/run/asterisk /var/log/asterisk /var/lib/asterisk /var/spool/asterisk /etc/asterisk
	ldconfig

	cp "${FILES_DIR}/asterisk.conf" /etc/asterisk/asterisk.conf
	chown asterisk:asterisk /etc/asterisk/asterisk.conf
}

configure_asterisk_service() {
	setCurrentStep "Configuring Asterisk systemd service"

	cp "${FILES_DIR}/asterisk.service" /etc/systemd/system/asterisk.service
	systemctl daemon-reload
	systemctl enable asterisk mariadb apache2
}

# ============================================================================
# DATABASE SETUP
# ============================================================================

setup_mariadb() {
	setCurrentStep "Initializing MariaDB..."

	mkdir -p /run/mysqld
	chown mysql:mysql /run/mysqld
	chmod 755 /run/mysqld

	log "Configuring MariaDB tmpfiles.d for reboot persistence..."
	mkdir -p /etc/tmpfiles.d
	cp "${FILES_DIR}/mariadb-tmpfiles.conf" /etc/tmpfiles.d/mariadb.conf
	systemd-tmpfiles --create /etc/tmpfiles.d/mariadb.conf 2>/dev/null || true

	cp "${FILES_DIR}/99-freepbx.cnf" /etc/mysql/mariadb.conf.d/99-freepbx.cnf

	systemctl start mariadb

	sleep 3
	if ! systemctl is-active --quiet mariadb; then
		error "MariaDB failed to start. Check: journalctl -xeu mariadb.service"
	fi

	mysqladmin -u root password "$DB_ROOT_PASS" 2>/dev/null || true
}

configure_database() {
	setCurrentStep "Configuring databases and permissions"

	mysql -u root -p"$DB_ROOT_PASS" -e "CREATE DATABASE IF NOT EXISTS asterisk; CREATE DATABASE IF NOT EXISTS asteriskcdrdb;"
	mysql -u root -p"$DB_ROOT_PASS" -e "GRANT ALL PRIVILEGES ON asterisk.* TO 'asterisk'@'localhost' IDENTIFIED BY '$DB_ROOT_PASS';"
	mysql -u root -p"$DB_ROOT_PASS" -e "GRANT ALL PRIVILEGES ON asterisk.* TO 'asterisk'@'127.0.0.1' IDENTIFIED BY '$DB_ROOT_PASS';"
	mysql -u root -p"$DB_ROOT_PASS" -e "GRANT ALL PRIVILEGES ON asteriskcdrdb.* TO 'asterisk'@'localhost';"
	mysql -u root -p"$DB_ROOT_PASS" -e "GRANT ALL PRIVILEGES ON asteriskcdrdb.* TO 'asterisk'@'127.0.0.1';"
	mysql -u root -p"$DB_ROOT_PASS" -e "FLUSH PRIVILEGES;"

	log "Configuring MySQL socket for FreePBX..."
	REAL_SOCKET=$(find /run /var/run -name mysqld.sock 2>/dev/null | head -n 1)
	if [ -z "$REAL_SOCKET" ]; then
		error "MariaDB socket not found!"
	fi
	log "Found MariaDB socket at: $REAL_SOCKET"
	ln -sf "$REAL_SOCKET" /tmp/mysql.sock
	chmod 777 /tmp/mysql.sock 2>/dev/null || true
}

configure_odbc() {
	setCurrentStep "Configuring ODBC for CDR"

	ODBC_DRIVER=$(find /usr/lib -name "libmaodbc.so" | head -n 1)
	REAL_SOCKET=$(find /run /var/run -name mysqld.sock 2>/dev/null | head -n 1)

	if [ -n "$ODBC_DRIVER" ]; then
		sed "s|__ODBC_DRIVER__|${ODBC_DRIVER}|g" "${FILES_DIR}/odbcinst.ini.tpl" > /etc/odbcinst.ini
		sed "s|__SOCKET_PATH__|${REAL_SOCKET}|g" "${FILES_DIR}/odbc.ini.tpl" > /etc/odbc.ini
	fi
}

# ============================================================================
# APACHE CONFIGURATION
# ============================================================================

configure_apache() {
	setCurrentStep "Hardening Apache configuration..."

	# vhost config (heredoc to preserve apache env vars)
	cat > /etc/apache2/sites-available/freepbx.conf <<'APACHEEOF'
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    DocumentRoot /var/www/html

    # redirect / to /admin
    RewriteEngine On
    RewriteCond %{REQUEST_URI} ^/$
    RewriteRule ^/$ /admin [R=302,L]

    <Directory /var/www/html>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog ${APACHE_LOG_DIR}/error.log
    CustomLog ${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
APACHEEOF

	sed -i 's/^\(User\|Group\).*/\1 asterisk/' /etc/apache2/apache2.conf
	a2enmod rewrite
	a2ensite freepbx.conf
	a2dissite 000-default.conf

	cp "${FILES_DIR}/index.php" /var/www/html/index.php

	# webroot ownership (apache runs as asterisk)
	chown -R asterisk:asterisk /var/www/html

	# php session dir must be writable by asterisk
	PHP_VER=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "8.2")
	SESSION_DIR="/var/lib/php/sessions"
	mkdir -p "$SESSION_DIR"
	chown asterisk:asterisk "$SESSION_DIR"
	chmod 1733 "$SESSION_DIR"

	systemctl restart apache2
}

# ============================================================================
# ASTERISK STARTUP & VERIFICATION
# ============================================================================

start_asterisk() {
	setCurrentStep "Starting Asterisk and waiting for readiness..."
	systemctl restart asterisk
	sleep 5

	ASTERISK_READY=0
	for i in {1..10}; do
		if asterisk -rx "core show version" &> /dev/null; then
			ASTERISK_READY=1
			log "Asterisk is responding to CLI."
			break
		fi
		warn "Waiting for Asterisk... ($i/10)"
		sleep 3
	done

	if [ $ASTERISK_READY -eq 0 ]; then
		error "Asterisk failed to respond. Check /var/log/asterisk/messages"
	fi
}

verify_dns() {
	setCurrentStep "Verifying DNS resolution for SIP trunks..."
	if command -v dig &> /dev/null; then
		if dig "google.com" +short | grep -q .; then
			log "âœ“ DNS resolution is working correctly"
		else
			warn "DNS resolution may have issues. Check /etc/resolv.conf"
		fi
	else
		warn "dig command not available."
	fi
}

# ============================================================================
# FREEPBX INSTALLATION
# ============================================================================

install_freepbx() {
	setCurrentStep "Installing FreePBX 17..."
	cd /usr/src
	wget -q http://mirror.freepbx.org/modules/packages/freepbx/freepbx-17.0-latest.tgz
	tar xfz freepbx-17.0-latest.tgz
	cd freepbx

	log "Verifying MySQL connection..."
	if ! mysql -u asterisk -p"$DB_ROOT_PASS" -e "SELECT 1;" &> /dev/null; then
		error "Cannot connect to MySQL as asterisk user."
	fi

	./install -n \
		--dbuser asterisk \
		--dbpass "$DB_ROOT_PASS" \
		--webroot /var/www/html \
		--user asterisk \
		--group asterisk
}

install_freepbx_modules() {
	setCurrentStep "Installing FreePBX modules (this may take 10-15 minutes)..."

	if ! command -v fwconsole &> /dev/null; then
		warn "fwconsole not found, skipping module installation"
		return
	fi

	fwconsole chown

	log "Restarting Asterisk to load DNS libraries..."
	systemctl restart asterisk
	sleep 5

	# bulk install all modules
	MODULES_LIST="asterisk-cli backup blacklist bulkhandler certman cidlookup \
		configedit contactmanager customappsreg featurecodeadmin presencestate \
		qxact_reports recordings soundlang superfecta ucp userman \
		amd announcement calendar callback callflow callforward callrecording \
		callwaiting conferences dictate directory disa donotdisturb findmefollow \
		infoservices ivr languages miscapps miscdests paging parking queueprio \
		queues ringgroups setcid timeconditions tts vmblast wakeup \
		dahdiconfig api sms webrtc dashboard \
		asterisklogfiles cdr cel phpinfo printextensions weakpasswords \
		asteriskapi arimanager fax filestore iaxsettings musiconhold pinsets \
		sipsettings ttsengines voicemail pm2"

	fwconsole ma downloadinstall $MODULES_LIST &>/dev/null || true

	# remove firewall module (causes network issues on armbian)
	fwconsole ma remove firewall &>/dev/null || true

	log "All modules installed. Reloading FreePBX..."
	fwconsole reload || true
}

# ============================================================================
# FAIL2BAN SETUP
# ============================================================================

configure_fail2ban() {
	setCurrentStep "Configuring Fail2ban for Asterisk protection..."

	cp "${FILES_DIR}/asterisk-pjsip.conf" /etc/fail2ban/filter.d/asterisk-pjsip.conf
	cp "${FILES_DIR}/asterisk-jail.local" /etc/fail2ban/jail.d/asterisk.local

	systemctl enable fail2ban
	systemctl restart fail2ban
	sleep 2

	if systemctl is-active --quiet fail2ban; then
		JAILS_ACTIVE=$(fail2ban-client status 2>/dev/null | grep "Jail list" | grep -o "asterisk" | wc -l)
		if [ "$JAILS_ACTIVE" -ge 1 ]; then
			log "âœ“ Fail2ban is active and protecting Asterisk (${JAILS_ACTIVE} jails)"
		else
			warn "Fail2ban is running but jails may not be active yet."
		fi
	else
		warn "Fail2ban failed to start."
	fi
}

# ============================================================================
# PERSISTENCE SERVICE
# ============================================================================

create_persistence_service() {
	setCurrentStep "Creating persistence service for FreePBX"

	cp "${FILES_DIR}/fix_free_perm.sh" /usr/local/bin/fix_free_perm.sh
	chmod +x /usr/local/bin/fix_free_perm.sh

	cp "${FILES_DIR}/free-perm-fix.service" /etc/systemd/system/free-perm-fix.service
	systemctl enable free-perm-fix.service
}

# ============================================================================
# LOGIN BANNER
# ============================================================================

create_system_banner() {
	setCurrentStep "Creating system status banner..."

	cp "${FILES_DIR}/99-pbx-status" /etc/update-motd.d/99-pbx-status
	chmod +x /etc/update-motd.d/99-pbx-status
	rm -f /etc/motd 2>/dev/null
}

# ============================================================================
# POST-INSTALLATION VALIDATION
# ============================================================================

check_services() {
	setCurrentStep "Checking services status"

	services=("asterisk" "mariadb" "apache2" "fail2ban")
	for service in "${services[@]}"; do
		service_status=$(systemctl is-active "$service")
		if [[ "$service_status" != "active" ]]; then
			warn "Service $service is not active."
		else
			log "âœ“ Service $service is active"
		fi
	done
}

verify_installation() {
	setCurrentStep "Post-installation validation"
	set +e

	check_services

	if command -v asterisk &> /dev/null; then
		ASTERISK_VERSION=$(asterisk -rx "core show version" 2>/dev/null | head -n1 || echo "Unknown")
		message "Asterisk version: $ASTERISK_VERSION"
	fi

	if command -v fwconsole &> /dev/null; then
		message "FreePBX is installed"
		fwconsole motd 2>/dev/null || true
	fi
}

cleanup() {
	setCurrentStep "Cleaning up temporary files..."
	rm -rf "${FILES_DIR}"
	npm cache clean --force 2>/dev/null || true
	rm -rf /root/.cache 2>/dev/null || true
}

# ============================================================================
# UPDATER (--update flag)
# ============================================================================

run_asterisk_updater() {
	log "Starting Asterisk 22 Robust Update with Rollback Protection..."

	# Backup
	BACKUP_DIR="/tmp/asterisk_backup_$(date +%s)"
	mkdir -p "$BACKUP_DIR"

	log "Creating backup of current Asterisk installation..."
	if [ -f /usr/sbin/asterisk ]; then
		cp /usr/sbin/asterisk "$BACKUP_DIR/" || error "Failed to backup binary"
	fi
	if [ -d /usr/lib/asterisk/modules ]; then
		mkdir -p "$BACKUP_DIR/modules"
		cp -r /usr/lib/asterisk/modules/* "$BACKUP_DIR/modules/" 2>/dev/null || true
	fi
	log "Backup created at: $BACKUP_DIR"

	# Environment verification
	log "Verifying Asterisk environment..."
	mkdir -p /var/run/asterisk /var/log/asterisk /var/lib/asterisk /var/spool/asterisk /etc/asterisk /usr/lib/asterisk/modules

	if [ ! -f /etc/asterisk/asterisk.conf ]; then
		warn "asterisk.conf missing, recreating..."
		download_config_files
		cp "${FILES_DIR}/asterisk.conf" /etc/asterisk/asterisk.conf
	fi

	# Stop Asterisk
	log "Stopping Asterisk..."
	systemctl stop asterisk
	sleep 2
	pkill -9 asterisk 2>/dev/null || true
	sleep 1

	# Download update
	if ! command -v jq &> /dev/null; then
		apt-get update && apt-get install -y jq
	fi

	log "Fetching latest Asterisk 22 release from GitHub..."
	LATEST_URL=$(curl -s "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/releases/latest" \
		| jq -r '.assets[] | select(.name | contains("asterisk")) | .browser_download_url' | head -n 1)

	if [ -z "$LATEST_URL" ]; then
		warn "Could not fetch latest release, using fallback URL."
		ASTERISK_ARTIFACT_URL="$FALLBACK_ARTIFACT"
	else
		log "Latest release found: $LATEST_URL"
		ASTERISK_ARTIFACT_URL="$LATEST_URL"
	fi

	STAGE_DIR="/tmp/asterisk_update_stage"
	rm -rf "$STAGE_DIR" && mkdir -p "$STAGE_DIR"

	DOWNLOAD_SUCCESS=0
	for attempt in {1..3}; do
		if wget --show-progress -O /tmp/asterisk_update.tar.gz "$ASTERISK_ARTIFACT_URL"; then
			if tar -tzf /tmp/asterisk_update.tar.gz > /dev/null 2>&1; then
				DOWNLOAD_SUCCESS=1
				log "Update artifact downloaded and verified."
				break
			else
				warn "Downloaded file corrupted. Attempt $attempt/3"
				rm -f /tmp/asterisk_update.tar.gz
			fi
		else
			warn "Download failed. Attempt $attempt/3"
			rm -f /tmp/asterisk_update.tar.gz
		fi
		sleep 2
	done

	if [ $DOWNLOAD_SUCCESS -eq 0 ]; then
		rm -rf "$BACKUP_DIR"
		error "Failed to download update after 3 attempts."
	fi

	# Deploy update
	log "Extracting update..."
	tar -xzf /tmp/asterisk_update.tar.gz -C "$STAGE_DIR"

	log "Deploying updated binaries and modules..."
	[ -d "$STAGE_DIR/usr/sbin" ] && cp -f "$STAGE_DIR/usr/sbin/asterisk" /usr/sbin/
	[ -d "$STAGE_DIR/usr/lib/asterisk/modules" ] && cp -rf "$STAGE_DIR/usr/lib/asterisk/modules"/* /usr/lib/asterisk/modules/

	# Restore permissions
	log "Restoring correct permissions..."
	chown asterisk:asterisk /usr/sbin/asterisk
	chmod +x /usr/sbin/asterisk
	chown -R asterisk:asterisk /usr/lib/asterisk/modules
	chown -R asterisk:asterisk /var/run/asterisk /var/log/asterisk /var/lib/asterisk /var/spool/asterisk /etc/asterisk

	rm -rf "$STAGE_DIR" /tmp/asterisk_update.tar.gz
	ldconfig

	# Health check
	log "Starting Asterisk and performing health check..."
	systemctl start asterisk
	sleep 5

	ASTERISK_HEALTHY=0
	for i in {1..10}; do
		if asterisk -rx "core show version" &>/dev/null; then
			ASTERISK_HEALTHY=1
			log "âœ“ Asterisk is responding to CLI - Update successful!"
			break
		fi
		warn "Waiting for Asterisk to respond... ($i/10)"
		sleep 2
	done

	if [ $ASTERISK_HEALTHY -eq 0 ]; then
		# ROLLBACK
		error_msg="Asterisk failed to start. Rolling back..."
		echo -e "${RED}[ERROR] ${error_msg}${NC}" | tee -a "$LOG_FILE"
		systemctl stop asterisk
		pkill -9 asterisk 2>/dev/null || true

		if [ -f "$BACKUP_DIR/asterisk" ]; then
			cp -f "$BACKUP_DIR/asterisk" /usr/sbin/asterisk
			chown asterisk:asterisk /usr/sbin/asterisk
			chmod +x /usr/sbin/asterisk
		fi
		if [ -d "$BACKUP_DIR/modules" ]; then
			rm -rf /usr/lib/asterisk/modules/*
			cp -r "$BACKUP_DIR/modules"/* /usr/lib/asterisk/modules/
			chown -R asterisk:asterisk /usr/lib/asterisk/modules
		fi

		ldconfig
		systemctl start asterisk
		sleep 3
		rm -rf "$BACKUP_DIR"
		error "Rollback complete. Previous version restored. Check: journalctl -xeu asterisk"
	fi

	# Final validation
	log "Running FreePBX reload..."
	if command -v fwconsole &> /dev/null; then
		fwconsole reload || warn "FreePBX reload had warnings"
	fi

	rm -rf "$BACKUP_DIR"

	ASTERISK_VERSION=$(asterisk -rx "core show version" 2>/dev/null | head -n1 | awk '{print $2}' || echo "Unknown")
	echo -e "${GREEN}========================================================${NC}"
	echo -e "${GREEN}     ASTERISK UPDATE COMPLETED SUCCESSFULLY!           ${NC}"
	echo -e "${GREEN}            Version: $ASTERISK_VERSION                 ${NC}"
	echo -e "${GREEN}========================================================${NC}"
	exit 0
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
	# Handle updater mode
	if [[ "$1" == "--update" ]]; then
		run_asterisk_updater
		exit 0
	fi

	# Setup
	export PATH=$SANE_PATH
	check_root_privileges
	setup_logging
	log "Logging initialized to $LOG_FILE"

	# Set error handlers
	trap 'errorHandler "$LINENO" "$?" "$BASH_COMMAND"' ERR
	trap "terminate" EXIT

	start=$(date +%s)

	clear
	echo "========================================================"
	echo "   ARMBIAN 12 FREEPBX 17 INSTALLER (Asterisk 22 LTS)  "
	echo "========================================================"

	# Main installation flow
	check_architecture
	download_config_files
	system_upgrade
	install_dependencies
	configure_php
	install_ioncube_loader
	configure_networkmanager

	create_asterisk_user
	download_asterisk_artifact
	install_asterisk_artifact
	configure_asterisk_service

	setup_mariadb
	configure_database
	configure_odbc

	configure_apache

	start_asterisk
	verify_dns

	install_freepbx
	install_freepbx_modules

	configure_fail2ban
	create_persistence_service
	create_system_banner

	verify_installation
	cleanup

	execution_time="$(($(date +%s) - start))"
	message "Total installation time: $execution_time seconds"

	echo -e "${GREEN}========================================================${NC}"
	echo -e "${GREEN}            FREEPBX INSTALLATION COMPLETE!              ${NC}"
	echo -e "${GREEN}           Access: http://$(hostname -I | cut -d' ' -f1)/admin  ${NC}"
	echo -e "${GREEN}========================================================${NC}"

	exit 0
}

# Run main function
main "$@"
