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
TODAY=$(tm_date_today)
LOGFILE="${LOG_DIR}/daily-${TODAY}.log"

tm_ensure_dir "${LOG_DIR}"

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
            if [[ ${rc} -eq 0 ]]; then
                tm_report_add "${srv_host}" "success" "${srv_duration}" "full"
            else
                tm_report_add "${srv_host}" "failed" "${srv_duration}" "full" "exit code ${rc}"
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

# Wait for all jobs to finish
_wait_all() {
    while true; do
        _collect_finished
        local running
        running=$(wc -l < "${PIDS_FILE}" | tr -d ' ')
        [[ ${running} -eq 0 ]] && break
        sleep 5
    done
}

# Launch backups in priority order with parallel limit
while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    srv_host=$(echo "${line}" | awk '{print $1}')

    _wait_for_slot

    srv_start=$(date +%s)
    "${SCRIPT_DIR}/timemachine.sh" ${line} >> "${LOGFILE}" 2>&1 &
    pid=$!
    echo "${pid}:${srv_host}:${srv_start}" >> "${PIDS_FILE}"
    tm_log "INFO" "Started backup for ${srv_host} (PID ${pid})"
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
