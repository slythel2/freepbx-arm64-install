#!/bin/bash

# ============================================================================
# SCRIPT:    setup_https.sh
# PROJECT:   FreePBX 17 ARM64 Installation Script (Asterisk 22 LTS)
# Apache HTTPS for the FreePBX admin, Let's Encrypt or self signed.
# ============================================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

LOG_FOLDER="/var/log/pbx"
LOG_FILE="${LOG_FOLDER}/setup_https-$(date '+%Y.%m.%d-%H.%M.%S').log"
VHOST_SSL=/etc/apache2/sites-available/freepbx-ssl.conf
VHOST_HTTP=/etc/apache2/sites-available/freepbx.conf
ACME_ROOT=/var/www/letsencrypt
STATE=/etc/freepbx-https.conf

HOSTNAME_FQDN=""
EMAIL=""
SELFSIGNED=false
REDIRECT=true
ASSUME_YES=false
STAGING=false
SHOW_STATUS=false

echo_ts() { echo "$(date +"%Y-%m-%d %T") - $*"; }
log()     { echo_ts "$*" >> "$LOG_FILE"; }
message() { echo_ts "$*" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[WARNING] $1${NC}" | tee -a "$LOG_FILE"; }
die()     { echo -e "${RED}[ERROR] $1${NC}" | tee -a "$LOG_FILE"; exit 1; }

usage() {
	cat <<EOF
Usage: setup_https.sh [OPTIONS]

Sets up HTTPS on the FreePBX admin interface.

  --hostname FQDN   public name of this PBX, must already resolve here
  --email ADDR      contact for the Let's Encrypt account, optional
  --selfsigned      skip Let's Encrypt, use a self signed certificate
  --no-redirect     leave plain HTTP working instead of redirecting to HTTPS,
                    re-runs without --hostname keep it
  --staging         use the Let's Encrypt staging CA, for testing the flow
  --yes             no questions, for unattended runs
  --status          show what is configured now and exit
  --help            this

With no --hostname it asks for one. Unattended, it keeps the Let's Encrypt name
set up last time, or uses a self signed certificate, which encrypts the traffic
but makes the browser complain. Let's Encrypt needs a real DNS name pointing at
this box and port 80 reachable from the internet.
EOF
}

# a missing value must not swallow the next flag
need_value() { [[ -n "${2:-}" && "$2" != -* ]] || { echo "$1 needs a value"; exit 1; }; }

while [[ $# -gt 0 ]]; do
	case $1 in
		--hostname) need_value "$@"; HOSTNAME_FQDN="$2"; shift 2 ;;
		--email)    need_value "$@"; EMAIL="$2"; shift 2 ;;
		--selfsigned) SELFSIGNED=true; shift ;;
		--no-redirect) REDIRECT=false; shift ;;
		--staging)  STAGING=true; shift ;;
		--yes|-y)   ASSUME_YES=true; shift ;;
		--status)   SHOW_STATUS=true; shift ;;
		--help|-h)  usage; exit 0 ;;
		*) echo "Unknown option: $1"; usage; exit 1 ;;
	esac
done

if [[ $EUID -ne 0 ]]; then
	echo -e "${RED}[ERROR] This script must be run as root.${NC}"
	exit 1
fi

# read, do not source: the values end up in apache config
state_get() {
	awk -F= -v k="$1" '$1 == k {print substr($0, length(k) + 2)}' "$STATE" 2>/dev/null
}

