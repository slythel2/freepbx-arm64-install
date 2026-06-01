#!/bin/bash

# ============================================================================
# SCRIPT:    update_asterisk.sh
# PROJECT:   FreePBX 17 ARM64 Installation Script (Asterisk 22 LTS)
# ============================================================================

set -e

# --- CONFIGURATION ---
REPO_OWNER="slythel2"
REPO_NAME="freepbx-arm64-install-test"
FALLBACK_ARTIFACT="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/1.0/asterisk-22-current-arm64-debian12-v2.tar.gz"

LOG_FOLDER="/var/log/pbx"
LOG_FILE="${LOG_FOLDER}/update_asterisk-$(date '+%Y.%m.%d-%H.%M.%S').log"
LOCK_FILE="/var/lock/asterisk_update.lock"
BACKUP_BASE="/var/backups/asterisk"
STAGE_DIR="/tmp/asterisk_update_stage"

# --- ARGUMENT PARSING ---
DRY_RUN=false
while [[ $# -gt 0 ]]; do
	case $1 in
		--dry-run)
			DRY_RUN=true
			shift
			;;
		--help|-h)
			echo "Usage: $0 [--dry-run]"
			echo ""
			echo "Options:"
			echo "  --dry-run    Check available version without downloading or stopping Asterisk"
			echo "  --help       Show this help"
			exit 0
			;;
		*)
			echo "Unknown option: $1"
			echo "Usage: $0 [--dry-run]"
			exit 1
			;;
	esac
