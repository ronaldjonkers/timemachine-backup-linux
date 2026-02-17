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
    local script_dir="${TM_INSTALL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
    local dump_script="${script_dir}/bin/dump_dbs.sh"

    tm_log "INFO" "Triggering remote database dump on ${hostname}"

    if [[ ! -f "${dump_script}" ]]; then
        tm_log "ERROR" "dump_dbs.sh not found at ${dump_script}"
        return 1
    fi

    # Pipe the dump script via SSH stdin so the server always controls
    # what runs on the client. This avoids version mismatch and
    # self-restart permission issues on the client side.
    # Extract the script body (skip the self-restart block, lines 1-31)
    # and prepend the env vars so they override defaults.
    {
        echo "#!/usr/bin/env bash"
        echo "# Piped from server — no self-restart needed"
        echo "export TM_DB_TYPES='${TM_DB_TYPES}'"
        echo "export TM_MYSQL_PW_FILE='${TM_MYSQL_PW_FILE}'"
        echo "export TM_MYSQL_HOST='${TM_MYSQL_HOST}'"
        echo "export TM_PG_USER='${TM_PG_USER}'"
        echo "export TM_PG_HOST='${TM_PG_HOST}'"
        echo "export TM_MONGO_HOST='${TM_MONGO_HOST}'"
        echo "export TM_MONGO_AUTH_DB='${TM_MONGO_AUTH_DB}'"
        echo "export TM_REDIS_HOST='${TM_REDIS_HOST}'"
        echo "export TM_REDIS_PORT='${TM_REDIS_PORT}'"
        echo "export TM_SQLITE_PATHS='${TM_SQLITE_PATHS}'"
        echo "export TM_DB_DUMP_RETRIES='${TM_DB_DUMP_RETRIES}'"
        # Output the script body after the self-restart block (from "# CONFIGURATION" onward)
        sed -n '/^# CONFIGURATION/,$p' "${dump_script}"
    } | ssh -p "${TM_SSH_PORT}" -i "${TM_SSH_KEY}" \
        -o ConnectTimeout="${TM_SSH_TIMEOUT}" \
        -o StrictHostKeyChecking=no \
        "${remote_user}@${hostname}" \
        "bash -s" 2>&1

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
