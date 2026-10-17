# CLP Helper — WordPress Management CLI for CloudPanel

> **Language / 語言切換**: **English** | [繁體中文 (Traditional Chinese)](README.zh-TW.md)
> 
> 💡 *歡迎使用繁體中文！若您習慣閱讀繁體中文，請點擊上方連結查閱完整手冊。Issues 與 Discussions 亦歡迎使用中文交流。*

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![OS: Ubuntu 22.04 / 24.04 / 26.04](https://img.shields.io/badge/OS-Ubuntu%2022.04%20%7C%2024.04%20%7C%2026.04%20LTS-orange.svg)](https://ubuntu.com/)
[![Platform: CloudPanel v2](https://img.shields.io/badge/Platform-CloudPanel%20v2-blue.svg)](https://www.cloudpanel.io/)
[![Shell: Bash 5+](https://img.shields.io/badge/Shell-Bash%205%2B-green.svg)](https://www.gnu.org/software/bash/)

**CLP Helper** is a command-line toolkit for managing **WordPress sites** on **CloudPanel v2** servers. It focuses on the day-to-day work of running WordPress: creating sites, SSL, backups and restores, cloning and cross-server migration, access protection, and PHP-FPM tuning. It also includes one-click deployment and security hardening for fresh VPS instances.

**CLP Helper (`clp`)** bridges the gap between CloudPanel's web GUI and underlying Linux operational automation, bringing scriptable workflows, dual-track Let's Encrypt automation (HTTP-01 & Cloudflare DNS-01), cross-server migration that never writes to the source server, and multi-cloud remote backup integration to terminal users.

> **Disclaimer:** CLP Helper is an independent, community-developed project. It is not affiliated with, endorsed by, or sponsored by CloudPanel or MGT Commerce GmbH. "CloudPanel" is used only to describe compatibility. The `clp` command is separate from CloudPanel's official `clpctl`.

---

## Table of Contents

- [1. Key Features](#1-key-features)
- [2. System Requirements & Compatibility](#2-system-requirements--compatibility)
- [3. Installation & Quick Start](#3-installation--quick-start)
- [4. Command Architecture](#4-command-architecture)
- [5. Language & Internationalization (i18n)](#5-language--internationalization-i18n)
- [6. Modules Reference](#6-modules-reference)
  - [1. Site Management (`clp site`)](#1-site-management-clp-site)
  - [2. Server Operations & Hardening (`clp server`)](#2-server-operations--hardening-clp-server)
  - [3. Backup Module (`clp backup`)](#3-backup-module-clp-backup)
  - [4. Restore Module (`clp restore`)](#4-restore-module-clp-restore)
  - [5. HTTP Basic Authentication (`clp httpauth`)](#5-http-basic-authentication-clp-httpauth)
  - [6. PHP-FPM Pool Tuning (`clp php-pm`)](#6-php-fpm-pool-tuning-clp-php-pm)
  - [7. Global Configuration Management (`clp config`)](#7-global-configuration-management-clp-config)
- [7. Crontab Best Practices](#7-crontab-best-practices)
- [8. Security Architecture](#8-security-architecture)
- [9. Directory Structure](#9-directory-structure)
- [10. License](#10-license)

---

## 1. Key Features

- ⚡ **Full Lifecycle WordPress Management**: One-click provisioning of sites, MySQL databases, and WordPress core, with automatic caching plugin setup, Nginx reload, and SSL configuration.
- 🔒 **Dual-Track Let's Encrypt SSL**: Supports both CloudPanel native HTTP-01 challenge and Cloudflare DNS-01 API automated challenge, with dedicated Certbot virtualenv deployment and automated weekly renewal crontab.
- 🔄 **Same-Host Site Cloning (Staging / Clone)**: Rapidly duplicate existing sites to new domains with automatic Path Sanitization, Wordfence WAF file re-pointing, Redis cache key salt isolation, `wp search-replace`, and `robots.txt` corrections.
- 🚀 **Zero-Write Cross-Server Migration**:
  - Source server is **100% read-only**; no temporary files or modifications are ever created on the source.
  - Three-tier site detection (SQLite DB ➔ Nginx configuration ➔ Physical directory).
  - Pre-flight validation checks for active admin sessions and 10-minute post edit locks (`_edit_lock`) to prevent overwriting in-progress drafts.
  - Database transfer via compressed SSH stream directly to target, verified before import; zero writes to source host.
  - Supports single-site migration and batch unattended migration of all sites (`-all`).
- 🛡️ **Server Operations & 17-Module One-Click Installer**:
  - **System Dashboard**: Real-time 3-area audit covering system overview, running services, and security metrics.
  - **Fresh VPS Installer**: Dynamically matches official compatible database engines (MySQL 8.4 LTS, MariaDB 11.4 LTS, etc.) with 17 core modules selectable via an interactive switchboard.
  - **Anti-Lockout Security Hardening**: SSH dual-key validation, password authentication disabling, UFW firewall rules, Fail2ban brute-force defense, systemd journal size capping (500M), and kernel sysctl tuning.
- 📦 **Flexible Backup & Cloud Sync**: 4 backup formats (`db`, `compact`, `archive` for past years' uploads, `full`) natively integrated with `rclone` supporting Google Drive, Backblaze B2, Cloudflare R2, and AWS S3, complete with precision expired backup cleanup (`-expire`).
- 🔐 **HTTP Basic Authentication & IP Whitelisting**: Protect WordPress admin dashboard (`/wp-admin/` and `wp-login.php`), entire site, or custom subdirectories, with CIDR IP whitelisting for password-free bypass.
- ⚙️ **Dynamic PHP-FPM Pool Tuning**: Automatically detects active PHP versions per site, adapts pool configuration parameters, and performs syntax tests with instant rollback safeguards.
- 💡 **Smart Typo Suggestion**: Automatically identifies mistyped domain names using Levenshtein distance and suggests closest matching existing sites.

---

## 2. System Requirements & Compatibility

| Item | Requirement |
| :--- | :--- |
| **Operating System** | Ubuntu 22.04 LTS / Ubuntu 24.04 LTS / Ubuntu 26.04 LTS (Standard and Minimal images; tested)<br>Debian 11 / Debian 12 (expected to work, but not tested) |
| **Control Panel** | CloudPanel v2 |
| **Permissions** | `root` user privilege (`sudo`) |
| **Environment** | Bash 5.0+, `curl`, `rsync`, `tar`, `gzip` (installer auto-installs missing packages) |

All end-to-end testing has been done on Ubuntu 22.04, 24.04, and 26.04. Debian is supported by CloudPanel and CLP Helper does not block it, but it has not been tested. Please report any issues.

---

## 3. Installation & Quick Start

### 1. Download & Install

Run one of the following on your CloudPanel server as root. All three methods give the same result.

**Option 1: One-line install (recommended)**

The installer script is saved to a file first, so you can inspect it before running it:

Using curl:

```bash
curl -fsSL https://raw.githubusercontent.com/yogoeasy/clp-helper/main/get.sh -o clp-get.sh && sudo bash clp-get.sh
```

Or using wget:

```bash
wget -qO clp-get.sh https://raw.githubusercontent.com/yogoeasy/clp-helper/main/get.sh && sudo bash clp-get.sh
```

`get.sh` downloads the latest version from GitHub into a temporary directory, runs `install.sh`, and removes the temporary files when it finishes.

**Option 2: Download the archive**

Using curl:

```bash
curl -fsSL https://github.com/yogoeasy/clp-helper/archive/refs/heads/main.tar.gz | tar xz && sudo bash clp-helper-main/install.sh
```

Or using wget:

```bash
wget -qO- https://github.com/yogoeasy/clp-helper/archive/refs/heads/main.tar.gz | tar xz && sudo bash clp-helper-main/install.sh
```

You can delete the extracted `clp-helper-main` directory after installation.

**Option 3: git clone**

```bash
git clone https://github.com/yogoeasy/clp-helper.git && sudo bash clp-helper/install.sh
```

You can delete the `clp-helper` directory after installation.

**Interface language**: append `--lang=en_US` (or `--lang=zh_TW`) to any of the commands above, e.g. `sudo bash clp-get.sh --lang=zh_TW`.

The installer will automatically:
- Install the program to `/usr/local/lib/clp-helper/` (legacy installations at `/home/clp/clp/` are migrated automatically).
- Create the command link `/usr/local/bin/clp`, so `clp` can be run from any directory.
- Set file ownership and permissions, and create the `/var/log/clp` log directory.

**Updating**: run any of the installation methods again. Your settings (`/etc/clp/`), backups (`/root/clpBackup/`) and site data are not affected.

### 2. Verify Installation

In any terminal window:

Check version information:

```bash
clp -v
```

Output example:`CLP Helper v1.0.0 (build 2026-10-17 21:30:03)`

Display global help menu:

```bash
clp --help
```

### 3. Uninstallation

To completely remove CLP Helper from your system:

```bash
sudo bash /usr/local/lib/clp-helper/install.sh --uninstall
```

---

## 4. Command Architecture

CLP Helper follows a unified, intuitive command syntax:

```bash
sudo clp <module> [target_domain] [options...]
```

> [!NOTE]
> Options that take a value must use the `-option=value` format (e.g. `-type=full`, `-to=google`, `-cf-waf=off`). Space-separated option values or extra unrecognized positional arguments will be rejected with an error and a syntax hint to prevent accidental misconfigurations.

### Core Modules Quick Overview

| Module | Description | Common Commands |
| :--- | :--- | :--- |
| **`site`** | WordPress Site Management | `-new`, `-list`, `-on`, `-off`, `-ssl`, `-cf-waf`, `-cf-only`, `-varnish`, `-clone-from`, `-migrate`, `delete` |
| **`server`** | Server Operations & Hardening | `(no args)`, `install`, `-harden`, `-ufw`, `-ssh`, `-fail2ban`, `-clean` |
| **`backup`** | Site & Database Backup | `-type={db\|full\|compact\|archive}`, `-to={local\|<remote>}`, `-expire=<Nd>` |
| **`restore`** | Site & Database Restore | `[-file=<name>]`, `-type={db\|full\|compact\|archive}`, `-to={local\|<remote>}` |
| **`httpauth`** | HTTP Authentication & Whitelisting | `-add`, `-delete`, `-list`, `-wp-admin`, `-path`, `-whitelist` |
| **`php-pm`** | PHP-FPM Pool Optimization | `<domain>`, `all` |
| **`config`** | Global Preferences & Credentials | `-set <key>=<val>`, `-get <key>`, `-list`, `-unset <key>` |

### Global Options

| Option | Description | Example |
| :--- | :--- | :--- |
| `--lang=<lang>` | Specify interface language (`en_US`, `zh_TW`) | `sudo clp --lang=zh_TW --help` |
| `-h`, `--help` | Display help menu (global or module-specific) | `sudo clp --help` |
| `-v`, `-V`, `--version` | Display version and build information | `clp -v` |

---

## 5. Language & Internationalization (i18n)

CLP Helper features a built-in internationalization (i18n) engine adhering to the **WordPress and GNU gettext language code standard** (`ISO-639` language code + `ISO-3166` country code), natively supporting **English (`en_US`)** and **Taiwan Traditional Chinese (`zh_TW`)**.

### Language Detection Cascade

The interface language is dynamically resolved in the following priority order:
1. **Command-Line Flag** (`--lang=...` or `-lang=...`): Highest priority, applies to the current command invocation (e.g. `--lang=en_US` or `--lang=zh_TW`; legacy `--lang=en` automatically maps to `en_US`).
2. **Environment Variable** (`CLP_LANG`): Session-wide or persistent override in shell profiles.
3. **Global Configuration File** (`/etc/clp/clp.conf` via `clp config`): Persistent system-wide setting across all users and sessions.
4. **System Environment Locale** (`LC_ALL`, `LC_MESSAGES`, `LANG`):
   - Locales such as `zh_TW`, `zh_HK`, `zh_MO`, and `zh_Hant` automatically map to Taiwan Traditional Chinese (`zh_TW`).
   - All other system locales (e.g. `en_US`, `en_GB`, `C`, `POSIX`) default to English (`en_US`).
5. **Fallback Default**: English (`en_US`) serves as the universal fallback for international server environments.

### Usage & Examples

#### 1. Runtime Override via Command-Line Flag
Pass `--lang=zh_TW` or `--lang=en_US` directly to any command:

Display help menu in Traditional Chinese:

```bash
sudo clp --lang=zh_TW --help
```

Display help menu in English:

```bash
sudo clp --lang=en_US --help
```

Check version in Traditional Chinese:

```bash
clp --lang=zh_TW -v
```

Check version in English:

```bash
clp --lang=en_US -v
```

Run module commands with language flag:

```bash
sudo clp --lang=zh_TW site -list
```

```bash
sudo clp --lang=en_US site example.com -new
```

```bash
sudo clp --lang=zh_TW server
```

#### 2. Persistent Override via Environment Variable
Set `CLP_LANG` in your current terminal session or persist it in `~/.bashrc` / `/etc/environment`:

Switch current terminal session to Traditional Chinese:

```bash
export CLP_LANG="zh_TW"
```

```bash
clp -v
```

```bash
sudo clp --help
```

Switch current terminal session to English:

```bash
export CLP_LANG="en_US"
```

```bash
clp -v
```

```bash
sudo clp --help
```

#### 3. Persistent Configuration via `clp config`
You can permanently configure your preferred system-wide default language using `clp config` without needing to export environment variables on every login:

Set system-wide default language to Traditional Chinese:

```bash
sudo clp config -set lang=zh_TW
```

Set system-wide default language to English:

```bash
sudo clp config -set lang=en_US
```

Query the currently configured default language:

```bash
clp config -get lang
```

Remove language configuration (reverts to system locale auto-detection):

```bash
sudo clp config -unset lang
```

#### 4. Installer Language Selection (`install.sh`)
The installer also fully respects the i18n cascade and runtime language flags:

Run installer in Traditional Chinese:

```bash
sudo bash install.sh --lang=zh_TW
```

Run installer in English (default on international servers):

```bash
sudo bash install.sh --lang=en_US
```

Display installer help menu:

```bash
bash install.sh --help
```

```bash
bash install.sh --lang=zh_TW --help
```

Uninstall with specified language:

```bash
sudo bash /usr/local/lib/clp-helper/install.sh --uninstall --lang=en_US
```

---

## 6. Modules Reference

### 1. Site Management (`clp site`)

#### ① Site Listing (`clp site -list`)

List all sites in a table:

```bash
sudo clp site -list
```

**Filter by state or SSL**

Only enabled sites:

```bash
sudo clp site -list=enabled
```

Only paused sites:

```bash
sudo clp site -list=disabled
```

Only sites with active SSL:

```bash
sudo clp site -list=ssl
```

Raw mode for scripts (-raw), one domain name per line:

```bash
sudo clp site -list=enabled -raw
```

#### ② Create New WordPress Site (`clp site <domain> -new`)

Interactive creation (prompts for site user, PHP version, SSL mode, admin credentials):

```bash
sudo clp site example.com -new
```

One-line creation using CloudPanel native HTTP-01 challenge:

```bash
sudo clp site example.com -new -http -php=8.4 -user=myuser
```

One-line creation using Cloudflare DNS-01 API challenge:

```bash
sudo clp site example.com -new -dns -php=8.4
```

Create site skipping SSL setup:

```bash
sudo clp site example.com -new -ssl=off
```

Overwrite existing site of the same name:

```bash
sudo clp site example.com -new -force-replace
```

> [!TIP]
> When running `-new`, pressing `Enter` to leave administrator credentials blank automatically applies defaults (Username defaults to `wpadmin`, a strong password is auto-generated and saved to `/root/.clp/<domain>-wp-admin.txt`, and Email defaults to `wpadmin@wp.com`).

#### ③ SSL Certificate Management (`clp site <domain> -ssl`)

Issue Cloudflare DNS-01 SSL (auto cron renewal & verification):

```bash
sudo clp site example.com -ssl=on -dns
```

```bash
sudo clp site example.com -dns
```

Use specific Cloudflare API credentials file:

```bash
sudo clp site example.com -ssl=on -dns -api=my-cloudflare.ini
```

Issue CloudPanel native HTTP-01 SSL (domain pointing to server IP):

```bash
sudo clp site example.com -ssl=on -http
```

Remove and disable SSL certificate:

```bash
sudo clp site example.com -ssl=off
```

#### ④ Clone / Duplicate Site on Same Host (`clp site -clone-from`)

Basic clone (target site is automatically created if absent):

```bash
sudo clp site -clone-from=example.com new-example.com
```

Overwrite existing target site:

```bash
sudo clp site -clone-from=example.com new-example.com -force-replace
```

Customize user and PHP version for target site:

```bash
sudo clp site -clone-from=example.com new-example.com -user=newuser -php=8.4
```

- **Automation Highlights**:
  - SSL validation executed first with Fail-Fast abort to prevent wasted transfer time.
  - Automatically detects and updates Wordfence WAF paths, neutralizing missing paths to avoid PHP 500 errors.
  - Automatically injects unique random salt (`WP_CACHE_KEY_SALT`) for Redis cache to prevent cross-site cache poisoning.
  - WP-CLI deep URL replacement and automatic correction of Sitemap URLs in `robots.txt`.

#### ⑤ Zero-Write Cross-Server Migration (`clp site -migrate`)

Same domain migration (keeps domain, skips search-replace):

```bash
sudo clp site -migrate=remote-vps -from=example.com
```

Cross-domain migration (automatically executes DB search-replace):

```bash
sudo clp site -migrate=remote-vps -from=example.com new-site.com
```

Migrate all sites from remote server to local:

```bash
sudo clp site -migrate=remote-vps -all
```

Batch migrate with domain exclusions:

```bash
sudo clp site -migrate=remote-vps -all -exclude="test.,dev.,staging." -force-replace
```

- **Safety Highlights**:
  - **Read-Only on Remote**: Database is transferred via compressed SSH stream to the target host and verified before import; zero files written to source server.
  - **Edit-Lock Detection**: Automatically detects active post editing locks (`_edit_lock`) within the last 10 minutes to prevent overwriting unsaved work.
  - **SSH Agent Integration**: Detects key passphrases and loads them into `ssh-agent` for seamless passwordless streaming.

#### ⑥ Site State Management

Pause site (preserves files and databases):

```bash
sudo clp site example.com -off
```

Resume site:

```bash
sudo clp site example.com -on
```

Interactive site and database deletion:

```bash
sudo clp site delete example.com
```

Force delete without interactive prompt:

```bash
sudo clp site delete example.com --force
```

#### ⑦ Cloudflare Edge WAF & Security Optimization (`clp site <domain> -cf-waf`)

> ⚠️ **Zone-wide:** the [CLP] WAF rules and the SSL/HTTPS/TLS settings apply to the whole Cloudflare zone (every hostname in it). Running `-cf-waf` (or `-cf-waf=off`) for one domain replaces the [CLP] rules for all hostnames in that zone. Your own non-[CLP] rules are kept. Zone settings follow `clp config -set cf-default-mode / cf-always-https / cf-min-tls` when set.

Automatically enforce Full (Strict) SSL, Always Use HTTPS, TLS 1.2+ on Cloudflare Anycast edge, and deploy 4 golden custom WAF rules (Protect WP Admin/Login, Block XML-RPC, Block Sensitive Files/Dumps, Block Bad Scanners):

Optimize edge security and deploy WAF rules for domain:

```bash
sudo clp site example.com -cf-waf
```

Dry-run simulation (verifies token, resolves zone, outputs payload without changes):

```bash
sudo clp site example.com -cf-waf --dry-run
```

Whitelist admin IP addresses for wp-login / wp-admin:

```bash
sudo clp site example.com -cf-waf --whitelist="1.2.3.4,5.6.7.8"
```

Check edge security and custom WAF rules status:

```bash
sudo clp site example.com -cf-waf=status
```

Safely remove CLP WAF rules (preserves user custom rules):

```bash
sudo clp site example.com -cf-waf=off
```

- **Key Security Highlights**:
  - **4-Level Token Cascade**: Supports CLI `--token`, existing Certbot `/root/.secrets/*.ini` files, global `/etc/clp/clp.conf`, or environment variables.
  - **Namespace Isolation**: Only rules prefixed with `[CLP]` are managed; existing user rules are never overwritten or removed.
  - **Quota Guard**: Checks custom rules limit against zone plan (Free 5 / Pro 20 / Business 100 / Enterprise 1000) before deploying, aborting and listing existing rules if exceeded to prevent API 400 errors.

#### ⑧ Allow Traffic from Cloudflare Only (`clp site <domain> -cf-only`)

Same as CloudPanel's per-site "Allow traffic from Cloudflare only" setting. When enabled, requests that connect to the server IP directly get a 403 from Nginx and never reach PHP, which blocks scanners that bypass Cloudflare. The CloudPanel UI only toggles one site at a time; this command works on a single site or on all sites at once.

Enable:

```bash
sudo clp site example.com -cf-only
```

Disable:

```bash
sudo clp site example.com -cf-only=off
```

Show the status of one site or of all sites (database, vhost, whether DNS goes through Cloudflare):

```bash
sudo clp site example.com -cf-only=status
```

```bash
sudo clp site -cf-only=status
```

Preview, then enable all sites (`-exclude` works like `backup all`):

```bash
sudo clp site -cf-only -all -dry-run
```

```bash
sudo clp site -cf-only -all -exclude="test.,dev."
```

Disable all sites:

```bash
sudo clp site -cf-only=off -all
```

- **DNS check**: before enabling, the domain and its www / non-www counterpart are resolved, and every A/AAAA record must be a Cloudflare address (orange cloud). A grey-cloud domain, or one pointing elsewhere, would become unreachable, so it is refused with the reason; add `-force` to enable anyway. Batch enabling skips sites that fail the check.
- **Updates both the vhost and the CloudPanel database**: only two places in the main server block change (`access_log` switches to the `cloudflare` format and `include /etc/nginx/cloudflare/ips;` is added), in the same format CloudPanel generates. The database field is updated too, so the setting survives when CloudPanel regenerates the vhost and the toggle in the UI shows the right state.
- **Safety**: the vhost, the previous database value and the database itself are backed up first (`/root/.clp/cf-only-backup/`, the last 3 database copies are kept); if `nginx -t` fails or the database write fails, the vhost is restored. Sites already in the requested state are left alone. Disabled sites are not processed.
- **Batch confirmation**: before a batch change, the sites to change and to skip are listed and you must type `yes`; `-y` proceeds directly, and non-interactive mode without `-y` is refused.
- **Warning: `X-Real-IP` bypass**: if `/etc/nginx/nginx.conf` contains `set_real_ip_from 0.0.0.0/0;` (as on every CloudPanel server we checked), anyone who connects directly with an `X-Real-IP: <Cloudflare IP>` header can bypass this setting. clp shows a warning but does not modify `nginx.conf`.

#### ⑨ Varnish Not Caching? (`clp site <domain> -varnish=status|fix`)

The CloudPanel UI may show Varnish as enabled while the site is not cached at all: every request still runs PHP, and a traffic spike can exhaust memory. Use these commands to check and fix it.

Check one site or all sites:

```bash
sudo clp site example.com -varnish=status
```

```bash
sudo clp site -varnish=status
```

Fix one site (preview first):

```bash
sudo clp site example.com -varnish=fix -dry-run
```

```bash
sudo clp site example.com -varnish=fix
```

Fix every site that needs it (`-exclude` works like `backup all`):

```bash
sudo clp site -varnish=fix -all -dry-run
```

```bash
sudo clp site -varnish=fix -all -exclude="test.,dev."
```

**Why caching does not happen**

1. **Varnish only caches pages for which PHP sends `Cache-Control`**: `/home/<user>/.varnish-cache/controller.php` sends those headers and must be loaded through PHP's `auto_prepend_file`. The `Cache-Control: no-store` your browser sees is always added by Varnish and says nothing about caching; ignore it.
2. **Toggle Varnish in the CloudPanel UI** (or press Save on the Vhost tab): the UI toggle is `enabled` in `/home/<user>/.varnish-cache/settings.json`, and switching it also makes CloudPanel regenerate the vhost and add `auto_prepend_file` to `PHP_VALUE`. The toggle of the "CLP Varnish Cache" WordPress plugin only changes `settings.json` and does not update the vhost. (`site.varnish_cache` in the CloudPanel database is a default set when a WordPress site is created, usually 1; it does not mean the UI toggle is on.)
3. **When optimizing the Wordfence firewall, choose "Include", not "Override", and enable Varnish before the Wordfence optimization**: Wordfence writes a `.user.ini` that switches to its own `wordfence-waf.php`, which takes precedence over the vhost, so `wordfence-waf.php` must include `controller.php`. If the order was reversed or Override was chosen, run `clp site <domain> -varnish=fix`.
4. **Changes to `.user.ini` take up to 5 minutes** (PHP's `user_ini.cache_ttl`). `-varnish=fix` never edits `.user.ini`; its changes to the vhost and `wordfence-waf.php` take effect immediately.
5. **Wordfence warns that `.user.ini` may be publicly readable**: the Nginx security rules of `clp server -harden` already block `.user.ini` (in `/etc/nginx/clp-security.conf`, loaded from `/etc/nginx/global_settings`).

**What `-varnish=fix` does**

- vhost: adds `auto_prepend_file=/home/<user>/.varnish-cache/controller.php;` right after `upload_max_filesize=…;` in the `PHP_VALUE` of the 8080 block, at the same place and in the same form as CloudPanel; restored if `nginx -t` fails.
- `wordfence-waf.php`: if `.user.ini` points to it and it does not include `controller.php`, adds a block in the same format as Wordfence's "Include" option, checked with `php -l`, keeping the file's owner and permissions.
- Backups go to `/root/.clp/varnish-backup/<time>/<domain>/`; after the fix, caching is checked again.
- **Left alone** (only reported): Varnish disabled (the UI toggle is off, i.e. `enabled` is false in `settings.json`), `varnish_cache` is 0 in the database (CloudPanel would drop the line again when it regenerates the vhost; shown separately), `.user.ini` pointing to another file, a vhost that already has another `auto_prepend_file`, and sites where the cause is unknown.

**Checking it yourself**:

```bash
curl -s -D- -o /dev/null -H "Host: example.com" -H "X-Forwarded-Proto: https" http://127.0.0.1:8080/ | grep -i x-cache-lifetime
```

If `X-Cache-Lifetime` is present, Varnish will cache the page.

**What to check after the fix**

After the fix, Varnish stores pages and serves the same copy to every visitor for `cacheLifetime` (7 days by default, `604800` seconds) without running PHP. These sites were never cached before, so try a few sites or one server first and check the following before fixing everything.

- **Already excluded from the cache**:
  - Logged-in users (requests with a `wordpress_logged_in_` cookie always bypass the cache, and `controller.php` also checks `is_user_logged_in()`).
  - POST requests (the form submission itself).
  - `excludes` in `settings.json`, by default `/my-account/`, `/cart/`, `/checkout/` and `wp-login.php`.
- **Things that can break and need a real test**:
  1. **Form submissions fail**: some form plugins put a time-limited token in the page (for example a WordPress nonce, usually valid for 12–24 hours). If the page is cached for 7 days, visitors get an expired token and see "link expired" or "verification failed". Submit the form while logged out, ideally again the next day.
  2. **Cart and member information**: after a guest adds something to the cart, the cart cookies (for example WooCommerce's `woocommerce_items_in_cart`) do not make requests bypass the cache, so widgets such as "Cart (N)" on other pages may show a stale state. The cart and checkout pages themselves are excluded.
  3. **Cookies are removed**: for cacheable responses Varnish strips `Set-Cookie`, so features that rely on cookies (language switchers, first-visit pop-ups, etc.) may stop working.
  4. **Time-dependent content**: stock levels, "sold out", countdowns, random recommendations and geo-based content may freeze at the moment the page was cached.
  5. **After editing content**: updating a post or page in WordPress usually makes the CLP Varnish Cache plugin purge the related cache; changes made in other ways (plugin settings, direct database edits) need a manual purge.
- **How to check**: in a private window (logged out), submit a form, add to cart and browse other pages, register / log in / log out, and switch languages.
- **If something breaks**:
  - Add the URL to the exclusion list on the site's Varnish Cache tab in CloudPanel (stored in `excludes` of `settings.json`), for example `/contact/`.
  - Shorten the cache lifetime on the same tab (for example 1 day) to make expired form tokens less likely.
  - Purge the cache from the CLP Varnish Cache plugin in WordPress or from CloudPanel.

---

### 2. Server Operations & Hardening (`clp server`)

#### ① System Status & Security Audit Dashboard

Run `sudo clp server` to view an instant color-coded audit dashboard:

```bash
sudo clp server
```

The dashboard covers 3 key areas:
1. **System Overview**: OS version, kernel, uptime, public IP, CPU load, RAM/Swap usage, disk usage.
2. **Service Status**: CloudPanel version, exact database type (MySQL 8.4 / MariaDB 11.4), Nginx, dynamically detected PHP-FPM versions, Redis, UFW firewall, Fail2ban ban count.
3. **Security Metrics**: SSH password auth status, firewall rules, journald disk cap, unattended security upgrades.

#### ② Fresh VPS One-Click Deployment (`sudo clp server install`)

Designed for newly provisioned Ubuntu / Debian VPS instances (Debian untested):

Interactive guided installer (choose database engine and 17 core modules):

```bash
sudo clp server install
```

One-click install with recommended configuration (default MySQL 8.4 LTS):

```bash
sudo clp server install -y
```

Specify MariaDB 11.4 LTS:

```bash
sudo clp server install -y --db=MARIADB_11.4
```

Dry-run test mode (makes zero changes to system):

```bash
sudo clp server install --dry-run
```

**16 Core Deployment Modules**:
1. `cloudpanel`: Official CloudPanel CE v2 (dynamic SHA256 integrity verification)
2. `system_basics`: Essential maintenance packages (`ncdu`, `jq`, `rsync`, locale, timezone)
3. `ufw`: Firewall default-deny, allow ports 22, 80, 443, 8443, drop ICMP ping
4. `ssh_hardening`: Strict SSH key anti-lockout check, disable password authentication
5. `fail2ban`: Brute-force protection rules and auto-ban jails
6. `dns`: System DNS resolver optimization (Google 8.8.8.8 & Cloudflare 1.1.1.1)
7. `sysctl`: Linux kernel performance tuning (`swappiness=10`, `file-max=500000`)
8. `journald`: Limit systemd journal logs to 500M max disk usage
9. `unattended_upgrades`: Automatic security patch updates
10. `snap_retention`: Cap Snap revisions to 2 to reclaim disk space
11. `php_timezone`: Synchronize system and multi-version PHP timezones
12. `nginx_security`: Global block rules for `.user.ini` and `debug.log` leaks
13. `smtp`: Postfix external SMTP relay setup
14. `certbot`: Isolated `/opt/certbot` virtualenv with Cloudflare DNS plugin
15. `netdata`: Netdata real-time monitoring agent on port 19999
16. `rclone`: Official Rclone multi-cloud backup engine

#### ③ Interactive Security Hardening (`sudo clp server -harden`)

Apply security hardening to an existing CloudPanel server step-by-step:

Interactive prompt for each hardening item:

```bash
sudo clp server -harden
```

Apply all hardening rules without interactive confirmation:

```bash
sudo clp server -harden -y
```

#### ④ Tool Installation On-Demand (`sudo clp server -install=...`)

Install Netdata monitoring:

```bash
sudo clp server -install=netdata
```

Install Rclone cloud backup:

```bash
sudo clp server -install=rclone
```

Install Certbot & Cloudflare DNS plugin:

```bash
sudo clp server -install=certbot
```

Install Postfix SMTP Relay:

```bash
sudo clp server -install=smtp
```

Install all tools at once:

```bash
sudo clp server -install=all -y
```

#### ⑤ Standalone Operations Commands

**Firewall management**

View UFW rules:

```bash
sudo clp server -ufw
```

Allow port:

```bash
sudo clp server -ufw -allow=8080
```

Drop external ICMP ping:

```bash
sudo clp server -ufw -icmp=drop
```

**SSH management & emergency recovery**

Check SSH status and authorized keys:

```bash
sudo clp server -ssh
```

Disable password authentication:

```bash
sudo clp server -ssh -harden
```

Emergency recovery, temporarily re-enable password login:

```bash
sudo clp server -ssh -unharden
```

**Fail2ban intrusion prevention**

View banned IPs:

```bash
sudo clp server -fail2ban
```

Unban specific IP:

```bash
sudo clp server -fail2ban -unban=203.0.113.10
```

Unban all IPs:

```bash
sudo clp server -fail2ban -unban=all
```

Add IP to whitelist:

```bash
sudo clp server -fail2ban -whitelist=1.2.3.4
```

**System DNS & Timezone synchronization**

Configure Google/Cloudflare DNS:

```bash
sudo clp server -dns=auto
```

Sync timezone across system & PHP versions:

```bash
sudo clp server -timezone=Asia/Taipei
```

**SMTP verification & Disk cleanup**

Send test email:

```bash
sudo clp server -smtp -test=admin@example.com
```

Clean journal logs, APT cache, and temp files:

```bash
sudo clp server -clean
```

---

### 3. Backup Module (`clp backup`)

#### ① Parameters Specification

```bash
sudo clp backup <domain|all> [options...]
```

| Option | Default | Description |
| :--- | :--- | :--- |
| `-type={db\|full\|compact\|archive}` | `full` | • `db`: Database only (`.sql.gz`)<br>• `full`: Complete archive of DB and all site files (`.tar.gz`)<br>• `compact`: Files without DB (current-year uploads only)<br>• `archive`: Past years' uploads (everything in uploads except the current year, plus `wp-content/shield` and `WPvivid_Uploads`); complements `compact` |
| `-to={local\|<remote>}` | `local` | • `local`: Local server storage (`/root/clpBackup`)<br>• `<remote>`: Remote target defined in rclone config (`google`, `b2`, `r2`) |
| `-path=<path>` | By destination | Custom local or remote folder path |
| `-expire=<Nd>` | None | Automatically remove expired backups of the same type (`-expire=7d`, `-expire=30d`) |
| `-exclude=<pattern>` | None | Exclude specific sites (for `backup all`, comma-separated) |
| `-skip-disabled` | None | With `backup all`: skip disabled sites (`clp site <domain> -off`, vhost not in `sites-enabled`). By default disabled sites are backed up too; a single named site is always backed up |

#### ② What Each Type Contains

No backup type includes the following folders (caches and other backup plugins' local backups), and a restore never deletes them:

- `wp-content/cache`
- UpdraftPlus `wp-content/updraft`, WPvivid `wp-content/wpvividbackups`, All-in-One WP Migration `wp-content/ai1wm-backups`
- Duplicator `wp-content/backups-dup-lite`, `wp-content/backups-dup-pro`, `wp-snapshots`
- Backup Migration `wp-content/backup-migration*`, BackUpWordPress `wp-content/backupwordpress-*-backups`
- BackWPup `wp-content/uploads/backwpup-*`, Solid Backups (BackupBuddy) `wp-content/uploads/backupbuddy_backups`, `backupbuddy_temp`, WP Staging `wp-content/uploads/wp-staging/backups`

| Type | Database | Site files | `wp-content/uploads` | `shield`, `WPvivid_Uploads` |
| :--- | :---: | :---: | :--- | :---: |
| `full` | ✅ | ✅ | Everything | ✅ |
| `compact` | — | ✅ | Only the current-year folder (`uploads/<year>/`) and hidden files at the uploads root | — |
| `archive` | — | — | Everything except the current year (past years, non-year folders such as `elementor/`, regular files at the uploads root) | ✅ |
| `db` | ✅ | — | — | — |

**`full` vs. `compact` + `db` + `archive`**:

- **Same file coverage**: together the three cover the same files as `full`.
- **Different points in time**: `full` is packed at a single moment, while the three files are created separately (for example `db` and `compact` daily, `archive` monthly). After a restore, past years' uploads may be older than the site files and database by up to one schedule interval.
- **In short**: use `full` when you need the complete site at a single point in time; `compact` + `db` + `archive` is the space-saving everyday combination.

#### ③ Usage Examples

Backup single site database locally:

```bash
sudo clp backup example.com -type=db
```

Daily DB backup retaining 7 days of archives:

```bash
sudo clp backup example.com -type=db -expire=7d
```

Full site backup to local with 30-day retention:

```bash
sudo clp backup example.com -type=full -expire=30d
```

Compact backup synced to Google Drive via rclone:

```bash
sudo clp backup example.com -type=compact -to=google
```

Past years' uploads to Google Drive with 35-day retention:

```bash
sudo clp backup example.com -type=archive -to=google -expire=35d
```

Batch backup all sites to Backblaze B2, excluding staging sites, 14-day retention:

```bash
sudo clp backup all -type=full -to=b2 -expire=14d -exclude="test.,dev.,staging."
```

---

### 4. Restore Module (`clp restore`)

#### ① Interactive Menu Restore (omitting `-file`)

Restore from local backups list:

```bash
sudo clp restore example.com
```

Restore from Google Drive cloud backups list:

```bash
sudo clp restore example.com -to=google
```

The system will list all available snapshots. Select a number and confirm with `yes` to execute database restoration, file extraction, PHP-FPM reload, and WordPress cache flushing. Use `-type={db|full|compact|archive}` to list only one type.

#### ② Exact Command Line Restore

Specify local backup file:

```bash
sudo clp restore example.com -file=example.com-db-20261005_120000.sql.gz
```

Specify remote backup file and force restore without prompt:

```bash
sudo clp restore example.com -file=example.com-full-20261005_153000.tar.gz -to=b2 --force
```

#### ③ Restored Files Match the Backup (Extra Files Are Deleted)

By default, a file restore deletes files on the site that are not in the backup (rsync `--delete`), such as injected malware or removed plugins, so the result matches the site at backup time.

- **Each type only touches its own scope**:
  - `full`: the whole site directory.
  - `compact`: `uploads/<year>/` of the backup year and the rest of the site files; other years and non-year folders in uploads, `shield` and `WPvivid_Uploads` are left alone.
  - `archive`: only `wp-content/uploads` (except the backup year's folder), plus `shield` and `WPvivid_Uploads` if they are in the backup; other site files are left alone.
  - `db`: imports the database only; no files are touched.
- **The year comes from the backup**: it is read from the timestamp in the file name, not the date of the restore.
- **Always protected**: the current `wp-config.php` (the backup's copy is saved in the snapshot folder) and the cache and backup-plugin folders listed above.
- **Confirmation**: in interactive mode, the number of items to be deleted and the first 20 are shown, and you must type `yes` to continue; with `-y` or `--force` it proceeds directly.
- **Previous behavior**: add `-keep-extra` to overwrite without deleting.
- **Recoverable**: a snapshot is taken before every restore (`/root/clpBackup/rollback/`) and covers every file that can be deleted; a failed restore is rolled back automatically.

#### ④ Pre-Restore Snapshot

- **Disk space check first**: before the snapshot, the size of the site directory (without the cache and backup-plugin folders above) plus the database, with a 10% margin, is compared with the free space of `/root/clpBackup`.
- **Not enough space or snapshot failure**: the incomplete snapshot is removed and nothing has been changed yet. In interactive mode you are asked whether to continue without a snapshot (type `yes`); with `-y` or `--force` the restore is aborted.
- **Skipping the snapshot**: add `-no-snapshot` to restore without a snapshot. A failed restore then cannot be rolled back automatically; use it at your own risk.

```bash
sudo clp restore example.com -type=compact -no-snapshot
```

Keep extra files on the site:

```bash
sudo clp restore example.com -type=compact -keep-extra
```

#### ⑤ Restoring a Complete Site from compact + db + archive

`restore` handles one file at a time. Each type only touches its own scope, so restoring the three files one after another rebuilds the complete site. Recommended order: `db` → `compact` → `archive`:

```bash
sudo clp restore example.com -type=db -to=google
```

```bash
sudo clp restore example.com -type=compact -to=google
```

```bash
sudo clp restore example.com -type=archive -to=google
```

Note: every restore takes a full site snapshot first, so three restores create three snapshots. Make sure `/root/clpBackup` has enough free space.

---

### 5. HTTP Basic Authentication (`clp httpauth`)

Password protection and access control for sites. Password files are stored securely outside document roots at `/home/<user>/.htpasswd`:

#### ① User Management

Interactive user creation (masked password input):

```bash
sudo clp httpauth example.com -add
```

Command-line creation with inline credentials (Note: inline password will appear in shell history; interactive mode is recommended):

```bash
sudo clp httpauth example.com -add=[admin,StrongPassword123!]
```

Delete user:

```bash
sudo clp httpauth example.com -delete=admin
```

List current authenticated users:

```bash
sudo clp httpauth example.com -list
```

#### ② WordPress Admin Protection (`-wp-admin`)

Enforce HTTP Auth on `/wp-admin/` and `wp-login.php` to prevent automated brute-force attempts:

Enable admin protection:

```bash
sudo clp httpauth example.com -wp-admin
```

Disable admin protection:

```bash
sudo clp httpauth example.com -wp-admin -off
```

#### ③ Full-Site or Path Protection (`-path`)

Full site protection (ideal for staging environments):

```bash
sudo clp httpauth example.com -path=/
```

Remove full site protection:

```bash
sudo clp httpauth example.com -path=/ -off
```

Protect specific subdirectory:

```bash
sudo clp httpauth example.com -path=/staging
```

#### ④ IP / CIDR Whitelisting (`-whitelist`)

Allow specified IP addresses or office subnets direct access without passwords (Nginx `satisfy any` mechanism):

Add IPs or CIDR blocks to whitelist:

```bash
sudo clp httpauth example.com -whitelist=203.0.113.50,192.168.1.0/24
```

Remove specific IP from whitelist:

```bash
sudo clp httpauth example.com -whitelist=203.0.113.50 -delete
```

Clear all whitelisted IPs (all users must authenticate):

```bash
sudo clp httpauth example.com -whitelist=clear
```

View protection summary dashboard:

```bash
sudo clp httpauth example.com -list=protected
```

---

### 6. PHP-FPM Pool Tuning (`clp php-pm`)

Tuning PHP-FPM pool parameters for high-traffic workloads (`pm.max_children = 35`, `pm.process_idle_timeout = 30s`, `pm.max_requests = 300`):

Optimize single site (auto-detects active PHP version):

```bash
sudo clp php-pm example.com
```

Optimize all sites on the server in batch:

```bash
sudo clp php-pm all
```

- Automatic timestamped backup saved to `/root/php/` prior to any change.
- Syntax testing via `php-fpm<version> -t` with instant automatic rollback upon syntax errors.

---

### 7. Global Configuration Management (`clp config`)

CLP Helper provides a dedicated configuration management module (`clp config`) to safely persist system preferences and API credentials in `/etc/clp/clp.conf` (strictly secured with `chmod 600`, accessible only by `root`).

#### Supported Configuration Keys

| Key | Description | Allowed Values / Format |
| :--- | :--- | :--- |
| `lang` | Default CLI interface language | `en_US`, `zh_TW` |
| `cf-token` | Cloudflare API Token for edge WAF & SSL DNS-01 automation | Token string or credentials file path (e.g. `/root/.secrets/example.ini`) |

#### Available Commands & Examples

Set system default language to Traditional Chinese:

```bash
sudo clp config -set lang=zh_TW
```

Set system default language to English (WordPress standard):

```bash
sudo clp config -set lang=en_US
```

Set Cloudflare API Token (direct token string):

```bash
sudo clp config -set cf-token="your_cloudflare_api_token"
```

Set Cloudflare API Token (credentials file path - auto-extracts token):

```bash
sudo clp config -set cf-token="/root/.secrets/example.ini"
```

Query configured value (sensitive tokens are automatically masked: 1234****cdef, shows source):

```bash
sudo clp config -get lang
```

```bash
sudo clp config -get cf-token
```

Output unmasked raw token string:

```bash
sudo clp config -get cf-token --raw
```

List all current global configuration parameters:

```bash
sudo clp config -list
```

Remove a configured key (reverts to system default):

```bash
sudo clp config -unset lang
```

```bash
sudo clp config -unset cf-token
```

---

## 7. Crontab Best Practices

Automate recurring maintenance tasks via `sudo crontab -e` (Note: CLI log messages are output to `stderr`; always redirect using `>> file 2>&1` in crontab):

```cron
# ==============================================================================
# CLP Helper Automated Backup & Maintenance Schedule
# ==============================================================================

# 1. Daily 03:00 - Database backup of all sites to Google Drive (7-day retention)
0 3 * * * /usr/local/bin/clp backup all -type=db -to=google -expire=7d -exclude="test.,dev.,staging." >> /var/log/clp/cron-backup-db.log 2>&1

# 2. Daily 03:30 - Compact file backup of all sites to Google Drive (7-day retention)
30 3 * * * /usr/local/bin/clp backup all -type=compact -to=google -expire=7d -exclude="test.,dev.,staging." >> /var/log/clp/cron-backup-compact.log 2>&1

# 3. Monthly 1st 04:00 - Past years' uploads (archive) to Google Drive (keeps the latest 2; together with 1 and 2 this is the complete site)
0 4 1 * * /usr/local/bin/clp backup all -type=archive -to=google -expire=35d -exclude="test.,dev.,staging." >> /var/log/clp/cron-backup-archive.log 2>&1

# 4. (Optional) Monthly 2nd 04:00 - Full backup to Google Drive (the complete site at a single point in time, keeps the latest 2)
0 4 2 * * /usr/local/bin/clp backup all -type=full -to=google -expire=35d -exclude="test.,dev.,staging." >> /var/log/clp/cron-backup-full.log 2>&1

# 5. Weekly Sunday 05:00 - Server cleanup (journal logs, APT packages, temp files)
0 5 * * 0 /usr/local/bin/clp server -clean >> /var/log/clp/cron-clean.log 2>&1
```

> [!NOTE]
> Old backups are removed only after the new backup has been uploaded successfully. A 35-day retention for the monthly backups (3 and 4) keeps both this month's and last month's copies after every run. Files deleted from Google Drive go to the trash by default and still use space until the trash is emptied; if space is tight, add `use_trash = false` to the rclone Google Drive remote.

---

## 8. Security Architecture

1. **Anti-Lockout SSH Guarantee**: Before disabling password authentication, strictly validates public key authorization in `/root/.ssh/authorized_keys` and `SUDO_USER`. Overrides conflicting provider drop-in configs (e.g. `50-cloud-init.conf`) and verifies active parameters using `sshd -T`.
2. **Zero-Write Cross-Server Migration**: All cross-host transfers stream data into the local instance. No agent or scripts are installed on the remote machine, ensuring source files are never altered or written to.
3. **Path Sanitization & WAF Fault Tolerance**: Automatically detects legacy paths in plugin configurations (Wordfence WAF, WP Rocket) during site cloning and migration to prevent fatal PHP errors.
4. **Isolated Redis Cache Salt**: Automatically injects unique random salts into `wp-config.php` for Redis caching to eliminate cross-site cache collision.

---

## 9. Directory Structure

```text
clp-helper/
├── clp.sh                   # Main router and command entrypoint
├── get.sh                   # One-line bootstrap installer (downloads from GitHub, then runs install.sh)
├── install.sh               # One-click global installer and uninstaller
├── LICENSE                  # MIT open source license
├── README.md                # Documentation & manual (English)
├── README.zh-TW.md          # Documentation & manual (Traditional Chinese)
├── lib/                     # Core module libraries
│   ├── backup.sh            # Backup & restore (rclone multi-cloud integration)
│   ├── cloudflare.sh        # Cloudflare integration (DNS-01 SSL, edge WAF)
│   ├── clp_fileops.py       # Secure file operations helper (O_NOFOLLOW / fd)
│   ├── config.sh            # Global configuration management (clp config)
│   ├── core.sh              # Core utilities (logging, checks, DB access, typos)
│   ├── httpauth.sh          # HTTP Basic auth & IP whitelisting
│   ├── httpauth_vhost.py    # Nginx vhost HTTP auth injector helper
│   ├── i18n.sh              # Internationalization (i18n) runtime engine
│   ├── php_fpm.sh           # Dynamic PHP-FPM detection and tuning
│   ├── server.sh            # Server ops, hardening & 17-module installer
│   └── site.sh              # Site management (create, clone, migrate, delete)
├── locales/                 # i18n language dictionary files (WordPress standard)
│   ├── en_US.sh             # English locale strings (primary / fallback: en_US)
│   ├── en.sh                # Compatibility redirect shim to en_US.sh
│   └── zh_TW.sh             # Taiwan Traditional Chinese locale strings (zh_TW)
└── templates/               # Configuration templates
    ├── cf-rules.conf        # Cloudflare custom WAF rules template
    └── nginx-httpauth.conf  # HTTP authentication template
```

---

## 10. License

This project is licensed under the [MIT License](LICENSE).
Free to modify, distribute, and use commercially.

CLP Helper is an independent project and is not affiliated with CloudPanel or MGT Commerce GmbH. CloudPanel and WordPress are trademarks of their respective owners.
