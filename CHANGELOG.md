# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [3.4.0] - 2026-02-17

### Added
- **Server search field** — The Servers page now has a search input in the panel header. Type to instantly filter servers by hostname, options, or status. Shows "No servers matching ..." when no results found.

## [3.3.6] - 2026-02-17

### Fixed
- **CRITICAL: DB backup silently crashed with no log output and no failure email** — Two root causes:
  1. `set -e` (from `common.sh`) killed the entire `timemachine.sh` script when SCP or SSH failed inside `tm_trigger_remote_dump`. The error handling code and email notification were never reached.
  2. `tm_trigger_remote_dump` was called inside a `$()` subshell, which captured all `tm_log` stderr output into a variable instead of writing it to the log file.
- **Fix**: `tm_trigger_remote_dump` now uses `set +e` internally and sets `_TM_DB_OUTPUT` directly (no subshell). Called with `|| db_rc=$?` pattern so failures are always caught and reported.
- **Also fixed**: Same `|| { }` pattern bug in `tm_rsync_sql` and `tm_rsync_backup` — replaced with safe `|| rc=$?` pattern throughout.

## [3.3.5] - 2026-02-17

### Improved
- **Comprehensive logging for DB backup flow** — Every step of the database backup process is now logged with clear phase markers so you can trace exactly what happened and where it failed:
  - `Phase 2a`: SCP deploy of `dump_dbs.sh` to remote (success/fail + output)
  - `Phase 2a`: SSH execution of `dump_dbs.sh` on remote (exit code + full remote output)
  - `Phase 2b`: rsync sync of SQL dumps back (source path, target dir, file count, total size)
  - All remote script output is logged line-by-line with `[remote]` prefix

## [3.3.4] - 2026-02-17

### Fixed
- **CRITICAL: Rewrote remote DB dump to use SCP+SSH instead of piped stdin** — The previous approach piped `dump_dbs.sh` via `bash -s` over SSH stdin, which was fragile (sed pattern matching to skip the self-restart block, env var injection). Replaced with the proven pattern: SCP the latest `dump_dbs.sh` to the remote server (`/home/timemachine/`), then SSH to run it there with env vars. This matches how the old backup script worked and ensures a fresh database dump is always created before rsync pulls the files back.

## [3.3.3] - 2026-02-17

### Fixed
- **CRITICAL: Remote database dumps were not executing** — The `sed` pattern in `tm_trigger_remote_dump` (`# ===.*CONFIGURATION`) never matched because the separator line (`# ====...`) and the `CONFIGURATION` title are on separate lines in `dump_dbs.sh`. This caused an **empty script** to be piped to the remote server via SSH, meaning no database dump was performed. The rsync then just synced stale/old dump files. Fixed pattern to `# CONFIGURATION` which correctly matches line 34 of `dump_dbs.sh` and sends the full 496-line script body.

## [3.3.2] - 2026-02-17

### Fixed
- **DB interval backups no longer send duplicate emails** — The scheduler previously sent its own "DB Interval OK/FAILED" notification in addition to the standard "Backup OK/FAILED" email from `timemachine.sh`. Now only the detailed email from `timemachine.sh` is sent (includes status, duration, mode, snap size, disk free).
- **DB-only runs now report correct snap size** — `tm_rsync_sql` now exports `_TM_SNAP_ID` back to the caller so `timemachine.sh` can find the correct snapshot directory for size calculation. Previously showed "unknown" for DB-only interval runs.
- **Fixed interval subdir detection regression** — Replaced `_TM_SNAP_ID` empty-check with `is_db_only` flag to correctly detect DB-only interval runs after the snap ID export fix.

## [3.3.1] - 2026-02-17

### Fixed
- **Editing server settings no longer triggers an immediate backup** — When changing interval settings (DB interval, backup interval) via the dashboard, the scheduler now resets the interval timestamps to "now". The first interval run will wait the full configured period before starting. Previously, changing settings (or configuring an interval for the first time) caused the scheduler to see a huge elapsed time and trigger immediately.

## [3.3.0] - 2026-02-17

### Added
- **Database version browser** — Servers with `--db-interval` now store each interval DB backup in a timestamped subdirectory (`sql/HHMMSS/`), preserving every version throughout the day. The daily full backup remains in `sql/` directly.
- **New API endpoint `/api/db-versions/<hostname>/<snapshot>`** — Returns all DB dump versions for a snapshot, including file lists, sizes, and timestamps. Available in both Python and bash API servers.
- **Dashboard: clickable DB version count** — Snapshot listings now show the number of DB versions (e.g. "3 versions") as a clickable link that opens a dedicated DB versions browser with per-version download and restore buttons.
- **DB versions modal** — New modal view showing all database backup versions for a snapshot in a clear table with version type (Daily/Interval), timestamp, size, individual file details, and Download/Restore actions per version.

## [3.2.3] - 2026-02-17

### Fixed
- **Legacy `daily.YYYY-MM-DD` snapshots now included in rotation** — Old backup directories from the previous backup script (format `daily.2026-02-15`) are now cleaned up during rotation when they exceed the retention period. Stale `latest-daily` symlinks are also removed.
- **Legacy snapshots visible in dashboard and API** — Snapshot counting, last backup detection, and the snapshot browser all include legacy `daily.*` directories alongside the current format.

## [3.2.2] - 2026-02-17

### Fixed
- **DB-only backups no longer block the daily run** — The pre-backup check (`daily-jobs-check.sh`) now reads the backup mode from the state file and skips `db-only` processes. Short-lived DB interval backups no longer prevent the daily full backup from starting.
- **DB-only backups no longer occupy parallel slots** — The `_wait_for_slot` function in the scheduler now excludes `db-only` backups from the running count, so they don't block full/file backups from launching.

## [3.2.1] - 2026-02-16

### Fixed
- **Backups no longer re-trigger on every service restart** — Three fixes:
  1. Daily run marker (`last-daily-run`) is now written **before** starting the daily run, not after. Previously, a restart mid-run would lose the marker and re-trigger all backups.
  2. Interval checks (`--db-interval`, `--backup-interval`) now have the same 5-minute startup delay as the daily run, preventing immediate re-triggering after `tmctl update`.
  3. Interval checks now skip servers that already have a running backup, preventing duplicate backups for the same server.

## [3.2.0] - 2026-02-16

