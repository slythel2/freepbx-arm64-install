#!/bin/bash

# ============================================================================
# PROJECT:   FreePBX 17 ARM64 Installation Script (Asterisk 22 LTS)
# LICENSE:   Apache-2.0
# REPO:      https://github.com/slythel2/freepbx-arm64-install
# ============================================================================

set -e
SCRIPTVER="1.1.0"

# --- CONFIGURATION ---
REPO_OWNER="slythel2"
REPO_NAME="freepbx-arm64-install"
REPO_RAW="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main"
FALLBACK_ARTIFACT="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/latest/download/asterisk-22-current-arm64-debian12.tar.gz"

# files/ and the helper scripts come from next to this script, the URLs above are
# just the fallback. unset when piped through bash, so no local dir to prefer
if [ -f "${BASH_SOURCE[0]:-}" ]; then
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
	SCRIPT_DIR="/nonexistent"
fi

# coreutils only, without openssl these came out empty
DB_ROOT_PASS=$(head -c 18 /dev/urandom | base64 | tr -d '/+=')
# separate password for the freepbx db user, it ends up in /etc/freepbx.conf
DB_ASTERISK_PASS=$(head -c 18 /dev/urandom | base64 | tr -d '/+=')
LOG_FOLDER="/var/log/pbx"
LOG_FILE="${LOG_FOLDER}/freepbx17-install-$(date '+%Y.%m.%d-%H.%M.%S').log"
FILES_DIR="/tmp/pbx_installer_files"
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export UCF_FORCE_CONFFOLD=1
# wait for the lock unattended-upgrades holds, keep changed conffiles instead of a prompt nobody sees
APT_OPTS=(-o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
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
PANEL_SHOWN=false
INTERRUPTED=false
ROOT_CACHE_OURS=false

# filled in by detect_hardware
IS_RASPBERRY_PI=false
PI_MODEL=""
TOTAL_RAM_MB=0

# CLI flags (defaults)
skipversion=false
nochrony=false
pbx_hostname=""
pbx_email=""
nohttps=false

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
		--hostname)
			# a missing value must not swallow the next flag
			[[ -n "${2:-}" && "$2" != -* ]] || { echo "--hostname needs a value"; exit 1; }
			pbx_hostname="$2"
			shift 2
			;;
		--email)
			[[ -n "${2:-}" && "$2" != -* ]] || { echo "--email needs a value"; exit 1; }
			pbx_email="$2"
			shift 2
			;;
		--nohttps)
			nohttps=true
			shift
			;;
		--help|-h)
			echo "Usage: $0 [OPTIONS]"
			echo ""
			echo "Options:"
			echo "  --skipversion    Skip remote installer version check"
			echo "  --nochrony       Skip chrony NTP installation"
			echo "  --hostname FQDN  Public name, gets a Let's Encrypt certificate"
			echo "  --email ADDR     Contact for the Let's Encrypt account"
			echo "  --nohttps        Leave the admin on plain HTTP"
			echo "  --help           Show this help"
			exit 0
			;;
		-*)
			echo "Unknown option: $1"
			echo "Usage: $0 [--skipversion] [--nochrony] [--hostname FQDN] [--email ADDR] [--nohttps] [--help]"
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
	show_error_panel "$1" "$2" "$3"
	exit "$2"
}

show_error_panel() {
	local err_line="$1"
	local err_code="$2"
	local err_cmd="$3"
	PANEL_SHOWN=true

	echo ""
	echo -e "${RED}╔══════════════════════════════════════════════════════════╗${NC}"
	echo -e "${RED}║              INSTALLATION FAILED - DEBUG INFO            ║${NC}"
	echo -e "${RED}╠══════════════════════════════════════════════════════════╣${NC}"
	echo -e "${RED}║ Step:    ${NC}${currentStep}"
	[ -n "$err_line" ] && echo -e "${RED}║ Line:    ${NC}${err_line}"
	echo -e "${RED}║ Exit:    ${NC}${err_code}"
	echo -e "${RED}║ Command: ${NC}${err_cmd}"
	echo -e "${RED}╠══════════════════════════════════════════════════════════╣${NC}"
	echo -e "${RED}║ Last 40 log entries:${NC}"
	tail -n 40 "$LOG_FILE" 2>/dev/null | while IFS= read -r line; do
		echo -e "${RED}║${NC}  $line"
	done
	echo -e "${RED}╠══════════════════════════════════════════════════════════╣${NC}"
	echo -e "${RED}║ Full log: ${NC}${LOG_FILE}"
	echo -e "${RED}╚══════════════════════════════════════════════════════════╝${NC}"
	echo ""

	log "****** INSTALLATION FAILED *****"
	log "Step: ${currentStep}"
	log "Error at line: ${err_line:-unknown} exiting with code $err_code (last command was: $err_cmd)"
}

terminate() {
	local exit_code=$?
	# tee fails on a dropped ssh session, the rest must still run
	set +e
	rm -f "$PIDFILE"
	rm -rf "$FILES_DIR" /tmp/freepbx_install.??????
	if [ "$INTERRUPTED" = true ]; then
		message "Installation interrupted, the system is only partly set up. Run install.sh again."
	elif [ "$exit_code" -ne 0 ]; then
		# set -e inside a function exits without running the ERR trap
		[ "$PANEL_SHOWN" = true ] || show_error_panel "" "$exit_code" "$BASH_COMMAND"
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

	# nothing to compare against when running from a working copy
	if [ -d "${SCRIPT_DIR}/.git" ]; then
		log "Running from a git working copy, skipping the remote version check."
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
		# padded to the box width, whatever the length of the versions
		printf "${YELLOW}║%-58s║${NC}\n" \
			"  A newer version ($latest_ver) is available on GitHub." \
			"  You are running version $SCRIPTVER." \
			"  Use --skipversion to bypass this check."
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
	# the asterisk build and the ioncube loader are arm64 only
	if [ "$ARCH" != "arm64" ]; then
		message "This installer supports arm64 only, this system is $ARCH."
		message "On x86_64 use Sangoma's sng_freepbx_debian_install instead."
		exit 1
	fi
	message "Architecture check passed: $ARCH"
}

check_os_version() {
	local codename
	codename=$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}") || true
	if [ "$codename" != "bookworm" ]; then
		message "FreePBX 17 needs Debian 12 (bookworm), this system is ${codename:-unknown}."
		exit 1
	fi
}

