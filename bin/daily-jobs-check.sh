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
STATE_DIR="${TM_STATE_DIR:-${TM_HOME:-/home/timemachine}/state}"

tm_ensure_dir "${TM_RUN_DIR}"

# Check process STATE files (the authoritative source for backup tracking).
# State files are created by daily-runner.sh and tmserviced.sh run_backup().
# Format: pid|hostname|mode|started|status|logfile|trigger
for state_file in "${STATE_DIR}"/proc-*.state; do
    [[ -f "${state_file}" ]] || continue

    srv_host=$(basename "${state_file}" .state)
    srv_host="${srv_host#proc-}"

    local_status=$(cut -d'|' -f5 "${state_file}" 2>/dev/null)
    [[ "${local_status}" != "running" ]] && continue

    pid=$(cut -d'|' -f1 "${state_file}" 2>/dev/null)

    # Verify the process is actually still alive
    if ! kill -0 "${pid}" 2>/dev/null; then
        tm_log "DEBUG" "Cleaning up stale state file for ${srv_host} (PID ${pid} no longer running)"
        # Update status to completed (process exited but state wasn't cleaned up)
        local content
        content=$(cat "${state_file}")
        local f1 f2 f3 f4 f6 f7
        f1=$(echo "${content}" | cut -d'|' -f1)
        f2=$(echo "${content}" | cut -d'|' -f2)
        f3=$(echo "${content}" | cut -d'|' -f3)
        f4=$(echo "${content}" | cut -d'|' -f4)
        f6=$(echo "${content}" | cut -d'|' -f6)
        f7=$(echo "${content}" | cut -d'|' -f7)
        echo "${f1}|${f2}|${f3}|${f4}|completed|${f6}|${f7}" > "${state_file}"
        continue
    fi

    local_mode=$(cut -d'|' -f3 "${state_file}" 2>/dev/null)
    local_trigger=$(cut -d'|' -f7 "${state_file}" 2>/dev/null)

    # DB-only backups are short-lived and should NOT block the daily run
    if [[ "${local_mode}" == "db-only" ]]; then
        tm_log "INFO" "DB-only backup running for ${srv_host} (PID ${pid}) — not blocking daily run"
        continue
    fi

    # Interval and manual backups should NOT block the daily run.
    # Only previous daily/scheduler backups still running indicate the server is lagging.
    if [[ "${local_trigger}" == "interval" || "${local_trigger}" == "interval-db" || "${local_trigger}" == "manual" || "${local_trigger}" == "api" ]]; then
        tm_log "INFO" "${local_trigger} backup running for ${srv_host} (PID ${pid}) — not blocking daily run"
        continue
    fi

    tm_log "WARN" "Previous daily backup still running: ${srv_host} (PID ${pid}, trigger=${local_trigger:-unknown})"
    STILL_RUNNING=1
done

# Also clean up stale PID files (legacy — no longer used for backup tracking)
for pidfile in "${TM_RUN_DIR}"/*.pid; do
    [[ -f "${pidfile}" ]] || continue
    lock_name=$(basename "${pidfile}" .pid)
    [[ "${lock_name}" == "tmserviced" ]] && continue
    pid=$(cat "${pidfile}" 2>/dev/null)
    if ! kill -0 "${pid}" 2>/dev/null; then
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
