#!/usr/bin/env bash
# ============================================================
# TimeMachine Backup - Daily Job Runner
# ============================================================
# Reads the job list from config/servers.conf and executes
# backups in parallel. This script is called from cron.
#
# Crontab entry example:
#   30 11 * * * timemachine /path/to/bin/daily-runner.sh
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
source "${SCRIPT_DIR}/../lib/report.sh"

tm_load_config
tm_require_user

# ============================================================
# CONFIGURATION
# ============================================================

SERVERS_CONF="${TM_PROJECT_ROOT}/config/servers.conf"
LOG_DIR="${TM_LOG_DIR}"
STATE_DIR="${TM_STATE_DIR}"
TODAY=$(tm_date_today)
LOGFILE="${LOG_DIR}/daily-${TODAY}.log"

tm_ensure_dir "${LOG_DIR}"
tm_ensure_dir "${STATE_DIR}"

# ============================================================
# PRE-FLIGHT CHECK
# ============================================================

tm_log "INFO" "Running pre-backup check..."

if ! "${SCRIPT_DIR}/daily-jobs-check.sh"; then
    tm_log "ERROR" "Pre-backup check failed. Aborting daily run."
    exit 1
fi

# ============================================================
# VALIDATE SERVER LIST
# ============================================================

if [[ ! -f "${SERVERS_CONF}" ]]; then
    tm_log "ERROR" "Server configuration not found: ${SERVERS_CONF}"
    exit 1
fi

# Count active jobs
JOB_COUNT=$(grep -cE '^\s*[^#\s]' "${SERVERS_CONF}" 2>/dev/null || echo 0)
tm_log "INFO" "Found ${JOB_COUNT} backup job(s) in ${SERVERS_CONF}"

if [[ "${JOB_COUNT}" -eq 0 ]]; then
    tm_log "WARN" "No backup jobs configured. Nothing to do."
    exit 0
fi

# ============================================================
# EXECUTE BACKUPS (sorted by priority, with reporting)
# ============================================================

tm_log "INFO" "Starting daily backups (parallel=${TM_PARALLEL_JOBS})"

# Parse --priority N from each line (default 10), sort ascending
_get_priority() {
    local line="$1"
    if echo "${line}" | grep -qo '\-\-priority[[:space:]]\+[0-9]\+'; then
        echo "${line}" | grep -o '\-\-priority[[:space:]]\+[0-9]\+' | awk '{print $2}'
    else
        echo "10"
    fi
}

# Build sorted job list
SORTED_JOBS=$(
    grep -E '^\s*[^#\s]' "${SERVERS_CONF}" | \
        sed 's/^[[:space:]]*//' | \
        while IFS= read -r line; do
            prio=$(_get_priority "${line}")
            printf '%03d|%s\n' "${prio}" "${line}"
        done | sort -t'|' -k1,1n | cut -d'|' -f2-
)

# Initialize report
tm_report_init "daily"

# Results tracking file (pid:hostname:start_time per line)
PIDS_FILE="${TM_RUN_DIR}/daily-pids-$$.tmp"
: > "${PIDS_FILE}"
EXIT_CODE=0
DAILY_START=$(date +%s)
MAX_DAILY_SECONDS=${TM_MAX_DAILY_SECONDS:-86400}  # 24 hours default

# Register a backup process in the state directory (visible to dashboard)
_register_proc() {
    local hostname="$1" pid="$2" mode="${3:-full}" logfile="${4:-}"
    local ts
    ts=$(date +'%Y-%m-%d %H:%M:%S')
    echo "${pid}|${hostname}|${mode}|${ts}|running|${logfile}|daily" > "${STATE_DIR}/proc-${hostname}.state"
}

# Update process state in the state directory
_update_proc_state() {
    local hostname="$1" status="$2"
    local state_file="${STATE_DIR}/proc-${hostname}.state"
    [[ -f "${state_file}" ]] || return 0
    local content
    content=$(cat "${state_file}")
    local f1 f2 f3 f4 f6 f7
    f1=$(echo "${content}" | cut -d'|' -f1)
    f2=$(echo "${content}" | cut -d'|' -f2)
    f3=$(echo "${content}" | cut -d'|' -f3)
    f4=$(echo "${content}" | cut -d'|' -f4)
    f6=$(echo "${content}" | cut -d'|' -f6)
    f7=$(echo "${content}" | cut -d'|' -f7)
    echo "${f1}|${f2}|${f3}|${f4}|${status}|${f6}|${f7}" > "${state_file}"
}

# Collect finished jobs and add to report
_collect_finished() {
    local new_entries=""
    while IFS= read -r entry; do
        [[ -z "${entry}" ]] && continue
        local pid="${entry%%:*}"
        local meta="${entry#*:}"
        local srv_host="${meta%%:*}"
        local srv_start="${meta#*:}"

        if kill -0 "${pid}" 2>/dev/null; then
            new_entries+="${entry}"$'\n'
        else
            wait "${pid}" 2>/dev/null || true
            local rc=$?
            local srv_end
            srv_end=$(date +%s)
            local srv_duration
            srv_duration=$(_tm_format_duration $(( srv_end - srv_start )))
            # Get logfile path from state file for inclusion in report
            local srv_logfile=""
            local srv_state="${STATE_DIR}/proc-${srv_host}.state"
            [[ -f "${srv_state}" ]] && srv_logfile=$(cut -d'|' -f6 "${srv_state}")
            if [[ ${rc} -eq 0 ]]; then
                tm_report_add "${srv_host}" "success" "${srv_duration}" "full" "" "${srv_logfile}"
                _update_proc_state "${srv_host}" "completed"
            else
                tm_report_add "${srv_host}" "failed" "${srv_duration}" "full" "exit code ${rc}" "${srv_logfile}"
                _update_proc_state "${srv_host}" "failed"
                EXIT_CODE=1
            fi
        fi
    done < "${PIDS_FILE}"
    printf '%s' "${new_entries}" > "${PIDS_FILE}"
}