### Fixed
- **CRITICAL: DB-only backups no longer create extra snapshot directories** — Previously, each `--db-interval` run created a new timestamped directory (e.g. `2026-02-16_160000/sql/`), inflating the version count and causing premature deletion of file backups during rotation. DB-only backups now reuse today's existing snapshot directory, keeping SQL dumps alongside the file backup.
- **Snapshot count shows unique dates** — Dashboard, email summaries, and API now count unique dates (YYYY-MM-DD) instead of individual snapshot directories. Multiple backups on the same day count as 1 version.

## [3.1.7] - 2026-02-16

### Fixed
- **Orphan detection rewritten** — Previous orphan detection had multiple bugs: used `pgrep` (unreliable), checked by PID instead of hostname, ran `while` loop in subshell (losing state), used non-portable `grep -oP`. Now uses `ps -eo pid,args` with here-string to avoid subshell, checks by hostname, and uses portable `sed` for parsing.

## [3.1.6] - 2026-02-16

### Fixed
- **CRITICAL: Service crash on startup** — The `_cleanup` trap referenced unbound variables (`HTTP_PID`, `SCHEDULER_PID`) when triggered before the HTTP server was started. Fixed with `${:-}` default guards on all `wait` calls.
- **CRITICAL: `set -e` exit in orphan detection** — Several `[[ condition ]] && action` patterns caused immediate script exit under `set -e` when the condition was false. Replaced all with `if/then` blocks in `_reconcile_state_files` and `run_backup`.

## [3.1.5] - 2026-02-16

### Fixed
- **Orphaned backup processes re-discovered after restart** — On startup, the service now scans for running `timemachine.sh` processes that have no state file (e.g. state files were lost during an upgrade from an older version). These orphaned backups are automatically re-registered so they appear in the dashboard immediately. This fixes the issue where running backups became invisible after `tmctl update` and stayed invisible even on fresh page loads.

## [3.1.4] - 2026-02-16

### Fixed
- **Dashboard retains data during service restart** — All refresh functions (processes, failures, restores, servers) now keep their current table contents when the API is temporarily unreachable (e.g. during `tmctl update`). Previously, a brief API outage would wipe all panels to "empty". Data is only cleared when the API explicitly returns an empty list.

## [3.1.3] - 2026-02-16

### Fixed
- **CRITICAL: Backup process state persists across service restarts** — State files (`proc-*.state`, `exit-*.code`, scheduler markers) are now stored in `TM_HOME/state` (persistent disk) instead of `TM_RUN_DIR/state` (tmpfs `/run/timemachine` which was wiped on every restart). Running backups now remain visible in the dashboard after `tmctl update` or `systemctl restart timemachine`.
- **Automatic migration** — On first start after update, existing state files are automatically moved from the old tmpfs location to the new persistent directory.

## [3.1.2] - 2026-02-16

### Fixed
- **Manual backup respects server mode** — When starting a manual backup for a server configured as "files-only", only the "Files only" option is shown (no "Full" or "DB only"). Same for "db-only" servers. Prevents errors from trying to back up a non-existent database.

## [3.1.1] - 2026-02-16

### Fixed
- **Priority column clarified** — Column header now shows "Priority (1=high)" with tooltip. Add Server placeholder also clarified.

## [3.1.0] - 2026-02-16

### Added
- **Sortable server overview** — Server table columns (Hostname, Priority, Last Backup, Status) are now clickable to sort. Default sort is by priority (ascending), so high-priority servers appear first.
- **Priority column** — Server priority is now visible in the overview table.
- **Add Server form moved to top** — Clicking "+ Add Server" now shows the form above the table instead of below it, so it's immediately visible even with a long server list. The hostname input is auto-focused.

## [3.0.3] - 2026-02-16

### Fixed
- **CRITICAL: Running backups survive service restarts** — Backup processes are now spawned in their own session (`setsid` in bash, `start_new_session=True` in Python) so they are fully detached from the service. Combined with `KillMode=process` in the systemd unit, a `tmctl update` or `systemctl restart timemachine` only kills the API server and scheduler — running backups continue uninterrupted.
- **State reconciliation on startup** — After a service restart, all state files are checked: if a "running" PID is still alive (backup survived), it stays visible in the dashboard. If the PID is dead (killed by an older version), it's marked as "failed" so the dashboard shows the correct status instead of a ghost "running" entry.
- **Increased TimeoutStopSec** — Changed from 3s to 10s for graceful API server shutdown.

## [3.0.2] - 2026-02-16

### Fixed
- **CRITICAL: "Start All Backups" now triggers daily-runner.sh** — Previously reimplemented backup launching in Python, bypassing priority sorting, parallel job limits, reporting, and overrun detection. Now delegates to `daily-runner.sh` which handles all of this correctly.
- **Scheduler email spam** — When backups were still running at the scheduled time, the scheduler retried `daily-jobs-check.sh` every minute for the rest of the day, sending an alert email each time. Now marks the day as attempted on first check, so the alert is sent only once.

## [3.0.1] - 2026-02-16

### Fixed
- **CRITICAL: "Start All Backups" ignored parallel job limit** — `_api_backup_all` spawned one thread per server simultaneously with no throttling. With 50 servers this meant 50 parallel `timemachine.sh` processes, overloading the backup server. Now uses a `threading.Semaphore` limited to `TM_PARALLEL_JOBS` (default 5), matching the behavior of `daily-runner.sh`.
- **Priority sorting for "Start All Backups"** — Servers are now sorted by `--priority` (ascending) before starting, so high-priority servers back up first.
- **Server mode respected** — `--files-only` and `--db-only` options from `servers.conf` are now correctly passed through when starting all backups via the dashboard.

## [3.0.0] - 2026-02-10

**TimeMachine Backup v3.0.0 — Production-Ready Release**

This major release marks the project as mature and production-ready. It consolidates all reliability improvements, dashboard enhancements, and notification fixes from the v2.18.x series into a stable baseline.

