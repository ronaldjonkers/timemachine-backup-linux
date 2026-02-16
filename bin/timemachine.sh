#!/usr/bin/env bash
# ============================================================
# TimeMachine Backup - Main Backup Script
# ============================================================
# Usage:
#   timemachine.sh <hostname> [OPTIONS]
#
# Options:
#   --files-only     Only backup files (skip database dump)
#   --db-only        Only backup databases (skip file sync)
#   --no-rotate      Skip backup rotation after sync
#   --priority N     Ignored (used by scheduler for ordering)
#   --db-interval Xh Ignored (used by scheduler for extra DB runs)
#   --dry-run        Show what would be done without executing
#   --verbose        Enable debug logging
#
# Examples:
#   timemachine.sh web1.example.com
#   timemachine.sh db1.example.com --files-only
#   timemachine.sh db1.example.com --db-only
# ============================================================

# Resolve symlinks to find real script directory
_src="$0"
while [[ -L "$_src" ]]; do
    _src_dir="$(cd -P "$(dirname "$_src")" && pwd)"
    _src="$(readlink "$_src")"
    [[ "$_src" != /* ]] && _src="$_src_dir/$_src"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_src")" && pwd)"
# If running from temp copy after self-restart, use original SCRIPT_DIR
[[ -n "${_TM_ORIG_SCRIPT_DIR:-}" ]] && SCRIPT_DIR="${_TM_ORIG_SCRIPT_DIR}"

# Load shared libraries
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/../lib/notify.sh"
source "${SCRIPT_DIR}/../lib/rsync.sh"
source "${SCRIPT_DIR}/../lib/database.sh"

# Enable self-restart
tm_self_restart "$0" "$@"

# ============================================================
# ARGUMENT PARSING
# ============================================================

HOSTNAME=""
FILES_ONLY=0
DB_ONLY=0
NO_ROTATE=0
DRY_RUN=0
TRIGGER="manual"

usage() {
    echo "Usage: $(basename "$0") <hostname> [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --files-only   Only backup files (skip database dump)"
    echo "  --db-only      Only backup databases (skip file sync)"
    echo "  --no-rotate    Skip backup rotation"
    echo "  --dry-run      Show what would be done"
    echo "  --verbose      Enable debug logging"
    echo "  --help         Show this help message"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --files-only)  FILES_ONLY=1; shift ;;
        --db-only)     DB_ONLY=1; shift ;;
        --no-rotate)   NO_ROTATE=1; shift ;;
        --trigger)     TRIGGER="$2"; shift; shift ;;
        --notify)           shift; shift ;;  # consumed by notify.sh
        --priority)         shift; shift ;;  # consumed by scheduler
        --db-interval)      shift; shift ;;  # consumed by scheduler
        --backup-interval)  shift; shift ;;  # consumed by scheduler
        --dry-run)     DRY_RUN=1; shift ;;
        --verbose)     TM_LOG_LEVEL="DEBUG"; shift ;;
        --help|-h)     usage ;;
        -*)            echo "Unknown option: $1"; usage ;;
        *)
            if [[ -z "${HOSTNAME}" ]]; then
                HOSTNAME="$1"
            else
                echo "Unexpected argument: $1"
                usage
            fi
            shift
            ;;
    esac
done

if [[ -z "${HOSTNAME}" ]]; then
    echo "Error: hostname is required"
    usage
fi

# ============================================================
# INITIALIZATION
# ============================================================

tm_load_config
tm_require_user

BACKUP_BASE="${TM_BACKUP_ROOT}/${HOSTNAME}"
LOCK_NAME="backup-${HOSTNAME}"

# ============================================================
# MAIN
# ============================================================

main() {
    tm_log "INFO" "=========================================="
    tm_log "INFO" "Starting backup for: ${HOSTNAME}"
    tm_log "INFO" "Triggered by: ${TRIGGER}"
    tm_log "INFO" "=========================================="

    # Acquire lock to prevent duplicate runs for same host
    if ! tm_acquire_lock "${LOCK_NAME}"; then
        tm_log "ERROR" "Cannot acquire lock for ${HOSTNAME}; another backup may be running"
        exit 1
    fi

    # Ensure cleanup on exit
    trap 'tm_release_lock "${LOCK_NAME}"' EXIT

    local exit_code=0
    local start_time
    start_time=$(date +%s)

    if [[ ${DRY_RUN} -eq 1 ]]; then
        tm_log "INFO" "[DRY-RUN] Would backup ${HOSTNAME} to ${BACKUP_BASE}"
        [[ ${FILES_ONLY} -eq 0 && ${DB_ONLY} -eq 0 ]] && tm_log "INFO" "[DRY-RUN] Mode: files + databases"
        [[ ${FILES_ONLY} -eq 1 ]] && tm_log "INFO" "[DRY-RUN] Mode: files only"
        [[ ${DB_ONLY} -eq 1 ]] && tm_log "INFO" "[DRY-RUN] Mode: databases only"
        return 0
    fi

    # --- File Backup ---
    if [[ ${DB_ONLY} -eq 0 ]]; then
        tm_log "INFO" "Phase 1: File backup"
        if ! tm_rsync_backup "${HOSTNAME}" "${BACKUP_BASE}"; then
            tm_log "ERROR" "File backup failed for ${HOSTNAME}"
            exit_code=1
        fi
    fi

    # --- Database Backup ---
    if [[ ${FILES_ONLY} -eq 0 ]]; then
        tm_log "INFO" "Phase 2: Database backup"

        # Trigger remote database dump via SSH
        local db_output
        db_output=$(tm_trigger_remote_dump "${HOSTNAME}" 2>&1)
        local db_rc=$?
        _TM_DB_OUTPUT="${db_output}"

        # Log remote output for visibility
        if [[ -n "${db_output}" ]]; then
            while IFS= read -r line; do
                [[ -n "${line}" ]] && tm_log "INFO" "  [remote] ${line}"
            done <<< "${db_output}"
        fi

        if [[ ${db_rc} -ne 0 ]]; then
            tm_log "ERROR" "Remote database dump failed on ${HOSTNAME}"
            exit_code=1

            # Check for credential/auth issues and send targeted alert
            local db_errors=""
            if echo "${db_output}" | grep -qi "No MySQL password found\|No.*password.*found"; then
                db_errors+="MySQL/MariaDB: password file missing or empty\n"
            fi
            if echo "${db_output}" | grep -qi "Failed to retrieve MySQL database list"; then
                db_errors+="MySQL/MariaDB: authentication failed (wrong password or access denied)\n"
            fi
            if echo "${db_output}" | grep -qi "Failed to retrieve PostgreSQL database list"; then
                db_errors+="PostgreSQL: authentication failed (peer auth or connection refused)\n"
            fi
            if echo "${db_output}" | grep -qi "mongodump failed"; then
                db_errors+="MongoDB: dump failed (check credentials in mongodb.conf)\n"
            fi
            if echo "${db_output}" | grep -qi "Failed to trigger Redis BGSAVE"; then
                db_errors+="Redis: BGSAVE failed (check password in redis.pw)\n"
            fi
            if [[ -n "${db_errors}" ]]; then
                local alert_body="Database backup failed on ${HOSTNAME} due to credential/access issues:\n\n${db_errors}\nFull output:\n$(echo "${db_output}" | tail -20)"
                tm_notify "DB credentials issue: ${HOSTNAME}" "${alert_body}" "error" "backup_fail" "${HOSTNAME}"
            fi
        elif echo "${db_output}" | grep -qi "No databases to dump\|No supported database engines detected"; then
            tm_log "INFO" "No databases found on ${HOSTNAME} — skipping database sync"
            tm_log "INFO" "If this server has databases, configure TM_DB_TYPES and credentials in .env"
        else
            # Sync the SQL dumps back
            if ! tm_rsync_sql "${HOSTNAME}" "${BACKUP_BASE}"; then
                tm_log "ERROR" "Database sync failed for ${HOSTNAME}"
                exit_code=1
            fi
        fi
    fi

    # --- Rotation ---
    if [[ ${NO_ROTATE} -eq 0 && ${exit_code} -eq 0 ]]; then
        tm_log "INFO" "Phase 3: Rotating old backups"
        tm_rotate_backups "${BACKUP_BASE}"
    fi

    # --- Summary & Notification ---
    # Temporarily disable set -e for the summary section so that
    # non-critical failures (du, df, mail) don't kill the script
    # and prevent the exit code from being reported correctly.
    set +e

    local end_time
    end_time=$(date +%s)
    local duration=$(( end_time - start_time ))

    # Build summary header
    local snap_dir="${BACKUP_BASE}/${_TM_SNAP_ID:-$(tm_date_today)}"
    local snap_size=""
    if [[ -d "${snap_dir}" ]]; then
        snap_size=$(du -sh "${snap_dir}" 2>/dev/null | cut -f1) || snap_size="unknown"
    fi
    local snap_count="0"
    # Count unique dates (YYYY-MM-DD), not individual snapshot dirs, so
    # multiple DB-only runs on the same day count as 1 version.
    snap_count=$(find "${BACKUP_BASE}" -maxdepth 1 -type d -name '20*' 2>/dev/null | \
        sed 's|.*/||; s|_.*||' | sort -u | wc -l | tr -d ' ') || snap_count="0"
    local disk_free=""
    disk_free=$(df -h "${TM_BACKUP_ROOT}" 2>/dev/null | awk 'NR==2{print $4}') || disk_free="unknown"

    local mode="full"
    [[ ${FILES_ONLY} -eq 1 ]] && mode="files-only"
    [[ ${DB_ONLY} -eq 1 ]] && mode="db-only"

    local status_line="OK"
    [[ ${exit_code} -ne 0 ]] && status_line="FAILED"

    if [[ ${exit_code} -eq 0 ]]; then
        tm_log "INFO" "Backup completed successfully for ${HOSTNAME} (${duration}s)"
    else
        tm_log "ERROR" "Backup completed with errors for ${HOSTNAME} (${duration}s)"
    fi

    # Build email summary (always included)
    local email_summary="Status:     ${status_line}
Server:     ${HOSTNAME}
Date:       $(tm_date_today)
Triggered:  ${TRIGGER}
Mode:       ${mode}
Duration:   ${duration}s
Snap size:  ${snap_size:-unknown}
Snapshots:  ${snap_count}
Disk free:  ${disk_free:-unknown}"

    if [[ ${exit_code} -eq 0 ]]; then
        # Success: concise email with status only — no logs
        tm_notify "Backup OK: ${HOSTNAME}" "${email_summary}" "info" "backup_ok" "${HOSTNAME}" || true
    else
        # Failure: include full diagnostic logs for debugging
        local email_body="${email_summary}"

        # Append rsync transfer log if available
        if [[ -n "${_TM_RSYNC_LOGFILE:-}" && -f "${_TM_RSYNC_LOGFILE}" ]]; then
            email_body+="

============================================================
RSYNC TRANSFER LOG (${_TM_RSYNC_LOGFILE##*/})
============================================================
$(cat "${_TM_RSYNC_LOGFILE}" 2>/dev/null)"
        fi

        # Append database output if any
        if [[ -n "${_TM_DB_OUTPUT:-}" ]]; then
            email_body+="

============================================================
DATABASE BACKUP OUTPUT
============================================================
${_TM_DB_OUTPUT}"
        fi

        # Append the full backup log (contains all tm_log output incl. errors)
        # Limit to last 500 lines to prevent bash OOM on huge first backups
        if [[ -n "${_TM_BACKUP_LOGFILE:-}" && -f "${_TM_BACKUP_LOGFILE}" ]]; then
            local log_lines
            log_lines=$(wc -l < "${_TM_BACKUP_LOGFILE}" 2>/dev/null) || log_lines=0
            local log_content
            log_content=$(tail -500 "${_TM_BACKUP_LOGFILE}" 2>/dev/null) || log_content="(could not read log)"
            local log_header="FULL BACKUP LOG (${_TM_BACKUP_LOGFILE##*/})"
            if [[ ${log_lines} -gt 500 ]]; then
                log_header+=" — last 500 of ${log_lines} lines"
            fi
            email_body+="

============================================================
${log_header}
============================================================
${log_content}"
        fi

        tm_notify "Backup FAILED: ${HOSTNAME}" "${email_body}" "error" "backup_fail" "${HOSTNAME}" || true
    fi

    return ${exit_code}
}

main
