# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
