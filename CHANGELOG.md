# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.4.1] - 2026-02-09

### Added
- **Live log streaming in web dashboard** — When viewing logs for a running backup, the log viewer auto-refreshes every 2 seconds with a green "Live" badge. Auto-scrolls to bottom as new lines appear. Switches to "Completed" badge when backup finishes and stops polling
- **`running` field in logs API** — `GET /api/logs/<hostname>` now includes `"running": true/false` so the frontend knows when to stream

### Changed
- Log viewer now shows up to 500 lines (was 200) with a header showing live/completed status and log filename
- Log viewer respects user scroll position — only auto-scrolls if user is already at the bottom

## [2.4.0] - 2026-02-09

### Added
- **Snapshot file browser in web dashboard** — Click "Browse" on any snapshot to navigate directories and files with breadcrumb navigation. Directories are clickable, files show size
- **Download from web dashboard** — Download any folder or file as a `.tar.gz` archive directly from the browser. Available at snapshot level, folder level, or individual item level
- **Restore from web dashboard** — "Restore" button on any folder/file opens a modal with options: restore mode (full/files-only/db-only), custom target directory, or download instead. Restore runs in background with logging
- **API: `GET /api/browse/<hostname>/<snapshot>/<path>`** — Browse directories and files inside backup snapshots
- **API: `GET /api/download/<hostname>/<snapshot>/<path>`** — Download a tar.gz archive of any path in a snapshot
- **API: `POST /api/restore/<hostname>`** — Start a restore job with snapshot, path, target, and mode options

### Changed
- Snapshots modal now includes Browse and Download buttons per snapshot
- CORS headers updated to include PUT method

## [2.3.1] - 2026-02-09

### Fixed
- **DB backup on servers without databases** — `dump_dbs.sh` now exits early with clear "No databases to dump — skipping" message when no DB engines are detected. `timemachine.sh` detects this and skips the SQL sync phase entirely, avoiding confusing "Phase 2: Database backup" + "All database dumps completed successfully" logs on DB-less servers
- **Remote dump output visibility** — All remote `dump_dbs.sh` output is now forwarded to the backup log with `[remote]` prefix for better debugging

### Changed
- **Backup button in web dashboard** — Clicking "Backup" on a server row now opens a mode selection modal (Full / Files only / Database only) instead of immediately starting a full backup

## [2.3.0] - 2026-02-09

### Added
- **`tmctl server edit`** — New CLI command to modify server settings: `tmctl server edit <hostname> --priority N --db-interval Xh --files-only --db-only --no-rotate --full --rotate`
- **`PUT /api/servers/<hostname>`** — New API endpoint to update server settings from the web dashboard. Accepts JSON body with `mode`, `priority`, `db_interval`, `no_rotate`
- **Server edit modal in web dashboard** — "Edit" button on each server row opens a settings modal with backup mode, priority, DB backup interval, and rotation toggle
- **Parsed flags in `GET /api/servers`** — Response now includes `files_only`, `db_only`, `no_rotate` boolean fields for easier frontend consumption

### Changed
- Server actions row now includes Edit button between Backup and Snaps
- `tmctl server` subcommand accepts `add`, `edit`, and `remove`

## [2.2.2] - 2026-02-09

### Fixed
- **Database dump self-restart permission denied on client** — Server now pipes `dump_dbs.sh` via SSH stdin instead of relying on the client having an up-to-date copy. Eliminates version mismatch and `.sh-tmp` permission errors entirely
- **Mail tool not found on RHEL 9** — RHEL 9+ uses `s-nail` (provides `mailx`) instead of `mailx` package. Updated install dependencies and all notification functions to try `mail`, `mailx`, `msmtp`, `sendmail` in order
- **Missing mail dependency on update** — `tmctl update` now auto-installs `s-nail`/`mailx`/`mailutils` if no mail tool is present

### Changed
- `tm_trigger_remote_dump()` rewritten: pipes script via SSH stdin with env vars prepended, no client-side script dependency needed
- Install dependencies: RHEL/Rocky/Fedora now install `s-nail` with `mailx` fallback
- Fallback package managers also include mail tools

## [2.2.1] - 2026-02-09