### Highlights since v2.x
- **Reliable backup status reporting** — Fixed critical bug where successful backups were falsely reported as "failed" due to `set -euo pipefail` killing the script during summary generation
- **Reliable email notifications** — Both success and failure emails are now guaranteed to be sent; summary section is fully guarded against non-critical command failures
- **Concise success emails** — "Backup OK" emails contain only the status summary (server, date, duration, snapshot size, disk free). Full diagnostic logs are only included in failure emails.
- **Dashboard: dismiss failed backups** — Individual "Dismiss" button per failed backup entry, permanently removes the error log files
- **Dashboard: delete finished processes** — Individual "Delete" button per completed/failed process entry
- **Dashboard: "No backups today" banner** — Warning banner with "Start All Backups Now" button when no backups have run today
- **Postfix auto-configuration** — `message_size_limit` set to 50MB during install/update to prevent email delivery failures for large backup logs
- **Global excludes** — `/home/timemachine` and `/Backup` excluded by default to prevent self-backup

## [2.18.13] - 2026-02-10

### Fixed
- **Dismiss failures now permanent** — Dismiss button now deletes the actual error log files instead of using a tracking file that got ignored after restart. Failures stay dismissed until a new backup produces new errors.

## [2.18.12] - 2026-02-10

### Changed
- **Success emails are now concise** — "Backup OK" emails only contain the status summary (server, date, duration, snap size, disk free). Rsync transfer logs, database output, and full backup logs are no longer included in success emails. "Backup FAILED" emails still include all diagnostic logs for debugging.

## [2.18.11] - 2026-02-10

### Added
- **Dismiss button on Failed Backups panel** — Each failed backup entry now has a "Dismiss" button to remove it from the list (`DELETE /api/failures/<hostname>`). Dismissed failures reappear automatically if the next backup for that host also fails.
- `DELETE /api/failures` to dismiss all failures at once

## [2.18.10] - 2026-02-10

### Added
- **Per-row delete button for finished processes** — Completed and failed backup entries in the Backup Processes panel now have an individual "Delete" button to remove them one by one (`DELETE /api/processes/<hostname>`)

## [2.18.9] - 2026-02-10

### Fixed
- **CRITICAL: Backups falsely reported as "failed" and no emails sent** — Root cause: `set -euo pipefail` (from `common.sh`) killed the script silently during the summary section when `du -sh` or `ls` returned non-zero (e.g., permission denied on some files). This caused:
  1. No "Backup completed successfully" log line
  2. No email notification (success OR failure)
  3. Non-zero exit code → status shown as "failed" in dashboard
  - **Fix**: `set +e` before the summary/notification section so non-critical commands (`du`, `df`, `find`, `mail`) cannot crash the script
  - **Fix**: All summary commands guarded with `|| fallback` for robustness
  - **Fix**: `tm_notify` calls guarded with `|| true`
  - **Fix**: Backup log limited to last 500 lines in emails to prevent bash OOM on huge first backups
- **Global excludes**: Added `/home/timemachine` and `/Backup` to prevent backing up TimeMachine's own data

## [2.18.8] - 2026-02-10

### Added
- **"No backups today" banner** — Dashboard shows a warning banner at the top when no backups have run today, with a "Start All Backups Now" button to trigger all configured servers at once (`POST /api/backup-all`)
- **Clear finished processes** — "Clear Finished" button in the Backup Processes panel to remove completed/failed entries from the dashboard (`DELETE /api/processes`)
- **Postfix message_size_limit** — `install.sh` and `tmctl update` now automatically configure postfix `message_size_limit` to 50MB (default 10MB was too small for backup log emails, causing "File too large" errors)

### Fixed
- **`_TM_BACKUP_LOGFILE` for API-triggered backups** — Single-server backups started via the dashboard API now also pass the logfile path so failure emails include the full backup log

## [2.18.7] - 2026-02-10

### Fixed
- **Failed backups now correctly show "failed" status in portal** — Status detection previously only checked the last 30 lines of the log for `[ERROR]`, but rsync failures appear early in the log and get pushed out by subsequent phases (database, rotation, summary). Now uses two-tier detection:
  1. Exit code file (`exit-{hostname}.code`) — most reliable, written by the backup wrapper
  2. Full log scan for `[ERROR]` markers — catches all errors regardless of position
  Applied to: `_check_process_exit()` (bash), `get_processes_json()` (Python), and `_api_servers_list()` (Python)
- **Failure email notifications now include the full backup log** — The `_TM_BACKUP_LOGFILE` environment variable is exported by both `tmserviced.sh` and `daily-runner.sh`, allowing `timemachine.sh` to include the complete backup log (with all `[ERROR]` messages, rsync output, timing info) in the notification email alongside the rsync transfer log and database output
- Removed redundant stripped-down failure notification from `run_backup()` wrapper — `timemachine.sh` already sends a comprehensive failure email with all logs

## [2.18.6] - 2026-02-10

### Added
- **Backup prompt when adding a server** — Both the web dashboard and CLI (`tmctl server add`) now ask whether to start a backup immediately after adding a server. Default is No
  - **Web**: `confirm()` dialog after successful add — if Yes, triggers backup via API
  - **CLI**: `Start a backup for <host> now? [y/N]` prompt — if Yes, starts via API (or directly if service is not running)
- **Skip-daily marker** — When a server is added, a `skip-daily-<hostname>` marker file is written with today's date. This prevents the daily runner, backup-interval checks, and DB-interval checks from automatically including the new server until the next day. Ensures the user's choice is respected

## [2.18.5] - 2026-02-10

### Changed
- **Snapshot dates formatted in dashboard** — Snapshot dates now display as `DD-MM-YYYY HH:MM uur` instead of raw `YYYY-MM-DD_HHMMSS`. Applied to: server detail snapshot list, modal snapshot list, browse breadcrumb, and archive last backup column. Old `YYYY-MM-DD` format displays as `DD-MM-YYYY`

## [2.18.4] - 2026-02-10

### Fixed
- **Service restart no longer triggers immediate backups** — After `tmctl update` (which restarts the service), the scheduler would immediately trigger the daily backup run and all interval-based backups. Two fixes applied:
  - **5-minute startup grace period**: The daily run will not trigger within the first 5 minutes after service startup, giving the service time to stabilize. If the server was genuinely down during the scheduled time, the daily run triggers after the grace period
  - **Interval timestamp initialization**: On startup, all servers with `--backup-interval` or `--db-interval` that don't have a timestamp file get initialized to "now", preventing immediate triggering due to `elapsed = now - 0`

## [2.18.3] - 2026-02-10

