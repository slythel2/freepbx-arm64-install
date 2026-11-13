#!/bin/bash
# ============================================================================
# SCRIPT:    setup_email.sh
# PROJECT:   FreePBX 17 ARM64 Installation Script (Asterisk 22 LTS)
# Postfix relay through an external SMTP provider, safe to re-run. --help for usage.
# ============================================================================

set -Eeuo pipefail

VERSION="2.0"

STATE_FILE="/etc/freepbx-email.conf"
SASL_FILE="/etc/postfix/sasl_passwd"
CANONICAL_FILE="/etc/postfix/sender_canonical"
MAIN_CF="/etc/postfix/main.cf"
BLOCK_START="# --- FreePBX Email Relay ---"
BLOCK_END="# --- End FreePBX Email Relay ---"

# voicemail attachments are WAV; 25 MB keeps long messages from being rejected
MIN_MESSAGE_SIZE=26214400

# backup sets to keep, each one holds the smtp password in clear
BACKUP_KEEP=5

# decided once here, link() runs in command substitution where -t 1 is always false
if [ -t 1 ]; then
	RED='\033[0;31m'
	GREEN='\033[0;32m'
	YELLOW='\033[1;33m'
	CYAN='\033[0;36m'
	BOLD='\033[1m'
	NC='\033[0m'
	USE_LINKS=true
else
	RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
	USE_LINKS=false
fi

SMTP_HOST=""
SMTP_PORT=""
# port given with --port, --force then keeps it instead of swapping
PORT_EXPLICIT=false
SMTP_USER=""
SMTP_PASS=""
FROM_EMAIL=""
PROVIDER_NAME=""
PROVIDER_KEY=""
TEST_RECIPIENT=""

MODE="setup"
ASSUME_YES=false
FORCE=false
DO_TEST=true
DO_ROOT_ALIAS=""
ASTERISK_GROUP_CHANGED=false
TEST_RESULT="skipped"
BACKUP_FILE=""
ROLLBACK_ARMED=false
INPUT_DEV=""

# ============================================================================
# OUTPUT HELPERS
# ============================================================================

step() { echo -e "${CYAN}$*${NC}"; }
ok()   { echo -e "${GREEN}  $*${NC}"; }
warn() { echo -e "${YELLOW}  $*${NC}"; }
err()  { echo -e "${RED}  $*${NC}"; }
info() { echo "  $*"; }

# OSC 8 link, the visible text is the url so a console without support can still copy it
link() {
	if [ "$USE_LINKS" = true ]; then
		printf '\033]8;;%s\033\\%s\033]8;;\033\\' "$1" "$1"
	else
		printf '%s' "$1"
	fi
}

die() {
	echo -e "${RED}$*${NC}" >&2
	exit 1
}

# ============================================================================
# ROLLBACK
# ============================================================================
# main.cf is wiped before the new block goes in, a failure in between puts the backup back

# sasl_passwd, sender_canonical and the state file change with main.cf, rollback and --revert restore all four
restore_companions() {
	local stamp="$1"
	if [ -f "${SASL_FILE}.bak.${stamp}" ]; then
		cp -a "${SASL_FILE}.bak.${stamp}" "$SASL_FILE"
		postmap "$SASL_FILE" || warn "postmap failed on ${SASL_FILE}"
		chmod 600 "${SASL_FILE}.db" 2>/dev/null || true
		ok "Credentials restored from the same run."
	elif [ -f "${SASL_FILE}.absent.${stamp}" ]; then
		# none before that run, so the password goes too
		shred -u "$SASL_FILE" "${SASL_FILE}.db" 2>/dev/null || rm -f "$SASL_FILE" "${SASL_FILE}.db"
		ok "Credentials removed, there were none before."
	fi
	if [ -f "${CANONICAL_FILE}.bak.${stamp}" ]; then
		cp -a "${CANONICAL_FILE}.bak.${stamp}" "$CANONICAL_FILE"
		postmap "$CANONICAL_FILE" || warn "postmap failed on ${CANONICAL_FILE}"
		ok "Sender rewrite map restored from the same run."
	elif [ -f "${CANONICAL_FILE}.absent.${stamp}" ]; then
		rm -f "$CANONICAL_FILE" "${CANONICAL_FILE}.db"
		ok "Sender rewrite map removed, there was none before."
	fi
	if [ -f "${STATE_FILE}.bak.${stamp}" ]; then
		cp -a "${STATE_FILE}.bak.${stamp}" "$STATE_FILE"
		ok "Saved configuration restored from the same run."
	elif [ -f "${STATE_FILE}.absent.${stamp}" ]; then
		rm -f "$STATE_FILE"
		ok "Saved configuration removed, there was none before."
	fi
}

# one key, no sourcing, so an old backup does not clobber the run in progress
state_value() {
	local file="$1" key="$2"
	[ -f "$file" ] || return 0
	sed -n -E "s/^${key}=(.*)$/\1/p" "$file" | tail -n1
}

voicemail_sender_in() {
	[ -f "$1" ] || return 0
	sed -n -E 's/^[[:space:]]*serveremail[[:space:]]*=[[:space:]]*(.*)$/\1/p' "$1" | tail -n1
}

# same file the setup writes, not whichever has the key
live_voicemail_sender() {
	local target
	target=$(voicemail_target)
	[ -z "$target" ] || voicemail_sender_in "$target"
	return 0
}

# a revert puts serveremail back too, that key only, the rest of voicemail.conf belongs to freepbx
restore_voicemail_sender() {
	local stamp="$1" prev cur live
	prev=$(state_value "${STATE_FILE}.bak.${stamp}" FROM_EMAIL)
	cur=$(state_value "$STATE_FILE" FROM_EMAIL)
	live=$(live_voicemail_sender)

	[ -n "$prev" ] || return 0
	[ "$prev" != "$live" ] || return 0

	# If the live value is not the one this script last set, a human did, so leave it.
	if [ -n "$cur" ] && [ -n "$live" ] && [ "$cur" != "$live" ]; then
		warn "Voicemail sender is ${live}, which this script did not set."
		info "Left alone. The backup expected ${prev}, set it yourself if that is wrong."
		return 0
	fi

	FROM_EMAIL="$prev"
	configure_freepbx_email
}

# keep BACKUP_KEEP sets, newest first by suffix, shred the credential copy of the rest
prune_backups() {
	local old f ts n=0
	old=$(find "$(dirname "$MAIN_CF")" -maxdepth 1 -name "$(basename "$MAIN_CF").bak.*" 2>/dev/null \
		| sort -r | tail -n +$((BACKUP_KEEP + 1)) || true)
	[ -n "$old" ] || return 0

	while IFS= read -r f; do
		[ -n "$f" ] || continue
		ts="${f##*.bak.}"
		rm -f "$f"
		if [ -f "${SASL_FILE}.bak.${ts}" ]; then
			shred -u "${SASL_FILE}.bak.${ts}" 2>/dev/null || rm -f "${SASL_FILE}.bak.${ts}"
		fi
		rm -f "${CANONICAL_FILE}.bak.${ts}" "${STATE_FILE}.bak.${ts}" \
			"${SASL_FILE}.absent.${ts}" "${CANONICAL_FILE}.absent.${ts}" "${STATE_FILE}.absent.${ts}"
		n=$((n + 1))
	done <<<"$old"

	info "Pruned ${n} old backup set(s), keeping the last ${BACKUP_KEEP}."

	# the before-revert copies pile up the same way
	local rev
	rev=$(find "$(dirname "$MAIN_CF")" -maxdepth 1 -name "$(basename "$MAIN_CF").before-revert.*" 2>/dev/null \
		| sort -r | tail -n +$((BACKUP_KEEP + 1)) || true)
	[ -n "$rev" ] || return 0
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		rm -f "$f"
	done <<<"$rev"
	return 0
}