### Fixed
- **Rsync permission denied on client** — Added `--rsync-path='sudo rsync'` so the remote (sender) side runs rsync with sudo, using the sudoers NOPASSWD rule. Fixes all "Permission denied" errors when backing up protected files
- **Email notifications not sending** — `timemachine.sh` now sources `lib/notify.sh` for full multi-channel notifications (email, webhook, Slack). Fallback also supports `msmtp` and `sendmail` besides `mail`
- **`dump_dbs.sh` not found on client** — SSH command now tries `~/dump_dbs.sh` then `/opt/timemachine-backup-linux/bin/dump_dbs.sh` with clear error if neither exists
- **`tmctl update` "dubious ownership" error** — Added `git config --global --add safe.directory` before git operations when running as root. Restores file ownership to `timemachine` after update
- **Version detection under sudo** — `_get_current_version()` now reads `VERSION` file first (single source of truth) instead of relying on `git describe` which fails under sudo

### Added
- **Dashboard timestamps** — Servers table shows full datetime + relative time ("2h ago"), failures panel shows relative timestamps, new `formatDateTime`/`timeAgo` JS helpers
- **`timestamp` field in `/api/failures`** — Extracted from log line or filename
- **`last_backup_time` field in `/api/history`** — Full datetime of last backup run

## [2.2.0] - 2026-02-09

### Added
- **`tmctl fix-permissions`** — New command to repair all file/directory permissions without re-running the full installer. Fixes install dir, home, SSH, logs, credentials, backup root, runtime dir, sudoers validation, and tmpfiles.d. Requires sudo
- **`server_fix_permissions()`** — Comprehensive permission repair function in `install.sh`, called as step 13 during server installation
- **`tmpfiles.d` support** — Creates `/etc/tmpfiles.d/timemachine.conf` so `/run/timemachine` persists across reboots on systemd systems

### Fixed
- **Self-restart temp dir conflicts** — Changed from shared `/tmp/tm-self-restart/` to per-user `/tmp/tm-self-restart-<uid>/` to prevent permission denied errors when root and timemachine user both use self-restart
- **Server sudoers hardcoded paths** — `server_setup_sudoers()` now resolves actual binary paths dynamically (like client installer already did). Adds database commands (mysql, mysqldump, mariadb, psql, pg_dump) if detected
- **Directory ownership gaps** — `server_setup_directories()` now explicitly sets ownership on `TM_HOME`, `TM_HOME/.ssh`, and all subdirs with restrictive permissions (750/700)
- **Systemd service file** — Added `RuntimeDirectoryMode=0750` and `StateDirectory=timemachine`, fixed documentation URL, removed stray whitespace on `ProtectSystem`
- **Uninstall cleanup** — `tmctl uninstall` and `uninstall.sh` now also remove `/etc/tmpfiles.d/timemachine.conf`

### Changed
- Install flow now has 13 steps (was 12) — final step runs `server_fix_permissions` to verify all ownership
- 159 tests across 9 suites (was 158)

## [2.1.0] - 2026-02-08

### Added
- **System metrics dashboard** — New cards showing CPU load (1m/5m), memory usage with progress bar, and full system info panel (OS, kernel, CPU cores, total memory, system uptime, load averages)
- **Failed backups panel** — Auto-detected from log files, shows server name and error message with "View Logs" and "Retry" buttons. Panel only visible when failures exist (red header)
- **Backup history in servers table** — Servers table now shows last backup date, snapshot count, total backup size, and health status (OK/Error) per server
- **Log viewer** — "Logs" button on every server and process row opens a modal with the last 100 lines of that server's log file
- **One-liner client installer** — New "Add New Client" panel shows a copy-pastable `curl | bash` command that installs the client on any server with one command
- **`/api/system` endpoint** — Returns CPU load averages, memory total/used/available/percent, CPU count, OS name, kernel version, system uptime
- **`/api/failures` endpoint** — Scans log files for FAIL/ERROR/fatal lines and returns recent failures per server
- **`/api/history` endpoint** — Returns last backup date, snapshot count, total size, and health status per configured server
- **`VERSION` file** — Single source of truth for version number, read by `/api/status` endpoint. Ensures `tmctl update` can always detect the current version