### Fixed
- **Daily report email now includes full per-server logs** — The daily summary report email previously only contained a brief summary table (OK/FAIL per server). Now includes the complete backup log for each server (all phases, timing, errors) plus the full rsync transfer log (file-by-file details). The report format is: summary table → per-server backup log → per-server rsync transfer log
- `tm_report_add()` now accepts a 6th parameter (logfile path). `daily-runner.sh` passes each server's backup log path from the state file
- `tm_report_send()` reads each server's backup log and finds the latest rsync log, appending both to the email body

## [2.18.2] - 2026-02-10

### Fixed
- **CRITICAL: Hardlinks broken by timestamped snapshots** — Since v2.18.0, every backup created a full copy instead of hardlinking unchanged files. Root cause: `--link-dest` pointed to the snapshot root directory (e.g. `.../2026-02-10_130500/`) but rsync syncs into the `files/` subdirectory. Rsync could not match relative paths (`--link-dest/etc/passwd` vs `dest/files/etc/passwd`). Fix: `--link-dest` now resolves the `latest` symlink to an absolute path and appends `/files` so relative paths match correctly. Added logging to confirm hardlink source is being used

## [2.18.1] - 2026-02-10

### Fixed
- **False "failed" status in portal** — Log tail check used overly broad regex (`FAIL|fatal|Permission denied`) that matched `dead.letter` output and other non-error text from mail commands. Now only matches our own `[ERROR]` log format markers. Applied to: `get_processes_json()`, `_check_process_exit()`, restore status check, and backup history status
- **DB backup false positive** — When no database engines are found on a remote server, the backup would still run `tm_rsync_sql` (syncing an empty `sql/` dir) and report "Database backup sync complete". Now also detects `"No supported database engines detected"` from `dump_dbs.sh` and skips the sync entirely with a clear log message
- **Email notifications missing rsync/DB logs** — The `exec > >(tee ...)` approach had race conditions (tee subprocess not flushed when file was read). Replaced with direct inclusion of rsync transfer log and database output in the email body without tee capture
- **Archive/full delete not removing backup data** — `shutil.rmtree` with `ignore_errors=True` silently failed because backup directories contain files owned by root (rsync preserves ownership). Now uses `sudo rm -rf` which the timemachine user has via sudoers
- **Auto-backup on server add** — When adding a server with `--backup-interval` or `--db-interval` via the dashboard, the scheduler would immediately trigger a backup because no timestamp file existed (elapsed = infinity). Now initializes interval timestamps on add

### Changed
- **Full page refresh after delete/archive/unarchive** — Dashboard now calls `refreshAll()` (servers + history + processes + disk) instead of only `refreshServers()` after archive, delete, and unarchive operations

## [2.18.0] - 2026-02-10

### Added
- **Multiple full backups per day** — Snapshot directories now use timestamped format `YYYY-MM-DD_HHMMSS` instead of `YYYY-MM-DD`, allowing multiple snapshots per day. Fully backwards compatible with existing `YYYY-MM-DD` directories
- **`--backup-interval Xh` per-server option** — Configure how often a server gets a full backup (e.g. `--backup-interval 6h` = 4 full backups/day). The scheduler checks every minute and triggers backups when the interval has elapsed. Configurable via dashboard server settings or `servers.conf`
- **Daily backup overrun detection** — If the daily backup run exceeds `TM_MAX_DAILY_SECONDS` (default 24h), an alert is sent with per-server status showing which servers completed, which are still running (with duration), and which never started. Configurable in `.env`
- **`tm_snapshot_id()` function** — Returns `YYYY-MM-DD_HHMMSS` for timestamped snapshot directories (`lib/common.sh`)

### Changed
- **Snapshot directory format** — `tm_rsync_backup()` and `tm_rsync_sql()` now create `YYYY-MM-DD_HHMMSS` directories. The SQL sync reuses the same snapshot ID as the file backup via `_TM_SNAP_ID` global variable
- **Rotation** — `tm_rotate_backups()` now handles both old (`YYYY-MM-DD`) and new (`YYYY-MM-DD_HHMMSS`) directories by comparing only the date portion (first 10 chars)
- **Restore** — `resolve_snapshot()` accepts both `YYYY-MM-DD` (resolves to latest snapshot of that day) and `YYYY-MM-DD_HHMMSS` (exact match). `list_snapshots()` shows all timestamped snapshots
- **API** — `_api_snapshots()`, `_api_browse()`, and server list snapshot counting all match both formats via regex `^\d{4}-\d{2}-\d{2}(_\d{6})?$`
- **Scheduler** — `_scheduler_loop()` now resets both DB and backup interval timestamps after daily run. New `_check_backup_intervals()` runs every minute alongside `_check_db_intervals()`
- **Dashboard** — Server edit modal now includes "Full Backup Interval" field. `saveServerSettings()` sends `backup_interval` to API
- **Documentation** — Updated README.md features list, `.env.example` with `TM_MAX_DAILY_SECONDS`, `servers.conf.example` with `--backup-interval` docs

## [2.17.2] - 2026-02-10

### Changed
- **Full logs in backup emails** — Per-server backup notification emails now include the complete backup log (all phases, timing, errors) followed by the full rsync transfer log (file-by-file details). Email structure: summary header → backup log → rsync transfer log. Both OK and FAILED emails include all logs so you can see exactly what happened
- `timemachine.sh` now captures its own output to an internal log file via `tee` so it can be included in the email body
- `_TM_RSYNC_LOGFILE` is now a global variable (set by `tm_rsync_backup`) so `timemachine.sh` can read it for the email

## [2.17.1] - 2026-02-10

### Fixed
- **`--notify` option causing backup failure** — `timemachine.sh` did not recognize `--notify` in its argument parser, causing `Unknown option` error and aborting the backup. Now properly consumed (skip + shift) like `--priority` and `--db-interval`
- **Kill events now logged** — When a backup is killed via the dashboard, a `[WARN] Backup killed by user via dashboard (PID ...)` line is appended to the backup log file so it's visible in the log viewer

### Added
- **Postfix installed by default** — The installer now includes `postfix` in all package manager dependency lists and enables/starts it after installation, so `s-nail`/`mailutils` have a working local MTA out of the box