# a relayhost with no sasl entry bounces every message
sasl_matches_relayhost() {
	local rh
	rh=$(postconf -h relayhost 2>/dev/null || true)
	[ -n "$rh" ] || return 0
	[ -f "$SASL_FILE" ] || return 1
	grep -qF "$rh" "$SASL_FILE"
}

warn_if_sasl_mismatch() {
	sasl_matches_relayhost && return 0
	warn "${SASL_FILE} has no entry for relayhost $(postconf -h relayhost 2>/dev/null)."
	info "Mail will bounce with 'Authentication required'. Re-run setup_email.sh to fix it."
}

rollback_on_error() {
	local rc=$?
	# EXIT is trapped too: die() leaves through exit, which never raises ERR.
	trap - ERR INT TERM EXIT
	[ "$rc" -ne 0 ] || return 0
	if [ "$ROLLBACK_ARMED" = true ] && [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ]; then
		echo ""
		err "Setup failed. Restoring the previous Postfix configuration..."
		cp -a "$BACKUP_FILE" "$MAIN_CF"
		restore_companions "${BACKUP_FILE##*.bak.}"
		systemctl reload postfix >/dev/null 2>&1 || systemctl restart postfix >/dev/null 2>&1 || true
		err "Restored from ${BACKUP_FILE}. Postfix is back to its previous state."
	fi
	exit "$rc"
}

arm_rollback() {
	ROLLBACK_ARMED=true
	trap rollback_on_error ERR INT TERM EXIT
}

disarm_rollback() {
	ROLLBACK_ARMED=false
	trap - ERR INT TERM EXIT
}

# ============================================================================
# INPUT HELPERS
# ============================================================================

# with curl | bash fd 0 is the script, so each read redirects on its own
tty_available() {
	[ -n "$INPUT_DEV" ] && return 0
	if [ -t 0 ]; then
		INPUT_DEV="/dev/stdin"
		return 0
	fi
	# /dev/tty passes -r and -c with no controlling terminal, only an open tells
	if ( : <>/dev/tty ) 2>/dev/null; then
		INPUT_DEV="/dev/tty"
		return 0
	fi
	return 1
}

need_tty() {
	tty_available && return 0
	die "No terminal available for interactive input. Re-run with flags instead (setup_email.sh --help)."
}

ask() {
	local prompt="$1" default="${2:-}" __var="$3" reply
	need_tty
	read -erp "$prompt" reply <"$INPUT_DEV"
	printf -v "$__var" '%s' "${reply:-$default}"
}

ask_secret() {
	local prompt="$1" __var="$2" reply
	need_tty
	read -rsp "$prompt" reply <"$INPUT_DEV"
	echo ""
	printf -v "$__var" '%s' "$reply"
}

# $1 question, $2 default Y or N. unknown answers are asked again, y s j mean yes
confirm() {
	local question="$1" default="${2:-Y}" reply attempts=0
	[ "$ASSUME_YES" = true ] && return 0
	local hint="[Y/n]"
	[ "$default" = "N" ] && hint="[y/N]"
	need_tty
	while [ $attempts -lt 3 ]; do
		read -erp "${question} ${hint}: " reply <"$INPUT_DEV"
		reply="${reply:-$default}"
		case "$reply" in
			[YyJjSs]*) return 0 ;;
			[Nn]*)     return 1 ;;
		esac
		attempts=$((attempts + 1))
		err "Answer y or n."
	done
	# Out of attempts. Take the stated default rather than guess.
	[ "$default" = "Y" ]
}

# stop sign, unattended runs stop here unless --force
gate() {
	if [ "$ASSUME_YES" = true ]; then
		[ "$FORCE" = true ]
		return
	fi
	confirm "$1" N
}