### Changed
- Dashboard layout reorganized: service info cards (row 1), system metrics + disk (row 2), failures, processes, servers with history, installer, SSH key, quick backup, system info
- Servers table columns changed from Options/Priority/DB Interval to Last Backup/Snapshots/Total Size/Status
- Modal widened to 800px max for better log viewing
- SSH key section simplified (removed install hints, replaced by dedicated installer panel)
- Process table now includes "Logs" button per process

## [2.0.0] - 2026-02-08

### Added
- **Standalone uninstaller** (`uninstall.sh`) — Single-line `curl | bash` command to completely remove TimeMachine from server or client. Auto-detects installation type, step-by-step progress, confirmation prompt, `--force` and `--remove-backups` options
- **Fancy ASCII art installer** — ANSI Shadow block-letter banner for TIME MACHINE with colored output, step-by-step progress display (`[1/12] Step description`), and completion banner
- **Multi-distro package manager support** — `get.sh` and `install.sh` now support Debian/Ubuntu, RHEL/CentOS/Fedora, Rocky/Alma, openSUSE (zypper), Arch/Manjaro (pacman), Alpine (apk), and macOS (brew) with auto-detection fallback
- **Service auto-start** — Server installation now automatically starts the TimeMachine service after setup; service is enabled on boot via systemd
- **Client database auto-detection** — Client installer now automatically detects installed database engines (MySQL/MariaDB, PostgreSQL, MongoDB, Redis, SQLite) and prompts for credentials per database. Auto-imports existing credentials from `/root/mysql.pw` and `/root/.my.cnf` for MySQL. PostgreSQL uses peer auth (no prompt). `--with-db` is auto-enabled when databases are found
- **Dashboard makeover** — Complete redesign of web dashboard with modern dark theme, gradient header, animated status indicators (pulsing dot), disk usage progress bar with color thresholds, toast notifications (replaces alert()), snapshot modal dialog, collapsible add-server form, and improved responsive layout
- **Disk usage API** — New `/api/disk` endpoint returns backup volume total/used/available/percent for the dashboard
- **SSH key download fallback** — Client installer tries HTTPS (port 443, nginx gateway) first, then HTTP (port 7600), with clear diagnostic messages on failure and graceful fallback to manual key paste
- **Firewall auto-configuration** — Server installer detects binadit-firewall (`/usr/local/sbin/binadit-firewall`), ufw, and firewalld and automatically opens the dashboard port (default 7600). Shows manual instructions if no managed firewall is found
- **Dashboard security with Let's Encrypt** — Server installer asks for domain, username, and password (with confirmation) to set up HTTPS + password protection via Nginx + certbot. Reuses report email for Let's Encrypt. Shows credentials in post-install output
- **Self-signed SSL support** (`setup-web.sh`) — New `--with-ssl`, `--with-auth`, and `--self-signed` flags for quick nginx proxy setup without a domain. Generates a 10-year self-signed certificate as fallback when certbot is unavailable
- **binadit-firewall integration** — `setup-web.sh` and server installer detect binadit-firewall at `/usr/local/sbin` and auto-open ports using `binadit-firewall config add TCP_PORTS`
- **Weekly auto-update** — Server installer asks whether to enable automatic weekly updates via cron (Sunday 04:00). Also available as `tmctl auto-update on|off|status` CLI command. Logs to `logs/auto-update.log`
- **Certbot multi-method install** — `setup-web.sh` tries EPEL + package manager, then snap, then pip to install certbot. Falls back to self-signed cert if all methods fail
- **Post-install command reference** — Server installer now shows complete `tmctl` command reference, dashboard credentials, and getting started guide after installation
- **Final service restart** — Installer restarts the TimeMachine service at the end to ensure it runs with the latest configuration
- **SELinux auto-configuration** — Installer and setup-web.sh automatically enable `httpd_can_network_connect` and set `httpd_sys_content_t` file context on RHEL/CentOS/Rocky/Alma for nginx proxy and static file serving
- **Nginx static file serving** — Dashboard HTML/CSS/JS served directly from disk by nginx with correct MIME types; only `/api/` requests proxied to TimeMachine service
- **Robust `tmctl update`** — Version detection from git tags or CHANGELOG.md; auto-unshallow for shallow clones; curl-based tarball fallback when git remote unreachable; shows actual git errors