### Changed
- **SSH key endpoint defaults to open** — `setup-web.sh` now defaults to `[Y/n]` (yes) for allowing unauthenticated access to `/api/ssh-key/raw` when configuring htpasswd auth. SSH public keys are not sensitive and client installs need this endpoint to work without credentials

## [2.17.0] - 2026-02-10

### Fixed
- **Backup status stuck on "running"** — State file was written with the API server's own PID instead of the subprocess PID. The dashboard would never detect completion because `is_process_alive()` always returned true for the API server. Now the state file is updated with the real subprocess PID inside the background thread, and directly updated on completion
- **PID 0 placeholder handling** — `get_processes_json()` and `_api_logs()` now skip the `is_process_alive` check for PID 0 (the placeholder written before the subprocess starts)

### Added
- **Trigger source in backup log** — Log header now shows `Triggered by: manual|daily|api|scheduler` so you can tell how a backup was started. `--trigger` option added to `timemachine.sh`, passed by API (`api`), daily-runner (`daily`), and scheduler (`scheduler`)
- **Dashboard toast on backup completion** — The processes table now detects when a backup transitions from running to completed/failed and shows a toast notification
- **Live rsync log viewer** — New "Rsync" button in the processes table opens a modal with the raw rsync transfer log (`--log-file`), with live auto-refresh while the backup is running. API: `GET /api/rsync-log/<hostname>`
- **Rsync transfer logging** — `tm_rsync_backup()` now passes `--log-file` to rsync, saving detailed file-by-file transfer info to `logs/rsync-<hostname>-<timestamp>.log`

### Changed
- **"SQL backup" → "Database backup"** in all log messages (`rsync.sh`, `timemachine.sh`). `tm_rsync_sql` now logs "Starting database backup sync" / "Database backup sync complete"
- **"No databases found" message improved** — When no databases are detected on a server, the log now shows: "No databases found on <host> — if this server has databases, make sure to configure them in .env (TM_DB_TYPES, credentials)"

## [2.16.0] - 2026-02-10

### Added
- **SMTP relay for email notifications** — Email notifications now use Python's built-in `smtplib` to send via an external SMTP server (Gmail, Mailgun, SendGrid, Amazon SES, etc.). No local MTA (`sendmail`, `postfix`) required. Fixes `s-nail: Cannot start /usr/sbin/sendmail: executable not found` errors
- **SMTP settings in dashboard** — New "SMTP Relay" section on the Settings page with fields for host, port, TLS, username, password, and from address. Settings are saved to `.env` and take effect immediately
- **Test email button** — "Send Test Email" button on the Settings page sends a test message via the configured SMTP relay to verify the configuration works. API: `POST /api/test-email`
- **Config variables**: `TM_SMTP_HOST`, `TM_SMTP_PORT`, `TM_SMTP_USER`, `TM_SMTP_PASS`, `TM_SMTP_FROM`, `TM_SMTP_TLS`

### Changed
- `_tm_send_email()` in `lib/notify.sh` now tries SMTP relay first (when `TM_SMTP_HOST` is set), then falls back to local mail tools (`mail`, `mailx`, `msmtp`, `sendmail`). Local tools have `2>/dev/null` to suppress MTA errors
- Fallback `tm_notify()` in `lib/common.sh` also uses SMTP relay first

## [2.15.1] - 2026-02-10

### Fixed
- **Slow service restart** — Python API server now calls `os._exit(0)` immediately on SIGTERM (no waiting for threads or socket close). Bash `_cleanup` sends SIGKILL directly (no SIGTERM grace period). Systemd service file adds `TimeoutStopSec=3`, `KillMode=mixed`, `SendSIGKILL=yes` so systemd itself force-kills the entire process group within 3 seconds

## [2.15.0] - 2026-02-10

### Added
- **Server Archive** — When removing a server, a modal now offers two choices:
  - **Archive**: Stop daily backups but preserve all existing snapshots. Archived servers appear in the new **Archive** tab where you can browse snapshots, restore data, re-activate the server, or permanently delete it
  - **Delete permanently**: Remove the server from config AND delete all backup data. Data deletion runs in the background (can take a long time for large datasets) — the web interface does not block. A "Background Deletions" panel on the Archive page shows progress
- **Archive page** — New nav tab between Servers and Restores. Lists archived servers with last backup date, snapshot count, total size, and actions (Browse, Re-activate, Delete)
- **API endpoints**: `GET /api/archived`, `DELETE /api/servers/<host>?action=archive|delete`, `POST /api/archived/<host>/unarchive`, `DELETE /api/archived/<host>`
- **Config file**: `config/archived.conf` — same format as `servers.conf`, stores archived server entries

## [2.14.5] - 2026-02-10

### Fixed
- **Systemd `StartLimitIntervalSec` warning** — Moved `StartLimitIntervalSec` and `StartLimitBurst` from `[Service]` to `[Unit]` section. Older systemd versions (CentOS 7, RHEL 7) only accept these directives in `[Unit]` and logged `Unknown key name 'StartLimitIntervalSec' in section 'Service'` on every daemon-reload
- **Service exit code 1 on shutdown** — When systemd sent SIGTERM, `wait` returned non-zero and the script exited with code 1, causing systemd to report `status=1/FAILURE`. The `_cleanup` trap now waits for child processes to terminate and explicitly exits 0 for a clean shutdown

## [2.14.4] - 2026-02-10

### Fixed
- **Daily backups invisible in dashboard** — `daily-runner.sh` launched backup processes but never wrote `proc-*.state` files to the state directory. The dashboard reads these files to show active jobs and the process table. Daily automated backups were completely invisible: "Active Jobs" always showed 0 and the Backup Processes table was empty during scheduled runs. Now `daily-runner.sh` registers each backup in the state directory on launch and updates the status (completed/failed) when finished
- **Per-server log files for daily backups** — Daily runner now writes individual `backup-<host>-<timestamp>.log` files instead of a single `daily-<date>.log`, so the dashboard log viewer can find and display them

### Changed
- **Process table: Duration column** — Added a live-updating Duration column to the Backup Processes table. Running backups show elapsed time (e.g. "12m 34s"), refreshed every poll cycle
- **Process sorting** — Running processes now always appear at the top of the process table, followed by finished processes sorted newest-first

## [2.14.3] - 2026-02-10

