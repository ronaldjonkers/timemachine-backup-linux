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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

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
# EXECUTE BACKUPS IN PARALLEL (sorted by priority)
# ============================================================

tm_log "INFO" "Starting daily backups (parallel=${TM_PARALLEL_JOBS})"

# Parse --priority N from each line (default 10), sort ascending
# Each non-comment, non-empty line is: <hostname> [options]
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

echo "${SORTED_JOBS}" | \
    xargs -I{} -P "${TM_PARALLEL_JOBS}" bash -c \
        "\"${SCRIPT_DIR}/timemachine.sh\" {} >> \"${LOGFILE}\" 2>&1"

EXIT_CODE=$?

# ============================================================
# SUMMARY
# ============================================================

if [[ ${EXIT_CODE} -eq 0 ]]; then
    tm_log "INFO" "Daily backup run completed successfully"
else
    tm_log "ERROR" "Daily backup run completed with errors (exit code ${EXIT_CODE})"
    tm_notify "Daily backup errors" \
        "The daily backup run on $(hostname) completed with errors. Check ${LOGFILE} for details."
fi

exit ${EXIT_CODE}