# ---------------------------------------------------------------------- status
show_status() {
	echo "========================================================"
	echo "  HTTPS STATUS"
	echo "========================================================"
	[ -f "$STATE" ] && { echo "  config:"; sed 's/^/    /' "$STATE"; }
	echo -n "  apache ssl module : "; a2query -m ssl > /dev/null 2>&1 && echo "enabled" || echo "NOT enabled"
	echo -n "  ssl vhost         : "; a2query -s freepbx-ssl > /dev/null 2>&1 && echo "enabled" || echo "NOT enabled"
	echo -n "  listening on 443  : "; ss -lnt 2>/dev/null | grep -q ':443 ' && echo "yes" || echo "NO"
	if command -v certbot > /dev/null 2>&1; then
		echo "  certificates:"
		certbot certificates 2>/dev/null | grep -E 'Certificate Name|Domains|Expiry' | sed 's/^ */    /'
		echo -n "  renewal timer     : "
		systemctl is-enabled --quiet certbot.timer 2>/dev/null && echo "enabled" || echo "NOT enabled"
	else
		echo "  certbot           : not installed"
	fi
	local cert
	cert=$(awk -F'[ \t]+' '/SSLCertificateFile/ {print $NF}' "$VHOST_SSL" 2>/dev/null | head -1)
	if [ -n "$cert" ] && [ -f "$cert" ]; then
		echo "  vhost cert        : $cert"
		echo "    $(openssl x509 -noout -subject -issuer -enddate -in "$cert" 2>/dev/null | tr '\n' ' ')"
	fi
	echo -n "  http redirect     : "; grep -qF '# setup_https: redirect' "$VHOST_HTTP" 2>/dev/null && echo "on" || echo "off"
	echo "========================================================"
}
[ "$SHOW_STATUS" = true ] && { show_status; exit 0; }

mkdir -p "$LOG_FOLDER" && touch "$LOG_FILE"

# ------------------------------------------------------------------- pre-flight
command -v apache2ctl > /dev/null 2>&1 || die "Apache is not installed."
[ -f "$VHOST_HTTP" ] || warn "freepbx.conf vhost not found, is this a FreePBX box?"

is_ipv4() { [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; }

# behind nat the local address says nothing about the public one
is_private_ipv4() { [[ "$1" =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.) ]]; }

# this box's address as the internet sees it, empty when it cannot tell.
# dig prints its errors on stdout, so only an address counts
public_ip() {
	local ip
	ip=$(dig +short +time=3 +tries=1 myip.opendns.com @resolver1.opendns.com 2>/dev/null | tail -1)
	is_ipv4 "$ip" || ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null)
	is_ipv4 "$ip" || ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}')
	if ! is_ipv4 "$ip" || is_private_ipv4 "$ip"; then
		ip=""
	fi
	echo "$ip"
}

# ---------------------------------------------------------------- ssl plumbing
enable_ssl_module() {
	if ! a2query -m ssl > /dev/null 2>&1; then
		message "Enabling Apache mod_ssl..."
		a2enmod ssl >> "$LOG_FILE" 2>&1
	fi
}

write_vhost() {
	local crt="$1" key="$2"
	message "Writing the HTTPS vhost..."
	{
		echo "<VirtualHost *:443>"
		[ -n "$HOSTNAME_FQDN" ] && echo "    ServerName $HOSTNAME_FQDN"
		echo "    DocumentRoot /var/www/html"
		echo "    SSLEngine on"
		echo "    SSLCertificateFile $crt"
		echo "    SSLCertificateKeyFile $key"
		cat <<'EOF'
    SSLProtocol -all +TLSv1.2 +TLSv1.3
    SSLHonorCipherOrder off
    SSLSessionTickets off

    RewriteEngine On
    RewriteCond %{REQUEST_URI} ^/$
    RewriteRule ^/$ /admin [R=302,L]

    <Directory /var/www/html>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog ${APACHE_LOG_DIR}/freepbx-ssl-error.log
    CustomLog ${APACHE_LOG_DIR}/freepbx-ssl-access.log combined
</VirtualHost>
EOF
	} > "$VHOST_SSL"
	# debian's default-ssl also claims *:443 and loads first, so it would win
	if a2query -s default-ssl > /dev/null 2>&1; then
		message "Disabling Debian's default-ssl vhost, it would shadow ours..."
		a2dissite default-ssl >> "$LOG_FILE" 2>&1
	fi
	a2ensite freepbx-ssl >> "$LOG_FILE" 2>&1
}

# insert a block just before the closing </VirtualHost>. ENVIRON, not -v,
# or awk eats the backslashes
insert_in_vhost() {
	local file="$1"
	local tmp="${file}.new"
	BLK="$2" awk 'BEGIN{blk=ENVIRON["BLK"]}
		/<\/VirtualHost>/ && !done { printf "%s", blk; done=1 }
		{ print }' "$file" > "$tmp" && mv "$tmp" "$file"
}

