# TimeMachine Backup for Linux

A robust, rsync-based backup system for Linux servers inspired by macOS Time Machine. Creates rotating daily snapshots with hardlinks for space-efficient, point-in-time recovery. Includes a service daemon with web dashboard, CLI control tool, restore functionality, multi-database support, encryption, and multi-channel notifications.

## Quick Install

The installer asks whether you want to set up a **server** (stores backups) or **client** (gets backed up).

```bash
curl -sSL https://raw.githubusercontent.com/ronaldjonkers/timemachine-backup-linux/main/get.sh | sudo bash
```

**Server** — also asks where to store backups; creates `<dir>/timemachine/` with correct permissions.

**Client** — pass mode and options directly:

```bash
curl -sSL https://raw.githubusercontent.com/ronaldjonkers/timemachine-backup-linux/main/get.sh | sudo bash -s -- client --server backup.example.com
```

## Features

- **Time Machine-style snapshots** — Daily backups with hardlinks (only changed files use extra disk space)
- **Service daemon** — Runs as a systemd service with built-in scheduler
- **Web dashboard** — Real-time monitoring UI with process control
- **CLI control tool (`tmctl`)** — Manage backups, view status, kill processes
- **Restore** — Selective file/database restore from any snapshot
- **Multi-database support** — MySQL/MariaDB, PostgreSQL, MongoDB, Redis, SQLite with auto-detection
- **Exclude system** — Global defaults + per-server exclude patterns
- **Parallel execution** — Back up multiple servers simultaneously
- **Multi-channel notifications** — Email, HTTP POST webhooks, Slack
- **Encryption** — GPG-based symmetric or asymmetric backup encryption
- **SSH key distribution** — Auto-download SSH keys from the backup server API
- **Configurable retention** — Automatic rotation of old backups
- **Client installer** — One-command setup with `--server` auto-configuration
- **Modular architecture** — Shared libraries with reusable functions

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
├── tests/                         # Test suite (95 tests)
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
├── get.sh                         # Single-line installer (curl | bash)
├── install.sh                     # Unified installer (server + client)
├── .env.example                   # Configuration template
├── .gitignore                     # Git ignore rules
├── CHANGELOG.md                   # Version history
└── README.md                      # This file
```

## Quick Start

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
- Create symlinks: `tmctl`, `timemachine`, `tm-restore` in `/usr/local/bin`

### 2. Configure

```bash
# Main settings
sudo -u timemachine vi .env

# Add servers to back up
sudo -u timemachine vi config/servers.conf
```

### 3. Start the Service

```bash
sudo systemctl start timemachine
```

The dashboard is now available at `http://<backup-server>:7600`.

### 4. Install on Client Servers

**Automatic** (downloads SSH key from the backup server API):

```bash
# Files only
sudo ./install.sh client --server backup.example.com

# With database support (auto-detects installed DB engines)
sudo ./install.sh client --server backup.example.com --with-db

# With specific database types
sudo ./install.sh client --server backup.example.com --db-type mysql,postgresql

# With autonomous DB dump cronjob
sudo ./install.sh client --server backup.example.com --with-db --db-cronjob
```

**Manual** (provide SSH key directly):

```bash
sudo ./install.sh client --ssh-key "ssh-rsa AAAA..."
```

### 5. Test

```bash
tmctl backup web1.example.com --dry-run
tmctl status
```

## CLI Tool (`tmctl`)

```bash
tmctl status              # Service status + running processes
tmctl ps                  # List all backup processes
tmctl backup <host>       # Start a backup
tmctl kill <host>         # Kill a running backup
tmctl restore <host>      # Restore from backup (interactive)
tmctl logs [host]         # View logs
tmctl servers             # List configured servers
tmctl server add <host>   # Add a server (with optional --files-only, --db-only, --no-rotate)
tmctl server remove <host> # Remove a server
tmctl snapshots <host>    # List available snapshots
tmctl ssh-key             # Show SSH public key
tmctl version             # Show version
```

## Restore

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

## Database Backup

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

### Configurable Backup Paths

By default, these remote paths are backed up: `/etc/`, `/home/`, `/root/`, `/var/spool/cron/`, `/opt/`.

Override in `.env`:

```bash
TM_BACKUP_PATHS="/etc/,/home/,/root/,/var/www/,/opt/,/srv/"
```

## Web Dashboard

The service daemon serves a monitoring dashboard at `http://<host>:7600`:

- **Status cards** — Uptime, hostname, active jobs, server count
- **Process table** — Running/completed backups with kill button
- **Server list** — Configured servers with one-click backup
- **SSH key** — Copy key for client installation
- **Quick backup** — Start ad-hoc backups from the UI

## API Endpoints

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

## Notifications

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

## Encryption

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

## Configuration Reference

All settings are in `.env`. See `.env.example` for the full list.

| Variable | Default | Description |
|---|---|---|
| `TM_USER` | `timemachine` | Backup user |
| `TM_BACKUP_ROOT` | `/backups` | Where backups are stored |
| `TM_BACKUP_PATHS` | `/etc/,/home/,...` | Remote paths to back up |
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

## Running Tests

```bash
# Run all tests (120 tests across 9 suites)
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

## Uninstalling

```bash
# Remove from a client server
sudo ./install.sh client --uninstall

# Remove the backup server
sudo systemctl stop timemachine
sudo systemctl disable timemachine
sudo rm -f /etc/systemd/system/timemachine.service
sudo userdel -r timemachine
sudo rm -f /etc/sudoers.d/timemachine
```

## License

MIT

## Contributing

1. Fork the repository
2. Create a feature branch
3. Run tests: `bash tests/run_all_tests.sh`
4. Submit a pull request