detect_hardware() {
	setCurrentStep "Detecting hardware platform..."

	TOTAL_RAM_MB=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 ))
	log "System RAM: ${TOTAL_RAM_MB}MB"

	# device-tree is the only reliable way to spot a Pi
	if [ -f /proc/device-tree/model ]; then
		PI_MODEL=$(tr -d '\0' < /proc/device-tree/model)
		if echo "$PI_MODEL" | grep -qi "raspberry pi"; then
			IS_RASPBERRY_PI=true
			message "Detected: $PI_MODEL (${TOTAL_RAM_MB}MB RAM)"
		fi
	fi

	if [ "$IS_RASPBERRY_PI" = false ]; then
		log "Not a Raspberry Pi, using standard config."
	fi

	if [ "$TOTAL_RAM_MB" -lt 1024 ]; then
		warn "Less than 1GB RAM (${TOTAL_RAM_MB}MB). FreePBX may not run reliably."
	elif [ "$TOTAL_RAM_MB" -lt 2048 ]; then
		warn "Less than 2GB RAM (${TOTAL_RAM_MB}MB). Expect slow module installs."
	fi
}

setup_zram() {
	if ! dpkg -s zram-tools > /dev/null 2>&1; then
		log "Installing zram-tools..."
		apt-get "${APT_OPTS[@]}" install -y zram-tools >> "$LOG_FILE" 2>&1 < /dev/null || return 1
	fi

	# zstd needs kernel support, check before asking for it
	local algo="lz4"
	modprobe zram > /dev/null 2>&1 || true
	if grep -qw zstd /sys/block/zram0/comp_algorithm 2>/dev/null; then
		algo="zstd"
	fi

	# priority above any disk swap, so the card is only used once zram is full
	cat > /etc/default/zramswap <<EOF
ALGO=${algo}
PERCENT=100
PRIORITY=100
EOF

	systemctl enable zramswap >> "$LOG_FILE" 2>&1 || true
	systemctl restart zramswap >> "$LOG_FILE" 2>&1 || return 1

	# only report success if it actually came up
	if swapon --show=NAME --noheadings 2>/dev/null | grep -q '/dev/zram'; then
		message "zram active: ${algo}, $(swapon --show=NAME,SIZE --noheadings | awk '/zram/ {print $2}')"
		return 0
	fi
	return 1
}

configure_swap() {
	setCurrentStep "Configuring swap space..."

	# 1GB under 2GB of RAM, 2GB under 4GB, nothing above
	local swap_size_mb=0
	if [ "$TOTAL_RAM_MB" -le 2048 ]; then
		swap_size_mb=1024
	elif [ "$TOTAL_RAM_MB" -le 4096 ]; then
		swap_size_mb=2048
	else
		log "System has ${TOTAL_RAM_MB}MB RAM, swap not needed."
		return
	fi

	# swap on an SD card kills it, small random writes forever
	local root_src="" on_flash=false
	root_src=$(findmnt -no SOURCE / 2>/dev/null || true)
	case "$root_src" in
		/dev/mmcblk*) on_flash=true ;;
	esac
	[ "$IS_RASPBERRY_PI" = true ] && on_flash=true

	if [ "$on_flash" = true ]; then
		message "Using zram for swap rather than writing to ${root_src:-the root device}."
		if setup_zram; then
			# swapping to RAM is cheap, use it. opposite of the disk case below
			printf 'vm.swappiness=100\nvm.page-cluster=0\n' > /etc/sysctl.d/99-swap.conf
			sysctl -q -p /etc/sysctl.d/99-swap.conf >> "$LOG_FILE" 2>&1 || true
			# any disk swap stays at its lower priority as the OOM backstop
			log "zram configured, swappiness=100, page-cluster=0, disk swap left as backstop"
			return
		fi
		warn "zram setup failed, falling back to a swap file on the card."
	fi

	# existing swap means someone already decided, could be a partition
	local current_swap_kb
	current_swap_kb=$(awk '/SwapTotal/ {print $2}' /proc/meminfo)
	if [ "$current_swap_kb" -ge 524288 ]; then
		log "Swap already configured (${current_swap_kb}KB), leaving it alone."
		return
	fi

	# swap size plus 1GB headroom
	local avail_kb
	avail_kb=$(df -k / | awk 'NR==2 {print $4}')
	if [ "$avail_kb" -lt $(( swap_size_mb * 1024 + 1048576 )) ]; then
		warn "Not enough disk space for ${swap_size_mb}MB of swap. Skipping."
		return
	fi

	if [ -f /etc/dphys-swapfile ]; then
		# pi os manages swap with dphys, adding our own would give it two
		message "dphys-swapfile present, resizing it to ${swap_size_mb}MB..."
		if grep -qE '^#?CONF_SWAPSIZE=' /etc/dphys-swapfile; then
			sed -i -E "s/^#?CONF_SWAPSIZE=.*/CONF_SWAPSIZE=${swap_size_mb}/" /etc/dphys-swapfile
		else
			echo "CONF_SWAPSIZE=${swap_size_mb}" >> /etc/dphys-swapfile
		fi
		# maxswap caps the above, defaults to 2048
		if grep -qE '^#?CONF_MAXSWAP=' /etc/dphys-swapfile; then
			sed -i -E "s/^#?CONF_MAXSWAP=.*/CONF_MAXSWAP=${swap_size_mb}/" /etc/dphys-swapfile
		else
			echo "CONF_MAXSWAP=${swap_size_mb}" >> /etc/dphys-swapfile
		fi
		dphys-swapfile swapoff >> "$LOG_FILE" 2>&1 || true
		dphys-swapfile setup   >> "$LOG_FILE" 2>&1 || warn "dphys-swapfile setup failed"
		dphys-swapfile swapon  >> "$LOG_FILE" 2>&1 || warn "dphys-swapfile swapon failed"
	else
		message "Creating ${swap_size_mb}MB swap file (system has ${TOTAL_RAM_MB}MB RAM)..."
		swapoff /swapfile 2>/dev/null || true
		rm -f /swapfile
		dd if=/dev/zero of=/swapfile bs=1M count="$swap_size_mb" status=progress 2>>"$LOG_FILE"
		chmod 600 /swapfile
		mkswap /swapfile >> "$LOG_FILE" 2>&1
		swapon /swapfile
		grep -qE '^[[:space:]]*/swapfile[[:space:]]' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
	fi

	# low swappiness on disk, only under real pressure
	echo 'vm.swappiness=10' > /etc/sysctl.d/99-swap.conf
	sysctl -q vm.swappiness=10

	log "Swap configured: ${swap_size_mb}MB on disk, swappiness=10"
}

setup_logging() {
	mkdir -p "${LOG_FOLDER}"
	touch "${LOG_FILE}"
	# freepbx's install prints the manager password
	chmod 600 "${LOG_FILE}"
	exec 2>>"${LOG_FILE}"
}

