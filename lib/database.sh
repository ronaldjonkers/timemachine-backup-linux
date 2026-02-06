#!/usr/bin/env bash
# ============================================================
# TimeMachine Backup - Database Functions (Server-Side)
# ============================================================
# Functions for triggering and syncing database dumps from
# remote hosts. The actual dump logic lives in bin/dump_dbs.sh
# which runs on the client.
#
# Supported databases:
#   - MySQL / MariaDB
#   - PostgreSQL
#   - MongoDB
#   - Redis
#   - SQLite
# ============================================================

# Trigger remote database dump via SSH
# The dump_dbs.sh script on the client auto-detects installed
# database engines and dumps all databases.
tm_trigger_remote_dump() {
    local hostname="$1"
    local remote_user="${TM_USER}"

    tm_log "INFO" "Triggering remote database dump on ${hostname}"

    # Pass database config to the remote script via environment
    local env_vars=""
    env_vars+="TM_DB_TYPES='${TM_DB_TYPES}' "
    env_vars+="TM_MYSQL_PW_FILE='${TM_MYSQL_PW_FILE}' "
    env_vars+="TM_MYSQL_HOST='${TM_MYSQL_HOST}' "
    env_vars+="TM_PG_USER='${TM_PG_USER}' "
    env_vars+="TM_PG_HOST='${TM_PG_HOST}' "
    env_vars+="TM_MONGO_HOST='${TM_MONGO_HOST}' "
    env_vars+="TM_MONGO_AUTH_DB='${TM_MONGO_AUTH_DB}' "
    env_vars+="TM_REDIS_HOST='${TM_REDIS_HOST}' "
    env_vars+="TM_REDIS_PORT='${TM_REDIS_PORT}' "
    env_vars+="TM_SQLITE_PATHS='${TM_SQLITE_PATHS}' "
    env_vars+="TM_DB_DUMP_RETRIES='${TM_DB_DUMP_RETRIES}' "

    ssh -p "${TM_SSH_PORT}" -i "${TM_SSH_KEY}" \
        -o ConnectTimeout="${TM_SSH_TIMEOUT}" \
        -o StrictHostKeyChecking=no \
        "${remote_user}@${hostname}" \
        "${env_vars} bash /home/${remote_user}/dump_dbs.sh" 2>&1

    return $?
}

# Wait for a remote database dump (triggered by cron) to complete
tm_wait_for_db_dump() {
    local today
    today=$(date +'%Y-%m-%d')
    local logfile="${TM_HOME:-/home/timemachine}/dump_dbs-${today}.log"
    local pidfile="${TM_RUN_DIR:-/var/run/timemachine}/dump_dbs.pid"

    tm_log "INFO" "Waiting for database dump to start..."

    # Wait for log file to appear (dump has started)
    local wait_count=0
    while [[ ! -f "${logfile}" ]]; do
        sleep 10
        wait_count=$((wait_count + 1))
        if [[ ${wait_count} -ge 360 ]]; then
            tm_log "ERROR" "Timeout waiting for database dump to start (1 hour)"
            return 1
        fi
    done

    tm_log "INFO" "Database dump started; waiting for completion..."

    # Wait for PID file to disappear (dump has finished)
    if [[ -f "${pidfile}" ]]; then
        local pid
        pid=$(cat "${pidfile}")
        while kill -0 "${pid}" 2>/dev/null; do
            sleep 10
        done
    fi

    # Output the dump log
    if [[ -f "${logfile}" ]]; then
        cat "${logfile}"
        rm -f "${logfile}"
    fi

    tm_log "INFO" "Database dump completed"
    return 0
}