### Changed
- `get.sh` — Fixed hanging during git installation by adding `DEBIAN_FRONTEND=noninteractive` and non-interactive flags for all package managers; added zypper/pacman/apk support; fetches tags on clone/update
- `install.sh` — Replaced plain-text banners with fancy ASCII art; added step-by-step progress for server (12 steps) and client (4-5 steps) installs; complete post-install output with getting started guide, dashboard info, and full command reference; SELinux auto-configuration in firewall step
- `tmserviced.sh` — Replaced fragile `export -f` + `SYSTEM:"bash -c '...'"` approach with self-contained handler script generation (`_generate_handler_script`). Each HTTP request now runs a standalone script with all functions and variables embedded. Changed socat from `SYSTEM:` to `EXEC:` for direct script execution. Added `disown` to `run_backup()` so background backups survive handler exit. ncat now uses `--keep-open --sh-exec` for concurrent connections. HTTP handler has 5s read timeouts. Content-Length uses byte count
- `setup-web.sh` — Nginx uses `restart` instead of `reload` after SSL setup; automatically restarts TimeMachine service after changing `TM_API_BIND` to `127.0.0.1`; shows actual password in completion output; serves static files from disk; SELinux file context and network connect configuration
- `timemachine.service` — Added `RuntimeDirectory=timemachine` and `LogsDirectory=timemachine` for automatic directory creation by systemd; removed hardcoded `ReadWritePaths=/backups`
- `README.md` — Complete SEO-optimized rewrite with keyword-rich headings, "Why TimeMachine for Linux?" section, badges, supported distributions list, horizontal rule separators, and keywords footer for search engine discoverability

### Fixed
- **Dashboard not starting** — HTTP server failed to bind port 7600 because `export -f` bash functions were stripped by socat's `/bin/sh` intermediary on systems with Shellshock mitigations. Replaced with handler script approach
- **Dashboard 502 errors with ncat** — ncat (without socat) handles only one connection at a time. Dashboard makes 5+ concurrent API calls, causing "Connection refused" on all but one. Now uses `ncat --keep-open --sh-exec` for concurrent handling
- **Dashboard broken after setup-web** — `setup-web.sh` changed `TM_API_BIND` to `127.0.0.1` but did not restart the TimeMachine service, leaving the old binding active. After manual restart, nginx proxy couldn't reach the API
- **Dashboard MIME type errors** — `X-Content-Type-Options: nosniff` blocked `app.js` execution when proxied through bash HTTP server with wrong Content-Type. Nginx now serves static files directly from disk
- **SELinux blocking nginx proxy** — On RHEL/CentOS, `httpd_can_network_connect` is off by default, preventing nginx from proxying to backend ports. Now auto-enabled during install and setup-web
- **SELinux blocking nginx static files** — Web directory lacked `httpd_sys_content_t` context. Now set automatically via `semanage`/`chcon`
- **binadit-firewall not detected** — Binary at `/usr/local/sbin/binadit-firewall` was not in sudo's `secure_path`, causing `command -v` to fail. Now checks the known path directly as fallback
- **Certbot install failure on RHEL/CentOS** — `certbot` and `python3-certbot-nginx` packages not available without EPEL. Now installs `epel-release` first, with snap and pip fallbacks
- **Nginx not restarted after SSL cert** — `finalize()` used `systemctl reload` which doesn't work for first-time SSL config. Changed to `systemctl restart`
- **Service not starting after install** — Missing `/var/run/timemachine` directory on first boot. Added `RuntimeDirectory=timemachine` to systemd unit and pre-creation in installer
- **`tmctl update` failing** — `git describe --tags` failed on shallow clones; `git fetch` errors hidden; no fallback when git remote unreachable
- `get.sh` installation hanging at `apt-get update` on systems with dpkg locks or interactive prompts
- Package installation failing silently on non-Debian/RHEL distributions
- `SCRIPT_DIR` not exported to socat subprocesses, causing backup-via-dashboard to fail

## [0.6.0] - 2026-02-06

### Added
- **Email backup reports** — After each daily backup run, a detailed report is generated and sent via email/webhook/slack with per-server success/failure status, duration, and mode
  - `lib/report.sh` — New report generator library (`tm_report_init`, `tm_report_add`, `tm_report_send`)
  - Reports saved to `logs/report-daily-YYYY-MM-DD.log`
  - DB interval backups send individual success/failure notifications