is_valid_email() {
	[[ "$1" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
}

# $1 = prompt, $2 = default, $3 = variable name. Empty input takes the default.
ask_email() {
	local prompt="$1" default="$2" __var="$3" attempts=0 reply
	while [ $attempts -lt 3 ]; do
		need_tty
		read -erp "$prompt" reply <"$INPUT_DEV"
		reply="${reply:-$default}"
		if is_valid_email "$reply"; then
			printf -v "$__var" '%s' "$reply"
			return 0
		fi
		attempts=$((attempts + 1))
		[ $attempts -lt 3 ] && err "Invalid email format. $((3 - attempts)) attempt(s) left."
	done
	die "Too many invalid attempts."
}

# ============================================================================
# SYSTEM HELPERS
# ============================================================================

check_root() {
	[ "$(id -u)" -eq 0 ] || die "This script must be run as root."
}

# into a variable first, grep -q on a pipe gets dpkg-query killed by SIGPIPE under pipefail
pkg_installed() {
	local status
	status=$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true)
	grep -q "ok installed" <<<"$status"
}

# myorigin is a path on debian and some values are $references, resolve both
postconf_value() {
	local v
	v=$(postconf -xh "$1" 2>/dev/null || true)
	case "$v" in
		/*) if [ -r "$v" ]; then v=$(head -n1 "$v" 2>/dev/null || true); else v=""; fi ;;
		\$*) v="" ;;
	esac
	printf '%s\n' "$v"
}

mail_log_since() {
	local since="$1" out=""
	if command -v journalctl >/dev/null 2>&1; then
		out=$(journalctl -q --facility=mail --since "$since" --no-pager 2>/dev/null || true)
	fi
	if [ -z "$out" ] && [ -r /var/log/mail.log ]; then
		out=$(tail -n 500 /var/log/mail.log 2>/dev/null || true)
	fi
	printf '%s\n' "$out"
}

asterisk_running() {
	pgrep -x asterisk >/dev/null 2>&1
}

# a running process keeps its startup groups, read the live ones from /proc
asterisk_has_postdrop_live() {
	local pid gid groups_line
	pid=$(pgrep -x asterisk 2>/dev/null | head -n1 || true)
	[ -n "$pid" ] || return 1
	gid=$(getent group postdrop 2>/dev/null | cut -d: -f3 || true)
	[ -n "$gid" ] || return 1
	groups_line=$(awk '/^Groups:/{$1=""; print}' "/proc/${pid}/status" 2>/dev/null || true)
	grep -qw "$gid" <<<"$groups_line"
}

# NoNewPrivileges makes the kernel ignore the setgid on postdrop, then only the group works
asterisk_nnp_live() {
	local pid
	pid=$(pgrep -x asterisk 2>/dev/null | head -n1 || true)
	[ -n "$pid" ] || return 1
	[ "$(awk '/^NoNewPrivs:/{print $2}' "/proc/${pid}/status" 2>/dev/null || true)" = "1" ]
}

# restart asterisk the way it is running, fwconsole would take it out of the unit
asterisk_restart_cmd() {
	if systemctl is-active --quiet asterisk 2>/dev/null; then
		echo "systemctl restart asterisk"
	else
		echo "fwconsole restart"
	fi
}

# ============================================================================
# PACKAGES
# ============================================================================

check_postfix() {
	export DEBIAN_FRONTEND=noninteractive

	if ! command -v postconf >/dev/null 2>&1; then
		step "Postfix is not installed. Installing..."
		# preseed, or the hidden debconf dialog makes the install look stuck
		local mailname
		mailname=$(hostname -f 2>/dev/null || hostname)
		debconf-set-selections <<<"postfix postfix/mailname string ${mailname}"
		debconf-set-selections <<<"postfix postfix/main_mailer_type select Internet Site"
		apt-get update -qq >/dev/null 2>&1 || true
		apt-get install -y -qq postfix libsasl2-modules ca-certificates >/dev/null 2>&1 \
			|| die "Could not install Postfix. Install it manually and re-run this script."
		ok "Postfix installed."
	fi

	local pkg
	for pkg in libsasl2-modules ca-certificates; do
		if ! pkg_installed "$pkg"; then
			apt-get install -y -qq "$pkg" >/dev/null 2>&1 || warn "Could not install ${pkg}."
		fi
	done

	command -v postconf >/dev/null 2>&1 || die "Postfix is still not available."
	systemctl enable postfix >/dev/null 2>&1 || true
}

# ============================================================================
# PROVIDERS
# ============================================================================

apply_provider() {
	case "$1" in
		gmail)
			PROVIDER_KEY="gmail"; PROVIDER_NAME="Gmail"
			SMTP_HOST="smtp.gmail.com"; SMTP_PORT="${SMTP_PORT:-587}" ;;
		brevo)
			PROVIDER_KEY="brevo"; PROVIDER_NAME="Brevo"
			SMTP_HOST="smtp-relay.brevo.com"; SMTP_PORT="${SMTP_PORT:-587}" ;;
		aruba)
			PROVIDER_KEY="aruba"; PROVIDER_NAME="Aruba"
			SMTP_HOST="smtps.aruba.it"; SMTP_PORT="${SMTP_PORT:-587}" ;;
		sendgrid)
			PROVIDER_KEY="sendgrid"; PROVIDER_NAME="SendGrid"
			SMTP_HOST="smtp.sendgrid.net"; SMTP_PORT="${SMTP_PORT:-587}" ;;
		mailjet)
			PROVIDER_KEY="mailjet"; PROVIDER_NAME="Mailjet"
			SMTP_HOST="in-v3.mailjet.com"; SMTP_PORT="${SMTP_PORT:-587}" ;;
		custom)
			PROVIDER_KEY="custom"; PROVIDER_NAME="${PROVIDER_NAME:-Custom}" ;;
		*)
			die "Unknown provider '$1'. Use: gmail, brevo, aruba, sendgrid, mailjet, custom." ;;
	esac
}

provider_hint() {
	case "$PROVIDER_KEY" in
		gmail)
			warn "Gmail requires an App Password. Your normal password will not work."
			info "1. Enable 2-Step Verification on the account"
			info "2. Create an App Password for 'Mail':"
			info "   $(link https://myaccount.google.com/apppasswords)"
			info "3. Paste it below, spaces are removed automatically"
			;;
		brevo)
			warn "Use your Brevo SMTP key, not your Brevo login password."
			info "Settings -> SMTP & API -> SMTP. The login is your Brevo account email."
			info "The From address must be a validated sender in your Brevo account."
			info "No account yet? $(link https://www.brevo.com)"
			;;
		aruba)
			warn "Use your full Aruba mailbox address and its password."
			info "Port 587 (STARTTLS) is preferred over 465 because many VPS block 465 outbound."
			;;
		sendgrid)
			warn "The SMTP username is the literal string 'apikey'."
			info "The password is the API key itself, and the From address must be a verified sender."
			info "No account yet? $(link https://sendgrid.com)"
			;;
		mailjet)
			warn "Use the API Key as username and the Secret Key as password."
			info "Account Settings -> REST API -> API Key Management."
			info "No account yet? $(link https://www.mailjet.com)"
			;;
	esac
}

select_provider() {
	echo -e "${BOLD}Select your SMTP provider:${NC}"
	echo ""
	echo "  1) Gmail        (App Password required, 500 emails/day)"
	echo "  2) Brevo        (free tier: 300 emails/day, no personal mailbox needed)"
	echo "  3) Aruba        (Italian provider - smtps.aruba.it)"
	echo "  4) SendGrid     (free tier, designed for servers)"
	echo "  5) Mailjet      (free tier, designed for servers)"
	echo "  6) Custom SMTP  (Yahoo, iCloud, Zoho, Microsoft 365, your own server...)"
	echo ""

	local choice
	while true; do
		ask "Choice [1-6]: " "" choice
		case "$choice" in
			1) apply_provider gmail; break ;;
			2) apply_provider brevo; break ;;
			3) apply_provider aruba; break ;;
			4) apply_provider sendgrid; break ;;
			5) apply_provider mailjet; break ;;
			6)
				echo ""
				echo -e "${BOLD}Common SMTP settings for reference:${NC}"
				info "Yahoo Mail:    smtp.mail.yahoo.com  / port 587"
				info "iCloud/Apple:  smtp.mail.me.com     / port 587"
				info "Zoho Mail:     smtp.zoho.com        / port 587"
				info "Microsoft 365: smtp.office365.com   / port 587"
				echo ""
				while [ -z "$SMTP_HOST" ]; do
					ask "SMTP host: " "" SMTP_HOST
				done
				ask "SMTP port [587]: " "587" SMTP_PORT
				apply_provider custom
				break
				;;
			*) err "Invalid choice. Enter a number from 1 to 6." ;;
		esac
	done

	echo ""
	provider_hint
	echo ""
}

collect_credentials() {
	while [ -z "$SMTP_USER" ]; do
		ask "SMTP username (usually your email address): " "" SMTP_USER
		[ -z "$SMTP_USER" ] && err "The username cannot be empty."
	done

	while [ -z "$SMTP_PASS" ]; do
		ask_secret "SMTP password: " SMTP_PASS
		[ -z "$SMTP_PASS" ] && err "The password cannot be empty."
	done

	echo "  (this is the sender address recipients will see)"
	ask_email "From email address [${SMTP_USER}]: " "$SMTP_USER" FROM_EMAIL
	echo ""
}

normalise_credentials() {
	# gmail shows app passwords with spaces, they break auth
	if [ "$PROVIDER_KEY" = "gmail" ]; then
		local stripped="${SMTP_PASS// /}"
		if [ "$stripped" != "$SMTP_PASS" ]; then
			SMTP_PASS="$stripped"
			info "Removed the spaces from the Gmail App Password."
		fi
	fi

	# postfix splits the sasl_passwd value at the first colon
	case "$SMTP_USER" in
		*:*) die "The SMTP username cannot contain a colon; Postfix cannot store it." ;;
	esac

	case "$SMTP_PASS" in
		*$'\n'*|*$'\r'*|*$'\t'*) die "The SMTP password cannot contain newlines or tabs." ;;
	esac

	[ -n "$FROM_EMAIL" ] || FROM_EMAIL="$SMTP_USER"
	is_valid_email "$FROM_EMAIL" || die "Invalid From address: ${FROM_EMAIL}"
	[ -n "$SMTP_PORT" ] || SMTP_PORT=587
	[[ "$SMTP_PORT" =~ ^[0-9]+$ ]] || die "Invalid SMTP port: ${SMTP_PORT}"
}

# ============================================================================
# CONNECTIVITY PRE-CHECK
# ============================================================================

# host and port as arguments, never spliced into the string, this runs as root
probe_port() {
	timeout 6 bash -c 'exec 3<>/dev/tcp/"$1"/"$2"' _ "$1" "$2" 2>/dev/null
}

# --force only counts with --yes, so the hint depends on the mode
abort_hint() {
	if [ "$ASSUME_YES" = true ]; then
		die "Aborted. Nothing was changed. Add --force to configure it anyway."
	fi
	die "Aborted. Nothing was changed. Re-run and answer yes to use it regardless."
}

precheck_connectivity() {
	step "Checking outbound connectivity to ${SMTP_HOST}:${SMTP_PORT}..."

	if ! getent hosts "$SMTP_HOST" >/dev/null 2>&1; then
		err "${SMTP_HOST} does not resolve. Check the hostname and your DNS."
		gate "Continue anyway?" || abort_hint
		return 0
	fi

	if probe_port "$SMTP_HOST" "$SMTP_PORT"; then
		ok "Port ${SMTP_PORT} is reachable."
		return 0
	fi

	warn "Cannot reach ${SMTP_HOST} on port ${SMTP_PORT}."
	info "Your hosting provider is probably blocking it outbound."

	local alt found=""
	for alt in 587 2525 465 25; do
		[ "$alt" = "$SMTP_PORT" ] && continue
		if probe_port "$SMTP_HOST" "$alt"; then
			found="$alt"
			break
		fi
	done

	if [ -n "$found" ]; then
		echo ""
		ok "Port ${found} on ${SMTP_HOST} is reachable."
		# --port with --force means that port, do not swap it
		if [ "$PORT_EXPLICIT" = true ] && [ "$FORCE" = true ]; then
			info "Keeping port ${SMTP_PORT} as asked, --force was given."
		elif confirm "  Use port ${found} instead?" Y; then
			# Under --yes nobody answered this, so say what happened.
			[ "$ASSUME_YES" = true ] && warn "Using port ${found} instead of the ${SMTP_PORT} you asked for."
			SMTP_PORT="$found"
			return 0
		fi
	else
		echo ""
		warn "No alternative port responded either (tried 587, 2525, 465, 25)."
		info "Ask your provider to unblock outbound SMTP, or use a relay that offers port 2525."
	fi

	gate "Continue with port ${SMTP_PORT} anyway?" || abort_hint
}

# ============================================================================
# POSTFIX PERMISSIONS
# ============================================================================
# postdrop is setgid so any user can queue mail, permission denied means broken permissions

postfix_permissions_ok() {
	[ -x /usr/sbin/postdrop ] || return 1
	[ -g /usr/sbin/postdrop ] || return 1
	[ "$(stat -c '%G' /usr/sbin/postdrop 2>/dev/null || true)" = "postdrop" ] || return 1
	[ -d /var/spool/postfix/maildrop ] || return 1
	[ "$(stat -c '%U:%G' /var/spool/postfix/maildrop 2>/dev/null || true)" = "postfix:postdrop" ] || return 1
	return 0
}

fix_postfix_permissions() {
	step "Checking mail submission permissions..."

	local need_group=false
	if postfix_permissions_ok; then
		ok "postdrop permissions are correct."
	else
		warn "postdrop permissions are wrong; Asterisk would not be able to queue mail."
		info "Running 'postfix set-permissions' to repair them..."
		postfix set-permissions >/dev/null 2>&1 || true
		if postfix_permissions_ok; then
			ok "Permissions repaired."
		else
			err "Could not repair the Postfix permissions automatically."
			info "Check manually: ls -l /usr/sbin/postdrop (expected -rwxr-sr-x root postdrop)"
			info "               ls -ld /var/spool/postfix/maildrop (expected drwx-wx--- postfix postdrop)"
			need_group=true
		fi
	fi

	if asterisk_nnp_live; then
		warn "Asterisk runs with NoNewPrivileges, so the setgid on postdrop does not apply to it."
		info "Remove NoNewPrivileges from its systemd unit, or it needs the postdrop group."
		need_group=true
	fi

	# the group is the fallback, setgid postdrop is what normally does the job
	[ "$need_group" = true ] || return 0
	if id asterisk >/dev/null 2>&1 && getent group postdrop >/dev/null 2>&1; then
		if ! grep -qx postdrop <<<"$(id -nG asterisk 2>/dev/null | tr ' ' '\n')"; then
			usermod -a -G postdrop asterisk
			ASTERISK_GROUP_CHANGED=true
			info "Added the asterisk user to the postdrop group."
		fi
	fi
}

offer_asterisk_restart() {
	[ "$ASTERISK_GROUP_CHANGED" = true ] || return 0
	asterisk_running || return 0
	asterisk_has_postdrop_live && return 0

	local cmd
	cmd=$(asterisk_restart_cmd)
	echo ""
	warn "Asterisk is running and will not pick up its new group membership until it restarts."
	info "Until then voicemail and fax mail from Asterisk will not queue."
	if [ "$ASSUME_YES" = true ] || ! tty_available; then
		# don't drop live calls when nobody is watching
		info "Restart it yourself when convenient with: ${cmd}"
		return 0
	fi
	if confirm "Restart Asterisk now? Active calls will be dropped." N; then
		$cmd >/dev/null 2>&1 </dev/null || true
		ok "Asterisk restarted."
	else
		info "Restart it later with: ${cmd}"
	fi
}

# ============================================================================
# SENDER REWRITING
# ============================================================================
# relays reject asterisk@hostname, rewrite the sender only, generic maps would touch recipients too

local_names() {
	local n names=()
	names+=("$(hostname -s 2>/dev/null || true)")
	names+=("$(hostname 2>/dev/null || true)")
	names+=("$(hostname -f 2>/dev/null || true)")
	names+=("$(postconf_value myhostname)")
	names+=("$(postconf_value mydomain)")
	names+=("$(postconf_value myorigin)")
	names+=("$(head -n1 /etc/mailname 2>/dev/null || true)")
	names+=("localhost")
	names+=("localhost.localdomain")

	for n in "${names[@]}"; do
		[ -n "$n" ] || continue
		# skip $references, paths and anything with spaces in it
		case "$n" in
			\$*|/*|*[[:space:]]*) continue ;;
		esac
		echo "$n"
	done | sort -u
}

build_sender_canonical() {
	local name
	{
		echo "# Generated by setup_email.sh - do not edit by hand."
		echo "# Rewrites mail originating on this host so it leaves with a real sender."
		while read -r name; do
			[ -n "$name" ] || continue
			echo "@${name} ${FROM_EMAIL}"
		done < <(local_names)
	} >"$CANONICAL_FILE"

	chmod 644 "$CANONICAL_FILE"
	postmap "$CANONICAL_FILE"

	# Older versions of this script used smtp_generic_maps, clean it up.
	rm -f /etc/postfix/generic /etc/postfix/generic.db
}

# ============================================================================
# POSTFIX CONFIGURATION
# ============================================================================

configure_postfix() {
	step "Configuring Postfix as an SMTP relay..."

	# one timestamp for the set, the sasl key is host and port so main.cf alone cannot go back
	local stamp
	stamp=$(date +%Y%m%d%H%M%S)
	BACKUP_FILE="${MAIN_CF}.bak.${stamp}"
	cp -a "$MAIN_CF" "$BACKUP_FILE"
	# a file that was not there gets a marker, so a revert removes it instead of leaving it
	local f
	for f in "$SASL_FILE" "$CANONICAL_FILE" "$STATE_FILE"; do
		if [ -f "$f" ]; then
			cp -a "$f" "${f}.bak.${stamp}"
		else
			: > "${f}.absent.${stamp}"
		fi
	done
	info "Backup: ${BACKUP_FILE}"
	prune_backups
	arm_rollback

	# 600 before the password is written
	install -m 600 -o root -g root /dev/null "$SASL_FILE"
	printf '[%s]:%s %s:%s\n' "$SMTP_HOST" "$SMTP_PORT" "$SMTP_USER" "$SMTP_PASS" >"$SASL_FILE"
	postmap "$SASL_FILE"
	chmod 600 "${SASL_FILE}.db"

	build_sender_canonical

	# drop the old block so re-runs do not stack, message_size_limit is read back below
	sed -i "/^${BLOCK_START}$/,/^${BLOCK_END}$/d" "$MAIN_CF"
	# the blank line before the block stayed behind, one more on every re-run
	sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$MAIN_CF"

	# only our keys, debian's smtp_tls_CApath and session cache stay
	local key
	for key in relayhost smtp_sasl_auth_enable smtp_sasl_password_maps \
	           smtp_sasl_security_options smtp_tls_security_level \
	           smtp_tls_wrappermode smtp_tls_CAfile sender_canonical_maps \
	           smtp_helo_name smtp_generic_maps smtp_use_tls inet_protocols; do
		sed -i -E "/^[[:space:]]*${key}[[:space:]]*=/d" "$MAIN_CF"
	done

	local tls_block="smtp_tls_security_level = encrypt"
	if [ "$SMTP_PORT" = "465" ]; then
		# 465 is implicit TLS, 587 and 2525 are STARTTLS
		tls_block="smtp_tls_security_level = encrypt
smtp_tls_wrappermode = yes"
	fi

	# Some relays reject a HELO that isn't a full domain name.
	local helo
	helo=$(hostname -f 2>/dev/null || true)
	case "$helo" in
		*.*) : ;;
		*)   helo="${FROM_EMAIL#*@}" ;;
	esac

	# base64 wav attachments are big, keep the admin's limit if it is higher
	local size_limit
	size_limit=$(postconf -h message_size_limit 2>/dev/null || echo 0)
	[[ "$size_limit" =~ ^[0-9]+$ ]] || size_limit=0
	[ "$size_limit" -lt "$MIN_MESSAGE_SIZE" ] && size_limit="$MIN_MESSAGE_SIZE"

	# no ipv6 route, pin ipv4, or a failed AAAA attempt hides the real error in the status
	local proto_block="" v6_route=""
	if command -v ip >/dev/null 2>&1; then
		v6_route=$(ip -6 route show default 2>/dev/null || true)
		if [ -z "$v6_route" ]; then
			proto_block="inet_protocols = ipv4"
		fi
	fi

	cat >>"$MAIN_CF" <<EOF

${BLOCK_START}
relayhost = [${SMTP_HOST}]:${SMTP_PORT}
smtp_sasl_auth_enable = yes
smtp_sasl_password_maps = hash:${SASL_FILE}
smtp_sasl_security_options = noanonymous
${tls_block}
smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt
sender_canonical_maps = hash:${CANONICAL_FILE}
smtp_helo_name = ${helo}
message_size_limit = ${size_limit}
${proto_block}
${BLOCK_END}
EOF

	postfix check 2>&1 | sed 's/^/  /' || true
	systemctl restart postfix || die "Postfix failed to restart. Check: systemctl status postfix"

	disarm_rollback
	ok "Relay configured through ${PROVIDER_NAME} (${SMTP_HOST}:${SMTP_PORT})"
	if [ -n "$proto_block" ]; then
		info "No IPv6 route here, so Postfix is pinned to IPv4 for outbound mail."
	fi

	if [ "$(postconf -h inet_interfaces 2>/dev/null || true)" = "all" ]; then
		warn "Postfix is listening on all interfaces (inet_interfaces = all)."
		info "A PBX rarely needs to receive mail. Consider 'loopback-only' to reduce exposure."
	fi
}

# ============================================================================
# ASTERISK / FREEPBX
# ============================================================================

# Writes key=value into a flat Asterisk include file, replacing any existing key.
set_asterisk_key() {
	local file="$1" key="$2" value="$3"
	touch "$file"
	if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$file"; then
		sed -i -E "s|^[[:space:]]*${key}[[:space:]]*=.*|${key}=${value}|" "$file"
	else
		printf '%s=%s\n' "$key" "$value" >>"$file"
	fi
}

# freepbx 17 reads and writes back voicemail.conf, vm_general.inc only when it is included
voicemail_target() {
	local vm_conf="/etc/asterisk/voicemail.conf"
	if [ -f "$vm_conf" ] && grep -qE '^[[:space:]]*#include[[:space:]]+vm_general\.inc' "$vm_conf"; then
		echo "/etc/asterisk/vm_general.inc"
	elif [ -f "$vm_conf" ]; then
		echo "$vm_conf"
	elif [ -f /etc/asterisk/vm_general.inc ]; then
		echo "/etc/asterisk/vm_general.inc"
	fi
}

configure_freepbx_email() {
	step "Configuring the FreePBX voicemail sender..."

	local target
	target=$(voicemail_target)

	if [ -z "$target" ]; then
		warn "voicemail.conf not found, skipping the Asterisk side."
		info "Set it later in FreePBX: Settings -> Voicemail Admin -> Settings -> serveremail"
		return 0
	fi

	local direct=false
	[ "$target" = "/etc/asterisk/voicemail.conf" ] && direct=true

	write_voicemail_settings "$target" "$direct"

	# fwconsole reads stdin and would eat a piped script
	if command -v fwconsole >/dev/null 2>&1; then
		fwconsole reload --quiet >/dev/null 2>&1 </dev/null || true
	fi

	# compare the value, freepbx always writes some serveremail line
	local live
	live=$(voicemail_sender_in "$target")
	if [ "$live" = "$FROM_EMAIL" ]; then
		ok "Voicemail sender set to ${FROM_EMAIL} in ${target}"
	else
		warn "The voicemail sender did not stick in ${target}."
		info "It now reads '${live:-nothing}' instead of ${FROM_EMAIL}."
		info "Set it in FreePBX: Settings -> Voicemail Admin -> Settings -> serveremail"
	fi
}

write_voicemail_settings() {
	local target="$1" direct="$2"

	if [ "$direct" = true ]; then
		# No include to write to, so edit [general] directly.
		if grep -qE "^[[:space:]]*serveremail[[:space:]]*=" "$target"; then
			sed -i -E "s|^[[:space:]]*serveremail[[:space:]]*=.*|serveremail=${FROM_EMAIL}|" "$target"
		else
			sed -i "0,/^\[general\]/s//[general]\nserveremail=${FROM_EMAIL}/" "$target"
		fi
		if grep -qE "^[[:space:]]*mailcmd[[:space:]]*=" "$target"; then
			sed -i -E "s|^[[:space:]]*mailcmd[[:space:]]*=.*|mailcmd=/usr/sbin/sendmail -t -f ${FROM_EMAIL}|" "$target"
		fi
	else
		set_asterisk_key "$target" serveremail "$FROM_EMAIL"
		# envelope sender at the source too, right even without the relay
		set_asterisk_key "$target" mailcmd "/usr/sbin/sendmail -t -f ${FROM_EMAIL}"
		chown asterisk:asterisk "$target" 2>/dev/null || true
	fi
}

# asked before postfix is touched, so a run with nobody to answer stops with nothing changed
decide_root_alias() {
	if [ -z "$DO_ROOT_ALIAS" ] && [ "$ASSUME_YES" = true ]; then
		# unattended runs leave /etc/aliases alone unless asked
		DO_ROOT_ALIAS=false
	fi
	[ -z "$DO_ROOT_ALIAS" ] || return 0
	echo ""
	info "System mail sent to root (cron, fail2ban, unattended upgrades) is currently"
	info "delivered to a local mailbox nobody reads."
	if confirm "Forward root's mail to ${FROM_EMAIL} as well?" Y; then
		DO_ROOT_ALIAS=true
	else
		DO_ROOT_ALIAS=false
	fi
}

configure_root_alias() {
	[ "$DO_ROOT_ALIAS" = true ] || return 0

	touch /etc/aliases
	if grep -qE '^[[:space:]]*root[[:space:]]*:' /etc/aliases; then
		sed -i -E "s|^[[:space:]]*root[[:space:]]*:.*|root: ${FROM_EMAIL}|" /etc/aliases
	else
		printf 'root: %s\n' "$FROM_EMAIL" >>/etc/aliases
	fi
	newaliases >/dev/null 2>&1 || true
	ok "System mail for root now goes to ${FROM_EMAIL}"
}

# ============================================================================
# STATE
# ============================================================================

save_state() {
	install -m 600 -o root -g root /dev/null "$STATE_FILE"
	cat >"$STATE_FILE" <<EOF
# Written by setup_email.sh v${VERSION} on $(date '+%Y-%m-%d %H:%M:%S')
# The password is not stored here; it lives in ${SASL_FILE}.
PROVIDER_KEY=${PROVIDER_KEY}
PROVIDER_NAME=${PROVIDER_NAME}
SMTP_HOST=${SMTP_HOST}
SMTP_PORT=${SMTP_PORT}
SMTP_USER=${SMTP_USER}
FROM_EMAIL=${FROM_EMAIL}
EOF
}

load_state() {
	[ -f "$STATE_FILE" ] || return 1
	# read, do not source: the values are not quoted
	PROVIDER_KEY=$(state_value "$STATE_FILE" PROVIDER_KEY)
	PROVIDER_NAME=$(state_value "$STATE_FILE" PROVIDER_NAME)
	SMTP_HOST=$(state_value "$STATE_FILE" SMTP_HOST)
	SMTP_PORT=$(state_value "$STATE_FILE" SMTP_PORT)
	SMTP_USER=$(state_value "$STATE_FILE" SMTP_USER)
	FROM_EMAIL=$(state_value "$STATE_FILE" FROM_EMAIL)
	return 0
}

# ============================================================================
# TEST EMAIL
# ============================================================================
# own Message-Id, find the queue id in the log, report what the provider answered

explain_smtp_error() {
	local reply="$1"
	echo ""
	case "$reply" in
		*535*|*[Aa]uthentication*|*"Username and Password not accepted"*|*"authentication failed"*|*5.7.8*)
			err "The provider refused the credentials."
			case "$PROVIDER_KEY" in
				gmail)    info "Gmail needs an App Password, not the account password." ;;
				sendgrid) info "The username must be the literal string 'apikey'." ;;
				mailjet)  info "Username = API Key, password = Secret Key." ;;
				brevo)    info "Use the SMTP key from Settings -> SMTP & API, not the login password." ;;
				*)        info "Double check the username and password with your provider." ;;
			esac
			info "Re-run setup_email.sh to enter them again."
			;;
		*"not allowed to relay"*|*"Sender address rejected"*|*554*|*"not verified"*|*"not validated"*)
			err "The provider accepted the login but refused the From address."
			info "Current From address: ${FROM_EMAIL}"
			info "It must be an address your account is allowed to send as (a verified sender or alias)."
			;;
		*"invalid sender domain"*|*"dominio mittente"*|*501*|*553*)
			err "The provider rejected the sender domain."
			info "Check the rewrite map: postmap -q \"@\$(hostname)\" hash:${CANONICAL_FILE}"
			;;
		*"Must issue a STARTTLS"*|*530*)
			err "The provider requires TLS before authenticating."
			info "If you are on port 465, re-run and confirm the port so wrappermode is enabled."
			;;
		*"Connection timed out"*|*"Network is unreachable"*|*"No route to host"*|*"Connection refused"*)
			err "Could not reach ${SMTP_HOST} on port ${SMTP_PORT}."
			info "Your host is blocking the port. Try 2525 or 465, or ask them to open it."
			;;
		*"certificate verification failed"*|*"Server certificate not trusted"*)
			err "TLS certificate verification failed."
			info "Run: apt-get install --reinstall ca-certificates"
			;;
		*)
			err "The provider rejected the message."
			;;
	esac
}

send_test_email() {
	local recipient="$1"
	step "Sending a test email to ${recipient}..."

	local host_fqdn since msgid
	host_fqdn=$(hostname -f 2>/dev/null || hostname)
	since=$(date '+%Y-%m-%d %H:%M:%S')
	msgid="freepbx-test-$(date +%s)-$$@${host_fqdn}"

	# Let journald settle so the "since" filter doesn't miss the first lines.
	sleep 1

	if ! printf 'Subject: FreePBX email test from %s\nFrom: %s\nTo: %s\nMessage-Id: <%s>\nX-Mailer: setup_email.sh %s\n\nThis is a test message from your FreePBX system (%s).\nIf you are reading it, outbound mail through %s works.\n\nSent at: %s\n' \
		"$host_fqdn" "$FROM_EMAIL" "$recipient" "$msgid" "$VERSION" \
		"$host_fqdn" "$PROVIDER_NAME" "$(date)" \
		| sendmail -t -i -f "$FROM_EMAIL"; then
		err "sendmail refused the message."
		info "Check: journalctl --facility=mail -n 30 --no-pager"
		return 1
	fi

	local qid="" status_line="" log i
	for ((i = 0; i < 30; i++)); do
		sleep 1
		log=$(mail_log_since "$since")

		if [ -z "$qid" ]; then
			qid=$(grep -F "message-id=<${msgid}>" <<<"$log" \
				| sed -nE 's/.*: ([0-9A-Za-z]+): message-id=<.*/\1/p' | tail -n1 || true)
			[ -n "$qid" ] || continue
		fi

		status_line=$(grep -E "[ :]${qid}: .*status=(sent|bounced|deferred|expired)" <<<"$log" | tail -n1 || true)
		[ -n "$status_line" ] && break
	done

	if [ -z "$qid" ]; then
		err "The message never reached the Postfix queue."
		local pd
		pd=$(mail_log_since "$since" | grep -i "postdrop" | tail -n3 || true)
		if [ -n "$pd" ]; then
			info "Postfix said:"
			# shellcheck disable=SC2001 # per-line prefix, sed is the right tool
			sed 's/^/    /' <<<"$pd"
			info "Run 'postfix set-permissions' and try again."
		else
			info "Check: journalctl --facility=mail -n 30 --no-pager"
		fi
		return 1
	fi

	local reply sasl_line
	reply=$(sed -nE 's/.*status=(bounced|deferred|expired) \((.*)\)[[:space:]]*$/\2/p' <<<"$status_line" || true)

	# the sasl failure sits on its own line and beats a later connect error
	sasl_line=$(grep -E "[ :]${qid}: SASL authentication failed" <<<"$log" | tail -n1 || true)
	if [ -n "$sasl_line" ]; then
		reply=$(sed -E 's/^.*: (SASL authentication failed)/\1/' <<<"$sasl_line")
	fi

	case "$status_line" in
		*status=sent*)
			ok "Delivered to ${PROVIDER_NAME} (queue id ${qid}, status=sent)."
			info "Check the inbox at ${recipient}, including the spam folder."
			return 0
			;;
		*status=bounced*)
			explain_smtp_error "$reply"
			echo ""
			info "Provider response:"
			echo "    ${reply:-$status_line}"
			return 1
			;;
		*status=deferred*)
			warn "The message was deferred; Postfix will keep retrying."
			explain_smtp_error "$reply"
			echo ""
			info "Provider response:"
			echo "    ${reply:-$status_line}"
			info "Watch the queue with: mailq"
			return 1
			;;
		*)
			warn "No delivery confirmation after 30 seconds (queue id ${qid})."
			info "Check the queue: mailq"
			info "Check the log:   journalctl --facility=mail --since '2 minutes ago' --no-pager"
			return 1
			;;
	esac
}

