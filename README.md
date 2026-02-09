# TimeMachine Backup for Linux

**The Time Machine alternative for Linux servers.** An open-source, rsync-based backup system that brings macOS Time Machine-style snapshots to Linux. Back up your entire server with rotating daily snapshots using hardlinks — only changed files consume extra disk space, giving you efficient point-in-time recovery for any day.

Perfect for sysadmins who want **automated Linux server backups** with a web dashboard, database support, encryption, and one-command install.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Shell: Bash](https://img.shields.io/badge/Shell-Bash-green.svg)](https://www.gnu.org/software/bash/)
[![Tests: 40+](https://img.shields.io/badge/Tests-40%2B-brightgreen.svg)](tests/)

---

## Why TimeMachine for Linux?

- **Zero-config backups** — One command installs everything. The installer detects your OS, databases, and firewall automatically.
- **Space-efficient** — Hardlinked snapshots mean a week of daily backups takes barely more space than a single copy.
- **Full-system coverage** — Backs up files *and* databases (MySQL, PostgreSQL, MongoDB, Redis, SQLite).
- **Web dashboard** — Monitor backups, start/kill jobs, and view snapshots from your browser.
- **Production-ready** — Used to protect real servers with systemd integration, automatic retries, and email/Slack alerts.

> *"Like macOS Time Machine, but for your Linux servers."*

---

## Quick Install

Install TimeMachine on any Linux server with a single command:

```bash
curl -sSL https://raw.githubusercontent.com/ronaldjonkers/timemachine-backup-linux/main/get.sh | sudo bash
```

The interactive installer asks whether you want to set up a **backup server** (stores backups) or **client** (gets backed up). It auto-detects your distro, installs dependencies, configures the firewall, and optionally sets up HTTPS + password protection for the dashboard.

**Supported distributions:** Debian, Ubuntu, RHEL, CentOS, Rocky Linux, AlmaLinux, Fedora, openSUSE, Arch Linux, Alpine Linux, and macOS (for development).

### Quick Client Install

On the servers you want to back up, run:

```bash
curl -sSL https://raw.githubusercontent.com/ronaldjonkers/timemachine-backup-linux/main/get.sh | sudo bash -s -- client --server backup.example.com
```

---

## Features

- **Time Machine-style snapshots** — Daily rotating backups with hardlinks (only changed files use extra disk space)
- **Service daemon** — Runs as a systemd service with built-in backup scheduler
- **Web dashboard** — Modern dark-themed monitoring UI with real-time status, process control, and disk usage
- **CLI control tool (`tmctl`)** — Full backup management from the command line
- **Restore** — Selective file and database restore from any snapshot
- **Multi-database support** — MySQL/MariaDB, PostgreSQL, MongoDB, Redis, SQLite with auto-detection
- **Exclude system** — Global defaults + per-server exclude patterns
- **Parallel execution** — Back up multiple servers simultaneously with priority ordering
- **Dashboard security** — HTTPS via Let's Encrypt + HTTP Basic Auth via Nginx reverse proxy
- **Multi-channel notifications** — Email reports, HTTP POST webhooks, Slack alerts
- **Encryption** — GPG-based symmetric or asymmetric backup encryption
- **SSH key distribution** — Auto-download SSH keys from the backup server API (HTTPS/HTTP fallback)
- **Configurable retention** — Automatic rotation of old backups (default: 7 days)
- **Firewall auto-detection** — Auto-opens ports on binadit-firewall, ufw, and firewalld
- **Weekly auto-updates** — Optional cron-based automatic updates
- **Client installer** — One-command setup with auto database detection and credential import
- **Modular architecture** — Clean shared libraries with reusable functions
- **Comprehensive tests** — 40+ automated tests across 9 test suites

---

## Architecture

```
timemachine-backup-linux/
├── bin/                           # Executable scripts
│   ├── timemachine.sh             # Main backup script (per host)
│   ├── tmserviced.sh              # Service daemon (HTTP API + scheduler)
│   ├── tmctl.sh                   # CLI control tool
│   ├── restore.sh                 # Restore from backup snapshots
│   ├── daily-runner.sh            # Parallel job runner (cron fallback)
│   ├── daily-jobs-check.sh        # Pre-backup stale process check
│   ├── dump_dbs.sh                # Multi-DB dump (runs on client)
│   └── dump_dbs_wait.sh           # Wait for cron-triggered DB dump
├── lib/                           # Shared libraries
│   ├── common.sh                  # Config, logging, locking, utilities
│   ├── rsync.sh                   # Rsync sync & rotation functions
│   ├── database.sh                # Database trigger & sync functions
│   ├── notify.sh                  # Multi-channel notifications
│   ├── report.sh                  # Backup report generator
│   └── encrypt.sh                 # GPG encryption/decryption
├── web/                           # Dashboard (served by tmserviced)
│   ├── index.html                 # Dashboard HTML
│   ├── style.css                  # Styles
│   └── app.js                     # Frontend JavaScript
├── config/                        # Configuration files
│   ├── servers.conf.example       # Server list template
│   ├── schedule.conf.example      # Scheduler configuration
│   ├── exclude.conf               # Global rsync exclude patterns
│   ├── exclude.example.com.conf   # Per-server exclude example
│   └── timemachine.service        # Systemd unit file
├── tests/                         # Test suite (158 tests)
│   ├── run_all_tests.sh           # Test runner
│   ├── test_common.sh             # Tests for lib/common.sh
│   ├── test_rsync.sh              # Tests for lib/rsync.sh
│   ├── test_notify.sh             # Tests for lib/notify.sh
│   ├── test_encrypt.sh            # Tests for lib/encrypt.sh
│   ├── test_restore.sh            # Tests for bin/restore.sh
│   ├── test_tmctl.sh              # Tests for bin/tmctl.sh
│   ├── test_excludes.sh           # Tests for exclude system
│   ├── test_database.sh           # Tests for database support
│   └── test_shellcheck.sh         # ShellCheck linting
├── bin/setup-web.sh               # Nginx + SSL + Auth setup for web dashboard
├── get.sh                         # Single-line installer (curl | bash)
├── install.sh                     # Unified installer (server + client)
├── uninstall.sh                   # Standalone uninstaller (curl | bash)
├── .env.example                   # Configuration template
├── .gitignore                     # Git ignore rules
├── CHANGELOG.md                   # Version history
└── README.md                      # This file
```

## Server Setup Guide

### 1. Install the Backup Server

```bash
# Single-line install (recommended)
curl -sSL https://raw.githubusercontent.com/ronaldjonkers/timemachine-backup-linux/main/get.sh | sudo bash

# Or manual install
git clone https://github.com/ronaldjonkers/timemachine-backup-linux.git
cd timemachine-backup-linux
sudo ./install.sh
```

This will:
- Create the `timemachine` user with SSH keys
- Install dependencies (rsync, socat, curl, gnupg2)
- Ask for the backup storage directory and create `<dir>/timemachine/` with correct permissions
- Set up sudoers and systemd service
- Generate `.env` and `config/servers.conf` from templates
- Create symlinks: `tmctl`, `timemachine`, `tm-restore` in `/usr/bin`
- Optionally enable weekly auto-updates (cron, Sunday 04:00)

### 2. Configure

```bash
# Main settings
sudo -u timemachine vi .env

# Add servers to back up
sudo -u timemachine vi config/servers.conf
```

### 3. Start / Restart the Service

The installer automatically starts the service and enables it on boot. To restart:

```bash
sudo systemctl restart timemachine
```

Other useful commands:

```bash
sudo systemctl status timemachine    # Check status
sudo systemctl stop timemachine      # Stop the service
journalctl -u timemachine -f         # Follow logs
```

The dashboard is now available at `http://<backup-server>:7600`.

> **Firewall:** The installer auto-detects binadit-firewall, ufw, and firewalld and opens port 7600 automatically. If no managed firewall is found, ensure TCP port 7600 is open manually.

#### Secure the Dashboard (optional)

During server installation you are asked whether to enable SSL + password protection. You can also run it later:

```bash
# Self-signed SSL + password (quick setup)
sudo tmctl setup-web --with-ssl --with-auth

# Let's Encrypt SSL + password (production)
sudo tmctl setup-web --domain tm.example.com --email admin@example.com

# Remove web proxy
sudo tmctl setup-web --remove
```

---

## Client Setup Guide

**Automatic** (downloads SSH key from the backup server API — tries HTTPS/443 first, then HTTP/7600, with manual-paste fallback):

```bash
# Standard install — auto-detects databases and asks for credentials
sudo ./install.sh client --server backup.example.com

# With autonomous DB dump cronjob
sudo ./install.sh client --server backup.example.com --db-cronjob

# Force specific database types (skip auto-detection)
sudo ./install.sh client --server backup.example.com --db-type mysql,postgresql
```

The installer automatically detects installed database engines (MySQL/MariaDB, PostgreSQL, MongoDB, Redis, SQLite) and prompts for credentials per database. Existing credentials are auto-imported:

- **MySQL**: checks `/root/mysql.pw` and `/root/.my.cnf` before asking
- **PostgreSQL**: uses peer auth (no password needed)
- **MongoDB**: asks for username + password if auth is enabled
- **Redis**: asks for password if `requirepass` is set
- **SQLite**: no credentials needed

**Manual** (provide SSH key directly):

```bash
sudo ./install.sh client --ssh-key "ssh-rsa AAAA..."
```

### 3. Test a Backup

```bash
tmctl backup web1.example.com --dry-run
tmctl status
```

---

## Updating TimeMachine

Update to the latest version on the backup server:

```bash
tmctl update
```

This will pull the latest code, restart the service if running, and show what's new. You can also re-run the one-liner:

```bash
curl -sSL https://raw.githubusercontent.com/ronaldjonkers/timemachine-backup-linux/main/get.sh | sudo bash
```

---

## CLI Tool — All Commands (`tmctl`)

The `tmctl` command is your primary interface for managing TimeMachine backups:

```bash
tmctl status              # Service status + running processes
tmctl ps                  # List all backup processes
tmctl backup <host>       # Start a backup
tmctl kill <host>         # Kill a running backup
tmctl restore <host>      # Restore from backup (interactive)
tmctl logs [host]         # View logs
tmctl servers             # List configured servers
tmctl server add <host>   # Add a server (--files-only, --db-only, --no-rotate, --priority N, --db-interval Xh)
tmctl server remove <host> # Remove a server
tmctl snapshots <host>    # List available snapshots
tmctl ssh-key             # Show SSH public key
tmctl setup-web           # Setup Nginx + SSL + Auth for external dashboard access
tmctl update              # Update to the latest version
tmctl auto-update on      # Enable weekly auto-updates (Sunday 04:00)
tmctl auto-update off     # Disable auto-updates
tmctl auto-update status  # Show auto-update status
tmctl fix-permissions     # Fix all file/directory permissions (sudo)
tmctl uninstall           # Remove TimeMachine completely (sudo)
tmctl version             # Show version
```

---

## Securing the Dashboard (HTTPS + Password Protection)

To make the web dashboard securely accessible from the internet:

```bash
sudo tmctl setup-web
```

This interactive command will:
1. Install **Nginx** as a reverse proxy
2. Obtain a **Let's Encrypt SSL** certificate (via certbot)
3. Create **HTTP Basic Auth** credentials (bcrypt hashed)
4. Configure firewall rules (ufw/firewalld)
5. Bind the API to `127.0.0.1` (only accessible through nginx)

You can also pass options non-interactively:

```bash
sudo tmctl setup-web --domain tm.example.com --email admin@example.com --user admin --pass secret
```

The `/api/ssh-key/raw` endpoint can optionally be left open (no auth) for automated client installs.

To remove external access:

```bash
sudo tmctl setup-web --remove
```

---

## Restoring from Backups

Restore files and/or databases from any snapshot:

```bash
# List available snapshots
tm-restore web1.example.com --list

# List files/databases in a snapshot
tm-restore web1.example.com --list-files
tm-restore web1.example.com --list-dbs

# Restore all files to a target directory
tm-restore web1.example.com --files-only --target /tmp/restore

# Restore specific path
tm-restore web1.example.com --path /etc/nginx --target /tmp/restore

# Restore specific database to target
tm-restore web1.example.com --db mydb --target /tmp/restore

# Restore from a specific date
tm-restore web1.example.com --date 2025-02-04 --target /tmp/restore

# Dry run
tm-restore web1.example.com --dry-run

# Decrypt encrypted backup before restore
tm-restore web1.example.com --decrypt --target /tmp/restore
```

---

## Database Backup Support

TimeMachine supports automatic backup of all major database engines. The `dump_dbs.sh` script runs on the client server, auto-detects installed databases, and dumps them before the file sync pulls the dumps back.

### Supported Databases

All database credentials are stored in a single directory: `~timemachine/.credentials/` (mode `700`).

| Engine | Dump Tool | Credential File |
|---|---|---|
| **MySQL / MariaDB** | `mysqldump` | `~/.credentials/mysql.pw` |
| **PostgreSQL** | `pg_dump` + `pg_dumpall` | Peer auth (or `~/.credentials/pgpass`) |
| **MongoDB** | `mongodump` | `~/.credentials/mongodb.conf` |
| **Redis** | `redis-cli BGSAVE` | `~/.credentials/redis.pw` |
| **SQLite** | `sqlite3 .backup` | No auth (file path based) |

### Configuration

Set `TM_DB_TYPES` in `.env`:

```bash
# Auto-detect installed engines (default)
TM_DB_TYPES="auto"

# Or specify explicitly
TM_DB_TYPES="mysql,postgresql,redis"
```

### Setting Up Credentials

#### MySQL / MariaDB

```bash
# On the CLIENT server, create a password file:
echo 'your_root_password' | sudo tee /home/timemachine/.credentials/mysql.pw
sudo chmod 600 /home/timemachine/.credentials/mysql.pw
```

The dump uses `--defaults-extra-file` with a process substitution, so the password never appears in `ps` output. Dumps are stored per-database in `sql/mysql/<dbname>.sql`.

#### PostgreSQL

PostgreSQL uses **peer authentication** by default — no password needed. The dump runs as the `postgres` system user via `sudo -u postgres pg_dump`.

```bash
# Verify it works on the client:
sudo -u postgres psql -c '\l'
```

If you use password auth or a remote host, configure `~postgres/.pgpass`:

```bash
# Format: hostname:port:database:username:password
echo '*:5432:*:postgres:yourpassword' | sudo tee ~postgres/.pgpass
sudo chmod 600 ~postgres/.pgpass
sudo chown postgres:postgres ~postgres/.pgpass
```

Set `TM_PG_HOST` in `.env` if PostgreSQL is on a different host.

Dumps include per-database SQL files in `sql/postgresql/` plus a `_globals.sql` with roles and tablespaces.

#### MongoDB

```bash
# On the CLIENT server, create a credentials file:
echo 'admin_user:admin_password' | sudo -u timemachine tee ~timemachine/.credentials/mongodb.conf
sudo chmod 600 ~timemachine/.credentials/mongodb.conf
```

If MongoDB has no authentication enabled, no credentials file is needed. Dumps are stored as BSON in `sql/mongodb/<dbname>/`.

#### Redis

```bash
# On the CLIENT server, create a password file:
echo 'your_redis_password' | sudo -u timemachine tee ~timemachine/.credentials/redis.pw
sudo chmod 600 ~timemachine/.credentials/redis.pw
```

If Redis has no password (`requirepass` not set), no file is needed. The dump copies the RDB snapshot to `sql/redis/dump.rdb`.

#### SQLite

SQLite databases are file-based — just specify their paths:

```bash
# In .env on the backup server:
TM_SQLITE_PATHS="/var/lib/app/db.sqlite3,/opt/wiki/data.db"
```

Dumps use `sqlite3 .backup` (hot-copy safe) with SQL dump fallback. Stored in `sql/sqlite/`.

### Dump Directory Structure

```
sql/
├── mysql/
│   ├── wordpress.sql
│   └── nextcloud.sql
├── postgresql/
│   ├── myapp.sql
│   ├── analytics.sql
│   └── _globals.sql
├── mongodb/
│   ├── mydb/
│   └── logs/
├── redis/
│   └── dump.rdb
└── sqlite/
    └── app.db.sql
```

---

## Server Priority & DB Interval

Servers can be assigned a **priority** (1 = highest, default = 10). During daily backup runs, servers with lower priority numbers are started first:

```bash
tmctl server add db1.example.com --priority 1          # runs first
tmctl server add web1.example.com --priority 5         # runs after priority 1
tmctl server add dev1.example.com --priority 20        # runs last
tmctl server add staging.example.com                   # default priority 10
```

For critical databases, you can schedule **extra DB-only backups** throughout the day with `--db-interval`:

```bash
tmctl server add db1.example.com --priority 1 --db-interval 4h   # DB backup every 4 hours
tmctl server add db2.example.com --db-interval 2h               # DB backup every 2 hours
```

The scheduler checks every minute and triggers a `--db-only` backup when the interval has elapsed. This works with all database types (MySQL, PostgreSQL, MongoDB, Redis, SQLite). The daily full backup resets the interval timer.

The daily backup schedule is controlled by `TM_SCHEDULE_HOUR` in `.env` (default: `11`, i.e. 11:00 AM).

---

## Email Reports & Alerts

After each daily backup run, a **report email** is sent with per-server results:

```
TimeMachine Backup Report
========================
Server:    backup.example.com
Date:      2026-02-06 11:45:00
Type:      daily
Summary:   4 succeeded, 1 failed, 0 skipped (5 total)

FAILED:
  FAIL db2.example.com (full, 12s) - exit code 1

SUCCEEDED:
  OK   db1.example.com (full, 2m 30s)
  OK   web1.example.com (full, 5m 12s)
  OK   app1.example.com (full, 1m 45s)
  OK   ns1.example.com (full, 30s)
```

**Setup during installation:** The installer prompts for an email address. You can also configure it manually in `.env`:

```bash
TM_ALERT_ENABLED=true
TM_ALERT_EMAIL="admin@example.com"
TM_NOTIFY_METHODS="email"          # also: webhook, slack
```

DB interval backups also send individual notifications on success or failure. Reports are saved to `logs/report-daily-YYYY-MM-DD.log`.

---

## File Excludes

### Global Excludes

Edit `config/exclude.conf` to set patterns excluded from **all** server backups. Default excludes:

```
/proc, /sys, /dev, /tmp, /run, /var/tmp, /var/cache
/var/lib/docker, /var/lib/containerd
lost+found, .cache, .thumbnails
```

### Per-Server Excludes

Create `config/exclude.<hostname>.conf` for server-specific patterns. These are **additive** to the global excludes:

```bash
# Example: exclude large uploads from web1.example.com
cat > config/exclude.web1.example.com.conf <<EOF
/var/www/uploads
/var/www/app/node_modules
/var/www/app/storage/cache
EOF
```

### Backup Source

By default, the entire remote filesystem (`/`) is backed up. The `config/exclude.conf` file determines what is **skipped** (system dirs, caches, DB data dirs, etc.).

To limit the backup to a specific subtree, override in `.env`:

```bash
# Only back up /home/ (not recommended — you'll miss /etc, /opt, etc.)
TM_BACKUP_SOURCE="/home/"
```

---

## Web Dashboard

The service daemon serves a monitoring dashboard at `http://<host>:7600`:

- **Status cards** — Uptime, hostname, active jobs, server count
- **Process table** — Running/completed backups with kill button
- **Server list** — Configured servers with one-click backup
- **SSH key** — Copy key for client installation
- **Quick backup** — Start ad-hoc backups from the UI

---

## REST API Endpoints

The service exposes a REST API:

| Method | Endpoint | Description |
|---|---|---|
| `GET` | `/api/status` | Service status + processes |
| `GET` | `/api/processes` | List backup processes |
| `POST` | `/api/backup/<host>` | Start backup |
| `DELETE` | `/api/backup/<host>` | Kill backup |
| `GET` | `/api/servers` | List configured servers |
| `GET` | `/api/snapshots/<host>` | List snapshots |
| `GET` | `/api/ssh-key` | SSH public key (JSON) |
| `GET` | `/api/ssh-key/raw` | SSH public key (plain text) |
| `GET` | `/api/logs/<host>` | View host logs |

---

## Notifications (Email, Webhook, Slack)

Configure multi-channel alerts in `.env`:

```bash
TM_ALERT_ENABLED=true
TM_NOTIFY_METHODS="email,webhook,slack"

# Email
TM_ALERT_EMAIL="admin@example.com"

# HTTP POST webhook (receives JSON payload)
TM_WEBHOOK_URL="https://example.com/hooks/backup"
TM_WEBHOOK_HEADERS="Authorization: Bearer YOUR_TOKEN"

# Slack
TM_SLACK_WEBHOOK_URL="https://hooks.slack.com/services/..."
```

Webhook JSON payload format:
```json
{
  "subject": "[TimeMachine] Backup FAILED: web1.example.com",
  "body": "Backup completed with errors after 120 seconds.",
  "level": "error",
  "hostname": "backup-server",
  "timestamp": "2025-02-06T10:30:00Z",
  "source": "timemachine"
}
```

---

## Backup Encryption (GPG)

Enable GPG-based backup encryption:

```bash
# Symmetric (passphrase)
TM_ENCRYPT_ENABLED=true
TM_ENCRYPT_MODE="symmetric"
TM_ENCRYPT_PASSPHRASE="your-strong-passphrase"

# Asymmetric (GPG key)
TM_ENCRYPT_ENABLED=true
TM_ENCRYPT_MODE="asymmetric"
TM_ENCRYPT_KEY_ID="your-gpg-key-id"

# Remove unencrypted originals after encryption
TM_ENCRYPT_REMOVE_ORIGINAL=true
```

---

## Configuration Reference

All settings are in `.env`. See `.env.example` for the full list.

| Variable | Default | Description |
|---|---|---|
| `TM_USER` | `timemachine` | Backup user |
| `TM_BACKUP_ROOT` | `/backups` | Where backups are stored |
| `TM_BACKUP_SOURCE` | `/` | Remote root path to back up (excludes determine what is skipped) |
| `TM_RETENTION_DAYS` | `7` | Days to keep old backups |
| `TM_PARALLEL_JOBS` | `5` | Max parallel backup jobs |
| `TM_SSH_PORT` | `22` | SSH port for connections |
| `TM_RSYNC_BW_LIMIT` | `0` | Bandwidth limit (KB/s, 0=unlimited) |
| `TM_DB_TYPES` | `auto` | DB engines: auto, mysql, postgresql, mongodb, redis, sqlite |
| `TM_CREDENTIALS_DIR` | `~/.credentials` | Credential storage directory on client |
| `TM_MYSQL_PW_FILE` | `~/.credentials/mysql.pw` | MySQL password file on client |
| `TM_PG_USER` | `postgres` | PostgreSQL system user |
| `TM_SQLITE_PATHS` | *(empty)* | Comma-separated SQLite file paths |
| `TM_API_PORT` | `7600` | HTTP API / dashboard port |
| `TM_API_BIND` | `0.0.0.0` | API bind address |
| `TM_SCHEDULE_HOUR` | `11` | Hour to trigger daily backups |
| `TM_ALERT_ENABLED` | `false` | Enable notifications |
| `TM_NOTIFY_METHODS` | `email` | Channels: email, webhook, slack |
| `TM_ENCRYPT_ENABLED` | `false` | Enable backup encryption |
| `TM_LOG_LEVEL` | `INFO` | Log verbosity (DEBUG/INFO/WARN/ERROR) |

---

## Running Tests

```bash
# Run all tests (158 tests across 9 suites)
bash tests/run_all_tests.sh

# Run specific test suite
bash tests/test_common.sh
bash tests/test_rsync.sh
bash tests/test_notify.sh
bash tests/test_encrypt.sh
bash tests/test_restore.sh
bash tests/test_tmctl.sh
bash tests/test_excludes.sh
bash tests/test_database.sh

# Run shellcheck linting (requires shellcheck)
bash tests/test_shellcheck.sh
```

---

## Uninstalling TimeMachine

### Single-Line Uninstall (recommended)

Completely removes TimeMachine from server or client with one command:

```bash
curl -sSL https://raw.githubusercontent.com/ronaldjonkers/timemachine-backup-linux/main/uninstall.sh | sudo bash
```

The uninstaller auto-detects whether this is a server or client installation and removes all components (service, cron, sudoers, symlinks, nginx config, user, install directory). **Backup data is preserved** unless explicitly requested.

#### Uninstall Options

```bash
# Non-interactive (skip confirmation)
curl -sSL .../uninstall.sh | sudo bash -s -- --force

# Also remove backup data (DANGEROUS)
curl -sSL .../uninstall.sh | sudo bash -s -- --force --remove-backups
```

### Manual Uninstall

```bash
# Remove from a client server
sudo ./install.sh client --uninstall

# Remove the backup server
sudo systemctl stop timemachine
sudo systemctl disable timemachine
sudo rm -f /etc/systemd/system/timemachine.service
sudo userdel -r timemachine
sudo rm -f /etc/sudoers.d/timemachine
sudo rm -f /usr/bin/{tmctl,timemachine,tm-restore}
sudo rm -rf /opt/timemachine-backup-linux
```

---

## License

MIT — free for personal and commercial use.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Run tests: `bash tests/run_all_tests.sh`
4. Submit a pull request

---

## Keywords

time machine linux, linux backup solution, rsync backup tool, automated server backup, time machine alternative linux, linux server backup software, incremental backup linux, snapshot backup, database backup linux, mysql backup, postgresql backup, web dashboard backup, open source backup tool
