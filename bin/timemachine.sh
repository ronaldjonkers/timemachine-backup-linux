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
#   --dry-run        Show what would be done without executing
#   --verbose        Enable debug logging
#
# Examples:
#   timemachine.sh web1.example.com
#   timemachine.sh db1.example.com --files-only
#   timemachine.sh db1.example.com --db-only
# ============================================================

# Self-restart in temp file (allows editing while running)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load shared libraries
source "${SCRIPT_DIR}/../lib/common.sh"
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
        tm_log "INFO" "Triggering remote database dump on ${HOSTNAME}"
        ssh -p "${TM_SSH_PORT}" -i "${TM_SSH_KEY}" \
            -o ConnectTimeout="${TM_SSH_TIMEOUT}" \
            -o StrictHostKeyChecking=no \
            "${TM_USER}@${HOSTNAME}" \
            "bash /home/${TM_USER}/dump_dbs.sh" 2>&1 || {
                tm_log "ERROR" "Remote database dump failed on ${HOSTNAME}"
                exit_code=1
            }

        # Sync the SQL dumps back
        if [[ ${exit_code} -eq 0 ]]; then
            if ! tm_rsync_sql "${HOSTNAME}" "${BACKUP_BASE}"; then
                tm_log "ERROR" "SQL sync failed for ${HOSTNAME}"
                exit_code=1
            fi
        fi
    fi

    # --- Rotation ---
    if [[ ${NO_ROTATE} -eq 0 && ${exit_code} -eq 0 ]]; then
        tm_log "INFO" "Phase 3: Rotating old backups"
        tm_rotate_backups "${BACKUP_BASE}"
    fi

    # --- Summary ---
    local end_time
    end_time=$(date +%s)
    local duration=$(( end_time - start_time ))

    if [[ ${exit_code} -eq 0 ]]; then
        tm_log "INFO" "Backup completed successfully for ${HOSTNAME} (${duration}s)"
    else
        tm_log "ERROR" "Backup completed with errors for ${HOSTNAME} (${duration}s)"
        tm_notify "Backup FAILED: ${HOSTNAME}" \
            "Backup for ${HOSTNAME} completed with errors after ${duration} seconds."
    fi

    return ${exit_code}
}

main