# asked up front with the other questions
decide_test_email() {
	[ "$DO_TEST" = true ] || return 0
	[ -z "$TEST_RECIPIENT" ] || return 0
	if [ "$ASSUME_YES" = true ]; then
		# nobody to ask, the sender is known to be deliverable
		TEST_RECIPIENT="$FROM_EMAIL"
		info "The test email will go to ${TEST_RECIPIENT} (use --test-to for another address)."
		return 0
	fi
	echo ""
	if ! confirm "Send a test email at the end to verify the relay works?" Y; then
		DO_TEST=false
		return 0
	fi
	ask_email "Recipient address [${FROM_EMAIL}]: " "$FROM_EMAIL" TEST_RECIPIENT
}

maybe_send_test_email() {
	[ "$DO_TEST" = true ] || return 0

	if send_test_email "$TEST_RECIPIENT"; then
		TEST_RESULT="ok"
	else
		TEST_RESULT="failed"
	fi
}

# ============================================================================
# STATUS AND REVERT
# ============================================================================

show_status() {
	echo ""
	echo -e "${CYAN}========================================================${NC}"
	echo -e "${CYAN}   FreePBX Email Status                                 ${NC}"
	echo -e "${CYAN}========================================================${NC}"
	echo ""

	if load_state; then
		echo -e "${BOLD}Saved configuration${NC}"
		info "Provider  : ${PROVIDER_NAME} (${SMTP_HOST}:${SMTP_PORT})"
		info "Username  : ${SMTP_USER}"
		info "From addr : ${FROM_EMAIL}"
	else
		warn "No saved configuration (${STATE_FILE} is missing)."
		info "Run setup_email.sh to configure the relay."
	fi

	echo ""
	echo -e "${BOLD}Postfix${NC}"
	if command -v postconf >/dev/null 2>&1; then
		local key
		for key in relayhost smtp_sasl_auth_enable smtp_tls_security_level sender_canonical_maps smtp_helo_name message_size_limit; do
			info "$(printf '%-26s %s' "$key" "$(postconf -h "$key" 2>/dev/null || echo '-')")"
		done
		if systemctl is-active --quiet postfix; then
			ok "postfix service is running"
		else
			err "postfix service is NOT running"
		fi
		# nothing else here would show a relayhost with no credentials
		if sasl_matches_relayhost; then
			ok "credentials match the configured relayhost"
		else
			err "no credentials for relayhost $(postconf -h relayhost 2>/dev/null)"
			info "Every message will bounce. Re-run setup_email.sh to fix it."
		fi
	else
		err "Postfix is not installed."
	fi

	echo ""
	echo -e "${BOLD}Mail submission permissions${NC}"
	if postfix_permissions_ok; then
		ok "postdrop is setgid and the maildrop queue is owned correctly"
	else
		err "postdrop permissions are wrong, run: postfix set-permissions"
	fi
	if asterisk_running; then
		if asterisk_has_postdrop_live; then
			ok "the running Asterisk process holds the postdrop group"
		elif asterisk_nnp_live; then
			err "Asterisk runs with NoNewPrivileges and without the postdrop group, its mail will not queue"
			info "Remove NoNewPrivileges from the asterisk unit, or re-run setup_email.sh"
		else
			ok "the running Asterisk process can queue mail through the setgid postdrop"
		fi
	else
		info "Asterisk is not running"
	fi

	echo ""
	echo -e "${BOLD}Asterisk voicemail sender${NC}"
	local f found=false
	for f in /etc/asterisk/vm_general.inc /etc/asterisk/voicemail.conf; do
		if [ -f "$f" ] && grep -qE "^[[:space:]]*serveremail[[:space:]]*=" "$f"; then
			info "$(printf '%-34s %s' "$f" "$(grep -E '^[[:space:]]*serveremail[[:space:]]*=' "$f" | tail -n1)")"
			found=true
		fi
	done
	[ "$found" = true ] || warn "no serveremail found in vm_general.inc or voicemail.conf"

	echo ""
	echo -e "${BOLD}Queue${NC}"
	info "$(mailq 2>/dev/null | tail -n1 || echo 'mailq unavailable')"

	echo ""
	echo -e "${BOLD}Recent mail log${NC}"
	local recent
	recent=$(mail_log_since "30 minutes ago" | grep -E "status=(sent|bounced|deferred|expired)" | tail -n8 || true)
	if [ -n "$recent" ]; then
		# shellcheck disable=SC2001 # per-line prefix, sed is the right tool
		sed 's/^/  /' <<<"$recent"
	else
		info "nothing in the last 30 minutes"
	fi
	echo ""
}

