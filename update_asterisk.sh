#!/bin/bash

# ============================================================================
# SCRIPT:    update_asterisk.sh
# PROJECT:   FreePBX 17 ARM64 Installation Script (Asterisk 22 LTS)
# ============================================================================

set -e
# bump on every change, it is how an installed copy finds out it is outdated
SCRIPTVER="1.2.1"

# --- CONFIGURATION ---
REPO_OWNER="slythel2"

# releases live here, nowhere else. do not repoint at a private repo, wget gets
# 404 on both the api and the download and the script just gives up
REPO_NAME="freepbx-arm64-install"
REPO_RAW="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main"
FALLBACK_ARTIFACT="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/latest/download/asterisk-22-current-arm64-debian12.tar.gz"

LOG_FOLDER="/var/log/pbx"
LOG_FILE="${LOG_FOLDER}/update_asterisk-$(date '+%Y.%m.%d-%H.%M.%S').log"
LOCK_FILE="/var/lock/asterisk_update.lock"
BACKUP_BASE="/var/backups/asterisk"
STAGE_DIR="/tmp/asterisk_update_stage"

# --- ARGUMENT PARSING ---
DRY_RUN=false
skipversion=false
while [[ $# -gt 0 ]]; do
	case $1 in
		--dry-run)
			DRY_RUN=true
			shift
			;;
		--skipversion)
			skipversion=true
			shift
			;;
		--help|-h)
			echo "Usage: $0 [--dry-run] [--skipversion]"
			echo ""
			echo "Options:"
			echo "  --dry-run        Check available version without downloading or stopping Asterisk"
			echo "  --skipversion    Skip the check for a newer version of this script"
			echo "  --help           Show this help"
			exit 0
			;;
		*)
			echo "Unknown option: $1"
			echo "Usage: $0 [--dry-run] [--skipversion]"
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

# nothing is deployed yet here, so cleaning up and leaving is enough. it has to exit though
trap 'rm -rf "$STAGE_DIR" /tmp/asterisk_update.tar.gz 2>/dev/null; exit 130' INT TERM
# a refused artifact left 300MB in /tmp until the next run
trap 'rm -rf "$STAGE_DIR" /tmp/asterisk_update.tar.gz 2>/dev/null' EXIT

echo -e "${GREEN}========================================================${NC}"
echo -e "${GREEN}          ASTERISK 22 UPDATER (with Rollback)           ${NC}"
echo -e "${GREEN}                   Version: ${SCRIPTVER}                    ${NC}"
echo -e "${GREEN}========================================================${NC}"

log "Starting Asterisk 22 update v${SCRIPTVER}..."

# ============================================================================
# SELF-VERSION CHECK
# ============================================================================

# the installer writes this script once, so a fix to it never reaches a box that
# is already installed. this only says so, it never replaces anything by itself:
# downloading and running a root script on every update is not worth the risk
check_script_version() {
	if [ "$skipversion" = true ]; then
		log "Skipping the version check (--skipversion)."
		return
	fi
	# nothing to compare against when running from a working copy
	local dir
	dir=$(cd "$(dirname "$(readlink -f "$0")")" && pwd 2>/dev/null) || return
	if [ -d "${dir}/.git" ]; then
		log "Running from a git working copy, skipping the version check."
		return
	fi

	local remote latest
	remote=$(mktemp) || return
	if ! wget -q -T 10 -O "$remote" "${REPO_RAW}/update_asterisk.sh" 2>/dev/null; then
		log "Could not check for a newer updater, continuing with v${SCRIPTVER}."
		rm -f "$remote"
		return
	fi
	latest=$(grep -m1 '^SCRIPTVER=' "$remote" | cut -d'"' -f2)
	rm -f "$remote"

	if [ -z "$latest" ]; then
		log "Could not read the published version, continuing with v${SCRIPTVER}."
		return
	fi
	if dpkg --compare-versions "$latest" gt "$SCRIPTVER" 2>/dev/null; then
		# piped through bash, $0 is just bash
		local target
		target=$(readlink -f "$0" 2>/dev/null)
		[ -f "$target" ] && [ "${target##*/}" = update_asterisk.sh ] || target=/usr/local/bin/update_asterisk.sh
		echo ""
		echo -e "${YELLOW}A newer updater is available: v${latest}, this one is v${SCRIPTVER}.${NC}"
		echo -e "${YELLOW}It is not replaced automatically. To take it:${NC}"
		echo -e "${YELLOW}  wget -O ${target} ${REPO_RAW}/update_asterisk.sh && chmod +x ${target}${NC}"
		echo ""
		log "A newer updater is published: v${latest} against v${SCRIPTVER}."
	else
		log "The updater is up to date (v${SCRIPTVER})."
	fi
}