download_config_files() {
	setCurrentStep "Loading configuration files..."
	mkdir -p "$FILES_DIR"

	# local files/ wins over the network
	local LOCAL_FILES_DIR="${SCRIPT_DIR}/files"

	local config_files=(
		"asterisk.conf" "asterisk.service" "freepbx.service"
		"mariadb-tmpfiles.conf" "99-freepbx.cnf"
		"asterisk-jail.local" "99-pbx-status"
		"odbcinst.ini.tpl" "odbc.ini.tpl" "sysctl-asterisk.conf"
		"dbus-fix.conf" "freepbx-modules.list" "asterisk.logrotate"
		"asterisk-tmpfiles.conf"
	)

	for f in "${config_files[@]}"; do
		if [ -f "${LOCAL_FILES_DIR}/${f}" ]; then
			cp "${LOCAL_FILES_DIR}/${f}" "${FILES_DIR}/${f}"
			log "Loaded ${f} from local files/"
		elif wget -q "${REPO_RAW}/files/${f}" -O "${FILES_DIR}/${f}"; then
			log "Downloaded ${f} from GitHub"
		else
			# wget leaves an empty file behind
			rm -f "${FILES_DIR}/${f}"
			error "Failed to get config file: ${f}"
		fi
	done
	log "All configuration files loaded."
}

system_upgrade() {
	setCurrentStep "Making sure installation is sane"
	# after a killed dpkg apt refuses everything until this runs
	# numbered entries only, a stray tmp.i is not an interrupted install
	if [ -n "$(ls /var/lib/dpkg/updates 2>/dev/null | grep '^[0-9]')$(dpkg --audit 2>/dev/null)" ]; then
		message "Finishing a package install that was interrupted, this can take a while..."
	fi
	dpkg --force-confdef --force-confold --configure -a >> "$LOG_FILE" 2>&1 < /dev/null \
		|| warn "dpkg --configure -a exited $?, apt will try again and waits if another apt is running."
	apt-get "${APT_OPTS[@]}" -y --fix-broken install >> "$LOG_FILE" < /dev/null
	apt-get "${APT_OPTS[@]}" autoremove -y >> "$LOG_FILE" < /dev/null

	if grep -q "^deb cdrom" /etc/apt/sources.list 2>/dev/null; then
		sed -i '/^deb cdrom/s/^/#/' /etc/apt/sources.list
		message "Commented out CD-ROM repository in sources.list"
	fi

	setCurrentStep "System upgrade and core dependencies..."
	# the lock timeout does not cover the lists lock apt-daily holds
	for i in 1 2 3 4 5 6; do
		apt-get "${APT_OPTS[@]}" update >> "$LOG_FILE" 2>&1 < /dev/null && break
		[ "$i" -lt 6 ] || error "apt-get update failed, see $LOG_FILE"
		message "apt-get update failed, another apt may be running, retrying in 10s..."
		sleep 10
	done
	# upgrade can fail, catch and fix
	if ! apt-get "${APT_OPTS[@]}" upgrade -y >> "$LOG_FILE" 2>&1 < /dev/null; then
		warn "apt-get upgrade had errors, attempting fix..."
		dpkg --force-confdef --force-confold --configure -a >> "$LOG_FILE" 2>&1 < /dev/null || true
		apt-get "${APT_OPTS[@]}" -y --fix-broken install >> "$LOG_FILE" 2>&1 < /dev/null || true
	fi
}

# major.minor of the installed php, 8.2 (bookworm's) until php is there
php_version() {
	php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "8.2"
}

install_dependencies() {
	setCurrentStep "Installing required packages"

	# pre-configure postfix
	debconf-set-selections <<< "postfix postfix/mailname string $(hostname -f)"
	debconf-set-selections <<< "postfix postfix/main_mailer_type select Internet Site"

	apt-get "${APT_OPTS[@]}" install -y \
		git curl wget vim htop subversion sox pkg-config g++ make sngrep \
		jq acl dnsutils bind9-dnsutils bind9-host \
		apache2 mariadb-server mariadb-client odbc-mariadb \
		php php-cli php-common php-curl php-gd php-mbstring \
		php-mysql php-soap php-xml php-intl php-zip php-bcmath \
		php-ldap php-pear libapache2-mod-php \
		libxml2 libsqlite3-0 libjansson4 libedit2 libxslt1.1 \
		libopus0 libvorbis0a libvorbisenc2 libvorbisfile3 libspeex1 libspeexdsp1 libgsm1 libspandsp2 \
		unixodbc unixodbc-dev odbcinst libltdl7 libicu-dev \
		libsrtp2-1 libportaudio2 liburiparser1 liblua5.4-0 nodejs npm fail2ban python3-systemd nftables \
		ffmpeg lame mpg123 postfix logrotate < /dev/null

	# chrony for NTP
	if [ "$nochrony" = false ]; then
		log "Installing chrony for NTP time synchronization..."
		apt-get "${APT_OPTS[@]}" install -y chrony >> "$LOG_FILE" 2>&1 < /dev/null || warn "Failed to install chrony."
	else
		log "Skipping chrony installation (--nochrony flag set)."
	fi

	# fallback: versioned php packages if generic ones didn't create the apache sapi
	PHP_VER=$(php_version)
	if [ ! -f "/etc/php/${PHP_VER}/apache2/php.ini" ]; then
		message "PHP ${PHP_VER} apache2 SAPI not found, installing version-specific packages..."
		apt-get "${APT_OPTS[@]}" install -y "php${PHP_VER}-cli" "php${PHP_VER}-common" "php${PHP_VER}-curl" \
			"php${PHP_VER}-gd" "php${PHP_VER}-mbstring" "php${PHP_VER}-mysql" \
			"php${PHP_VER}-soap" "php${PHP_VER}-xml" "php${PHP_VER}-intl" \
			"php${PHP_VER}-zip" "php${PHP_VER}-bcmath" "php${PHP_VER}-ldap" \
			"libapache2-mod-php${PHP_VER}" >> "$LOG_FILE" 2>&1 < /dev/null || true
	fi
}

# ============================================================================
# PHP CONFIGURATION
# ============================================================================