do_revert() {
	local latest
	# the suffix is a timestamp, so sorting backwards gives the newest first
	latest=$(find "$(dirname "$MAIN_CF")" -maxdepth 1 -name "$(basename "$MAIN_CF").bak.*" 2>/dev/null \
		| sort -r | head -n1 || true)
	[ -n "$latest" ] || die "No backup found (${MAIN_CF}.bak.*)."

	echo ""
	info "Most recent backup: ${latest}"
	# cp -a keeps the old mtime, the backup time is in the suffix
	local ts="${latest##*.bak.}"
	if [ "${#ts}" = 14 ]; then
		info "Taken: ${ts:0:4}-${ts:4:2}-${ts:6:2} ${ts:8:2}:${ts:10:2}:${ts:12:2}"
	else
		info "Taken: $(stat -c '%y' "$latest" 2>/dev/null | cut -d. -f1)"
	fi
	if [ -f "${SASL_FILE}.bak.${ts}" ] || [ -f "${SASL_FILE}.absent.${ts}" ]; then
		info "Credentials, sender map, saved config and voicemail sender go back with it."
	else
		warn "This backup predates the full backup set, so only ${MAIN_CF} goes back."
		warn "If its relayhost or sender differ from the current ones, mail will bounce"
		warn "until you re-run the setup."
	fi
	echo ""
	confirm "Restore it over the current ${MAIN_CF}?" N || die "Aborted."

	cp -a "$MAIN_CF" "${MAIN_CF}.before-revert.$(date +%Y%m%d%H%M%S)"
	cp -a "$latest" "$MAIN_CF"
	# before restore_companions replaces the state file it reads
	restore_voicemail_sender "$ts"
	restore_companions "$ts"
	systemctl restart postfix || warn "Postfix failed to restart, check: systemctl status postfix"
	ok "Restored ${latest}"
	warn_if_sasl_mismatch
}