- **Email setup during install** — `install.sh` now prompts for a report email address during server installation, automatically configures `TM_ALERT_ENABLED` and `TM_ALERT_EMAIL` in `.env`
- **Server priority** — `--priority N` option per server (1=highest, default=10). Servers with lower numbers are backed up first during daily runs
- **DB interval backups** — `--db-interval Xh` option per server for extra DB-only backups throughout the day (e.g. `--db-interval 4h` = every 4 hours). Works with all DB types (MySQL, PostgreSQL, MongoDB, Redis, SQLite)
- **Priority sorting** in `daily-runner.sh` and `tmserviced.sh` scheduler — servers processed in priority order
- **DB interval scheduler** — checks every minute, triggers `--db-only` backup when interval elapsed, resets after daily full backup
- **Web dashboard** — Priority and DB Interval columns in server table, input fields in add server form
- **API** — `/api/servers` response now includes `priority` and `db_interval` fields
- **`tmctl update`** — Update to the latest version with one command. Fetches latest code, shows version diff, restarts service if running, displays changelog excerpt
- **`tmctl uninstall`** — Complete removal: stops service, removes systemd/cron/sudoers/symlinks/nginx config/user/install directory. Preserves backup data. Requires sudo and confirmation
- **New tests** — Report library (18), priority/db-interval (15), syntax checks (3), update/uninstall help (2) — 158 total tests across 9 suites

### Changed
- `bin/timemachine.sh` — Accepts and skips `--priority N` and `--db-interval Xh` flags (consumed by scheduler)
- `bin/daily-runner.sh` — Rewritten: sorts by priority, tracks per-server results via PID file, generates report after run
- `bin/tmserviced.sh` — Scheduler delegates daily runs to `daily-runner.sh`; DB interval backups send notifications; sources `lib/report.sh`
- `config/servers.conf.example` — Updated with priority and db-interval examples
- `install.sh` — Added `server_ask_email()` step; improved post-install instructions with `tmctl server add` examples, curl one-liner for client install, and `tmctl update` hint

### Fixed
- Color escape sequences not rendered in installer prompts (use `$'...'` syntax)

## [0.5.0] - 2026-02-06

### Added
- **`tmctl setup-web`** — Interactive command to expose the web dashboard securely over HTTPS
  - Installs and configures **Nginx** as reverse proxy to `localhost:7600`
  - Obtains **Let's Encrypt SSL** certificate via certbot (with auto-renewal)
  - Creates **HTTP Basic Auth** credentials (bcrypt via htpasswd)
  - Configures firewall (ufw/firewalld) for ports 80/443
  - Binds API to `127.0.0.1` so it's only accessible through nginx
  - Optional: leave `/api/ssh-key/raw` open (no auth) for automated client installs
  - Supports non-interactive mode: `--domain`, `--email`, `--user`, `--pass`
  - `--remove` flag to undo all changes
- **`bin/setup-web.sh`** — Standalone setup script (also callable via `tmctl setup-web`)

### Changed
- **Full-filesystem backup** — Rsync now syncs entire remote filesystem (`/`) instead of individual paths. The `config/exclude.conf` determines what is skipped (system dirs, caches, DB data dirs, etc.). Replaces `TM_BACKUP_PATHS` with `TM_BACKUP_SOURCE=/`
- `lib/rsync.sh` — Replaced per-path loop with single rsync from `$TM_BACKUP_SOURCE` (default `/`)
- `lib/common.sh` — `TM_BACKUP_PATHS` replaced by `TM_BACKUP_SOURCE=/`
- `.env.example` — Updated file backup section to document `TM_BACKUP_SOURCE`

## [0.4.0] - 2026-02-06

### Added
- **Server management via CLI** — `tmctl server add <host> [OPTIONS]` and `tmctl server remove <host>` to manage `servers.conf` from the command line
- **Server management via API** — `POST /api/servers` and `DELETE /api/servers/<host>` endpoints for programmatic server management
- **Server management via web dashboard** — Add/remove servers directly from the web UI with hostname + options form
- **Standardized credential storage** — All database credentials now stored in `~timemachine/.credentials/` (mode 700) with consistent file names: `mysql.pw`, `mongodb.conf`, `redis.pw`, `pgpass`
- **`TM_CREDENTIALS_DIR`** — New config variable for credential storage directory (default: `~timemachine/.credentials/`)
- **New tests** — Server add/remove (8 tests), credential path validation, help text — 120 total tests across 9 suites

