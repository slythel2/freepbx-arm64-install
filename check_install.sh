#!/bin/bash

# ============================================================================
# SCRIPT:    check_install.sh
# PROJECT:   FreePBX 17 ARM64 Installation Script (Asterisk 22 LTS)
# Post-install checks. Read only, changes nothing.
# ============================================================================

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
pass=0; fail=0; warned=0

ok()   { echo -e "  ${GREEN}ok  ${NC} $1"; pass=$((pass+1)); }
ko()   { echo -e "  ${RED}FAIL${NC} $1"; fail=$((fail+1)); }
note() { echo -e "  ${YELLOW}note${NC} $1"; warned=$((warned+1)); }
info() { echo -e "  ---- $1"; }
head2() { echo; echo "== $1"; }

[ "$EUID" -ne 0 ] && echo "run as root" && exit 1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "========================================================"
echo "  POST-INSTALL CHECK"
echo "========================================================"

# ---------------------------------------------------------------- hardware
head2 "hardware"
RAM=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 ))
ROOT_SRC=$(findmnt -no SOURCE / 2>/dev/null)
MODEL=$([ -f /proc/device-tree/model ] && tr -d '\0' < /proc/device-tree/model || echo "no device-tree")
info "${MODEL}, ${RAM}MB RAM, root on ${ROOT_SRC}"
info "$(uname -m), $(. /etc/os-release && echo "$PRETTY_NAME")"

# -------------------------------------------------------------------- swap
head2 "swap"
swapon --show 2>/dev/null | sed 's/^/       /'
if swapon --show=NAME --noheadings 2>/dev/null | grep -q zram; then
	ok "zram active"
	zramctl 2>/dev/null | sed 's/^/       /'
	algo=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null | grep -o '\[[a-z0-9]*\]' | tr -d '[]')
	[ "$algo" = zstd ] && ok "compression is zstd" || note "compression is ${algo:-unknown}, not zstd"
	prio=$(awk '/zram/ {print $5}' /proc/swaps 2>/dev/null | head -1)
	[ "${prio:-0}" -ge 100 ] 2>/dev/null && ok "zram priority $prio" || note "zram priority ${prio:-unknown}, expected 100"
	sw=$(sysctl -n vm.swappiness)
	[ "$sw" = 100 ] && ok "swappiness 100" || ko "swappiness $sw, expected 100 on zram"
	pc=$(sysctl -n vm.page-cluster)
	[ "$pc" = 0 ] && ok "page-cluster 0" || ko "page-cluster $pc, expected 0"
	other=$(grep -vc 'zram\|Filename' /proc/swaps)
	[ "$other" -gt 0 ] && info "plus $other disk swap as backstop" || info "no disk swap backstop"
elif swapon --show=NAME --noheadings 2>/dev/null | grep -q .; then
	ok "disk swap active"
	case "$ROOT_SRC" in
		/dev/mmcblk*) ko "root is on a card and swap is on disk, zram should have been used" ;;
	esac
	sw=$(sysctl -n vm.swappiness)
	# the installer leaves swap it did not create alone, swappiness included
	if [ -f /etc/sysctl.d/99-swap.conf ]; then
		[ "$sw" = 10 ] && ok "swappiness 10" || ko "swappiness $sw, expected 10 on disk swap"
	else
		note "swap was already there, swappiness left at $sw"
	fi
else
	[ "$RAM" -gt 4096 ] && ok "no swap, over 4GB of RAM" || ko "no swap at all on a ${RAM}MB box"
fi

# ------------------------------------------------------------------ sysctl
head2 "sysctl"
[ -f /etc/sysctl.d/99-asterisk.conf ] && ok "99-asterisk.conf present" || ko "99-asterisk.conf missing"
res=$(sysctl -n net.ipv4.ip_local_reserved_ports 2>/dev/null)
[ "$res" = "10000-20000" ] && ok "RTP ports reserved: $res" || ko "reserved ports are '${res:-empty}', expected 10000-20000"
rng=$(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null | tr -s ' \t' ' ')
lo=${rng%% *}
[ "${lo:-0}" -gt 20000 ] 2>/dev/null && ok "ephemeral range $rng, clear of RTP" || ko "ephemeral range '$rng' overlaps the RTP ports"
grep -qE '^[[:space:]]*net[.]netfilter[.]nf_conntrack_helper' /etc/sysctl.d/99-asterisk.conf 2>/dev/null \
	&& ko "nf_conntrack_helper is in 99-asterisk.conf, kernel 6.0 removed it" \
	|| ok "no nf_conntrack_helper line"