### Fixed
- **Service fails to start: NAMESPACE error** — Systemd service file had `ProtectSystem=false` with a leading space, causing systemd to ignore it and default to strict mount namespacing. When the backup directory (e.g. `/backups`) didn't exist at service start, systemd failed with `Failed to set up mount namespacing: /run/systemd/unit-root/backups: No such file or directory` (exit code 226/NAMESPACE). Removed `ProtectSystem`, `ProtectHome`, `StateDirectory`, and `LogsDirectory` directives entirely — a backup service needs full filesystem access to arbitrary mount points

## [2.14.2] - 2026-02-10

### Fixed
- **Daily backups never triggered** — Two bugs working together prevented all scheduled backups:
  1. `daily-jobs-check.sh` scanned `${TM_RUN_DIR}/*.pid` for stale backup processes, but `tmserviced.pid` (the service daemon itself) was always present with a live PID. This caused the pre-backup check to always report "previous backups still running" and exit 1, permanently blocking all daily runs
  2. `_scheduler_loop` inherited `set -euo pipefail` from `common.sh`. Any non-zero exit code (e.g. `grep` finding no matches in an empty `servers.conf`, or `_check_db_intervals` returning 1) silently killed the entire scheduler subshell. No error was logged — the scheduler simply stopped running
- **Fix**: `daily-jobs-check.sh` now skips `tmserviced.pid`. Scheduler loop now starts with `set +e` to prevent silent death. Added `|| true` guards on `_check_db_intervals` and `_generate_handler_script`. Fixed `return` → `return 0` in helper functions to avoid propagating error codes
- **Scheduler heartbeat** — Logs a DEBUG heartbeat every 30 minutes with the current schedule time, making it easy to verify the scheduler is alive via `journalctl -u timemachine`

## [2.14.1] - 2026-02-10

### Fixed
- **502 errors / service restarts** — Removed `WatchdogSec=120` from the systemd service file. Neither `tmserviced.sh` nor `tm-api-server.py` sends `sd_notify WATCHDOG=1` heartbeats, so systemd was killing the service every ~2 minutes thinking it was hung. `Restart=always` then brought it back, causing a restart loop and intermittent 502 errors
- **Python API server crash resilience** — Added `handle_error` override to suppress `BrokenPipeError`/`ConnectionResetError` from crashing threads when clients disconnect mid-response. All HTTP handler methods (`do_GET`, `do_POST`, `do_PUT`, `do_DELETE`) now wrapped with try/except for these exceptions

### Added
- **Exclude pattern editor** — New UI in Settings to edit global excludes (`config/exclude.conf`) and per-server excludes (`config/exclude.<hostname>.conf`). Per-server excludes are additive to global. New API endpoints: `GET/PUT /api/excludes` and `GET/PUT /api/excludes/<hostname>`
- **Disk usage mount point** — Dashboard now shows which mount point the disk usage refers to (the mount containing the backup directory, not the root disk). API response includes `mount` and `path` fields

### Changed
- **Help page** — Expanded exclude documentation with syntax reference table, two-level explanation (global vs per-server), and examples
- `StartLimitIntervalSec` increased from 120s to 300s for more lenient restart behavior

## [2.14.0] - 2026-02-10

### Added
- **Python API server** (`bin/tm-api-server.py`) — Production-grade threaded HTTP server replacing bash+socat. Uses Python's `ThreadingHTTPServer` with `daemon_threads` and `request_queue_size=128` for proper concurrent request handling (1000+ simultaneous users). All API endpoints are a 1:1 port from the bash implementation. Falls back to socat if Python 3 is not available
- **Schedule minute** — Backup start time can now be set to quarter-hour precision (00/15/30/45) via a dropdown in Settings. New `TM_SCHEDULE_MINUTE` config variable. Scheduler compares total minutes instead of just hours

### Changed
- **Dashboard layout** — Disk Usage card is now equal width next to Memory (4-column grid instead of 3+wide). Both use compact progress bars
- Scheduler time comparison uses `10#` prefix and minute-level granularity, fixing the octal parsing issue permanently
- **Smooth upgrade path** — `tmctl update` and `install.sh --reconfigure` now auto-install Python 3 if missing, set correct permissions on `.py` scripts, and refresh existing nginx configs (increased proxy timeouts, removed outdated comments). Users upgrading from the old socat-based setup get a seamless migration
- **Nginx proxy timeouts** — Increased `proxy_read_timeout` to 300s and `proxy_send_timeout` to 60s for large restore downloads and snapshot operations. Both `setup-web.sh` templates and the reconfigure step apply this
- **install.sh** — All package manager install lists now include `python3`. Permissions setup covers both `*.sh` and `*.py` scripts

## [2.13.1] - 2026-02-10

### Fixed
- **API broken pipe** — Removed `pty,stderr` options from socat `EXEC:` that caused all API requests to fail with "Broken pipe". The pseudo-terminal interfered with HTTP request/response over TCP sockets
- **Scheduler octal parsing** — `date +'%H'` returns zero-padded hours (e.g. `09`) which bash interprets as invalid octal. Fixed with `10#` prefix to force base-10 arithmetic

## [2.13.0] - 2026-02-10

### Added
- **Help/Wiki page** — New "Help" tab in the portal with comprehensive setup documentation:
  - Getting Started (3-step quick setup)
  - Client Setup (installer one-liner, backup modes)
  - Database Backup Setup (credential file instructions for all 5 engines: MySQL, PostgreSQL, MongoDB, Redis, SQLite with copy-paste commands)
  - Credential file summary table
  - Restoring Backups (UI and CLI instructions)
  - Server Configuration (per-server options, exclude files, CLI command reference)
- **Restore history** — Restores page now shows all tasks from the last 30 days (was limited to 50 most recent). Renamed to "Restore History"
- **Bulk clear restores** — New `DELETE /api/restores` endpoint clears all finished restore tasks at once. "Clear All" button replaces the old one-by-one delete loop

### Changed
- **System Info moved to Dashboard** — System Info panel relocated from Settings to the bottom of the Dashboard for better visibility
- Restore state files are now filtered by date (30-day window) instead of count

## [2.12.0] - 2026-02-10

### Added
- **DB credential alerts** — When a database dump fails due to missing or wrong credentials, a targeted email notification is sent to the admin. Detects specific issues per engine: MySQL password file missing, MySQL auth failed, PostgreSQL auth failed, MongoDB credentials issue, Redis BGSAVE failed
- **Custom 502 auto-retry page** — `web/502.html` shows a friendly "API temporarily unavailable" message with 5-second auto-retry instead of raw nginx error