done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Logging functions
echo_ts() { echo "$(date +"%Y-%m-%d %T") - $*"; }
log() { echo_ts "$*" >> "$LOG_FILE"; }
message() { echo_ts "$*" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[WARNING] $1${NC}" | tee -a "$LOG_FILE"; }
error() {
	echo -e "${RED}[ERROR] $1${NC}" | tee -a "$LOG_FILE"
	echo "Check log at: $LOG_FILE"
	exit 1
}

# ============================================================================
# PRE-FLIGHT CHECKS
# ============================================================================

if [[ $EUID -ne 0 ]]; then
	echo "This script must be run as root."
	exit 1
fi

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

# Acquire exclusive lock (prevent concurrent runs)
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
	echo -e "${RED}[ERROR] Another instance of update_asterisk.sh is already running.${NC}"
	exit 1
fi

mkdir -p "${LOG_FOLDER}"
touch "${LOG_FILE}"

trap 'rm -rf "$STAGE_DIR" /tmp/asterisk_update.tar.gz 2>/dev/null' INT TERM

echo -e "${GREEN}========================================================${NC}"
echo -e "${GREEN}          ASTERISK 22 UPDATER (with Rollback)           ${NC}"
echo -e "${GREEN}========================================================${NC}"

log "Starting Asterisk 22 Robust Update with Rollback Protection..."

# ============================================================================
# VERSION CHECK
# ============================================================================

message "Checking for available updates..."

if ! command -v jq &> /dev/null; then
	message "Installing jq dependency..."
	apt-get update -qq && apt-get install -y jq >> "$LOG_FILE" 2>&1
fi

# Fetch current installed version
CURRENT_VERSION="unknown"
if command -v asterisk &> /dev/null && systemctl is-active --quiet asterisk 2>/dev/null; then
	CURRENT_VERSION=$(asterisk -rx "core show version" 2>/dev/null | grep -oP 'Asterisk \K[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
fi
message "Current installed version: ${CURRENT_VERSION}"

# Fetch latest release info
RELEASE_JSON=$(curl -s "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/releases/latest")
LATEST_URL=$(echo "$RELEASE_JSON" | jq -r '.assets[] | select((.name | contains("asterisk")) and (.name | endswith(".tar.gz"))) | .browser_download_url' | head -n 1)
SHA_URL=$(echo "$RELEASE_JSON" | jq -r '.assets[] | select((.name | contains("asterisk")) and (.name | endswith(".sha256"))) | .browser_download_url' | head -n 1)
RELEASE_TAG=$(echo "$RELEASE_JSON" | jq -r '.tag_name // empty')

if [ -z "$LATEST_URL" ]; then
	warn "Could not fetch latest release, using fallback URL."
	ASTERISK_ARTIFACT_URL="$FALLBACK_ARTIFACT"
	SHA_URL=""
else
	log "Latest release found: $LATEST_URL (tag: ${RELEASE_TAG:-unknown})"
	ASTERISK_ARTIFACT_URL="$LATEST_URL"

	# Compare versions if possible
	AVAILABLE_VERSION=$(echo "$RELEASE_TAG" | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' || echo "")
	# Fallback: parse version from release body if tag doesn't contain semver
	if [ -z "$AVAILABLE_VERSION" ]; then
		AVAILABLE_VERSION=$(echo "$RELEASE_JSON" | jq -r '.body // ""' | grep -oP 'Version.*?`\K[0-9]+\.[0-9]+\.[0-9]+' || echo "")
		[ -n "$AVAILABLE_VERSION" ] && log "Parsed version from release body: $AVAILABLE_VERSION"
	fi
	if [ -n "$AVAILABLE_VERSION" ] && [ "$CURRENT_VERSION" != "unknown" ]; then
		if [ "$CURRENT_VERSION" = "$AVAILABLE_VERSION" ]; then
			echo -e "${GREEN}Asterisk is already at version ${CURRENT_VERSION}. No update needed.${NC}"
			log "No update needed: installed=$CURRENT_VERSION, available=$AVAILABLE_VERSION"
			read -p "Force update anyway? (y/N): " force_update
			if [[ "$force_update" != "y" && "$force_update" != "Y" ]]; then
				echo "Update cancelled."
				exit 0
			fi
			message "User chose to force update."
		else
			message "Update available: ${CURRENT_VERSION} -> ${AVAILABLE_VERSION}"
		fi
	fi
fi

# Dry-run: show what would be done and exit without touching the system
if [ "$DRY_RUN" = true ]; then
	echo ""
	echo -e "${GREEN}[DRY-RUN] No changes will be made to the system.${NC}"
	echo -e "${GREEN}  Current version  : ${CURRENT_VERSION}${NC}"
	echo -e "${GREEN}  Available version: ${AVAILABLE_VERSION:-unknown}${NC}"
	echo -e "${GREEN}  Artifact URL     : ${ASTERISK_ARTIFACT_URL}${NC}"
	echo -e "${GREEN}[DRY-RUN] Asterisk has NOT been stopped. Exiting.${NC}"
	exit 0
fi

# ============================================================================
# BACKUP (persistent directory, survives reboot)
# ============================================================================

check_disk_space "/var/backups" 1 "backup directory"

BACKUP_DIR="${BACKUP_BASE}/backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

message "Creating backup of current Asterisk installation..."

# Binary
if [ -f /usr/sbin/asterisk ]; then
	cp /usr/sbin/asterisk "$BACKUP_DIR/" || error "Failed to backup binary"
fi

# Modules
if [ -d /usr/lib/asterisk/modules ]; then
	mkdir -p "$BACKUP_DIR/modules"
	cp -r /usr/lib/asterisk/modules/* "$BACKUP_DIR/modules/" 2>/dev/null || true
fi

# Shared libraries (critical for ABI compatibility)
mkdir -p "$BACKUP_DIR/libs"
for lib in /usr/lib/libasterisk*.so*; do
	[ -f "$lib" ] && cp "$lib" "$BACKUP_DIR/libs/" 2>/dev/null || true
done

# Configuration (safety net — not overwritten by deploy, but saved just in case)
if [ -d /etc/asterisk ]; then
	mkdir -p "$BACKUP_DIR/config"
	cp -r /etc/asterisk/* "$BACKUP_DIR/config/" 2>/dev/null || true
fi

echo -e "Backup created at: ${YELLOW}$BACKUP_DIR${NC}"

# ============================================================================
# ENVIRONMENT VERIFICATION
# ============================================================================

log "Verifying Asterisk environment..."
mkdir -p /var/run/asterisk /var/log/asterisk /var/lib/asterisk /var/spool/asterisk /etc/asterisk /usr/lib/asterisk/modules

if [ ! -f /etc/asterisk/asterisk.conf ]; then
	warn "asterisk.conf missing! Ensure FreePBX is correctly installed first."
fi

# ============================================================================
# DOWNLOAD (before stopping Asterisk to minimize outage window)
# ============================================================================

message "Downloading Asterisk update artifact..."

rm -rf "$STAGE_DIR" && mkdir -p "$STAGE_DIR"

# Fetch the published SHA256 (if any) to verify integrity before deploying
# binaries as root. Older releases without a checksum fall back to a
# gzip-validity check.
EXPECTED_SHA=""
if [ -n "${SHA_URL:-}" ] && wget -q -O /tmp/asterisk_update.tar.gz.sha256 "$SHA_URL"; then
	EXPECTED_SHA=$(awk '{print $1}' /tmp/asterisk_update.tar.gz.sha256)
fi
rm -f /tmp/asterisk_update.tar.gz.sha256
[ -z "$EXPECTED_SHA" ] && warn "No SHA256 checksum published for this release; integrity will not be verified."

DOWNLOAD_SUCCESS=0
for attempt in {1..3}; do
	if wget -q --show-progress -O /tmp/asterisk_update.tar.gz "$ASTERISK_ARTIFACT_URL"; then
		if [ -n "$EXPECTED_SHA" ] && [ "$(sha256sum /tmp/asterisk_update.tar.gz | awk '{print $1}')" != "$EXPECTED_SHA" ]; then
			warn "SHA256 checksum MISMATCH — refusing this artifact. Attempt $attempt/3"
			rm -f /tmp/asterisk_update.tar.gz
		elif tar -tzf /tmp/asterisk_update.tar.gz > /dev/null 2>&1; then
			DOWNLOAD_SUCCESS=1
			if [ -n "$EXPECTED_SHA" ]; then
				log "Update artifact downloaded and SHA256-verified."
			else
				log "Update artifact downloaded (validity-checked; no checksum available)."
			fi
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
	error "Failed to download a valid update after 3 attempts. Asterisk was NOT stopped."
fi

# ============================================================================
# GRACEFUL STOP (after successful download — outage starts here)
# ============================================================================

message "Stopping Asterisk service..."
if systemctl is-active --quiet asterisk 2>/dev/null; then
	# Try graceful shutdown first (gives active calls time to end)
	asterisk -rx "core stop gracefully" >> "$LOG_FILE" 2>&1 || true
	for i in {1..15}; do
		if ! systemctl is-active --quiet asterisk 2>/dev/null; then
			log "Asterisk stopped gracefully after ${i}x2 seconds."
			break
		fi
		sleep 2
	done
fi

# Force stop if still running
systemctl stop asterisk >> "$LOG_FILE" 2>&1 || true
sleep 1

if pgrep -x asterisk > /dev/null 2>&1; then
	warn "Asterisk still running after graceful stop, forcing kill..."
	pkill -9 asterisk 2>/dev/null || true
	sleep 1
fi

# ============================================================================
# DEPLOY
# ============================================================================

message "Deploying updated binaries, modules, and libraries..."
tar -xzf /tmp/asterisk_update.tar.gz -C "$STAGE_DIR"

# Extract confirmed version from tarball's VERSION.txt
if [ -f "$STAGE_DIR/VERSION.txt" ]; then
	TARBALL_VERSION=$(cat "$STAGE_DIR/VERSION.txt" | tr -d '[:space:]')
	message "Tarball contains Asterisk version: $TARBALL_VERSION"
	# Update AVAILABLE_VERSION if we got a better answer from the tarball
	if echo "$TARBALL_VERSION" | grep -qP '^[0-9]+\.[0-9]+\.[0-9]+'; then
		AVAILABLE_VERSION="$TARBALL_VERSION"
	fi
fi

# SAFETY: The tarball also contains sample configs (/etc/asterisk/) and data
# files (/var/lib/asterisk/) from `make samples` and `make install`, but we
# intentionally ONLY deploy binary + modules + libraries below.
# User configurations in /etc/asterisk/ and FreePBX data MUST NOT be overwritten.

# Binary
[ -f "$STAGE_DIR/usr/sbin/asterisk" ] && cp -f "$STAGE_DIR/usr/sbin/asterisk" /usr/sbin/

# Modules
[ -d "$STAGE_DIR/usr/lib/asterisk/modules" ] && cp -rf "$STAGE_DIR/usr/lib/asterisk/modules"/* /usr/lib/asterisk/modules/

# Shared libraries (critical for ABI compatibility with new modules)
for lib in "$STAGE_DIR"/usr/lib/libasterisk*.so*; do
	[ -f "$lib" ] && cp -f "$lib" /usr/lib/
done

# Restoring permissions
log "Restoring correct permissions..."
chown asterisk:asterisk /usr/sbin/asterisk
chmod +x /usr/sbin/asterisk
chown -R asterisk:asterisk /usr/lib/asterisk/modules
chown -R asterisk:asterisk /var/run/asterisk /var/log/asterisk /var/lib/asterisk /var/spool/asterisk /etc/asterisk

rm -rf "$STAGE_DIR" /tmp/asterisk_update.tar.gz
ldconfig

# ============================================================================
# HEALTH CHECK
# ============================================================================

message "Starting Asterisk and performing health check..."
systemctl start asterisk >> "$LOG_FILE" 2>&1
sleep 5

ASTERISK_HEALTHY=0
NEW_VERSION="Unknown"
for i in {1..10}; do
	if systemctl is-active --quiet asterisk 2>/dev/null && asterisk -rx "core show version" &>/dev/null; then
		ASTERISK_HEALTHY=1
		NEW_VERSION=$(asterisk -rx "core show version" 2>/dev/null | grep -oP 'Asterisk \K[0-9]+\.[0-9]+\.[0-9]+' || echo "Unknown")
		echo -e "${GREEN}✓ Asterisk is responding to CLI — Update successful!${NC}"
		break
	fi
	warn "Waiting for Asterisk to respond... ($i/10)"
	sleep 2
done

# ============================================================================
# ROLLBACK (if health check failed)
# ============================================================================

if [ $ASTERISK_HEALTHY -eq 0 ]; then
	echo -e "${RED}[ERROR] Asterisk failed to start after update. Rolling back...${NC}" | tee -a "$LOG_FILE"
	systemctl stop asterisk >> "$LOG_FILE" 2>&1 || true
	pkill -9 asterisk 2>/dev/null || true

	# Restore binary
	if [ -f "$BACKUP_DIR/asterisk" ]; then
		cp -f "$BACKUP_DIR/asterisk" /usr/sbin/asterisk
		chown asterisk:asterisk /usr/sbin/asterisk
		chmod +x /usr/sbin/asterisk
	fi

	# Restore modules
	if [ -d "$BACKUP_DIR/modules" ]; then
		rm -rf /usr/lib/asterisk/modules/*
		cp -r "$BACKUP_DIR/modules"/* /usr/lib/asterisk/modules/
		chown -R asterisk:asterisk /usr/lib/asterisk/modules
	fi

	# Restore shared libraries
	if [ -d "$BACKUP_DIR/libs" ] && ls "$BACKUP_DIR/libs"/*.so* &>/dev/null; then
		cp -f "$BACKUP_DIR/libs"/*.so* /usr/lib/
	fi

	ldconfig
	systemctl start asterisk >> "$LOG_FILE" 2>&1
	sleep 3

	# Keep backup for diagnostics — do NOT delete
	echo -e "${YELLOW}Backup preserved at $BACKUP_DIR for diagnostics.${NC}"
	error "Rollback complete. Previous version restored. Check: journalctl -xeu asterisk"
fi

# ============================================================================
# FINAL VALIDATION
# ============================================================================

message "Running FreePBX reload..."
if command -v fwconsole &> /dev/null; then
	fwconsole reload >> "$LOG_FILE" 2>&1 || warn "FreePBX reload had warnings"
fi

# Clean up old backups (keep last 3)
if [ -d "$BACKUP_BASE" ]; then
	BACKUP_COUNT=$(ls -1d "$BACKUP_BASE"/backup_* 2>/dev/null | wc -l)
	if [ "$BACKUP_COUNT" -gt 3 ]; then
		ls -1dt "$BACKUP_BASE"/backup_* | tail -n +4 | xargs rm -rf
		log "Cleaned old backups, kept last 3."
	fi
fi

echo -e "${GREEN}========================================================${NC}"
echo -e "${GREEN}     ASTERISK UPDATE COMPLETED SUCCESSFULLY!            ${NC}"
echo -e "${GREEN}            Version: $NEW_VERSION                       ${NC}"
echo -e "${GREEN}========================================================${NC}"
exit 0
