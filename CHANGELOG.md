# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