### Fixed
- **HTTP server stability** — socat now runs with `max-children=10` (prevents fork bomb under load), `keepalive` (reuses TCP connections), and `pty,stderr` (proper I/O handling). This significantly reduces 502 errors for concurrent users

### Changed
- **Dashboard layout** — Removed Uptime card; dashboard now shows Hostname, Active Jobs, Servers on row 1 (3 cards) and CPU 1m, CPU 5m, Memory, Disk on row 2 (4 cards) — fits cleanly in 2 rows
- Row 1 uses new `cards-3` CSS grid class

## [2.11.0] - 2026-02-10

### Added
- **Parallel jobs setting** — `TM_PARALLEL_JOBS` now configurable in Settings UI (1-50, default 5). Controls how many backup processes run simultaneously
- **Config reload** — Saving settings triggers automatic config reload: the scheduler loop detects a `.reload_config` signal file, re-reads `.env`, and regenerates the HTTP handler script. No service restart needed
- **502 error page** — Custom `web/502.html` with auto-retry (5s) shown when the API is temporarily unavailable instead of a raw nginx error

### Fixed
- **False database backup display** — Snapshot detail now checks for actual dump files inside `sql/` instead of just directory existence. Servers without databases no longer show "Yes" in the Database column
- **Column renamed** — "SQL" column renamed to "Database" in snapshot detail tables (more accurate since multiple DB engines are supported)

### Changed
- Nginx proxy config (`setup-web.sh`) now includes `proxy_connect_timeout`, `proxy_read_timeout`, `proxy_next_upstream` with retry for better stability against brief API drops
- `GET/PUT /api/settings` extended with `parallel_jobs` field
- `GET /api/snapshots` returns `has_db` (was `has_sql`), checks for actual files not empty dirs

## [2.10.0] - 2026-02-09

### Added
- **Per-event notification control** — Enable/disable notifications independently for: backup success, backup failure, restore success, restore failure. Each event type can have its own email address override (falls back to global `TM_ALERT_EMAIL`)
- **Per-server notification email** — New `--notify email@...` option in `servers.conf`. The server-specific recipient receives emails in addition to the global/per-event address. Configurable via the server edit modal in the UI
- **Notification settings UI** — Settings page now has a full "Notifications" panel with: global enable/disable toggle, default email, per-event enable/disable checkboxes, per-event email override fields
- **Notification email routing** — `notify.sh` resolves recipients in priority order: per-event email → global email → plus per-server email as additional CC

### Changed
- `tm_notify()` now accepts `event_type` and `server_hostname` parameters for routing
- `GET/PUT /api/settings` extended with all notification fields
- `GET /api/servers` now returns `notify_email` field
- `PUT /api/servers/:host` accepts `notify_email` to set `--notify` in servers.conf
- `.env.example` updated with all new notification variables

## [2.9.0] - 2026-02-09

### Added
- **Backup Schedule settings** — Settings page now has configurable "Daily backup start hour" (0-23) and "Retention days" (1-365) with a Save button. Values are persisted to `.env` via new `GET/PUT /api/settings` endpoints
- **"Add New Client" moved to Dashboard** — The client installer one-liner is now on the Dashboard page for quick access, instead of buried in Settings

### Changed
- Settings page now shows: Backup Schedule, SSH Key, System Info
- Dashboard page now shows: Status, System, Disk, Failed Backups, Active Processes, Add New Client, Quick Backup

## [2.8.0] - 2026-02-09

### Added
- **Service auto-restart** — Systemd service now uses `Restart=always` with `StartLimitBurst=5` (max 5 restarts in 120s). Added `WatchdogSec=120` so systemd kills and restarts the service if it becomes unresponsive
- **Cron-based watchdog** — New `bin/watchdog.sh` runs every 5 minutes via `/etc/cron.d/timemachine-watchdog`. If the service is down (even after systemd gives up), the watchdog restarts it. Also resets systemd's failed state to allow future restarts
- **Email on successful backup** — Sends a notification with server name, date, mode, duration, snapshot size, snapshot count, and disk free space
- **Email on restore completion** — Sends a notification (success or failure) with server, snapshot, format, target, and the last 100 lines of the restore log included in the email body
- Systemd watchdog ping in scheduler loop (`systemd-notify WATCHDOG=1`)

### Changed
- Watchdog cron is now installed during both `install.sh --server` and `install.sh --reconfigure`

## [2.7.4] - 2026-02-09

### Fixed
- **Zip archive creation failing with exit code 18** — `zip` returns exit code 18 ("nothing was done") when it encounters special files like Unix sockets (e.g. `.pm2/pub.sock`). These are now treated as warnings instead of errors when the archive file was successfully created. Also fixed zip output going to a separate log file instead of the restore log

## [2.7.3] - 2026-02-09

### Fixed
- **Restore log not displaying after completion** — Log content with backslashes, carriage returns, or tabs from rsync output broke JSON escaping. Fixed by stripping `\r`, escaping `\` before `"`, and escaping tabs in both restore-log and backup-log API endpoints
- **Removed `--progress` from archive transfer rsync** — Progress output with control characters polluted the restore log and broke JSON parsing

## [2.7.2] - 2026-02-09

### Added
- **Archive transfer to source server** — After creating a tar.gz or zip archive on the backup server, it is automatically transferred via rsync/SSH to the source server at `/home/timemachine/restores/`. The sysadmin of that machine can then place the files back where needed

## [2.7.1] - 2026-02-09

### Fixed
- **`install.sh --reconfigure` hung on interactive prompt** — The `select_mode()` function ran before the `--reconfigure` check, causing it to wait for user input. Now `--reconfigure` is checked immediately after parsing args
- **`tar` and `zip` added to server dependencies** — All package manager install lines now include `tar` and `zip` to ensure they're always available
- **`reconfigure_server` installs missing dependencies** — The reconfigure step now checks for and installs `tar`/`zip` if missing, so `tmctl update` ensures these tools are present

## [2.7.0] - 2026-02-09

