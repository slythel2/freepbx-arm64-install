#!/bin/bash

# ============================================================================
# PROJECT:   FreePBX 17 ARM64 Installation Script (Asterisk 22 LTS)
# LICENSE:   Apache-2.0
# REPO:      https://github.com/slythel2/freepbx-arm64-install-test
# ============================================================================

set -e
SCRIPTVER="0.7.0"

# --- CONFIGURATION ---
REPO_OWNER="slythel2"
REPO_NAME="freepbx-arm64-install-test"
REPO_RAW="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main"
FALLBACK_ARTIFACT="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/1.0/asterisk-22-current-arm64-debian12-v2.tar.gz"

DB_ROOT_PASS=$(openssl rand -base64 18 | tr -d '/+=')
LOG_FOLDER="/var/log/pbx"
LOG_FILE="${LOG_FOLDER}/freepbx17-install-$(date '+%Y.%m.%d-%H.%M.%S').log"
FILES_DIR="/tmp/pbx_installer_files"
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
SANE_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
PIDFILE="/var/run/freepbx_installer.pid"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Global state
currentStep=""
STEP_NUM=0

# CLI flags (defaults)
skipversion=false
nochrony=false

# --- ARGUMENT PARSING ---
while [[ $# -gt 0 ]]; do
	case $1 in
		--skipversion)
			skipversion=true
			shift
			;;
		--nochrony)
			nochrony=true
			shift
			;;
		--help|-h)
			echo "Usage: $0 [OPTIONS]"
			echo ""
			echo "Options:"
			echo "  --skipversion    Skip remote installer version check"
			echo "  --nochrony       Skip chrony NTP installation"
			echo "  --help           Show this help"
			exit 0
			;;
		-*)
			echo "Unknown option: $1"
			echo "Usage: $0 [--skipversion] [--nochrony] [--help]"
			exit 1
			;;
		*)
			echo "Unknown argument: $1"
			exit 1
			;;
	esac
done

# ============================================================================
# LOGGING & ERROR HANDLING
# ============================================================================

echo_ts() { echo "$(date +"%Y-%m-%d %T") - $*"; }
log() { echo_ts "$*" >> "$LOG_FILE"; }
message() { echo_ts "$*" | tee -a "$LOG_FILE"; }
setCurrentStep() { STEP_NUM=$(( STEP_NUM + 1 )); currentStep="$1"; message "[Step ${STEP_NUM}] ${currentStep}"; }
warn() { echo -e "${YELLOW}[WARNING] $1${NC}" | tee -a "$LOG_FILE"; }

error() {
	echo -e "${RED}[ERROR] $1${NC}" | tee -a "$LOG_FILE"
	errorHandler "${BASH_LINENO[0]}" 1 "$1"
}

errorHandler() {
	local err_line="$1"
	local err_code="$2"
	local err_cmd="$3"

	echo ""
	echo -e "${RED}╔══════════════════════════════════════════════════════════╗${NC}"
	echo -e "${RED}║              INSTALLATION FAILED — DEBUG INFO            ║${NC}"
	echo -e "${RED}╠══════════════════════════════════════════════════════════╣${NC}"
	echo -e "${RED}║ Step:    ${NC}${currentStep}"
	echo -e "${RED}║ Line:    ${NC}${err_line}"
	echo -e "${RED}║ Exit:    ${NC}${err_code}"
	echo -e "${RED}║ Command: ${NC}${err_cmd}"
	echo -e "${RED}╠══════════════════════════════════════════════════════════╣${NC}"
	echo -e "${RED}║ Last 20 log entries:${NC}"
	tail -n 20 "$LOG_FILE" 2>/dev/null | while IFS= read -r line; do
		echo -e "${RED}║${NC}  $line"
	done
	echo -e "${RED}╠══════════════════════════════════════════════════════════╣${NC}"
	echo -e "${RED}║ Full log: ${NC}${LOG_FILE}"
	echo -e "${RED}╚══════════════════════════════════════════════════════════╝${NC}"
	echo ""

	log "****** INSTALLATION FAILED *****"
	log "Step: ${currentStep}"
	log "Error at line: $err_line exiting with code $err_code (last command was: $err_cmd)"

	exit "$err_code"
}