### Changed
- `bin/dump_dbs.sh` — MySQL password now reads from `$TM_CREDENTIALS_DIR/mysql.pw` (was `/root/mysql.pw`); MongoDB from `$TM_CREDENTIALS_DIR/mongodb.conf` (was `~/.mongo_credentials`); Redis from `$TM_CREDENTIALS_DIR/redis.pw` (was `~/.redis_password`)
- `lib/common.sh` — Added `TM_CREDENTIALS_DIR` default; `TM_MYSQL_PW_FILE` now defaults to `$TM_CREDENTIALS_DIR/mysql.pw`
- `.env.example` — Credential storage section with unified documentation for all DB engines
- `install.sh` — Client mode now creates `~/.credentials/` directory with mode 700
- `bin/tmctl.sh` — Added `server add`/`server remove` subcommands; updated version to v0.3.1; `_api_post` now supports JSON body
- `bin/tmserviced.sh` — Added `POST /api/servers` and `DELETE /api/servers/<host>` API routes
- `web/app.js` — `apiPost` supports JSON body; added `addServer()`/`removeServer()` functions; server table includes Remove button
- `web/index.html` — Add Server form below server table; version updated

## [0.3.1] - 2026-02-06

### Changed
- **Unified installer** — Merged `install.sh`, `install-client.sh`, and `get.sh` into one workflow. `install.sh` now interactively asks whether to install as **server** or **client**. `install-client.sh` is removed.
- `install.sh` — Accepts `server` or `client` as first argument; client mode supports all previous `install-client.sh` options (`--server`, `--ssh-key`, `--with-db`, `--db-type`, `--db-cronjob`, `--uninstall`). Interactive SSH key setup when no key/server provided.
- `get.sh` — Simplified to clone/update repo and `exec install.sh` with all arguments passed through. Works for both server and client: `curl ... | sudo bash -s -- client --server host`
- `config/exclude.conf` — Expanded with production-tested defaults: `/backup`, `/Timemachine`, `/media`, `/mnt`, `/net`, `/var/log`, `/var/lib/mysql`, `/var/lib/postgresql`, `/var/lib/mongodb`, `/var/lib/redis`, `/var/lib/lxcfs/`, `/var/named/run-root/`, `varnish_storage.bin`, `node_modules`, `__pycache__`
- Updated all references from `install-client.sh` to `install.sh client` in `tmctl.sh`, `dump_dbs.sh`, `web/index.html`, `README.md`

### Removed
- `install-client.sh` — Functionality merged into `install.sh client`

## [0.3.0] - 2026-02-06

### Added
- **Single-line installer** (`get.sh`) — `curl | bash` install with interactive backup directory selection
- **Multi-database support** — MySQL/MariaDB, PostgreSQL, MongoDB, Redis, SQLite with auto-detection (`TM_DB_TYPES=auto`)
- **Per-server exclude files** — `config/exclude.<hostname>.conf` for server-specific rsync exclude patterns (additive to global)
- **Configurable backup paths** — `TM_BACKUP_PATHS` variable to customize which remote directories to back up
- **Per-server exclude example** — `config/exclude.example.com.conf` template
- **Database credential docs** — Complete setup instructions for each DB engine's authentication
- **New tests** — `test_excludes.sh` (11 tests), `test_database.sh` (19 tests) — 95 total tests across 9 suites

