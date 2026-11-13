# FreePBX 17 ARM64 Installation Script

An automated installer for **Asterisk 22 LTS** and **FreePBX 17** on **Debian 12 ARM64** systems.

This is the ARM64 equivalent of Sangoma's official [sng_freepbx_debian_install](https://github.com/FreePBX/sng_freepbx_debian_install) (which only supports x86_64).

The same installer covers ARM64 cloud servers and the **Raspberry Pi** (Raspberry Pi OS Lite 64-bit).

## Installation

Requires a clean **Debian 12 (Bookworm) ARM64** installation and root access.

```bash
wget https://raw.githubusercontent.com/slythel2/freepbx-arm64-install/refs/heads/main/install.sh
chmod +x install.sh
./install.sh
```

The installer is idempotent: run it again on the same box and it keeps the database, the passwords and the FreePBX configuration.

| Flag | Description |
|------|-------------|
| `--hostname FQDN` | Public DNS name of the PBX, gets a Let's Encrypt certificate |
| `--email ADDR` | Contact address for the Let's Encrypt account |
| `--nohttps` | Leave the admin interface on plain HTTP |
| `--nochrony` | Skip chrony (NTP) installation |
| `--skipversion` | Skip the installer version check at startup |
| `--help` | Show the available options |

## Asterisk Updates

The installer includes an update script with automatic backup and rollback:

```bash
update_asterisk.sh
```

Pre-compiled Asterisk binaries are built on native ARM64 GitHub Actions runners and published as [GitHub Releases](https://github.com/slythel2/freepbx-arm64-install/releases). The updater downloads the latest release, backs up the current installation, deploys the new binaries, and automatically rolls back if the update is interrupted or the health check fails.

| Flag | Description |
|------|-------------|
| `--dry-run` | Show the installed and available versions without downloading or stopping Asterisk |
| `--skipversion` | Skip the check for a newer version of the updater |
| `--help` | Show the available options |

The updater does not replace itself. When a newer one is published it says so and prints the command to download it.

## Access

After installation:
- **Web Interface:** `https://<YOUR_IP>/admin`

Without `--hostname` the certificate is self signed, so the browser warns about it.

The installer sets up fail2ban for SIP and SSH, but not a firewall. Use your provider's firewall or nftables and open only what you need: SIP (5060), RTP (10000-20000/udp) and 80/443 for the web interface.

## HTTPS

For a trusted certificate give the installer a DNS name that already points at the box. Let's Encrypt validates over plain HTTP, so port 80 must be reachable from the internet. Renewal is automatic.

```bash
./install.sh --hostname pbx.example.com --email you@example.com
```

It can be set up or changed later:

```bash
setup_https.sh --hostname pbx.example.com --email you@example.com
setup_https.sh --status
```

## Email

Most VPS providers block outbound port 25, so voicemail notifications never leave the box. `setup_email.sh` sends them through an SMTP relay instead: Gmail, Brevo, Aruba, SendGrid, Mailjet or any custom SMTP server. The installer offers to run it at the end, or run it later:

```bash
setup_email.sh
setup_email.sh --test you@example.com
setup_email.sh --status
```

## Checking an installation

`check_install.sh` runs read only checks on an installed box (services, modules, HTTPS, fail2ban, log rotation). Useful before opening an issue:

```bash
wget https://raw.githubusercontent.com/slythel2/freepbx-arm64-install/refs/heads/main/check_install.sh
bash check_install.sh
```

## Features

* **One-click install**: all dependencies are handled automatically
* **Fast deployment**: uses pre-compiled Asterisk 22 artifacts (no on-device compilation)
* **Update script**: Asterisk 22 updater script with backup, health check, and automatic rollback
* **HTTPS**: Let's Encrypt with automatic renewal, or a self signed certificate
* **Email**: SMTP relay setup for voicemail and system mail
* **Hardening**: fail2ban for SIP and SSH, log rotation, MariaDB on loopback only
* **Raspberry Pi**: zram instead of a swap file on SD cards, memory limits sized to the board

## Licensing

This project is licensed under the **Apache License 2.0** for all automation scripts,
GitHub Actions workflows, and configuration files authored by the maintainer.

The pre-compiled Asterisk 22 binaries distributed via GitHub Releases are compiled
directly from [upstream official sources](https://downloads.asterisk.org/pub/telephony/asterisk/)
and remain subject to their original license
(**[GNU General Public License v2](https://www.gnu.org/licenses/old-licenses/gpl-2.0.html)**).
Full build transparency is provided by the public
[build workflow](.github/workflows/build_asterisk.yml) and
[builder script](builder_script.sh) in this repository.

FreePBX is a registered trademark of [Sangoma Technologies](https://www.sangoma.com/).
This project is not affiliated with or endorsed by Sangoma.

---

**Credits:** FreePBX & Asterisk open-source projects.