terminate() {
	local exit_code=$?
	if [ $exit_code -ne 0 ]; then
		# errorHandler already logged it
		log "Script terminated with exit code $exit_code"
	fi
	message "Exiting script"
}

# ============================================================================
# SELF-VERSION CHECK
# ============================================================================

check_script_version() {
	if [ "$skipversion" = true ]; then
		log "Skipping version check (--skipversion flag set)"
		return
	fi

	setCurrentStep "Checking for newer installer version on GitHub..."
	local remote_script="/tmp/install_latest_check.sh"

	if ! wget -q -T 10 "${REPO_RAW}/install.sh" -O "$remote_script" 2>/dev/null; then
		warn "Could not check for updates (network issue). Continuing with current version."
		return
	fi

	local latest_ver
	latest_ver=$(grep '^SCRIPTVER=' "$remote_script" | head -1 | cut -d'"' -f2)
	rm -f "$remote_script"

	if [ -z "$latest_ver" ]; then
		warn "Could not parse remote version. Continuing."
		return
	fi

	if dpkg --compare-versions "$latest_ver" gt "$SCRIPTVER" 2>/dev/null; then
		echo ""
		echo -e "${YELLOW}╔══════════════════════════════════════════════════════════╗${NC}"
		echo -e "${YELLOW}║  A newer version ($latest_ver) is available on GitHub.      ║${NC}"
		echo -e "${YELLOW}║  You are running version $SCRIPTVER.                        ║${NC}"
		echo -e "${YELLOW}║  Use --skipversion to bypass this check.                 ║${NC}"
		echo -e "${YELLOW}╚══════════════════════════════════════════════════════════╝${NC}"
		echo ""
		echo -n "Continue anyway? [y/N]: "
		read -r answer
		if [[ ! "$answer" =~ ^[Yy]$ ]]; then
			echo "Aborting. Download the latest version from:"
			echo "  https://github.com/${REPO_OWNER}/${REPO_NAME}"
			exit 0
		fi
	else
		log "Installer is up to date (v${SCRIPTVER})."
	fi
}

# ============================================================================
# TRIXIE UPGRADE PROTECTION
# ============================================================================