configure_php() {
	setCurrentStep "Configuring PHP settings"

	# detect php version
	PHP_VER=$(php_version)
	message "Detected PHP version: ${PHP_VER}"

	# only the apache limit scales down, it applies per worker. cli stays at 512M
	# because fwconsole module installs need the room
	local web_memory_limit="512M"
	local opcache_memory=128
	if [ "$TOTAL_RAM_MB" -le 2048 ]; then
		web_memory_limit="128M"
		opcache_memory=64
		message "Low-RAM mode: apache2 memory_limit=${web_memory_limit}, opcache=${opcache_memory}MB"
	elif [ "$TOTAL_RAM_MB" -le 4096 ]; then
		web_memory_limit="256M"
		opcache_memory=96
	fi

	for INI in /etc/php/${PHP_VER}/apache2/php.ini /etc/php/${PHP_VER}/cli/php.ini; do
		if [ -f "$INI" ]; then
			# performance
			case "$INI" in
				*/apache2/*) sed -i "s/^memory_limit = .*/memory_limit = ${web_memory_limit}/" "$INI" ;;
				*)           sed -i 's/^memory_limit = .*/memory_limit = 512M/' "$INI" ;;
			esac
			sed -i 's/^upload_max_filesize = .*/upload_max_filesize = 120M/' "$INI"
			sed -i 's/^post_max_size = .*/post_max_size = 120M/' "$INI"
			sed -i 's/^;date.timezone =.*/date.timezone = UTC/' "$INI"
			# opcache settings
			sed -i 's/^;opcache.enable=.*/opcache.enable=1/' "$INI"
			sed -i "s/^;opcache.memory_consumption=.*/opcache.memory_consumption=${opcache_memory}/" "$INI"
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

		PHP_VER=$(php_version)
		# ensure php dirs exist
		mkdir -p "/etc/php/${PHP_VER}/mods-available"
		mkdir -p "/etc/php/${PHP_VER}/apache2/conf.d"
		mkdir -p "/etc/php/${PHP_VER}/cli/conf.d"
		if [ -f "ioncube/ioncube_loader_lin_${PHP_VER}.so" ]; then
			# new inode, overwriting the mapped .so on a re-run crashed apache and php
			install -m 644 "ioncube/ioncube_loader_lin_${PHP_VER}.so" "$PHP_EXT_DIR/.ioncube.new"
			mv -f "$PHP_EXT_DIR/.ioncube.new" "$PHP_EXT_DIR/ioncube_loader_lin_${PHP_VER}.so"
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
# NETWORK & ASTERISK USER
# ============================================================================

configure_networkmanager() {
	setCurrentStep "Configuring NetworkManager..."
	# no-op on cloud images, they use systemd-networkd
	if systemctl list-unit-files NetworkManager.service 2>/dev/null | grep -q NetworkManager; then
		log "NetworkManager found, applying dbus-fix override"
		mkdir -p /etc/systemd/system/NetworkManager.service.d
		cp "${FILES_DIR}/dbus-fix.conf" /etc/systemd/system/NetworkManager.service.d/dbus-fix.conf
		systemctl daemon-reload
		log "override installed at /etc/systemd/system/NetworkManager.service.d/dbus-fix.conf"
	else
		log "NetworkManager not installed, skipping dbus-fix"
	fi
}

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
	# a curl that fails must still reach the fallback url below
	release_json=$(curl -s --max-time 30 "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/releases/latest") || release_json=""
	LATEST_URL=$(echo "$release_json" | jq -r '.assets[] | select((.name | contains("asterisk")) and (.name | endswith(".tar.gz"))) | .browser_download_url' | head -n 1)
	local sha_url
	sha_url=$(echo "$release_json" | jq -r '.assets[] | select((.name | contains("asterisk")) and (.name | endswith(".sha256"))) | .browser_download_url' | head -n 1)

	if [ -z "$LATEST_URL" ]; then
		warn "Could not fetch latest release from GitHub API, using fallback URL."
		ASTERISK_ARTIFACT_URL="$FALLBACK_ARTIFACT"
		# the release ships the checksum next to the tarball, latest/download finds it too
		sha_url="${FALLBACK_ARTIFACT}.sha256"
	else
		log "Latest release found: $LATEST_URL"
		ASTERISK_ARTIFACT_URL="$LATEST_URL"
	fi

	# checksum before extracting as root, gzip check when the release has none
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
				warn "SHA256 checksum MISMATCH, refusing this artifact. Attempt $attempt/3"
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

	# keep-directory-symlink, or the tarball's var/run/ replaces the /var/run symlink with a directory
	tar -xzf /tmp/asterisk.tar.gz -C / --keep-directory-symlink --exclude='*etc/asterisk*'
	# configs only where missing so a re-run keeps freepbx's, and no sample voicemail.conf with demo boxes
	tar -xzf /tmp/asterisk.tar.gz -C / --keep-directory-symlink --skip-old-files --wildcards '*etc/asterisk/*' \
		--exclude='*etc/asterisk/voicemail.conf' --exclude='*etc/asterisk/extensions.lua'
	# the sample extensions.lua is a demo dialplan that pbx_lua loads next to freepbx's, also on older installs
	if [ ! -f /etc/asterisk/extensions.lua ] || tar -xzOf /tmp/asterisk.tar.gz --wildcards '*etc/asterisk/extensions.lua' 2>/dev/null \
		| cmp -s - /etc/asterisk/extensions.lua; then
		printf -- '-- freepbx writes the dialplan in extensions.conf, no lua contexts\nextensions = {}\nhints = {}\n' > /etc/asterisk/extensions.lua
	fi
	rm /tmp/asterisk.tar.gz

	# /var/run/asterisk is on a tmpfs, it has to come back at every boot
	cp "${FILES_DIR}/asterisk-tmpfiles.conf" /etc/tmpfiles.d/asterisk.conf
	systemd-tmpfiles --create /etc/tmpfiles.d/asterisk.conf
	[ -L /var/run ] || warn "/var/run is a directory, not a link to /run. See check_install.sh"

	mkdir -p /var/run/asterisk /var/log/asterisk /var/lib/asterisk /var/spool/asterisk /etc/asterisk /usr/lib/asterisk/modules
	chown -R asterisk:asterisk /var/run/asterisk /var/log/asterisk /var/lib/asterisk /var/spool/asterisk /etc/asterisk
	ldconfig

	cp "${FILES_DIR}/asterisk.conf" /etc/asterisk/asterisk.conf
	chown asterisk:asterisk /etc/asterisk/asterisk.conf
}

configure_asterisk_service() {
	setCurrentStep "Configuring Asterisk systemd service"

	cp "${FILES_DIR}/asterisk.service" /etc/systemd/system/asterisk.service

	# FreePBX needs its own service to start PM2 processes on boot
	cp "${FILES_DIR}/freepbx.service" /etc/systemd/system/freepbx.service

	systemctl daemon-reload
	systemctl enable asterisk mariadb apache2 freepbx
}