### Changed
- `install.sh` — Creates `<backup_dir>/timemachine/` subdirectory with correct ownership (750); writes `TM_BACKUP_ROOT` to `.env`
- `bin/dump_dbs.sh` — Complete rewrite: auto-detects DB engines, supports MySQL, PostgreSQL, MongoDB, Redis, SQLite with per-engine credential handling
- `lib/database.sh` — New `tm_trigger_remote_dump()` passes all DB config vars to remote `dump_dbs.sh` via SSH environment
- `lib/rsync.sh` — Replaced hardcoded excludes with file-based system (`_tm_rsync_excludes()`); backup paths now configurable via `TM_BACKUP_PATHS`
- `lib/common.sh` — Added config defaults for `TM_BACKUP_PATHS`, `TM_INSTALL_DIR`, `TM_DB_TYPES`, `TM_PG_USER`, `TM_PG_HOST`, `TM_MONGO_HOST`, `TM_MONGO_AUTH_DB`, `TM_REDIS_HOST`, `TM_REDIS_PORT`, `TM_SQLITE_PATHS`
- `install-client.sh` — Added `--db-type` option; sudoers now includes all detected DB tools (mysql, pg_dump, mongodump, redis-cli, sqlite3)
- `.env.example` — Expanded database section with all DB engine configs and credential documentation
- `bin/timemachine.sh` — Uses new `tm_trigger_remote_dump()` instead of inline SSH command

## [0.2.0] - 2026-02-06

### Added
- **Service daemon** (`bin/tmserviced.sh`) — Runs as systemd service with HTTP API and built-in scheduler
- **Web dashboard** (`web/`) — Real-time monitoring UI with status cards, process table, server list, kill buttons, and quick backup
- **CLI control tool** (`bin/tmctl.sh`) — Full CLI for status, ps, backup, kill, restore, logs, servers, snapshots, ssh-key
- **Restore functionality** (`bin/restore.sh`) — Selective file/database restore from any snapshot with `--list`, `--list-files`, `--list-dbs`, `--path`, `--db`, `--target`, `--date`, `--decrypt`, `--dry-run`
- **Multi-channel notifications** (`lib/notify.sh`) — Email, HTTP POST webhook (JSON payload), and Slack support via `TM_NOTIFY_METHODS`
- **Encryption** (`lib/encrypt.sh`) — GPG-based symmetric (passphrase) and asymmetric (key ID) backup encryption/decryption
- **SSH key distribution** — API endpoint `/api/ssh-key/raw` for auto-download; `install-client.sh --server <host>` fetches key automatically
- **Systemd integration** — `config/timemachine.service` unit file, installed by `install.sh` with fallback to cron
- **Convenience symlinks** — `tmctl`, `timemachine`, `tm-restore` in `/usr/local/bin`
- **Schedule configuration** — `config/schedule.conf.example` for daemon scheduler
- **New tests** — `test_notify.sh`, `test_encrypt.sh`, `test_restore.sh`, `test_tmctl.sh` (65 total tests)

### Changed
- `lib/common.sh` — Log output now goes to stderr (prevents interference with function return values); added config defaults for notifications, encryption, API, scheduler
- `lib/common.sh` — OS-aware rsync flags via `TM_RSYNC_FLAGS` array (macOS compatibility)
- `lib/rsync.sh` — Uses `TM_RSYNC_FLAGS` array instead of hardcoded flags
- `install.sh` — Now installs socat, curl, gnupg2; sets up systemd service; creates CLI symlinks
- `install-client.sh` — Added `--server` and `--server-port` options for automatic SSH key download
- `.env.example` — Added sections for notifications (webhook, Slack), encryption, service/API, scheduler

## [0.1.0] - 2026-02-06

### Added
- Initial project structure with modular architecture
- **bin/timemachine.sh** — Main backup script with `--files-only`, `--db-only`, `--no-rotate`, `--dry-run`, `--verbose` options
- **bin/daily-runner.sh** — Parallel job runner triggered by cron
- **bin/daily-jobs-check.sh** — Pre-backup stale process detection
- **bin/dump_dbs.sh** — Client-side MySQL/MariaDB database dump with retry logic
- **bin/dump_dbs_wait.sh** — Wait for cron-triggered database dumps
- **lib/common.sh** — Shared library: config loading, logging, locking, notifications, utilities
- **lib/rsync.sh** — Rsync-based file sync with hardlink rotation
- **lib/database.sh** — Database dump functions
- **config/servers.conf.example** — Server list template
- **config/exclude.conf** — Global rsync exclude patterns
- **install.sh** — Backup server installer (Debian/Ubuntu, RHEL/CentOS/Fedora)
- **install-client.sh** — Client server installer with `--with-db`, `--db-cronjob`, `--uninstall` options
- **tests/** — Test suite with unit tests and ShellCheck linting
- **.env.example** — Full configuration template with all options documented
- **README.md** — Comprehensive documentation