# ============================================================================
# CLI
# ============================================================================

usage() {
	cat <<EOF
FreePBX Email Setup v${VERSION}

  setup_email.sh                      interactive setup
  setup_email.sh --status             show the current config and health checks
  setup_email.sh --test [ADDRESS]     send a test email using the saved config
  setup_email.sh --revert             restore the last main.cf backup

--revert asks for confirmation, so from cron or a non-interactive ssh it needs
--yes as well. --test falls back to the saved sender when there is no terminal.

Non-interactive setup:

  --provider NAME     gmail | brevo | aruba | sendgrid | mailjet | custom
  --host HOST         SMTP host (required with --provider custom)
  --port PORT         SMTP port (default 587)
  --user USER         SMTP username
  --pass PASS         SMTP password (visible in the process list, prefer the options below)
  --pass-file FILE    read the password from the first line of FILE
  --pass-env VAR      read the password from the environment variable VAR
  --from ADDRESS      sender address (default: the SMTP username)
  --test-to ADDRESS   address for the test email
  --no-test           skip the test email
  --root-alias        forward root's system mail to the sender address
  --no-root-alias     leave /etc/aliases alone
  -y, --yes           answer yes to every confirmation
  --force             with --yes, carry on even if the SMTP port is unreachable

Example:

  SMTP_PASSWORD='...' setup_email.sh --provider brevo \\
      --user me@example.com --from pbx@example.com \\
      --pass-env SMTP_PASSWORD --test-to admin@example.com --yes
EOF
}