apply_production_tuning() {
	setCurrentStep "Applying production performance tuning..."

	# Sysctl tuning
	cp "${FILES_DIR}/sysctl-asterisk.conf" /etc/sysctl.d/99-asterisk.conf

	# 16MB buffers are too much for a 1GB board. into the file, not sysctl -w,
	# which would be lost at the next reboot
	if [ "$TOTAL_RAM_MB" -le 2048 ]; then
		log "Trimming network buffers for a ${TOTAL_RAM_MB}MB box"
		sed -i -E 's/^net\.core\.(r|w)mem_max = .*/net.core.\1mem_max = 4194304/' /etc/sysctl.d/99-asterisk.conf
	fi

	sysctl --system >> "$LOG_FILE" 2>&1 || warn "Some sysctl settings could not be applied"

	# Asterisk limits (also set in systemd, belt-and-suspenders)
	# no core here, pm2 gets it through pam and php dumped into the webroot
	cat > /etc/security/limits.d/asterisk.conf <<'EOF'
asterisk soft nofile 65536
asterisk hard nofile 65536
asterisk soft nproc  8192
asterisk hard nproc  8192
EOF

	log "Production tuning applied."
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

	# debian's socket unit binds 3306 on every address at boot, bind-address is ignored
	systemctl disable --now mariadb.socket >> "$LOG_FILE" 2>&1 || true
	systemctl restart mariadb

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

	# a re-run keeps the password freepbx already has, or its ./install cannot log in
	local existing
	existing=$(grep -oP "AMPDBPASS'\]\s*=\s*'\K[^']+" /etc/freepbx.conf 2>/dev/null || true)
	if [ -n "$existing" ]; then
		DB_ASTERISK_PASS="$existing"
		log "FreePBX is already installed, keeping its database password."
	fi

	# root authenticates via /root/.my.cnf (written in setup_mariadb), so the
	# password is never placed on the command line where local users could read
	# it from `ps`/ /proc/<pid>/cmdline. the asterisk one goes in on stdin for
	# the same reason
	mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS asterisk;
CREATE DATABASE IF NOT EXISTS asteriskcdrdb;
GRANT ALL PRIVILEGES ON asterisk.* TO 'asterisk'@'localhost' IDENTIFIED BY '$DB_ASTERISK_PASS';
GRANT ALL PRIVILEGES ON asterisk.* TO 'asterisk'@'127.0.0.1' IDENTIFIED BY '$DB_ASTERISK_PASS';
GRANT ALL PRIVILEGES ON asteriskcdrdb.* TO 'asterisk'@'localhost';
GRANT ALL PRIVILEGES ON asteriskcdrdb.* TO 'asterisk'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL

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
        Options -Indexes +FollowSymLinks
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

	# no index.php of our own, freepbx signs its copy and a re-run would flag it as tampered

	# webroot ownership
	chown -R asterisk:asterisk /var/www/html

	# php session dir
	SESSION_DIR="/var/lib/php/sessions"
	mkdir -p "$SESSION_DIR"
	chown asterisk:asterisk "$SESSION_DIR"
	chmod 1733 "$SESSION_DIR"

	systemctl restart apache2
}

# ============================================================================
# ASTERISK STARTUP & VERIFICATION
# ============================================================================

# the cli answers before the modules are loaded, fwconsole needs them loaded
wait_for_asterisk() {
	local i
	for i in $(seq 1 "$1"); do
		timeout 30 asterisk -rx "core waitfullybooted" > /dev/null 2>&1 && return 0
		sleep 2
	done
	return 1
}

start_asterisk() {
	setCurrentStep "Starting Asterisk and waiting for readiness..."
	# on a re-run freepbx.service restarts with asterisk and its chown races the module step
	systemctl stop freepbx 2>/dev/null || true
	systemctl restart asterisk

	if ! wait_for_asterisk 60; then
		error "Asterisk did not finish booting. Check journalctl -u asterisk"
	fi
	log "Asterisk is fully booted."
}

