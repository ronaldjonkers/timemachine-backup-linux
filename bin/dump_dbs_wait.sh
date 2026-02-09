#!/usr/bin/env bash
# ============================================================
# TimeMachine Backup - Wait for Database Dump (Client-Side)
# ============================================================
# Waits for a cron-triggered dump_dbs.sh to complete, then
# outputs its log. Used when the backup server needs to wait
# for a client-side cronjob to finish before syncing SQL dumps.
# ============================================================

# Self-restart in temp file
_TM_TMP="${TMPDIR:-/tmp}/tm-self-restart-$(id -u)"
if [[ ! "$0" =~ tm-self-restart ]]; then
    mkdir -p "${_TM_TMP}"
    DIST="${_TM_TMP}/$(basename "$0").$$"
    install -m 700 "$0" "${DIST}"
    exec "${DIST}" "$@"
    exit
else
    cleanup() { rm -f "$0"; }
    trap cleanup EXIT
fi

# ============================================================
# CONFIGURATION
# ============================================================

TM_HOME="${TM_HOME:-/home/timemachine}"
TM_RUN_DIR="${TM_RUN_DIR:-/var/run/timemachine}"

log() {
    printf "[%s] [%-5s] %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$1" "$2"
}

# ============================================================
# WAIT FOR DUMP TO START
# ============================================================

TODAY="$(date +'%Y-%m-%d')"
LOGFILE="${TM_HOME}/dump_dbs-${TODAY}.log"
PIDFILE="${TM_RUN_DIR}/dump_dbs.pid"

log "INFO" "Waiting for database dump to start..."

WAIT_COUNT=0
MAX_WAIT=360  # 1 hour (360 * 10s)

while [[ ! -f "${LOGFILE}" ]]; do
    sleep 10
    WAIT_COUNT=$((WAIT_COUNT + 1))
    if [[ ${WAIT_COUNT} -ge ${MAX_WAIT} ]]; then
        log "ERROR" "Timeout waiting for database dump to start"
        exit 1
    fi
done

# ============================================================
# WAIT FOR DUMP TO COMPLETE
# ============================================================

log "INFO" "Database dump started; waiting for completion..."

if [[ -f "${PIDFILE}" ]]; then
    PID=$(cat "${PIDFILE}")
    while kill -0 "${PID}" 2>/dev/null; do
        sleep 10
    done
fi

# ============================================================
# OUTPUT LOG AND CLEANUP
# ============================================================

if [[ -f "${LOGFILE}" ]]; then
    cat "${LOGFILE}"
    rm -f "${LOGFILE}"
fi

log "INFO" "Database dump completed"
exit 0