# a missing value must not swallow the next flag
need_value() { [[ -n "${2:-}" && "$2" != -* ]] || die "$1 needs a value"; }

parse_args() {
	while [ $# -gt 0 ]; do
		case "$1" in
			--status)        MODE="status" ;;
			--revert)        MODE="revert" ;;
			--test)
				MODE="test"
				if [ $# -gt 1 ] && [[ "$2" != -* ]]; then
					TEST_RECIPIENT="$2"; shift
				fi
				;;
			--provider)      need_value "$@"; apply_provider "$2"; shift ;;
			--host)          need_value "$@"; SMTP_HOST="$2"; shift ;;
			--port)          need_value "$@"; SMTP_PORT="$2"; PORT_EXPLICIT=true; shift ;;
			--user)          need_value "$@"; SMTP_USER="$2"; shift ;;
			# a password may start with a dash, so only an empty one is refused
			--pass)          [ -n "${2:-}" ] || die "--pass needs a value"; SMTP_PASS="$2"; shift ;;
			--pass-file)
				need_value "$@"
				[ -r "$2" ] || die "Cannot read ${2}"
				SMTP_PASS=$(head -n1 "$2"); shift ;;
			--pass-env)
				[[ "${2:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "--pass-env needs a variable name"
				SMTP_PASS="${!2:-}"; shift ;;
			--from)          need_value "$@"; FROM_EMAIL="$2"; shift ;;
			--test-to)       need_value "$@"; TEST_RECIPIENT="$2"; shift ;;
			--no-test)       DO_TEST=false ;;
			--root-alias)    DO_ROOT_ALIAS=true ;;
			--no-root-alias) DO_ROOT_ALIAS=false ;;
			-y|--yes)        ASSUME_YES=true ;;
			--force)         FORCE=true ;;
			-h|--help)       usage; exit 0 ;;
			*)               die "Unknown option: $1 (try --help)" ;;
		esac
		shift
	done
}