if [ "$RAM" -le 2048 ]; then
	grep -q 'rmem_max = 4194304' /etc/sysctl.d/99-asterisk.conf 2>/dev/null \
		&& ok "socket buffers trimmed for a ${RAM}MB box" || ko "buffers not trimmed on a ${RAM}MB box"
fi
# compared one by one, sysctl --system would apply the files
stale=""
while read -r key val; do
	[ "$(sysctl -n "$key" 2>/dev/null | tr -s ' \t' ' ')" = "$val" ] || stale+=" $key"
done < <(sed -n -E 's/^[[:space:]]*([a-z0-9_.]+)[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1 \2/p' /etc/sysctl.d/99-asterisk.conf 2>/dev/null)
[ -z "$stale" ] && ok "every setting in 99-asterisk.conf is live" || ko "in 99-asterisk.conf but not applied:$stale"

# ------------------------------------------------------------------ systemd
head2 "asterisk.service"
# systemd renders some of these in microseconds and some human readable
chk() {
	local k="$1" got
	shift
	got=$(systemctl show asterisk -p "$k" --value 2>/dev/null)
	for want in "$@"; do
		[ "$got" = "$want" ] && { ok "$k=$got"; return; }
	done
	ko "$k is '$got', expected $*"
}
# the directive is StartLimitIntervalSec=, the property systemd exposes is USec

chk Restart on-failure
chk StartLimitBurst 3
chk StartLimitIntervalUSec 1min 60s 60000000
chk TimeoutStopUSec 30s 30000000
chk LimitNOFILE 65536
# with it on, postdrop loses its setgid and voicemail mail never queues
chk NoNewPrivileges no
systemctl show asterisk -p ExecStop --value 2>/dev/null | grep -q 'core stop gracefully' \
	&& ok "ExecStop set" || ko "ExecStop missing, a reboot will kill calls"
journalctl -b -u asterisk --no-pager 2>/dev/null | grep -qi 'unknown key\|ignoring' \
	&& ko "systemd complained about a key in the unit, see journalctl -u asterisk" \
	|| ok "no unknown-key warnings from systemd"

# ------------------------------------------------------------------ services
head2 "services"
for s in asterisk mariadb apache2 freepbx fail2ban; do
	systemctl is-enabled --quiet "$s" 2>/dev/null && e=enabled || e="NOT enabled"
	systemctl is-active  --quiet "$s" 2>/dev/null && a=active  || a="NOT active"
	[ "$e" = enabled ] && [ "$a" = active ] && ok "$s $e, $a" || ko "$s $e, $a"
done

# ------------------------------------------------------------------ asterisk
head2 "asterisk"
if v=$(asterisk -rx "core show version" 2>/dev/null); then
	ok "CLI responds: $(echo "$v" | head -1)"
else
	ko "asterisk CLI not responding"
fi
grep -qE '^[[:space:]]*minmemfree[[:space:]]*=' /etc/asterisk/asterisk.conf 2>/dev/null \
	&& ko "minmemfree is active in asterisk.conf, calls will be refused" \
	|| ok "no active minmemfree"
# safe_asterisk passes -vvv, without it the full log gets no call flow
vb=$(asterisk -rx "core show settings" 2>/dev/null | awk '/Root console verbosity/ {print $NF}')
[ "${vb:-0}" -ge 3 ] 2>/dev/null && ok "verbosity $vb, calls reach the full log" \
	|| ko "verbosity is ${vb:-unknown}, the full log gets no call flow"
asterisk -rx "logger show channels" 2>/dev/null | grep -q '^/var/log/asterisk/full .*VERBOSE' \
	&& ok "the full log takes verbose" || ko "the full log has no verbose level, see Asterisk Logfile Settings"
