# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.7.0] - 2026-02-08

### Added
- **Standalone uninstaller** (`uninstall.sh`) — Single-line `curl | bash` command to completely remove TimeMachine from server or client. Auto-detects installation type, step-by-step progress, confirmation prompt, `--force` and `--remove-backups` options
- **Fancy ASCII art installer** — ANSI Shadow block-letter banner for TIME MACHINE with colored output, step-by-step progress display (`[1/9] Step description`), and completion banner
- **Multi-distro package manager support** — `get.sh` and `install.sh` now support Debian/Ubuntu, RHEL/CentOS/Fedora, Rocky/Alma, openSUSE (zypper), Arch/Manjaro (pacman), Alpine (apk), and macOS (brew) with auto-detection fallback
- **Service auto-start** — Server installation now automatically starts the TimeMachine service after setup; service is enabled on boot via systemd

### Changed
- `get.sh` — Fixed hanging during git installation by adding `DEBIAN_FRONTEND=noninteractive` and non-interactive flags for all package managers; added zypper/pacman/apk support
- `install.sh` — Replaced plain-text banners with fancy ASCII art; added step-by-step progress for both server (9 steps) and client (4-5 steps) installs; post-install instructions now show `restart` instead of `start`; added uninstall command reference in post-install output
- `README.md` — Expanded uninstalling section with single-line curl command, `--force`/`--remove-backups` options, and manual uninstall; updated "Start the Service" to "Start / Restart the Service" with systemctl commands; added `uninstall.sh` to architecture diagram

### Fixed
- `get.sh` installation hanging at `apt-get update` on systems with dpkg locks or interactive prompts
- Package installation failing silently on non-Debian/RHEL distributions

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
