# FreePBX 17 ARM64 Installation Script

An automated installer for **Asterisk 22 LTS** and **FreePBX 17** on **Debian 12 ARM64** systems.

This is the ARM64 equivalent of Sangoma's official [sng_freepbx_debian_install](https://github.com/FreePBX/sng_freepbx_debian_install) (which only supports x86_64).

## Installation

Requires a clean **Debian 12 (Bookworm) ARM64** installation and root access.

```bash
wget https://raw.githubusercontent.com/slythel2/freepbx-arm64-install-test/refs/heads/main/install.sh
chmod +x install.sh
./install.sh
```

## Asterisk Updates

The installer includes an update script with automatic backup and rollback:

```bash
update_asterisk.sh
```

Pre-compiled Asterisk binaries are built on native ARM64 GitHub Actions runners and published as [GitHub Releases](https://github.com/slythel2/freepbx-arm64-install-test/releases). The updater downloads the latest release, backs up the current installation, deploys the new binaries, and automatically rolls back if the health check fails.

## CLI Flags

| Flag | Description |
|------|-------------|
| `--skipversion` | Skip the self-update check at startup |
| `--nochrony` | Skip chrony (NTP) installation |

## Features

* **One-click install**: all dependencies are handled automatically
* **Fast deployment**: uses pre-compiled Asterisk 22 artifacts (no on-device compilation)
* **Update script**: Asterisk 22 updater script with backup, health check, and automatic rollback

## Access

After installation:
- **Web Interface:** `http://<YOUR_IP>/admin`

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