check_script_version

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
# pgrep, not systemctl: fwconsole starts asterisk outside the unit
if command -v asterisk &> /dev/null && pgrep -x asterisk > /dev/null 2>&1; then
	CURRENT_VERSION=$(asterisk -rx "core show version" 2>/dev/null | grep -oP 'Asterisk \K[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
fi
message "Current installed version: ${CURRENT_VERSION}"

# Fetch latest release info
# a curl that fails must still reach the fallback url below
RELEASE_JSON=$(curl -s --max-time 30 "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/releases/latest") || RELEASE_JSON=""
LATEST_URL=$(echo "$RELEASE_JSON" | jq -r '.assets[] | select((.name | contains("asterisk")) and (.name | endswith(".tar.gz"))) | .browser_download_url' | head -n 1)
SHA_URL=$(echo "$RELEASE_JSON" | jq -r '.assets[] | select((.name | contains("asterisk")) and (.name | endswith(".sha256"))) | .browser_download_url' | head -n 1)
RELEASE_TAG=$(echo "$RELEASE_JSON" | jq -r '.tag_name // empty')

if [ -z "$LATEST_URL" ]; then
	warn "Could not fetch latest release, using fallback URL."
	ASTERISK_ARTIFACT_URL="$FALLBACK_ARTIFACT"
	SHA_URL="${FALLBACK_ARTIFACT}.sha256"
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
			if [ "$DRY_RUN" != true ]; then
				# no terminal means no
				force_update=""
				read -rp "Force update anyway? (y/N): " force_update || true
				if [[ "$force_update" != "y" && "$force_update" != "Y" ]]; then
					echo "Update cancelled."
					exit 0
				fi
				message "User chose to force update."
			fi
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

# xml docs, they go with the modules
if [ -d /var/lib/asterisk/documentation ]; then
	cp -r /var/lib/asterisk/documentation "$BACKUP_DIR/" 2>/dev/null || true
fi

# Configuration (safety net, not overwritten by deploy, but saved just in case)
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

# older installs shipped minmemfree = 256, which silently refuses every call once
# the page cache grows. asterisk gets stopped further down anyway
if [ -f /etc/asterisk/asterisk.conf ] && \
   grep -qE '^[[:space:]]*minmemfree[[:space:]]*=' /etc/asterisk/asterisk.conf; then
	sed -i -E 's/^([[:space:]]*minmemfree[[:space:]]*=.*)$/; \1  ; disabled by update_asterisk.sh, it refuses calls on a healthy box/' \
		/etc/asterisk/asterisk.conf
	message "Disabled minmemfree in asterisk.conf: it was refusing all new calls."
	message "The original is in the backup at $BACKUP_DIR/config/asterisk.conf"
fi

# ============================================================================
# DOWNLOAD
# ============================================================================

message "Downloading Asterisk update artifact..."

rm -rf "$STAGE_DIR" && mkdir -p "$STAGE_DIR"

# Fetch the published SHA256 to verify integrity before deploying
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
			warn "SHA256 checksum MISMATCH, refusing this artifact. Attempt $attempt/3"
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
# STAGE, before the stop: a tarball that only breaks here must cost no downtime
# ============================================================================

tar -xzf /tmp/asterisk_update.tar.gz -C "$STAGE_DIR" \
	|| error "Failed to extract the update. Asterisk was NOT stopped."

if [ ! -f "$STAGE_DIR/usr/sbin/asterisk" ]; then
	error "The artifact has no usr/sbin/asterisk. Asterisk was NOT stopped."
fi

# the tarball knows its own version better than the release tag
if [ -f "$STAGE_DIR/VERSION.txt" ]; then
	TARBALL_VERSION=$(tr -d '[:space:]' < "$STAGE_DIR/VERSION.txt")
	message "Tarball contains Asterisk version: $TARBALL_VERSION"
	if echo "$TARBALL_VERSION" | grep -qP '^[0-9]+\.[0-9]+\.[0-9]+'; then
		AVAILABLE_VERSION="$TARBALL_VERSION"
	fi
fi

# ============================================================================
# ROLLBACK
# ============================================================================

# stopping asterisk also stopped freepbx.service (Requires=), and with it ucp and fastagi
start_freepbx() {
	systemctl is-enabled --quiet freepbx 2>/dev/null || return 0
	systemctl start freepbx >> "$LOG_FILE" 2>&1 \
		|| warn "freepbx.service did not start, UCP and FastAGI are down. Run: systemctl start freepbx"
}

# asterisk keeps a second copy of the xml docs for its http server
copy_static_docs() {
	if [ -f /var/lib/asterisk/documentation/core-en_US.xml ] && [ -d /var/lib/asterisk/static-http ]; then
		cp -f /var/lib/asterisk/documentation/core-en_US.xml /var/lib/asterisk/static-http/
	fi
}

# puts the backed up build back and starts it again. never returns
rollback() {
	# reached from the trap and from the health check, it must not die halfway on either path
	trap '' INT TERM HUP
	set +e
	systemctl stop asterisk >> "$LOG_FILE" 2>&1
	# -x, or the pattern matches this script (update_asterisk) and kills the rollback
	pkill -9 -x asterisk 2>/dev/null

	if [ -f "$BACKUP_DIR/asterisk" ]; then
		cp -f "$BACKUP_DIR/asterisk" /usr/sbin/asterisk
		chown asterisk:asterisk /usr/sbin/asterisk
		chmod +x /usr/sbin/asterisk
	fi

	# never restore from an empty backup, that would wipe every module instead
	if [ -d "$BACKUP_DIR/modules" ] && [ -n "$(ls -A "$BACKUP_DIR/modules" 2>/dev/null)" ]; then
		rm -rf /usr/lib/asterisk/modules/*
		cp -r "$BACKUP_DIR/modules"/* /usr/lib/asterisk/modules/
		chown -R asterisk:asterisk /usr/lib/asterisk/modules
	else
		warn "The backup holds no modules, leaving /usr/lib/asterisk/modules as it is."
		warn "The old binary may now sit next to the new modules, check: asterisk -rx 'module show'"
	fi

	if [ -d "$BACKUP_DIR/libs" ] && ls "$BACKUP_DIR/libs"/*.so* > /dev/null 2>&1; then
		cp -f "$BACKUP_DIR/libs"/*.so* /usr/lib/
	fi

	if [ -d "$BACKUP_DIR/documentation" ]; then
		cp -rf "$BACKUP_DIR/documentation"/. /var/lib/asterisk/documentation/
		copy_static_docs
	fi

	rm -rf "$STAGE_DIR" /tmp/asterisk_update.tar.gz
	ldconfig
	# the crashing build may have used up the unit's start limit
	systemctl reset-failed asterisk > /dev/null 2>&1
	systemctl start asterisk >> "$LOG_FILE" 2>&1
	sleep 5
	start_freepbx

	# Keep backup for diagnostics, do NOT delete
	echo -e "${YELLOW}Backup preserved at $BACKUP_DIR for diagnostics.${NC}"
	if asterisk -rx "core show version" > /dev/null 2>&1; then
		error "Rollback complete. Previous version restored and running. Check: journalctl -xeu asterisk"
	fi
	error "Rollback done but Asterisk did not come back. Check: journalctl -xeu asterisk"
}

# asterisk is down from the stop below until the health check passes. a failed command,
# a ctrl-c or a dropped ssh session in between must bring the old build back, not exit with no pbx
deploy_failed() {
	# ignore, not default: a second ctrl-c must not kill the rollback halfway
	trap '' ERR INT TERM HUP
	set +e
	echo -e "${RED}[ERROR] Update interrupted${1:+ at line $1}. Rolling back...${NC}" | tee -a "$LOG_FILE"
	rollback
}
# errtrace, or a failure inside message, warn or any other function never reaches the trap
set -E
trap 'deploy_failed "$LINENO"' ERR
trap 'deploy_failed' INT TERM HUP

# ============================================================================
# GRACEFUL STOP
# ============================================================================

message "Stopping Asterisk service..."
# fwconsole runs asterisk under safe_asterisk, which would respawn it mid deploy
pkill -x safe_asterisk 2>/dev/null || true
if pgrep -x asterisk > /dev/null 2>&1; then
	# Try graceful shutdown first
	asterisk -rx "core stop gracefully" >> "$LOG_FILE" 2>&1 || true
	for i in {1..15}; do
		if ! pgrep -x asterisk > /dev/null 2>&1; then
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
	# -x, the pattern alone also matches this script's own name
	pkill -9 -x asterisk 2>/dev/null || true
	sleep 1
fi

# ============================================================================
# DEPLOY
# ============================================================================

message "Deploying updated binaries, modules, and libraries..."

# binary, modules, libraries and xml docs only, the tarball's sample configs must not reach /etc/asterisk

# if blocks, not && lists: with the ERR trap armed a false test must not look like a failure
# Binary
if [ -f "$STAGE_DIR/usr/sbin/asterisk" ]; then
	cp -f "$STAGE_DIR/usr/sbin/asterisk" /usr/sbin/
fi

# Modules
if [ -d "$STAGE_DIR/usr/lib/asterisk/modules" ]; then
	cp -rf "$STAGE_DIR/usr/lib/asterisk/modules"/* /usr/lib/asterisk/modules/
fi

# Shared libraries (critical for ABI compatibility with new modules)
for lib in "$STAGE_DIR"/usr/lib/libasterisk*.so*; do
	[ -f "$lib" ] && cp -f "$lib" /usr/lib/
done

# xml docs, without them every option the old file lacks is an error at each start
if [ -d "$STAGE_DIR/var/lib/asterisk/documentation" ]; then
	mkdir -p /var/lib/asterisk/documentation
	cp -rf "$STAGE_DIR/var/lib/asterisk/documentation"/. /var/lib/asterisk/documentation/
	copy_static_docs
fi

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
# a failed start must reach the rollback below, not exit here
systemctl reset-failed asterisk > /dev/null 2>&1 || true
systemctl start asterisk >> "$LOG_FILE" 2>&1 || true
sleep 5

ASTERISK_HEALTHY=0
NEW_VERSION="Unknown"
for i in {1..10}; do
	# fully booted, the reload below needs the manager
	if systemctl is-active --quiet asterisk 2>/dev/null && timeout 30 asterisk -rx "core waitfullybooted" &>/dev/null; then
		ASTERISK_HEALTHY=1
		NEW_VERSION=$(asterisk -rx "core show version" 2>/dev/null | grep -oP 'Asterisk \K[0-9]+\.[0-9]+\.[0-9]+' || echo "Unknown")
		echo -e "${GREEN}✓ Asterisk is responding to CLI, update successful!${NC}"
		break
	fi
	warn "Waiting for Asterisk to respond... ($i/10)"
	sleep 2
done

# ============================================================================
# ROLLBACK (if health check failed)
# ============================================================================

# past this point a later failure must not roll back. the rollback below ignores signals by itself
trap - ERR INT TERM HUP
set +E

if [ $ASTERISK_HEALTHY -eq 0 ]; then
	echo -e "${RED}[ERROR] Asterisk failed to start after update. Rolling back...${NC}" | tee -a "$LOG_FILE"
	rollback
fi

# ============================================================================
# FINAL VALIDATION
# ============================================================================

start_freepbx

message "Running FreePBX reload..."
if command -v fwconsole &> /dev/null; then
	# reload leaves a signature check running in the background, it must not keep our lock
	fwconsole reload 200>&- >> "$LOG_FILE" 2>&1 || warn "FreePBX reload had warnings"
fi

# Clean up old backups (keeps last 3)
if [ -d "$BACKUP_BASE" ]; then
	BACKUP_COUNT=$(ls -1d "$BACKUP_BASE"/backup_* 2>/dev/null | wc -l)
	if [ "$BACKUP_COUNT" -gt 3 ]; then
		ls -1dt "$BACKUP_BASE"/backup_* | tail -n +4 | xargs rm -rf
		log "Cleaned old backups, kept last 3."
	fi
fi

echo -e "${GREEN}========================================================${NC}"
echo -e "${GREEN}     ASTERISK UPDATE COMPLETED SUCCESSFULLY!            ${NC}"
echo -e "${GREEN}               Version: $NEW_VERSION                       ${NC}"
echo -e "${GREEN}========================================================${NC}"
exit 0