# Wait until running count drops below parallel limit
_wait_for_slot() {
    while true; do
        _collect_finished
        local running
        running=$(wc -l < "${PIDS_FILE}" | tr -d ' ')
        [[ ${running} -lt ${TM_PARALLEL_JOBS} ]] && break
        sleep 5
    done
}

# Wait for all jobs to finish (with overrun detection)
_wait_all() {
    while true; do
        _collect_finished
        local running
        running=$(wc -l < "${PIDS_FILE}" | tr -d ' ')
        [[ ${running} -eq 0 ]] && break

        # Check for overrun
        local now elapsed
        now=$(date +%s)
        elapsed=$(( now - DAILY_START ))
        if [[ ${elapsed} -ge ${MAX_DAILY_SECONDS} ]]; then
            tm_log "ERROR" "Daily backup run exceeded ${MAX_DAILY_SECONDS}s ($(( elapsed / 3600 ))h). ${running} job(s) still running."
            _send_overrun_alert
            break
        fi

        sleep 5
    done
}

# Send overrun alert with per-server status
_send_overrun_alert() {
    local elapsed=$(( $(date +%s) - DAILY_START ))
    local elapsed_h=$(( elapsed / 3600 ))
    local elapsed_m=$(( (elapsed % 3600) / 60 ))

    local body="WARNING: Daily backup run has exceeded the maximum allowed time.

Elapsed:    ${elapsed_h}h ${elapsed_m}m
Max allowed: $(( MAX_DAILY_SECONDS / 3600 ))h
Date:        ${TODAY}

Per-server status:
============================================================"

    # Collect status from report + still-running PIDs
    local report_file="${TM_LOG_DIR}/report-daily-${TODAY}.log"
    if [[ -f "${report_file}" ]]; then
        body+=$'\n'"$(cat "${report_file}")"
    fi

    # Add still-running servers
    if [[ -s "${PIDS_FILE}" ]]; then
        body+=$'\n\nSTILL RUNNING:'
        while IFS= read -r entry; do
            [[ -z "${entry}" ]] && continue
            local pid="${entry%%:*}"
            local meta="${entry#*:}"
            local srv_host="${meta%%:*}"
            local srv_start="${meta#*:}"
            local srv_elapsed=$(( $(date +%s) - srv_start ))
            local srv_dur
            srv_dur=$(_tm_format_duration ${srv_elapsed})
            body+=$'\n'"  - ${srv_host} (PID ${pid}, running for ${srv_dur})"
        done < "${PIDS_FILE}"
    fi

    body+=$'\n\nAction required: Check if servers are reachable and backups are progressing.'
    body+=$'\nConsider reducing the number of servers, increasing parallelism (TM_PARALLEL_JOBS),'
    body+=$'\nor splitting servers across multiple backup schedules.'

    tm_notify "OVERRUN: Daily backups exceeded $(( MAX_DAILY_SECONDS / 3600 ))h" "${body}" "error" "backup_overrun"
    tm_log "ERROR" "Overrun alert sent"
}

# Determine backup mode from server options
_parse_mode() {
    local opts="$1"
    if echo "${opts}" | grep -q '\-\-files-only'; then echo "files-only"
    elif echo "${opts}" | grep -q '\-\-db-only'; then echo "db-only"
    else echo "full"
    fi
}

# Launch backups in priority order with parallel limit
while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    srv_host=$(echo "${line}" | awk '{print $1}')
    srv_mode=$(_parse_mode "${line}")

    # Skip servers that were just added today (user chose not to backup now)
    skip_file="${STATE_DIR}/skip-daily-${srv_host}"
    if [[ -f "${skip_file}" ]]; then
        skip_date=$(cat "${skip_file}" 2>/dev/null)
        if [[ "${skip_date}" == "${TODAY}" ]]; then
            tm_log "INFO" "Skipping ${srv_host} — added today, will be included from tomorrow"
            tm_report_add "${srv_host}" "skipped" "0s" "${srv_mode}" "newly added"
            continue
        else
            rm -f "${skip_file}"
        fi
    fi

    _wait_for_slot

    srv_start=$(date +%s)
    srv_logfile="${LOG_DIR}/backup-${srv_host}-$(date +'%Y-%m-%d_%H%M%S').log"
    _TM_BACKUP_LOGFILE="${srv_logfile}" "${SCRIPT_DIR}/timemachine.sh" ${line} --trigger daily >> "${srv_logfile}" 2>&1 &
    pid=$!
    echo "${pid}:${srv_host}:${srv_start}" >> "${PIDS_FILE}"

    # Register in state directory so the dashboard can see it
    _register_proc "${srv_host}" "${pid}" "${srv_mode}" "${srv_logfile}"

    tm_log "INFO" "Started backup for ${srv_host} (PID ${pid}, mode=${srv_mode})"
done <<< "${SORTED_JOBS}"

# Wait for all remaining jobs
_wait_all

# Cleanup
rm -f "${PIDS_FILE}"

# ============================================================
# REPORT & SUMMARY
# ============================================================

tm_report_send "daily"

if [[ ${EXIT_CODE} -eq 0 ]]; then
    tm_log "INFO" "Daily backup run completed successfully"
else
    tm_log "ERROR" "Daily backup run completed with errors"
fi

exit ${EXIT_CODE}