### Added
- **Navigation menu** — Top navigation bar with 4 pages: Dashboard, Servers, Restores, Settings
- **Dashboard page** — Status cards, system metrics, disk usage, active backup processes, failed backups, quick backup
- **Servers page** — Full server list with backup history. Click "Details" to see all snapshots inline with Browse, Download, and Restore buttons per snapshot
- **Restores page** — Dedicated page for restore task management (no longer hidden when empty)
- **Settings page** — Client installer, SSH key, system info
- **Server detail panel** — Inline expandable panel on the Servers page showing paginated snapshots per server with direct actions

### Changed
- Servers table now has a "Details" button instead of "Snaps" — opens inline detail panel instead of modal
- Restore tasks panel is always visible on the Restores page (no longer conditionally hidden)
- Responsive navigation: tabs wrap on tablets, compact on mobile

## [2.6.3] - 2026-02-09

### Changed
- **`tmctl update` now applies all configuration changes** — After pulling new code, `tmctl update` automatically re-applies sudoers rules, file permissions, symlinks, systemd service config, and restarts the service. No more need to manually re-run `install.sh` after an update
- **New `install.sh --reconfigure` flag** — Non-interactive mode that re-applies all server configuration (sudoers, permissions, symlinks, service) without prompting. Called automatically by `tmctl update`

## [2.6.2] - 2026-02-09

### Fixed
- **Sudoers: add `tar` and `zip` to allowed commands** — The timemachine user now has passwordless sudo access to `tar` and `zip` on the server, required for creating restore archives from root-owned backup files
- Re-running `install.sh` on the server will automatically update the sudoers rules with the new commands

## [2.6.1] - 2026-02-09

### Fixed
- **Archive only selected path** — When restoring a specific folder (e.g. `root`), the tar/zip now archives only that folder, not the entire `files/` directory
- **Permission denied on archive creation** — `tar` and `zip` now run with `sudo` to read root-owned backup files like `/etc/shadow`, `/usr/bin/sudo`, etc. Archive is chowned back to the timemachine user after creation
- **Sanitized archive filenames** — Paths with `/` in the label are converted to `-` in the archive filename (e.g. `root` → `hostname-date-root.tar.gz`)
- **Fixed `$?` check in archive creation** — Exit code is now properly captured before the chown step, preventing false success/failure reports

## [2.6.0] - 2026-02-09

### Changed
- **Restore always goes to the server** — Choosing tar.gz or zip now creates the archive *on the backup server* in the target directory, not as a browser download. Use the separate "Download" button if you want to download to your browser
- **Removed Restore Mode dropdown** — Files and databases are now separate restore flows. Clicking "Restore" on a file item uses `--files-only`, clicking "Restore" on a database item uses `--db-only` automatically
- **Database restore creates archive on server** — Restore button on SQL items packages the database dumps as files, tar.gz, or zip on the server in the target directory
- **`restore.sh` supports `--format` flag** — New option: `--format files|tar.gz|zip` to control how restored content is placed on the server
- **Default restore target** — When no target directory is specified, restores go to `$TM_HOME/restores/<hostname>/<date>/` instead of trying to write to `/`
- Removed dead code for remote database import via SSH (was unreachable)

## [2.5.3] - 2026-02-09

### Added
- **Delete restore tasks** — Each finished restore task now has a "Delete" button to remove it (and its log file) from the list. Running tasks cannot be deleted
- **Clear Finished button** — Bulk-delete all completed/failed restore tasks in one click
- **Snapshot pagination** — Snapshots viewer now shows 15 per page (newest first) with Previous/Next navigation
- **API: `DELETE /api/restore/<id>`** — Remove a restore task state file and its associated log

### Changed
- Snapshots API limited to last 3 months (older snapshots are still on disk, just not shown in the web portal)
- Restore tasks API now includes `id` field for referencing individual tasks
- Snapshots modal title shows "(last 3 months)" for clarity

## [2.5.2] - 2026-02-09

### Fixed
- **Restore format choice now available** — Restore modal shows "Restore Format" dropdown with Files (direct restore), tar.gz, or zip options. Previously tar/zip was only available via the separate download flow
- **Permission denied on restore** — When target directory is not writable (e.g. `/home/ronald`), restore now falls back to `$TM_HOME/restores/<hostname>/<date>/` instead of failing with `mkdir: Permission denied`
- **Simplified restore modal** — Removed confusing action toggle (restore vs download). Single unified form with format, mode, and target directory fields

### Changed
- `restore.sh` checks target directory writability before starting, with automatic fallback for both file and database restores
- Restore modal placeholder updated to show `/home/timemachine/restores` as example target

## [2.5.1] - 2026-02-09

### Fixed
- **Database backups now browsable and downloadable** — Snapshot browser now shows both **Files** and **Databases** sections at the root level. Previously only the `files/` directory was accessible
- **Database dumps can be downloaded** — Individual `.sql` files or all databases as tar.gz/zip from the snapshot browser
- **Database dumps can be restored** — Restore modal auto-detects database items, defaults to "Database only" mode, and supports restoring to a custom target directory (copies SQL files there) or back to the server (imports via MySQL/PostgreSQL)

### Changed
- Snapshot root browse view now shows two sections: Files and Databases with separate action buttons for each
- Database items use a distinct database icon in the file browser
- Restore modal dynamically sets default mode based on item type (files-only for files, db-only for databases)

## [2.5.0] - 2026-02-09

### Added
- **Restore Tasks panel in web dashboard** — New panel shows all active and completed restore jobs with server, description, timestamp, and status (running/completed/failed). Auto-hides when no tasks exist
- **Restore log viewer with live streaming** — Click "Logs" on any restore task to view its log. Running restores auto-refresh every 2 seconds with Live/Completed badge, just like backup logs
- **Download format choice** — All download buttons now open a format picker: tar.gz (default) or zip. API supports `?format=zip` query parameter
- **Restore action toggle** — Restore modal now lets you choose between "Restore to server" (with mode + target dir) or "Download archive" (with format choice) in a single unified UI
- **API: `GET /api/restores`** — List all restore tasks with PID, hostname, description, status, and logfile
- **API: `GET /api/restore-log/<logfile>`** — View restore log content with `running` status indicator
- **Restore process tracking** — Restore jobs are now tracked in state files with PID, status updates on completion/failure

### Changed
- Download endpoint supports `?format=zip` in addition to default tar.gz
- Restore processes run in background subshell that auto-updates state file on exit

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