show_banner() {
	echo ""
	echo -e "${CYAN}========================================================${NC}"
	echo -e "${CYAN}   FreePBX Email Setup - SMTP Relay Configuration       ${NC}"
	echo -e "${CYAN}========================================================${NC}"
	echo ""
	info "Most VPS providers block outbound port 25, so Postfix cannot deliver"
	info "mail on its own. This configures it to relay through your provider."
	echo ""
	info "Once it is done, voicemail-to-email, fax-to-email and system alerts"
	info "are delivered through your account."
	echo ""
}

print_summary() {
	echo ""
	if [ "$TEST_RESULT" = "failed" ]; then
		echo -e "${YELLOW}========================================================${NC}"
		echo -e "${YELLOW}   Relay configured, but the test email did NOT arrive  ${NC}"
		echo -e "${YELLOW}========================================================${NC}"
		echo ""
		info "Fix whatever the error above points at, then re-run this script"
		info "or just retry the delivery with: setup_email.sh --test ${TEST_RECIPIENT}"
		echo ""
	else
		echo -e "${GREEN}========================================================${NC}"
		echo -e "${GREEN}   Email setup complete                                 ${NC}"
		echo -e "${GREEN}========================================================${NC}"
		echo ""
	fi
	info "Provider  : ${PROVIDER_NAME} (${SMTP_HOST}:${SMTP_PORT})"
	info "From addr : ${FROM_EMAIL}"
	info "Config    : ${STATE_FILE}"
	echo ""
	info "Check the setup any time : setup_email.sh --status"
	info "Send another test email  : setup_email.sh --test you@example.com"
	info "Undo the Postfix changes : setup_email.sh --revert"
	echo ""
	warn "The SMTP password is stored in ${SASL_FILE} (root only, readable in clear)."
	info "Postfix needs it there to authenticate against the relay, so it cannot be"
	info "encrypted: anything the machine can decrypt unattended, an intruder can too."
	case "$PROVIDER_KEY" in
		brevo|sendgrid|mailjet) : ;;
		*)
			info "What limits the damage is the kind of credential, not where it sits."
			info "A send-only API key from Brevo, SendGrid or Mailjet can only send mail"
			info "and is revoked in one click. A mailbox password also reads your mail."
			info "  $(link https://www.brevo.com)   free tier, 300 emails/day"
			;;
	esac
	echo ""
}

# ============================================================================

main() {
	parse_args "$@"
	check_root

	case "$MODE" in
		status)
			show_status
			exit 0
			;;
		revert)
			do_revert
			exit 0
			;;
		test)
			load_state || die "No saved configuration. Run setup_email.sh first."
			# nobody to ask from cron or ssh, the saved sender is the target
			if [ -z "$TEST_RECIPIENT" ]; then
				if tty_available; then
					ask_email "Recipient address [${FROM_EMAIL}]: " "$FROM_EMAIL" TEST_RECIPIENT
				else
					TEST_RECIPIENT="$FROM_EMAIL"
				fi
			fi
			if send_test_email "$TEST_RECIPIENT"; then exit 0; else exit 1; fi
			;;
	esac

	show_banner
	check_postfix

	# a previous run exists, start over only if asked
	if [ -z "$PROVIDER_KEY" ] && [ -z "$SMTP_HOST" ] && load_state 2>/dev/null; then
		info "Found a previous configuration for ${PROVIDER_NAME} (${SMTP_USER})."
		if ! confirm "Reconfigure from scratch?" Y; then
			die "Nothing to do. Use --status to inspect it or --test to send a test email."
		fi
		SMTP_HOST=""; SMTP_PORT=""; SMTP_USER=""; FROM_EMAIL=""; PROVIDER_KEY=""; PROVIDER_NAME=""
		echo ""
	fi

	[ -n "$PROVIDER_KEY" ] || select_provider
	[ -n "$SMTP_HOST" ] || die "No SMTP host. Pass --host with --provider custom."

	if [ -z "$SMTP_USER" ] || [ -z "$SMTP_PASS" ]; then
		collect_credentials
	fi
	normalise_credentials
	decide_root_alias
	decide_test_email

	precheck_connectivity
	configure_postfix
	fix_postfix_permissions
	configure_freepbx_email
	configure_root_alias
	save_state
	offer_asterisk_restart
	maybe_send_test_email
	print_summary
}

main "$@"