# the artifact used to turn the /var/run symlink into a directory on disk
if [ "$(readlink -f /var/run)" = /run ]; then
	ok "/var/run points at /run"
	[ -f /etc/tmpfiles.d/asterisk.conf ] && ok "/run/asterisk comes back at boot" \
		|| ko "nothing recreates /run/asterisk, asterisk loses its control socket at the next reboot"
else
	ko "/var/run is a directory on disk, pid files survive reboots and old D-Bus clients fail"
fi
unit_of() { cut -d: -f3 "/proc/${1}/cgroup" 2>/dev/null | head -1; }
# fwconsole start puts asterisk under safe_asterisk in the caller's cgroup, outside the unit's limits
astcg=$(unit_of "$(pgrep -x asterisk | head -1)")
case "$astcg" in
	*asterisk.service) ok "asterisk runs inside asterisk.service" ;;
	"") ;;
	*) note "asterisk runs outside its unit ($astcg), systemctl stop freepbx, start asterisk, start freepbx" ;;
esac
nofile=$(cat /proc/$(pgrep -x asterisk | head -1)/limits 2>/dev/null | awk '/open files/ {print $4}')
[ "${nofile:-0}" -ge 65536 ] 2>/dev/null && ok "asterisk nofile $nofile" || ko "asterisk nofile is ${nofile:-unknown}, expected 65536"
# the sample voicemail.conf ships mailbox 1234 with pin 4242
asterisk -rx "voicemail show users" 2>/dev/null | grep -qE 'Example Mailbox|Company2 User' \
	&& ko "the sample demo mailboxes are live, remove them from /etc/asterisk/voicemail.conf" \
	|| ok "no sample demo mailboxes"
