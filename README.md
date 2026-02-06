# TimeMachine Backup for Linux

A robust, rsync-based backup system for Linux servers inspired by macOS Time Machine. Creates rotating daily snapshots with hardlinks for space-efficient, point-in-time recovery. Includes a service daemon with web dashboard, CLI control tool, restore functionality, encryption, and multi-channel notifications.

## Features

- **Time Machine-style snapshots** — Daily backups with hardlinks (only changed files use extra disk space)
- **Service daemon** — Runs as a systemd service with built-in scheduler
- **Web dashboard** — Real-time monitoring UI with process control
- **CLI control tool (`tmctl`)** — Manage backups, view status, kill processes
- **Restore** — Selective file/database restore from any snapshot, from server or client
- **MySQL/MariaDB database dumps** — Automatic remote dumping with retry logic
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
│   ├── dump_dbs.sh                # Database dump (runs on client)
│   └── dump_dbs_wait.sh           # Wait for cron-triggered DB dump
├── lib/                           # Shared libraries
│   ├── common.sh                  # Config, logging, locking, utilities
│   ├── rsync.sh                   # Rsync sync & rotation functions
│   ├── database.sh                # Database dump functions
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
│   └── timemachine.service        # Systemd unit file
├── tests/                         # Test suite (65 tests)
│   ├── run_all_tests.sh           # Test runner
│   ├── test_common.sh             # Tests for lib/common.sh
│   ├── test_rsync.sh              # Tests for lib/rsync.sh
│   ├── test_notify.sh             # Tests for lib/notify.sh
│   ├── test_encrypt.sh            # Tests for lib/encrypt.sh
│   ├── test_restore.sh            # Tests for bin/restore.sh
│   ├── test_tmctl.sh              # Tests for bin/tmctl.sh
│   └── test_shellcheck.sh         # ShellCheck linting
├── install.sh                     # Server (backup host) installer
├── install-client.sh              # Client (remote server) installer
├── .env.example                   # Configuration template
├── .gitignore                     # Git ignore rules
├── CHANGELOG.md                   # Version history
└── README.md                      # This file
```

## Quick Start

### 1. Install the Backup Server

```bash
git clone https://github.com/your-org/timemachine-backup-linux.git
cd timemachine-backup-linux
sudo ./install.sh
```

This will:
- Create the `timemachine` user with SSH keys
- Install dependencies (rsync, socat, curl, gnupg2)
- Set up directories, sudoers, and systemd service
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
sudo ./install-client.sh --server backup.example.com
sudo ./install-client.sh --server backup.example.com --with-db
sudo ./install-client.sh --server backup.example.com --db-cronjob
```

**Manual** (provide SSH key directly):

```bash
sudo ./install-client.sh --ssh-key "ssh-rsa AAAA..."
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
| `TM_RETENTION_DAYS` | `7` | Days to keep old backups |
| `TM_PARALLEL_JOBS` | `5` | Max parallel backup jobs |
| `TM_SSH_PORT` | `22` | SSH port for connections |
| `TM_RSYNC_BW_LIMIT` | `0` | Bandwidth limit (KB/s, 0=unlimited) |
| `TM_API_PORT` | `7600` | HTTP API / dashboard port |
| `TM_API_BIND` | `0.0.0.0` | API bind address |
| `TM_SCHEDULE_HOUR` | `11` | Hour to trigger daily backups |
| `TM_ALERT_ENABLED` | `false` | Enable notifications |
| `TM_NOTIFY_METHODS` | `email` | Channels: email, webhook, slack |
| `TM_ENCRYPT_ENABLED` | `false` | Enable backup encryption |
| `TM_LOG_LEVEL` | `INFO` | Log verbosity (DEBUG/INFO/WARN/ERROR) |

## Running Tests

```bash
# Run all tests (65 tests across 7 suites)
bash tests/run_all_tests.sh

# Run specific test suite
bash tests/test_common.sh
bash tests/test_rsync.sh
bash tests/test_notify.sh
bash tests/test_encrypt.sh
bash tests/test_restore.sh
bash tests/test_tmctl.sh

# Run shellcheck linting (requires shellcheck)
bash tests/test_shellcheck.sh
```

## Uninstalling

```bash
# Remove from a client server
sudo ./install-client.sh --uninstall

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