# the acme challenge gets its own directory, so nothing FreePBX does to the
# docroot or a stray .htaccess can break a renewal
add_acme_alias() {
	mkdir -p "$ACME_ROOT/.well-known/acme-challenge"
	chmod -R 755 "$ACME_ROOT"
	grep -qF '# setup_https: acme' "$VHOST_HTTP" && return
	message "Adding the ACME challenge alias to the HTTP vhost..."
	insert_in_vhost "$VHOST_HTTP" "    # setup_https: acme
    Alias /.well-known/acme-challenge/ ${ACME_ROOT}/.well-known/acme-challenge/
    <Directory ${ACME_ROOT}/.well-known/acme-challenge/>
        Options None
        AllowOverride None
        Require all granted
    </Directory>
"
}

set_redirect() {
	if [ "$REDIRECT" != true ]; then
		if grep -qF '# setup_https: redirect' "$VHOST_HTTP"; then
			message "Removing the HTTP to HTTPS redirect..."
			sed -i '/# setup_https: redirect/,+2d' "$VHOST_HTTP"
		fi
		return 0
	fi
	grep -qF '# setup_https: redirect' "$VHOST_HTTP" && return
	message "Redirecting plain HTTP to HTTPS..."
	# acme-challenge stays on plain HTTP or renewals stop working
	insert_in_vhost "$VHOST_HTTP" '    # setup_https: redirect
    RewriteCond %{REQUEST_URI} !^/\.well-known/acme-challenge/
    RewriteRule ^(.*)$ https://%{HTTP_HOST}$1 [R=301,L]
'
}

reload_apache() {
	if apache2ctl configtest >> "$LOG_FILE" 2>&1; then
		systemctl reload-or-restart apache2
	else
		apache2ctl configtest 2>&1 | tail -5
		die "Apache config test failed, nothing was reloaded. See $LOG_FILE"
	fi
}

# apache whines on every configtest without a global ServerName
set_global_servername() {
	[ -n "$HOSTNAME_FQDN" ] || return
	echo "ServerName $HOSTNAME_FQDN" > /etc/apache2/conf-available/servername.conf
	a2enconf servername >> "$LOG_FILE" 2>&1 || true
}

# ------------------------------------------------------------------ self signed
use_snakeoil() {
	local crt=/etc/ssl/certs/ssl-cert-snakeoil.pem
	local key=/etc/ssl/private/ssl-cert-snakeoil.key
	if [ ! -f "$crt" ] || [ ! -f "$key" ]; then
		message "Generating a self signed certificate..."
		apt-get install -y ssl-cert >> "$LOG_FILE" 2>&1 || true
		make-ssl-cert generate-default-snakeoil --force-overwrite >> "$LOG_FILE" 2>&1
	fi
	enable_ssl_module
	write_vhost "$crt" "$key"
}

do_selfsigned() {
	use_snakeoil
	reload_apache
	printf 'MODE=selfsigned\nCONFIGURED=%s\n' "$(date -Is)" > "$STATE"
	chmod 644 "$STATE"
	echo
	echo -e "${GREEN}HTTPS is on with a self signed certificate.${NC}"
	echo "The browser will warn about it: the traffic is encrypted, the identity is not proven."
	echo "For a certificate without warnings, point a DNS name here and run:"
	echo "  setup_https.sh --hostname pbx.example.com --email you@example.com"
}