# a module whose library is not installed never loads, and a new build can bring one
nolib=$(for m in /usr/lib/asterisk/modules/*.so; do ldd "$m" 2>/dev/null | grep -q 'not found' && basename "$m"; done | xargs)
[ -z "$nolib" ] && ok "every asterisk module has its libraries" || ko "modules with a missing library: $nolib, see ldd"
# a sample lua dialplan would load next to freepbx's
grep -q 'misery.digium.com' /etc/asterisk/extensions.lua 2>/dev/null \
	&& ko "extensions.lua is the sample demo dialplan, pbx_lua loads it" || ok "no sample lua dialplan"
# modprobe runs these as root
notroot=$(find /etc/modprobe.d -maxdepth 1 -type f ! -user root 2>/dev/null | xargs)
[ -z "$notroot" ] && ok "/etc/modprobe.d owned by root" || ko "not owned by root in /etc/modprobe.d: $notroot"
rtp=$(asterisk -rx "rtp show settings" 2>/dev/null | awk '/Port range/ {print $NF}')
[ -n "$rtp" ] && info "RTP port range: $rtp"

# ------------------------------------------------------------------ fail2ban
head2 "fail2ban"
if command -v fail2ban-client > /dev/null 2>&1; then
	fail2ban-client status asterisk-pjsip > /dev/null 2>&1 && ok "asterisk-pjsip jail running" || ko "asterisk-pjsip jail not running"
	ba=$(fail2ban-client get asterisk-pjsip actions 2>/dev/null | tr -d '\n')
	case "$ba" in
		*nftables*) ok "bans go through nftables" ;;
		*iptables*) command -v iptables > /dev/null 2>&1 && ok "bans go through iptables" || ko "jail bans with iptables, which is not installed, nothing gets blocked" ;;
		*) note "could not read the jail's ban action" ;;
	esac
	# a known failure line must give the packet source, not the From host
	line="[$(date '+%F %T')] NOTICE[1]: res_pjsip/pjsip_distributor.c:1 log_failed_request: Request 'REGISTER' from '<sip:1@203.0.113.5>' failed for '198.51.100.9:5060' (callid: x) - No matching endpoint found"
	flt=$(awk -F' *= *' '/^\[asterisk-pjsip\]/ {j=1} j && /^filter/ {print $2; exit}' /etc/fail2ban/jail.d/asterisk.local 2>/dev/null)
	got=$(fail2ban-regex -o ip "$line" "/etc/fail2ban/filter.d/${flt:-asterisk}.conf" 2>/dev/null | head -1)
	[ "$got" = "198.51.100.9" ] && ok "filter bans the packet source" || ko "filter extracted '${got}' instead of the packet source"
else
	ko "fail2ban not installed"
fi

# ------------------------------------------------------------------- helpers
head2 "helper scripts"
for f in update_asterisk.sh setup_email.sh setup_https.sh; do
	if [ -x "/usr/local/bin/$f" ]; then
		ok "$f installed and executable"
	else
		ko "$f missing or not executable"
	fi
done
grep -q 'REPO_NAME="freepbx-arm64-install"' /usr/local/bin/update_asterisk.sh 2>/dev/null \
	&& ok "updater points at the public repo" || ko "updater does not point at the public repo"

# ------------------------------------------------------------------- network
head2 "networkmanager"
if systemctl list-unit-files NetworkManager.service 2>/dev/null | grep -q NetworkManager; then
	[ -f /etc/systemd/system/NetworkManager.service.d/dbus-fix.conf ] \
		&& ok "dbus-fix override installed" || ko "NetworkManager present but no dbus-fix override"
else
	ok "no NetworkManager, nothing to do"
fi

# --------------------------------------------------------------- freepbx modules
head2 "freepbx modules"
if command -v fwconsole > /dev/null 2>&1; then
	# fwconsole prints module status in the gui language, the table and the module folders do not
	modules=$(mysql -N asterisk -e "SELECT modulename, enabled FROM modules" 2>/dev/null)
	moddir=/var/www/html/admin/modules
	if [ -z "$modules" ]; then
		ko "cannot read the modules table"
	else
		# ucp needs g++ and make to build its node modules, and used to fail silently
		if awk '$1 == "ucp" && $2 == 1' <<< "$modules" | grep -q .; then
			ok "ucp installed"
		else
			ko "ucp not installed, check that g++ and make are present"
		fi
		bad=$( {
			awk '$2 != 1 {print $1 "(disabled)"}' <<< "$modules"
			awk '{print $1}' <<< "$modules" | while read -r m; do [ -f "$moddir/$m/module.xml" ] || echo "$m(broken)"; done
			for f in "$moddir"/*/module.xml; do
				m=$(basename "$(dirname "$f")")
				awk -v m="$m" '$1 == m' <<< "$modules" | grep -q . || echo "$m(not installed)"
			done
		} | xargs)
		[ -z "$bad" ] && ok "no broken or missing modules" || ko "not installed, broken or disabled: $bad"
	fi
	# never downloaded modules have no folder, compare with the installer's list
	list="${SCRIPT_DIR}/files/freepbx-modules.list"
	if [ -f "$list" ]; then
		enabled=" $(awk '$2 == 1 {print $1}' <<< "$modules" | xargs) "
		want=$(grep -v '^[[:space:]]*#' "$list" | xargs)
		missing=""
		for m in $want; do
			[[ "$enabled" == *" $m "* ]] || missing="$missing $m"
		done
		[ -z "$missing" ] && ok "all $(echo $want | wc -w) listed modules enabled" || ko "listed but not enabled:$missing"
	else
		note "no files/freepbx-modules.list next to this script, run it from the clone"
	fi
	systemctl is-active --quiet freepbx 2>/dev/null && ok "freepbx oneshot unit active" || ko "freepbx unit not active"
	# a crash loop still reads online, only the restart counter moves
	pm2_list() { fwconsole pm2 --list 2>/dev/null | awk -F'|' '/^\|/ && $2 !~ /Process Name/ {n=$2; s=$4; r=$5; gsub(/ /,"",n); gsub(/ /,"",s); gsub(/ /,"",r); print n, s, r}'; }
	# fwconsole pm2 would start a daemon in this shell's session
	if ! pgrep -u asterisk -f 'PM2 v' > /dev/null; then
		ko "pm2 is not running, systemctl restart freepbx"
	elif before=$(pm2_list); [ -z "$before" ]; then
		ko "no pm2 processes, see fwconsole pm2 --list"
	else
		sleep 10
		# freepbx may have restarted in those 10s
		after=""
		pgrep -u asterisk -f 'PM2 v' > /dev/null && after=$(pm2_list)
		[ -z "$after" ] && ko "pm2 went away during the check, run it again"
		[ -n "$after" ] && while read -r n s r; do
			r0=$(awk -v n="$n" '$1 == n {print $3}' <<< "$before")
			if [ "$s" != online ]; then
				ko "pm2 $n is $s"
			elif [ "${r:-0}" -gt "${r0:-0}" ]; then
				ko "pm2 $n restarted $((r - r0)) times in 10s, see /var/log/asterisk/${n}_err.log"
			else
				ok "pm2 $n online, stable"
			fi
		done <<< "$after"
	fi
	# started by hand or by the installer, pm2 keeps running in that session's cgroup until a reboot
	pm2cg=$(unit_of "$(pgrep -u asterisk -f 'PM2 v' | head -1)")
	case "$pm2cg" in
		*freepbx.service) ok "pm2 runs inside freepbx.service" ;;
		"") ;;
		*) note "pm2 runs outside freepbx.service ($pm2cg), systemctl stop freepbx, pkill -u asterisk -f 'PM2 v', systemctl start freepbx" ;;
	esac
	# connect the way ucp does, node picks ::1 for localhost
	node_reach() { node -e 'const s=require("net").connect(+process.argv[2],process.argv[1]);s.setTimeout(3000,()=>{console.log("timeout");process.exit(1)});s.on("connect",()=>{console.log(s.remoteAddress);process.exit(0)});s.on("error",e=>{console.log(e.code+" "+(e.address||""));process.exit(1)})' "$1" "$2" 2>&1; }
	dbhost=$(grep -oP "AMPDBHOST'\]\s*=\s*'\K[^']+" /etc/freepbx.conf 2>/dev/null)
	r=$(node_reach "${dbhost:-localhost}" 3306) && ok "node reaches the database at ${dbhost} ($r)" \
		|| ko "node cannot reach the database at ${dbhost:-?}: $r, ucp will crash loop"
	amihost=$(mysql -N asterisk -e "SELECT value FROM freepbx_settings WHERE keyword='ASTMANAGERHOST'" 2>/dev/null)
	r=$(node_reach "${amihost:-localhost}" 5038) && ok "node reaches the manager at ${amihost} ($r)" \
		|| ko "node cannot reach the manager at ${amihost:-?}: $r, ucp will crash loop"
	asterisk -rx "manager show user ucp_events" 2>/dev/null | grep -q "username: ucp_events" \
		&& ok "ucp has its asterisk manager user" \
		|| ko "no ucp_events manager user, install the manager module then run fwconsole ma install ucp"
	# freepbx's own login, a stopped install can leave a different one in manager.conf
	mgru=$(mysql -N asterisk -e "SELECT value FROM freepbx_settings WHERE keyword='AMPMGRUSER'" 2>/dev/null)
	mgrp=$(mysql -N asterisk -e "SELECT value FROM freepbx_settings WHERE keyword='AMPMGRPASS'" 2>/dev/null)
	mgrs=$(awk -v u="[$mgru]" '$0 == u {f=1; next} /^\[/ {f=0} f && /^secret/ {sub(/^secret *= */, ""); print; exit}' /etc/asterisk/manager.conf 2>/dev/null)
	if [ -n "$mgru" ] && [ -n "$mgrs" ] && [ "$mgrs" = "$mgrp" ] \
		&& asterisk -rx "manager show user $mgru" 2>/dev/null | grep -q "username: $mgru"; then
		ok "freepbx's manager login is the one in manager.conf"
	else
		ko "freepbx's manager login is not in manager.conf, it cannot reload asterisk"
	fi
	# tampered files and vulnerable modules only show on the dashboard, 100 critical, 200 security
	sec=$(mysql -N asterisk -e "SELECT CONCAT(display_text, ' ', IFNULL(extended_text, '')) FROM notifications WHERE level <= 200" 2>/dev/null | cut -c1-150 | paste -sd';' -)
	[ -z "$sec" ] && ok "no security notices on the dashboard" || ko "security notice on the dashboard: $sec"
	# a file named core has no dot, admin/.htaccess lets it through
	dumps=$(find /var/www/html -xdev -type f \( -name core -o -name 'core.[0-9]*' \) 2>/dev/null | head -3 | xargs)
	[ -z "$dumps" ] && ok "no core dumps in the webroot" || ko "core dump in the webroot, it holds the database password: $dumps"
	# debian's mariadb.socket listens on every address and bind-address is ignored
	db=$(ss -lntH 'sport = :3306' 2>/dev/null | awk '{print $4}' | grep -vE '^(127\.0\.0\.1|\[::1\]):3306$' | xargs)
	[ -z "$db" ] && ok "mariadb only on loopback" || ko "mariadb listens on $db, check bind-address in 99-freepbx.cnf and systemctl disable --now mariadb.socket"