block_trixie_upgrade() {
	setCurrentStep "Blocking accidental Debian 13 (Trixie) upgrade..."

	# block trixie packages
	cat >/etc/apt/preferences.d/99-block-trixie.pref <<'EOF'
# block Debian 13 Trixie - FreePBX 17 only supports Bookworm
Package: *
Pin: release n=trixie
Pin-Priority: -1

EOF

	# If sources.list uses "stable" instead of "bookworm", fix it
	if grep -qE 'deb\s+.*\s+stable\b' /etc/apt/sources.list 2>/dev/null; then
		sed -i.bak -E 's|(deb\s+.*\s+)stable\b|\1bookworm|g' /etc/apt/sources.list
		message "Fixed sources.list: replaced 'stable' with 'bookworm'"
	fi

	log "Trixie upgrade protection enabled."
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

check_disk_space() {
	local path="$1" required_gb="$2" desc="${3:-$1}"
	local available_kb
	available_kb=$(df -k "$path" 2>/dev/null | awk 'NR==2 {print $4}')
	if [ -z "$available_kb" ]; then
		warn "Could not check disk space at $path"
		return
	fi
	local required_kb=$(( required_gb * 1024 * 1024 ))
	if [ "$available_kb" -lt "$required_kb" ]; then
		error "Insufficient disk space at $path: need ${required_gb}GB, have $(( available_kb / 1024 / 1024 ))GB free"
	fi
	log "Disk space OK: $desc has $(( available_kb / 1024 / 1024 ))GB free (need ${required_gb}GB)"
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
		"asterisk.conf" "asterisk.service"
		"mariadb-tmpfiles.conf" "99-freepbx.cnf" "index.php"
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
	# upgrade can fail, catch and fix
	if ! apt-get upgrade -y >> "$LOG_FILE" 2>&1; then
		warn "apt-get upgrade had errors, attempting fix..."
		apt-get -y --fix-broken install >> "$LOG_FILE" 2>&1 || true
		dpkg --configure -a >> "$LOG_FILE" 2>&1 || true
	fi
}

install_dependencies() {
	setCurrentStep "Installing required packages"

	# pre-configure postfix
	debconf-set-selections <<< "postfix postfix/mailname string $(hostname -f)"
	debconf-set-selections <<< "postfix postfix/main_mailer_type string 'Internet Site'"

	apt-get install -y \
		git curl wget vim htop subversion sox pkg-config sngrep \
		jq acl dnsutils bind9-dnsutils bind9-host \
		apache2 mariadb-server mariadb-client odbc-mariadb \
		php php-cli php-common php-curl php-gd php-mbstring \
		php-mysql php-soap php-xml php-intl php-zip php-bcmath \
		php-ldap php-pear libapache2-mod-php \
		libxml2 libsqlite3-0 libjansson4 libedit2 libxslt1.1 \
		libopus0 libvorbis0a libspeex1 libspeexdsp1 libgsm1 \
		unixodbc unixodbc-dev odbcinst libltdl7 libicu-dev \
		libsrtp2-1 libportaudio2 liburiparser1 nodejs npm fail2ban python3-systemd \
		ffmpeg lame mpg123 postfix

	# chrony for NTP
	if [ "$nochrony" = false ]; then
		log "Installing chrony for NTP time synchronization..."
		apt-get install -y chrony >> "$LOG_FILE" 2>&1 || warn "Failed to install chrony."
	else
		log "Skipping chrony installation (--nochrony flag set)."
	fi

	# pm2 required by FreePBX 17 modules
	npm install -g pm2 >> "$LOG_FILE" 2>&1 || true

	# fallback: versioned php packages if generic ones didn't create the apache sapi
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
			# performance
			sed -i 's/^memory_limit = .*/memory_limit = 512M/' "$INI"
			sed -i 's/^upload_max_filesize = .*/upload_max_filesize = 120M/' "$INI"
			sed -i 's/^post_max_size = .*/post_max_size = 120M/' "$INI"
			sed -i 's/^;date.timezone =.*/date.timezone = UTC/' "$INI"
			# opcache settings
			sed -i 's/^;opcache.enable=.*/opcache.enable=1/' "$INI"
			sed -i 's/^;opcache.memory_consumption=.*/opcache.memory_consumption=128/' "$INI"
			sed -i 's/^;opcache.interned_strings_buffer=.*/opcache.interned_strings_buffer=8/' "$INI"
			sed -i 's/^;opcache.max_accelerated_files=.*/opcache.max_accelerated_files=10000/' "$INI"
			# mysql socket
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
		# ensure php dirs exist
		mkdir -p "/etc/php/${PHP_VER}/mods-available"
		mkdir -p "/etc/php/${PHP_VER}/apache2/conf.d"
		mkdir -p "/etc/php/${PHP_VER}/cli/conf.d"
		if [ -f "ioncube/ioncube_loader_lin_${PHP_VER}.so" ]; then
			cp ioncube/ioncube_loader_lin_${PHP_VER}.so "$PHP_EXT_DIR/"
			echo "zend_extension = $PHP_EXT_DIR/ioncube_loader_lin_${PHP_VER}.so" > "/etc/php/${PHP_VER}/mods-available/ioncube.ini"
			ln -sf /etc/php/${PHP_VER}/mods-available/ioncube.ini /etc/php/${PHP_VER}/apache2/conf.d/00-ioncube.ini
			ln -sf /etc/php/${PHP_VER}/mods-available/ioncube.ini /etc/php/${PHP_VER}/cli/conf.d/00-ioncube.ini
			log "ionCube Loader installed successfully"
		else
			warn "ionCube Loader file not found, FreePBX commercial modules may not work"
		fi
	else
		warn "Failed to download ionCube Loader"
	fi

	cd /
	rm -rf "$IONCUBE_DIR"
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

	local release_json
	release_json=$(curl -s "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/releases/latest")
	LATEST_URL=$(echo "$release_json" | jq -r '.assets[] | select((.name | contains("asterisk")) and (.name | endswith(".tar.gz"))) | .browser_download_url' | head -n 1)
	local sha_url
	sha_url=$(echo "$release_json" | jq -r '.assets[] | select((.name | contains("asterisk")) and (.name | endswith(".sha256"))) | .browser_download_url' | head -n 1)

	if [ -z "$LATEST_URL" ]; then
		warn "Could not fetch latest release from GitHub API, using fallback URL."
		ASTERISK_ARTIFACT_URL="$FALLBACK_ARTIFACT"
		sha_url=""
	else
		log "Latest release found: $LATEST_URL"
		ASTERISK_ARTIFACT_URL="$LATEST_URL"
	fi

	# Fetch the published SHA256 (if any) so we can verify integrity BEFORE
	# extracting attacker-influenceable content as root. If the release has no
	# checksum asset (older releases) we fall back to a gzip-validity check.
	local expected_sha=""
	if [ -n "$sha_url" ] && wget -q -O /tmp/asterisk.tar.gz.sha256 "$sha_url"; then
		expected_sha=$(awk '{print $1}' /tmp/asterisk.tar.gz.sha256)
	fi
	rm -f /tmp/asterisk.tar.gz.sha256
	if [ -z "$expected_sha" ]; then
		warn "No SHA256 checksum published for this release; integrity will not be verified."
	fi

	log "Downloading Asterisk artifact..."
	DOWNLOAD_SUCCESS=0
	for attempt in {1..3}; do
		if wget --show-progress -O /tmp/asterisk.tar.gz "$ASTERISK_ARTIFACT_URL"; then
			if [ -n "$expected_sha" ] && [ "$(sha256sum /tmp/asterisk.tar.gz | awk '{print $1}')" != "$expected_sha" ]; then
				warn "SHA256 checksum MISMATCH — refusing this artifact. Attempt $attempt/3"
				rm -f /tmp/asterisk.tar.gz
			elif tar -tzf /tmp/asterisk.tar.gz > /dev/null 2>&1; then
				DOWNLOAD_SUCCESS=1
				if [ -n "$expected_sha" ]; then
					log "Asterisk artifact downloaded and SHA256-verified successfully."
				else
					log "Asterisk artifact downloaded (validity-checked; no checksum available)."
				fi
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
		error "Failed to download a valid Asterisk artifact after 3 attempts."
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
	printf '[client]\npassword=%s\n' "$DB_ROOT_PASS" > /root/.my.cnf
	chmod 600 /root/.my.cnf
	log "MariaDB root password saved to /root/.my.cnf (root-only)"
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

	# vhost config
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

	# hide apache version
	sed -i 's/^ServerTokens .*/ServerTokens Prod/' /etc/apache2/conf-available/security.conf 2>/dev/null || true
	sed -i 's/^ServerSignature .*/ServerSignature Off/' /etc/apache2/conf-available/security.conf 2>/dev/null || true
	a2enconf security 2>/dev/null || true

	cp "${FILES_DIR}/index.php" /var/www/html/index.php

	# webroot ownership
	chown -R asterisk:asterisk /var/www/html

	# php session dir
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
			log "DNS resolution is working correctly"
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

	# clean up if re-running
	rm -f freepbx-17.0-latest.tgz 2>/dev/null || true
	rm -rf freepbx 2>/dev/null || true

	log "Downloading FreePBX 17 tarball..."
	if ! wget --retry-connrefused --waitretry=1 --read-timeout=20 --timeout=15 -t 3 http://mirror.freepbx.org/modules/packages/freepbx/freepbx-17.0-latest.tgz; then
		error "Failed to download FreePBX tarball from mirror.freepbx.org"
	fi
	log "FreePBX tarball downloaded successfully."

	log "Extracting FreePBX tarball..."
	tar xfz freepbx-17.0-latest.tgz
	cd freepbx
	log "FreePBX extracted and ready."

	log "Verifying MySQL connection..."
	if ! mysql -u asterisk -p"$DB_ROOT_PASS" -e "SELECT 1;" &> /dev/null; then
		error "Cannot connect to MySQL as asterisk user."
	fi

	log "Starting FreePBX core installation script in verbose mode..."
	
	set +e
	
	# run with verbose output so we can check for real errors
	./install -n -v \
		--dbuser asterisk \
		--dbpass "$DB_ROOT_PASS" \
		--webroot /var/www/html \
		--user asterisk \
		--group asterisk 2>&1 | tee /tmp/freepbx_install.log
	
	fp_exit=${PIPESTATUS[0]}
	
	set -e

	cat /tmp/freepbx_install.log >> "$LOG_FILE"

	if [ $fp_exit -ne 0 ]; then
		if grep -q "You have successfully installed FreePBX" /tmp/freepbx_install.log; then
			echo -e "${YELLOW}[WARNING] FreePBX returned error code $fp_exit, but output indicates success. Treating as false-positive and continuing.${NC}" | tee -a "$LOG_FILE"
		else
			echo -e "${RED}[ERROR] FreePBX core installation failed with code $fp_exit! Printing last 30 lines of verbose log:${NC}" | tee -a "$LOG_FILE"
			tail -n 30 /tmp/freepbx_install.log
			exit $fp_exit
		fi
	fi

	echo -e "${GREEN}[INFO] FreePBX core installation script completed.${NC}" | tee -a "$LOG_FILE"
}

install_freepbx_modules() {
	setCurrentStep "Installing FreePBX modules (this may take 10-15 minutes)..."

	if ! command -v fwconsole &> /dev/null; then
		warn "fwconsole not found, skipping module installation"
		return
	fi

	log "Fixing FreePBX permissions..."
	fwconsole chown

	log "Restarting Asterisk to load DNS libraries..."
	systemctl restart asterisk
	sleep 5

	# module list
	MODULES_LIST="asterisk-cli backup blacklist bulkhandler certman cidlookup \
		configedit contactmanager customappsreg featurecodeadmin presencestate \
		qxact_reports recordings soundlang superfecta ucp userman \
		amd announcement calendar callback callflow callforward callrecording \
		callwaiting conferences dictate directory disa donotdisturb findmefollow \
		infoservices ivr languages miscapps miscdests paging parking queueprio \
		queues ringgroups setcid timeconditions tts vmblast wakeup \
		api sms webrtc dashboard dahdiconfig \
		asterisklogfiles cdr cel phpinfo printextensions weakpasswords \
		asteriskapi arimanager fax filestore iaxsettings musiconhold pinsets \
		sipsettings ttsengines voicemail pm2"

	log "Starting bulk module installation..."
	if fwconsole ma downloadinstall $MODULES_LIST >> "$LOG_FILE" 2>&1; then
		log "Modules installed successfully."
	else
		warn "fwconsole ma downloadinstall returned non-zero. Some modules may have failed or already exist."
	fi

	log "Upgrading all modules (framework, core, etc.) to ensure dependencies are met..."
	fwconsole ma upgradeall >> "$LOG_FILE" 2>&1 || true

	# remove firewall module (causes network lockouts)
	log "Removing problematic firewall module..."
	fwconsole ma remove firewall &>/dev/null || true

	# DAHDI stub configs - needed by dahdiconfig module on systems without hardware
	log "Creating DAHDI stub config files..."
	mkdir -p /etc/dahdi
	[ -f /etc/dahdi/modules ]     || echo "# configure if telephony hardware is installed" > /etc/dahdi/modules
	[ -f /etc/dahdi/system.conf ] || echo "# configure if telephony hardware is installed" > /etc/dahdi/system.conf
	[ -f /etc/modprobe.d/dahdi.conf ] || echo "# configure if telephony hardware is installed" > /etc/modprobe.d/dahdi.conf
	chown -R asterisk:asterisk /etc/dahdi
	chown asterisk:asterisk /etc/modprobe.d/dahdi.conf 2>/dev/null || true

	log "Module installation phase finished."

	# fix permissions after module install - install.php runs as root and can leave files owned by root
	log "Fixing permissions after module installation..."
	fwconsole chown
	# fwconsole chown can miss some files, force it
	chown -R asterisk:asterisk /etc/asterisk /var/www/html /var/lib/asterisk /var/spool/asterisk /var/log/asterisk

	log "Updating Sangoma GPG keys to prevent dashboard warnings..."
	fwconsole util updategpgkey >> "$LOG_FILE" 2>&1 || true

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

	# Debian 12: rsyslog not installed by default, use systemd backend for sshd jail
	echo -e "[sshd]\nbackend = systemd" > /etc/fail2ban/jail.d/sshd.local

	# log files must exist before fail2ban starts
	touch /var/log/asterisk/full /var/log/asterisk/messages
	chown asterisk:asterisk /var/log/asterisk/full /var/log/asterisk/messages

	systemctl enable fail2ban
	systemctl restart fail2ban
	sleep 2

	if systemctl is-active --quiet fail2ban; then
		JAILS_ACTIVE=$(fail2ban-client status 2>/dev/null | grep "Jail list" | grep -o "asterisk" | wc -l)
		if [ "$JAILS_ACTIVE" -ge 1 ]; then
			log "Fail2ban is active and protecting Asterisk (${JAILS_ACTIVE} jails)"
		else
			warn "Fail2ban is running but jails may not be active yet."
		fi
	else
		warn "Fail2ban failed to start."
	fi
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

install_updater_script() {
	setCurrentStep "Installing Asterisk update script..."
	if wget -q "${REPO_RAW}/update_asterisk.sh" -O /usr/local/bin/update_asterisk.sh; then
		chmod +x /usr/local/bin/update_asterisk.sh
	else
		warn "Failed to download update_asterisk.sh"
	fi
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
			log "✓ Service $service is active"
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

print_install_summary() {
	local asterisk_ver freepbx_ver php_ver mariadb_ver ip_addr
	asterisk_ver=$(asterisk -rx "core show version" 2>/dev/null | grep -oP 'Asterisk \K[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
	freepbx_ver=$(fwconsole --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || echo "unknown")
	php_ver=$(php -r 'echo PHP_VERSION;' 2>/dev/null || echo "unknown")
	mariadb_ver=$(mysql --version 2>/dev/null | grep -oP 'Distrib \K[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
	ip_addr=$(hostname -I | cut -d' ' -f1)

	echo ""
	echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
	echo -e "${GREEN}║              INSTALLATION SUMMARY                        ║${NC}"
	echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
	echo -e "${GREEN}║${NC}  Asterisk  : ${asterisk_ver}"
	echo -e "${GREEN}║${NC}  FreePBX   : ${freepbx_ver}"
	echo -e "${GREEN}║${NC}  PHP       : ${php_ver}"
	echo -e "${GREEN}║${NC}  MariaDB   : ${mariadb_ver}"
	echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
	echo -e "${GREEN}║${NC}  Access    : http://${ip_addr}/admin"
	echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
	echo ""
}

cleanup() {
	setCurrentStep "Cleaning up temporary files..."
	rm -rf "${FILES_DIR}"
	npm cache clean --force 2>/dev/null || true
	rm -rf /root/.cache 2>/dev/null || true
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
	# setup
	export PATH=$SANE_PATH
	check_root_privileges
	setup_logging
	log "Logging initialized to $LOG_FILE"

	# prevent parallel runs
	if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
		echo "Another instance of the installer is already running (PID $(cat "$PIDFILE"))."
		echo "If this is incorrect, remove $PIDFILE and try again."
		exit 1
	fi
	echo $$ > "$PIDFILE"

	# error handlers
	trap 'errorHandler "$LINENO" "$?" "$BASH_COMMAND"' ERR
	trap 'rm -f "$PIDFILE"; terminate' EXIT

	start=$(date +%s)

	clear
	echo "========================================================"
	echo "   FREEPBX 17 ARM64 INSTALLER (Asterisk 22 LTS)       "
	echo "   Version: $SCRIPTVER"
	echo "========================================================"

	# pre-flight
	check_disk_space "/" 5 "root filesystem"
	check_architecture
	check_script_version
	block_trixie_upgrade

	# install
	download_config_files
	system_upgrade
	install_dependencies
	configure_php
	install_ioncube_loader

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
	create_system_banner
	install_updater_script

	verify_installation
	cleanup

	execution_time="$(($(date +%s) - start))"
	message "Total installation time: $execution_time seconds"

	print_install_summary

	echo -e "${GREEN}========================================================${NC}"
	echo -e "${GREEN}            FREEPBX INSTALLATION COMPLETE!              ${NC}"
	echo -e "${GREEN}           Duration: ${execution_time}s (~$(( execution_time / 60 )) min)    ${NC}"
	echo -e "${GREEN}========================================================${NC}"

	exit 0
}

# Run main function
main "$@"
