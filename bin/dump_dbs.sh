#!/usr/bin/env bash
# ============================================================
# TimeMachine Backup - Database Dump Script (Client-Side)
# ============================================================
# This script runs ON THE REMOTE SERVER to dump all MySQL/MariaDB
# databases to /home/timemachine/sql/. It is deployed to clients
# via install-client.sh and triggered remotely by timemachine.sh.
#
# Can also run as a cronjob on the remote server:
#   0 1 * * * timemachine /home/timemachine/dump_dbs.sh --db-cronjob
# ============================================================

# Self-restart in temp file (allows editing while running)
if [[ ! "$(dirname "$0")" =~ /.sh-tmp$ ]]; then
    mkdir -p "$(dirname "$0")/.sh-tmp/"
    DIST="$(dirname "$0")/.sh-tmp/$(basename "$0").$$"
    install -m 700 "$0" "${DIST}"
    exec "${DIST}" "$@"
    exit
else
    cleanup() { rm -f "$0"; }
    trap cleanup EXIT
fi

# ============================================================
# CONFIGURATION (standalone defaults for client-side execution)
# ============================================================

TM_USER="${TM_USER:-timemachine}"
TM_HOME="${TM_HOME:-/home/timemachine}"
TM_MYSQL_PW_FILE="${TM_MYSQL_PW_FILE:-/root/mysql.pw}"
TM_MYSQL_HOST="${TM_MYSQL_HOST:-}"
TM_DB_DUMP_RETRIES="${TM_DB_DUMP_RETRIES:-3}"
TM_RUN_DIR="${TM_RUN_DIR:-/var/run/timemachine}"

# Minimal logging function (standalone; no lib dependency on client)
log() {
    printf "[%s] [%-5s] %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$1" "$2"
}

# ============================================================
# ARGUMENT PARSING
# ============================================================

DB_CRONJOB=0
if [[ "${1:-}" == "--db-cronjob" ]]; then
    DB_CRONJOB=1
fi

# ============================================================
# LOCK MANAGEMENT
# ============================================================

PIDFILE="${TM_RUN_DIR}/dump_dbs.pid"
mkdir -p "${TM_RUN_DIR}"

if [[ ${DB_CRONJOB} -eq 1 ]]; then
    if [[ -f "${PIDFILE}" ]]; then
        OLD_PID=$(cat "${PIDFILE}")
        if kill -0 "${OLD_PID}" 2>/dev/null; then
            log "ERROR" "Already running (PID ${OLD_PID})"
            exit 1
        else
            rm -f "${PIDFILE}"
        fi
    fi
    echo $$ > "${PIDFILE}"
fi

# Redirect output to log file when running as cronjob
if [[ ${DB_CRONJOB} -eq 1 ]]; then
    TODAY="$(date +'%Y-%m-%d')"
    LOGFILE="${TM_HOME}/dump_dbs-${TODAY}.log"
    touch "${LOGFILE}"
    exec 1>>"${LOGFILE}"
    exec 2>&1
    log "INFO" "Starting database dumps (cronjob mode)"
fi

# ============================================================
# MAIN
# ============================================================

FAILED=0
SQL_DIR="${TM_HOME}/sql"

# Create or clean dump directory
mkdir -p "${SQL_DIR}"
rm -rf "${SQL_DIR:?}"/*

# Read database root password
DBPASS=$(sudo cat "${TM_MYSQL_PW_FILE}" 2>/dev/null) || true
if [[ -z "${DBPASS}" ]]; then
    log "ERROR" "No database root password found at ${TM_MYSQL_PW_FILE}"
    rm -f "${PIDFILE}"
    exit 1
fi

# Build MySQL host option
HOST_OPT=""
if [[ -n "${TM_MYSQL_HOST}" ]]; then
    HOST_OPT="-h ${TM_MYSQL_HOST}"
fi

# Get list of databases
DBLIST=$(echo 'SHOW DATABASES;' | \
    mysql --defaults-extra-file=<(printf "[client]\nuser=root\npassword=%s" "${DBPASS}") \
    ${HOST_OPT} 2>/dev/null | \
    grep -Ev '^(Database|information_schema|performance_schema|sys)$') || {
        log "ERROR" "Failed to retrieve database list"
        rm -f "${PIDFILE}"
        exit 1
    }

# Dump each database
for DB in ${DBLIST}; do
    DUMPFILE="${SQL_DIR}/${DB}.sql"
    log "INFO" "Dumping database: ${DB}"

    NR_TRIES=0
    RESULT=1
    while [[ ${NR_TRIES} -lt ${TM_DB_DUMP_RETRIES} ]]; do
        if [[ ${NR_TRIES} -gt 0 ]]; then
            log "WARN" "Dump failed for ${DB}; retrying (${NR_TRIES}/${TM_DB_DUMP_RETRIES})..."
        fi

        mysqldump \
            --defaults-extra-file=<(printf "[client]\nuser=root\npassword=%s" "${DBPASS}") \
            ${HOST_OPT} \
            --force --opt --single-transaction \
            --disable-keys --skip-add-locks \
            --ignore-table=mysql.event \
            --routines "${DB}" > "${DUMPFILE}" 2>/dev/null

        RESULT=$?
        if [[ ${RESULT} -eq 0 ]]; then break; fi
        NR_TRIES=$((NR_TRIES + 1))
    done

    if [[ ${RESULT} -ne 0 ]]; then
        log "ERROR" "Failed to dump database: ${DB}"
        FAILED=1
    fi
done

# Summary
if [[ ${FAILED} -eq 1 ]]; then
    log "WARN" "One or more database dumps failed"
else
    log "INFO" "All database dumps completed successfully"
fi

rm -f "${PIDFILE}"
exit ${FAILED}
