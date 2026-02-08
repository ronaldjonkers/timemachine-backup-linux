#!/usr/bin/env bash
# ============================================================
# TimeMachine Backup - Pre-Backup Check
# ============================================================
# Runs before daily backups to verify that yesterday's backups
# have completed. If any are still running, sends an alert and
# exits with code 1 to prevent new backups from starting.
# ============================================================

# Resolve symlinks to find real script directory
_src="$0"
while [[ -L "$_src" ]]; do
    _src_dir="$(cd -P "$(dirname "$_src")" && pwd)"
    _src="$(readlink "$_src")"
    [[ "$_src" != /* ]] && _src="$_src_dir/$_src"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_src")" && pwd)"

source "${SCRIPT_DIR}/../lib/common.sh"

tm_load_config
tm_require_user

# ============================================================
# CHECK FOR RUNNING BACKUP PROCESSES
# ============================================================

STILL_RUNNING=0

tm_ensure_dir "${TM_RUN_DIR}"

for pidfile in "${TM_RUN_DIR}"/*.pid; do
    [[ -f "${pidfile}" ]] || continue

    pid=$(cat "${pidfile}")
    lock_name=$(basename "${pidfile}" .pid)

    if kill -0 "${pid}" 2>/dev/null; then
        tm_log "WARN" "Previous backup still running: ${lock_name} (PID ${pid})"
        STILL_RUNNING=1
    else
        tm_log "DEBUG" "Removing stale PID file: ${pidfile}"
        rm -f "${pidfile}"
    fi
done

# ============================================================
# ALERT AND EXIT
# ============================================================

if [[ "${STILL_RUNNING}" -eq 1 ]]; then
    tm_log "ERROR" "Yesterday's backups are still running. Backup server is lagging."
    tm_notify "Backups still running" \
        "Yesterday's backups are still running on $(hostname). New backups will NOT start until previous ones complete."
    exit 1
fi

tm_log "INFO" "Pre-backup check passed. No stale processes found."
exit 0