# ---------------------------------------------------------------- let's encrypt
check_dns() {
	local resolved mine
	resolved=$(dig +short +time=3 +tries=2 A "$HOSTNAME_FQDN" 2>/dev/null | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$')
	mine=$(public_ip)
	if [ -z "$resolved" ]; then
		warn "$HOSTNAME_FQDN does not resolve to anything."
		return 1
	fi
	message "$HOSTNAME_FQDN resolves to ${resolved//$'\n'/ }, this box looks like ${mine:-unknown}"
	if [ -n "$mine" ] && ! grep -qxF "$mine" <<<"$resolved"; then
		warn "The name does not point at this box. Let's Encrypt will fail."
		return 1
	fi
	return 0
}

# a cert for this name valid one more day, of the kind asked for, beats self signed
current_cert_ok() {
	local live="/etc/letsencrypt/live/${HOSTNAME_FQDN}" staged=false
	[ -f "$live/fullchain.pem" ] || return 1
	openssl x509 -checkend 86400 -noout -in "$live/fullchain.pem" > /dev/null 2>&1 || return 1
	grep -qs 'acme-staging' "/etc/letsencrypt/renewal/${HOSTNAME_FQDN}.conf" && staged=true
	[ "$staged" = "$STAGING" ]
}

keep_current_cert() {
	warn "Keeping the current certificate for $HOSTNAME_FQDN, it is still valid. certbot.timer will try again."
	finish_letsencrypt
}

do_letsencrypt() {
	# certbot stores the name in lower case
	HOSTNAME_FQDN="${HOSTNAME_FQDN,,}"
	if [ ! -f "$VHOST_HTTP" ]; then
		warn "No $VHOST_HTTP to serve the ACME challenge from, falling back to a self signed certificate."
		do_selfsigned
		return
	fi

	# a vhost left pointing at a deleted certificate fails every configtest below
	local cur
	cur=$(awk '/SSLCertificateFile/ {print $NF}' "$VHOST_SSL" 2>/dev/null | head -1)
	if [ -n "$cur" ] && [ ! -f "$cur" ]; then
		warn "The HTTPS vhost points at a missing $cur, putting the self signed one in first."
		use_snakeoil
	fi

	if ! command -v certbot > /dev/null 2>&1; then
		message "Installing certbot..."
		apt-get update -qq >> "$LOG_FILE" 2>&1
		apt-get install -y certbot >> "$LOG_FILE" 2>&1 || die "Could not install certbot."
	fi

	enable_ssl_module
	set_global_servername
	add_acme_alias
	reload_apache

	if ! check_dns; then
		echo
		echo "Let's Encrypt validates by fetching a file over plain HTTP from"
		echo "http://${HOSTNAME_FQDN}/.well-known/acme-challenge/ , so it needs:"
		echo "  - an A record for $HOSTNAME_FQDN pointing at this box"
		echo "  - port 80 open to the whole internet, not just your IP"
		local a=""
		# nobody to ask counts as no
		if [ "$ASSUME_YES" != true ] && ( : <>/dev/tty ) 2>/dev/null; then
			read -rp "Try anyway? [y/N]: " a < /dev/tty || a=""
		fi
		if [[ ! "$a" =~ ^[Yy] ]]; then
			current_cert_ok && { keep_current_cert; return; }
			warn "Falling back to a self signed certificate."
			do_selfsigned
			return
		fi
	fi

	local args=(certonly --webroot -w "$ACME_ROOT" -d "$HOSTNAME_FQDN"
		--agree-tos --non-interactive --keep-until-expiring
		--deploy-hook "systemctl reload apache2")
	if [ -n "$EMAIL" ]; then
		args+=(--email "$EMAIL")
	else
		# let's encrypt stopped expiry mails in 2025, the address is only the account contact
		args+=(--register-unsafely-without-email)
		log "No --email given, the Let's Encrypt account has no contact address."
	fi
	[ "$STAGING" = true ] && args+=(--staging)

	# a staging cert on the same name is not due for renewal, so certbot would
	# keep it and we would serve a TEST_CERT thinking it went fine
	if [ "$STAGING" != true ] && grep -qs 'acme-staging' "/etc/letsencrypt/renewal/${HOSTNAME_FQDN}.conf"; then
		message "Found a staging certificate for $HOSTNAME_FQDN, replacing it with a real one..."
		args+=(--force-renewal)
	fi

	message "Asking Let's Encrypt for a certificate for $HOSTNAME_FQDN..."
	echo
	certbot "${args[@]}" 2>&1 | tee -a "$LOG_FILE"
	local rc=${PIPESTATUS[0]}
	echo
	if [ "$rc" -ne 0 ]; then
		warn "certbot failed. Its own log is /var/log/letsencrypt/letsencrypt.log"
		current_cert_ok && { keep_current_cert; return; }
		warn "Falling back to a self signed certificate so HTTPS still works."
		do_selfsigned
		return
	fi
	finish_letsencrypt
}

finish_letsencrypt() {
	local live="/etc/letsencrypt/live/${HOSTNAME_FQDN}"
	[ -f "$live/fullchain.pem" ] || die "certbot reported success but $live/fullchain.pem is missing."

	write_vhost "$live/fullchain.pem" "$live/privkey.pem"
	set_redirect
	reload_apache

	# debian ships the timer, make sure it is actually on
	systemctl enable --now certbot.timer >> "$LOG_FILE" 2>&1 || warn "Could not enable certbot.timer, renewals may not run."

	printf 'MODE=letsencrypt\nFQDN=%s\nEMAIL=%s\nSTAGING=%s\nREDIRECT=%s\nCONFIGURED=%s\n' \
		"$HOSTNAME_FQDN" "${EMAIL:-none}" "$STAGING" "$REDIRECT" "$(date -Is)" > "$STATE"
	chmod 644 "$STATE"

	echo
	if [ "$STAGING" = true ]; then
		echo -e "${YELLOW}HTTPS is on with a Let's Encrypt STAGING certificate, browsers will not trust it.${NC}"
	else
		echo -e "${GREEN}HTTPS is on with a Let's Encrypt certificate.${NC}"
	fi
	echo "  https://${HOSTNAME_FQDN}/admin"
	certbot certificates 2>/dev/null | grep -E 'Domains|Expiry' | sed 's/^ */  /'
	echo "  renewal: certbot.timer, twice a day, reloads apache on success"
	echo "  dry run: certbot renew --dry-run"
}

# ------------------------------------------------------------------------ main
echo "========================================================"
echo "          FREEPBX HTTPS SETUP"
echo "========================================================"

# what the last let's encrypt run used, so a re-run does not throw it away
SAVED_FQDN="" SAVED_EMAIL="" SAVED_REDIRECT=""
if [ "$(state_get MODE)" = letsencrypt ]; then
	SAVED_FQDN=$(state_get FQDN)
	SAVED_EMAIL=$(state_get EMAIL)
	SAVED_REDIRECT=$(state_get REDIRECT)
	[ "$SAVED_EMAIL" = none ] && SAVED_EMAIL=""
fi

if [ "$SELFSIGNED" = true ]; then
	do_selfsigned
elif [ -n "$HOSTNAME_FQDN" ]; then
	do_letsencrypt
elif [ "$ASSUME_YES" = true ] || [ ! -t 0 ]; then
	if [ -n "$SAVED_FQDN" ]; then
		message "No hostname given, keeping the Let's Encrypt setup for $SAVED_FQDN."
		HOSTNAME_FQDN="$SAVED_FQDN"
		[ -n "$EMAIL" ] || EMAIL="$SAVED_EMAIL"
		[ "$(state_get STAGING)" = true ] && STAGING=true
		# phones provisioning over plain http break if a re-run turns the redirect back on
		[ "$SAVED_REDIRECT" = false ] && REDIRECT=false
		do_letsencrypt
	else
		message "No hostname given, using a self signed certificate."
		do_selfsigned
	fi
else
	echo
	echo "A Let's Encrypt certificate needs a DNS name that already points here."
	echo "Leave it empty to use a self signed certificate instead."
	read -rp "Hostname for this PBX${SAVED_FQDN:+ [$SAVED_FQDN]} (e.g. pbx.example.com): " HOSTNAME_FQDN < /dev/tty
	HOSTNAME_FQDN="${HOSTNAME_FQDN:-$SAVED_FQDN}"
	[ -n "$SAVED_FQDN" ] && [ "$HOSTNAME_FQDN" = "$SAVED_FQDN" ] && [ "$SAVED_REDIRECT" = false ] && REDIRECT=false
	if [ -n "$HOSTNAME_FQDN" ]; then
		read -rp "Email for the Let's Encrypt account (optional)${SAVED_EMAIL:+ [$SAVED_EMAIL]}: " EMAIL < /dev/tty
		EMAIL="${EMAIL:-$SAVED_EMAIL}"
		do_letsencrypt
	else
		do_selfsigned
	fi
fi

echo
echo "Check anytime with: setup_https.sh --status"
exit 0