verify_dns() {
	setCurrentStep "Verifying DNS resolution for SIP trunks..."
	if command -v dig &> /dev/null; then
		# dig prints its errors on stdout, so only an address counts
		if dig "google.com" +short 2>/dev/null | grep -qE '^[0-9.]+$'; then
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

	# on a re-run ./install puts the tarball's older framework and modules over the upgraded ones.
	# core too, not framework alone: ./install registers framework first, so an install interrupted
	# right after it would be skipped while still missing core, which is not in our module list
	local installed
	installed=$(mysql -N asterisk -e "SELECT COUNT(*) FROM modules WHERE modulename IN ('framework','core') AND enabled=1" 2>/dev/null || echo 0)
	if [ -f /etc/freepbx.conf ] && [ "$installed" = 2 ]; then
		log "FreePBX is already installed, skipping its core install. The module step brings it up to date."
		fwconsole setting ASTMANAGERHOST 127.0.0.1 >> "$LOG_FILE" 2>&1 || true
		return
	fi

	# a stopped ./install leaves settings the next one keeps, the ami user among them, and then
	# manager.conf gets a new one: freepbx and asterisk never talk. no core, no config to lose
	local core=0 tables has_modules dump
	tables=$(mysql -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='asterisk'" 2>/dev/null || echo 0)
	has_modules=$(mysql -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='asterisk' AND table_name='modules'" 2>/dev/null || echo 0)
	if [ "$has_modules" = 1 ]; then
		# a table that cannot be read is not an empty one
		core=$(mysql -N asterisk -e "SELECT COUNT(*) FROM modules WHERE modulename='core'" 2>> "$LOG_FILE") \
			|| error "Cannot read the FreePBX modules table, leaving the database alone. Check it with: mysqlcheck asterisk"
	fi
	if [ "$core" = 0 ] && [ "${tables:-0}" -gt 0 ]; then
		message "A previous FreePBX install stopped half way, clearing what it left so this one starts clean..."
		dump="/var/backups/asterisk-db-$(date +%Y%m%d_%H%M%S).sql.gz"
		(umask 077; set -o pipefail; mysqldump --single-transaction asterisk 2>> "$LOG_FILE" | gzip > "$dump") \
			|| error "Could not save the old database to $dump, leaving it alone."
		log "The old database is saved in $dump"
		mysql -e "DROP DATABASE asterisk; CREATE DATABASE asterisk;" >> "$LOG_FILE" 2>&1 \
			|| error "Could not clear the half installed FreePBX database."
		rm -f /etc/freepbx.conf /etc/amportal.conf
	fi

	cd /usr/src

	# clean up if re-running
	rm -f freepbx-17.0-latest.tgz 2>/dev/null || true
	rm -rf freepbx 2>/dev/null || true

	log "Downloading FreePBX 17 tarball..."
	if ! wget --retry-connrefused --waitretry=1 --read-timeout=20 --timeout=15 -t 3 https://mirror.freepbx.org/modules/packages/freepbx/freepbx-17.0-latest.tgz; then
		error "Failed to download FreePBX tarball from mirror.freepbx.org"
	fi
	log "FreePBX tarball downloaded successfully."

	log "Extracting FreePBX tarball..."
	tar xfz freepbx-17.0-latest.tgz
	cd freepbx
	log "FreePBX extracted and ready."

	# the 180s per-step timeout is not enough on an SD card
	log "Patching FreePBX installer timeout..."
	sed -i 's/setTimeout($timeout)/setTimeout(3600)/g' installlib/installcommand.class.php 2>/dev/null || true

	log "Verifying MySQL connection..."
	# the environment, unlike the arguments, is readable by root and the owner only
	# a defaults file, not MYSQL_PWD: root's /root/.my.cnf wins over the variable and logs asterisk in with root's password
	if ! mysql --defaults-file=<(printf '[client]\nuser=asterisk\npassword=%s\n' "$DB_ASTERISK_PASS") -e "SELECT 1;" &> /dev/null; then
		error "Cannot connect to MySQL as asterisk user."
	fi

	log "Starting FreePBX core installation script in verbose mode..."

	# it prints the manager password, mktemp makes it 600
	local fp_log
	fp_log=$(mktemp /tmp/freepbx_install.XXXXXX)

	set +e

	# verbose to catch real errors. 127.0.0.1 because node resolves localhost to ::1, mariadb is ipv4 only
	./install -n -v \
		--dbhost 127.0.0.1 \
		--dbuser asterisk \
		--dbpass "$DB_ASTERISK_PASS" \
		--webroot /var/www/html \
		--user asterisk \
		--group asterisk 2>&1 | tee "$fp_log"

	fp_exit=${PIPESTATUS[0]}

	set -e

	cat "$fp_log" >> "$LOG_FILE"

	if [ $fp_exit -ne 0 ]; then
		if grep -q "You have successfully installed FreePBX" "$fp_log"; then
			echo -e "${YELLOW}[WARNING] FreePBX returned error code $fp_exit, but output indicates success. Treating as false-positive and continuing.${NC}" | tee -a "$LOG_FILE"
		else
			echo -e "${RED}[ERROR] FreePBX core installation failed with code $fp_exit! Printing last 30 lines of verbose log:${NC}" | tee -a "$LOG_FILE"
			tail -n 30 "$fp_log"
			exit $fp_exit
		fi
	fi

	# the copy in the log is enough
	rm -f "$fp_log"

	echo -e "${GREEN}[INFO] FreePBX core installation script completed.${NC}" | tee -a "$LOG_FILE"

	# the manager is ipv4 only too, and ucp connects to it from node
	fwconsole setting ASTMANAGERHOST 127.0.0.1 >> "$LOG_FILE" 2>&1 \
		|| warn "Could not set ASTMANAGERHOST, ucp will not reach the Asterisk manager"
}

# listed modules not enabled. from the database, fwconsole prints status in the gui language
missing_modules() {
	local enabled m
	enabled=" $(mysql -N asterisk -e "SELECT modulename FROM modules WHERE enabled=1" 2>/dev/null | xargs) "
	for m in $MODULES_LIST; do
		[[ "$enabled" == *" $m "* ]] || echo "$m"
	done
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
	# the framework dies on the engine check while asterisk is still booting
	wait_for_asterisk 60 || warn "Asterisk is not fully booted, module installs may fail."

	MODULES_LIST=$(grep -v '^[[:space:]]*#' "${FILES_DIR}/freepbx-modules.list" | xargs)

	# a module disabled in Module Admin stays disabled, fwconsole would stop and ask about each one
	local disabled wanted="" left="" m
	disabled=" $(mysql -N asterisk -e "SELECT modulename FROM modules WHERE enabled=0" 2>/dev/null | xargs) "
	for m in $MODULES_LIST; do
		if [[ "$disabled" == *" $m "* ]]; then left+=" $m"; else wanted+=" $m"; fi
	done
	MODULES_LIST=$wanted
	[ -z "$left" ] || message "Disabled in Module Admin, left as they are:$left"

	# stdin from /dev/null on every fwconsole ma here: its questions go to the log, nobody would see them
	log "Starting bulk module installation..."
	# it stops at the first module that fails, the rest is picked up below
	fwconsole ma --skipdisabled downloadinstall $MODULES_LIST < /dev/null >> "$LOG_FILE" 2>&1 \
		|| log "Bulk install stopped early, the missing modules are retried one by one."

	log "Upgrading all modules (framework, core, etc.) to ensure dependencies are met..."
	fwconsole ma --skipdisabled upgradeall < /dev/null >> "$LOG_FILE" 2>&1 || true

	# second pass for modules that needed one that failed in the first
	local pass missing
	for pass in 1 2; do
		missing=$(missing_modules)
		[ -z "$missing" ] && break
		message "Installing $(echo $missing | wc -w) modules one by one (pass $pass)..."
		for m in $missing; do
			log "Installing module $m..."
			fwconsole ma --skipdisabled downloadinstall "$m" < /dev/null >> "$LOG_FILE" 2>&1 || log "Module $m failed."
		done
	done

	missing=$(missing_modules)
	if [ -n "$missing" ]; then
		warn "Not installed: $(echo $missing). Retry with: fwconsole ma downloadinstall <module>"
	else
		log "All $(echo $MODULES_LIST | wc -w) listed modules are enabled."
	fi

	# ucp only creates its ami user if manager was there first, and it does not depend on it
	if [[ "$disabled" != *" ucp "* ]] && ! mysql -N asterisk -e "SELECT name FROM manager WHERE name='ucp_events'" 2>/dev/null | grep -q .; then
		log "UCP has no Asterisk manager user yet, installing ucp again..."
		fwconsole ma --skipdisabled install ucp < /dev/null >> "$LOG_FILE" 2>&1 || true
		mysql -N asterisk -e "SELECT name FROM manager WHERE name='ucp_events'" 2>/dev/null | grep -q . \
			|| warn "UCP has no Asterisk manager user, its node server will keep restarting."
	fi

	# remove firewall module (causes network lockouts)
	log "Removing problematic firewall module..."
	fwconsole ma remove firewall &>/dev/null || true

	# no chan_dahdi in this build, sangoma only installs dahdiconfig with --dahdi. older runs installed it
	if fwconsole ma list 2>/dev/null | grep -qE '^\| *dahdiconfig '; then
		log "Removing dahdiconfig, this build has no DAHDI support..."
		fwconsole ma -f remove dahdiconfig < /dev/null >> "$LOG_FILE" 2>&1 || true
	fi
	# and the empty stubs they made for it, asterisk owning a modprobe.d file is a way to root
	local f
	for f in /etc/modprobe.d/dahdi.conf /etc/dahdi/modules /etc/dahdi/system.conf; do
		if [ -f "$f" ] && ! grep -qv '^[[:space:]]*\(#\|$\)' "$f"; then
			rm -f "$f"
		fi
	done
	rmdir /etc/dahdi 2>/dev/null || true

	log "Module installation phase finished."

	# fix permissions after module install - install.php runs as root and can leave files owned by root
	log "Fixing permissions after module installation..."
	fwconsole chown
	# fwconsole chown can miss some files, force it
	chown -R asterisk:asterisk /etc/asterisk /var/www/html /var/lib/asterisk /var/spool/asterisk /var/log/asterisk

	log "Updating Sangoma GPG keys to prevent dashboard warnings..."
	fwconsole util updategpgkey >> "$LOG_FILE" 2>&1 || true

	# the core in the freepbx tarball is old enough to be flagged vulnerable, and the
	# notification is only recomputed when the module list is fetched again
	log "Refreshing the online module list so the security notice matches what is installed..."
	fwconsole ma listonline >> "$LOG_FILE" 2>&1 || true

	set_local_nets

	log "All modules installed. Reloading FreePBX..."
	fwconsole reload || true

	# the module installs started pm2 in this script's own cgroup, hand it to systemd
	log "Handing the node apps over to freepbx.service..."
	# a re-run finds the unit already active, and then a start does nothing at all
	systemctl stop freepbx || true
	stop_pm2_daemon
	# stopping the unit stops asterisk with it, put it back before fwconsole looks for it
	systemctl start asterisk
	wait_for_asterisk 60 || warn "Asterisk did not finish booting, the FreePBX services may not have started."
	systemctl start freepbx || warn "freepbx.service did not start, check systemctl status freepbx"
}

# freepbx puts the public address in the sdp of lan phones too and they get no audio, same as the gui's detect button
set_local_nets() {
	local nets
	nets=$(ip -4 route show scope link proto kernel 2>/dev/null | awk '{print $1}' \
		| grep -E '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' | sort -u | xargs)
	[ -n "$nets" ] || return 0
	# only when empty, a re-run keeps what the admin set
	NETS="$nets" php -r '
		$bootstrap_settings["freepbx_auth"] = false;
		include "/etc/freepbx.conf";
		$s = \FreePBX::Sipsettings();
		if (!empty($s->getConfig("localnets"))) exit(0);
		$l = [];
		foreach (explode(" ", getenv("NETS")) as $n) {
			list($net, $mask) = explode("/", $n);
			$l[] = ["net" => $net, "mask" => $mask];
		}
		$s->setConfig("localnets", $l);
	' >> "$LOG_FILE" 2>&1 && log "SIP local networks, unless already set: $nets" \
		|| warn "Could not set the SIP local networks, set them in Settings, Asterisk SIP Settings"
}

# kill the pm2 daemon so the next start puts it, and the node apps, inside freepbx.service
stop_pm2_daemon() {
	local home pm2bin
	home=$(pgrep -u asterisk -af 'PM2 v' 2>/dev/null | sed -n 's/.*God Daemon (\(.*\)).*/\1/p' | head -1)
	[ -n "$home" ] || return 0
	pm2bin=$(ls /var/www/html/admin/modules/pm2/node/node_modules/pm2/bin/pm2 2>/dev/null | head -1)
	if [ -z "$pm2bin" ]; then
		warn "pm2 binary not found, the node apps keep running outside freepbx.service until a reboot"
		return 0
	fi
	runuser -u asterisk -- env PM2_HOME="$home" node "$pm2bin" kill >> "$LOG_FILE" 2>&1 || true
}

# ============================================================================
# FAIL2BAN SETUP
# ============================================================================

configure_fail2ban() {
	setCurrentStep "Configuring Fail2ban for Asterisk protection..."

	cp "${FILES_DIR}/asterisk-jail.local" /etc/fail2ban/jail.d/asterisk.local
	# the old custom filter matched no asterisk 22 line, the jail uses the stock one now
	rm -f /etc/fail2ban/filter.d/asterisk-pjsip.conf

	# jail.conf still defaults to iptables, which debian 12 does not install, so bans did nothing
	printf '[DEFAULT]\nbanaction = nftables-multiport\nbanaction_allports = nftables-allports\n' > /etc/fail2ban/jail.d/00-banaction.local

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

configure_logrotate() {
	setCurrentStep "Configuring log rotation for Asterisk and FreePBX..."
	# nothing rotated /var/log/asterisk, full grows until the disk is full
	cp "${FILES_DIR}/asterisk.logrotate" /etc/logrotate.d/asterisk
	chmod 644 /etc/logrotate.d/asterisk
	# it exits 0 on a line it ignores, its error lines tell
	local lr
	lr=$(logrotate -d /etc/logrotate.d/asterisk 2>&1) && ! grep -q '^error:' <<< "$lr" \
		|| warn "logrotate rejects /etc/logrotate.d/asterisk, run: logrotate -d /etc/logrotate.d/asterisk"
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

install_helper_scripts() {
	setCurrentStep "Installing helper scripts..."

	# same rule as the config files, local copy wins
	local f
	for f in update_asterisk.sh setup_email.sh setup_https.sh; do
		if [ -f "${SCRIPT_DIR}/${f}" ]; then
			cp "${SCRIPT_DIR}/${f}" "/usr/local/bin/${f}"
			chmod +x "/usr/local/bin/${f}"
			log "Installed ${f} from the local copy"
		elif wget -q "${REPO_RAW}/${f}" -O "/usr/local/bin/${f}.new" && [ -s "/usr/local/bin/${f}.new" ]; then
			chmod +x "/usr/local/bin/${f}.new"
			mv -f "/usr/local/bin/${f}.new" "/usr/local/bin/${f}"
			log "Downloaded ${f}"
		else
			# the copy of an earlier run stays
			rm -f "/usr/local/bin/${f}.new"
			warn "Could not install ${f}"
		fi
	done
}

# ============================================================================
# POST-INSTALLATION VALIDATION
# ============================================================================

check_services() {
	setCurrentStep "Checking services status"

	services=("asterisk" "freepbx" "mariadb" "apache2" "fail2ban")
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
	freepbx_ver=$(fwconsole --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
	[ -n "$freepbx_ver" ] || freepbx_ver="unknown"
	php_ver=$(php -r 'echo PHP_VERSION;' 2>/dev/null || echo "unknown")
	mariadb_ver=$(mysql --version 2>/dev/null | grep -oP 'Distrib \K[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
	ip_addr=$(hostname -I | cut -d' ' -f1)

	# follow whatever setup_https did, or the url here is wrong
	local scheme="http" web_host="$ip_addr" cert_note=""
	if [ -f /etc/freepbx-https.conf ]; then
		scheme="https"
		local fqdn mode
		fqdn=$(awk -F= '/^FQDN=/{print $2}' /etc/freepbx-https.conf 2>/dev/null)
		mode=$(awk -F= '/^MODE=/{print $2}' /etc/freepbx-https.conf 2>/dev/null)
		[ -n "$fqdn" ] && web_host="$fqdn"
		[ "$mode" = "selfsigned" ] && cert_note="self signed, the browser will warn"
		grep -qx 'STAGING=true' /etc/freepbx-https.conf && cert_note="Let's Encrypt staging, the browser will warn"
		# asked for a name but got self signed, say so or it looks like it worked
		[ -n "$pbx_hostname" ] && [ "$mode" = "selfsigned" ] && cert_note="self signed, Let's Encrypt failed for ${pbx_hostname}, see ${LOG_FILE}"
	fi

	echo ""
	echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
	echo -e "${GREEN}║              INSTALLATION SUMMARY                        ║${NC}"
	echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
	echo -e "${GREEN}║${NC}  Asterisk  : ${asterisk_ver}"
	echo -e "${GREEN}║${NC}  FreePBX   : ${freepbx_ver}"
	echo -e "${GREEN}║${NC}  PHP       : ${php_ver}"
	echo -e "${GREEN}║${NC}  MariaDB   : ${mariadb_ver}"
	echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
	echo -e "${GREEN}║${NC}  Access    : ${scheme}://${web_host}/admin"
	[ -n "$cert_note" ] && echo -e "${GREEN}║${NC}  Cert      : ${cert_note}"
	echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
	echo ""
}

cleanup() {
	setCurrentStep "Cleaning up temporary files..."
	rm -rf "${FILES_DIR}"
	npm cache clean --force 2>/dev/null || true
	# only a cache this run made, not one root already had
	if [ "$ROOT_CACHE_OURS" = true ]; then
		rm -rf /root/.cache 2>/dev/null || true
	fi
}

configure_https() {
	setCurrentStep "Configuring HTTPS for the admin interface..."
	local args=(--yes) mode="" fqdn=""
	if [ -f /etc/freepbx-https.conf ]; then
		mode=$(awk -F= '/^MODE=/{print $2}' /etc/freepbx-https.conf)
		fqdn=$(awk -F= '/^FQDN=/{print $2}' /etc/freepbx-https.conf)
	fi
	if [ "$nohttps" = true ]; then
		if [ "$mode" != letsencrypt ]; then
			log "--nohttps given, leaving the admin on plain HTTP."
			return
		fi
		# the http vhost was rewritten above, without its acme alias the certificate stops renewing
		log "--nohttps given, but Let's Encrypt is set up for ${fqdn}: keeping it."
	else
		[ -n "$pbx_hostname" ] && args+=(--hostname "$pbx_hostname")
		[ -n "$pbx_email" ] && args+=(--email "$pbx_email")
		# the same name again keeps a redirect that was turned off
		if [ -n "$pbx_hostname" ] && [ "${pbx_hostname,,}" = "$fqdn" ] && grep -qx 'REDIRECT=false' /etc/freepbx-https.conf 2>/dev/null; then
			args+=(--no-redirect)
		fi
	fi
	# --yes so a piped install never blocks, self signed when no hostname
	/usr/local/bin/setup_https.sh "${args[@]}" >> "$LOG_FILE" 2>&1 \
		|| warn "HTTPS setup had a problem, run setup_https.sh by hand. See $LOG_FILE"
}

prompt_email_setup() {
	# only prompt if running interactively (not piped)
	if [ ! -t 0 ]; then
		echo ""
		echo "To set up email for FreePBX, run: setup_email.sh"
		return
	fi

	echo ""
	# stderr goes to the log, prompts need the terminal
	read -rp "Would you like to set up an email account for FreePBX? [y/N]: " setup_email 2>&1
	if [[ "$setup_email" =~ ^[Yy] ]]; then
		/usr/local/bin/setup_email.sh 2>&1 || warn "Email setup had an issue. You can run 'setup_email.sh' later."
	else
		echo "You can set up email later by running: setup_email.sh"
	fi
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
	# plain refusals, before the traps so they get no debug panel
	check_architecture
	check_os_version

	# prevent parallel runs
	if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
		echo "Another instance of the installer is already running (PID $(cat "$PIDFILE"))."
		echo "If this is incorrect, remove $PIDFILE and try again."
		exit 1
	fi
	echo $$ > "$PIDFILE"

	# error handlers
	trap 'errorHandler "$LINENO" "$?" "$BASH_COMMAND"' ERR
	trap terminate EXIT
	# a killed install used to end with a plain "Exiting script"
	trap 'INTERRUPTED=true; exit 129' HUP
	trap 'INTERRUPTED=true; exit 130' INT
	trap 'INTERRUPTED=true; exit 143' TERM

	start=$(date +%s)
	[ -e /root/.cache ] || ROOT_CACHE_OURS=true

	# no TERM from cloud-init or ssh without a tty, and a failed clear ended the install
	clear 2>/dev/null || true
	echo "========================================================"
	echo "   FREEPBX 17 ARM64 INSTALLER (Asterisk 22 LTS)       "
	echo "   Version: $SCRIPTVER"
	echo "========================================================"

	# pre-flight
	check_disk_space "/" 5 "root filesystem"
	detect_hardware
	check_script_version
	block_trixie_upgrade

	# install
	download_config_files
	system_upgrade
	configure_swap
	install_dependencies
	configure_networkmanager
	configure_php
	install_ioncube_loader

	create_asterisk_user
	download_asterisk_artifact
	install_asterisk_artifact
	configure_asterisk_service
	apply_production_tuning

	setup_mariadb
	configure_database
	configure_odbc

	configure_apache

	start_asterisk
	verify_dns

	install_freepbx
	install_freepbx_modules

	configure_fail2ban
	configure_logrotate
	create_system_banner
	install_helper_scripts

	configure_https
	verify_installation
	cleanup

	execution_time="$(($(date +%s) - start))"
	message "Total installation time: $execution_time seconds"

	print_install_summary
	prompt_email_setup

	echo -e "${GREEN}========================================================${NC}"
	echo -e "${GREEN}            FREEPBX INSTALLATION COMPLETE!              ${NC}"
	echo -e "${GREEN}               Duration: ${execution_time}s (~$(( execution_time / 60 )) min)    ${NC}"
	echo -e "${GREEN}========================================================${NC}"

	exit 0
}

# Run main function
main "$@"