else
	ko "fwconsole not found"
fi

# ---------------------------------------------------------------------- https
head2 "https"
if ss -lnt 2>/dev/null | grep -q ':443 '; then
	ok "listening on 443"
	a2query -s default-ssl > /dev/null 2>&1 \
		&& ko "default-ssl is enabled, it shadows the freepbx vhost on 443" \
		|| ok "default-ssl not enabled"
	crt=$(awk '/SSLCertificateFile/ {print $NF}' /etc/apache2/sites-available/freepbx-ssl.conf 2>/dev/null | head -1)
	if [ -n "$crt" ] && [ -f "$crt" ]; then
		info "cert: $(openssl x509 -noout -subject -enddate -in "$crt" 2>/dev/null | tr '\n' ' ')"
		case "$crt" in
			/etc/letsencrypt/*)
				if openssl x509 -noout -issuer -in "$crt" 2>/dev/null | grep -q STAGING; then
					note "Let's Encrypt staging certificate, browsers will warn"
				else
					ok "Let's Encrypt certificate"
				fi
				systemctl is-enabled --quiet certbot.timer 2>/dev/null \
					&& ok "renewal timer enabled" || ko "certbot.timer not enabled, the cert will expire"
				grep -q 'acme-challenge' /etc/apache2/sites-available/freepbx.conf 2>/dev/null \
					&& ok "acme-challenge alias present" || ko "no acme-challenge alias, renewals will fail"
				;;
			*) note "self signed certificate, browsers will warn" ;;
		esac
	else
		ko "no certificate found in the freepbx-ssl vhost"
	fi
	apache2ctl configtest > /dev/null 2>&1 && ok "apache config test passes" || ko "apache config test fails"
else
	note "nothing on 443, run setup_https.sh"
fi

# ---------------------------------------------------------------------- logs
head2 "logs"
if [ -f /etc/logrotate.d/asterisk ]; then
	# logrotate -d exits 0 on a line or a whole file it ignores, its error lines tell
	lr=$(logrotate -d /etc/logrotate.d/asterisk 2>&1); lrc=$?
	lerr=$(grep -m1 '^error:' <<< "$lr")
	[ "$lrc" -eq 0 ] && [ -z "$lerr" ] && ok "asterisk logs rotated daily" \
		|| ko "logrotate rejects /etc/logrotate.d/asterisk: ${lerr#error: }"
else
	ko "nothing rotates /var/log/asterisk, full grows forever"
fi
info "$(du -sh /var/log/asterisk 2>/dev/null | cut -f1) in /var/log/asterisk"

# ----------------------------------------------------------------------- php
head2 "php"
PHP_VER=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null)
web=$(awk -F'= *' '/^memory_limit/ {print $2}' "/etc/php/${PHP_VER}/apache2/php.ini" 2>/dev/null)
cli=$(awk -F'= *' '/^memory_limit/ {print $2}' "/etc/php/${PHP_VER}/cli/php.ini" 2>/dev/null)
info "php ${PHP_VER}, apache2 memory_limit=${web}, cli memory_limit=${cli}"
[ "$cli" = "512M" ] && ok "cli limit 512M" || ko "cli limit is $cli, module installs need 512M"
if [ "$RAM" -le 2048 ]; then
	[ "$web" = "128M" ] && ok "apache2 limit scaled to 128M" || ko "apache2 limit is $web on a ${RAM}MB box"
fi
php -m 2>/dev/null | grep -qi ioncube && ok "ionCube loaded" || ko "ionCube not loaded"
ls / 2>/dev/null | grep -q 'ioncube_loader' && ko "an ionCube .so was dropped in /" || ok "nothing stray in /"

echo
echo "========================================================"
echo -e "  ${GREEN}${pass} ok${NC}, ${RED}${fail} failed${NC}, ${YELLOW}${warned} to look at${NC}"
echo "========================================================"
[ "$fail" -eq 0 ]
