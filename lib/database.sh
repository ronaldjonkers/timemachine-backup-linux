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

# Common SSH options used by all remote commands
_tm_ssh_opts() {
    echo "-p ${TM_SSH_PORT} -i ${TM_SSH_KEY} -o ConnectTimeout=${TM_SSH_TIMEOUT} -o StrictHostKeyChecking=no"
}

# Trigger remote database dump via SSH.
# Pipes dump_dbs.sh to the remote server via SSH stdin and runs it.
# No SCP or remote filesystem write needed — the server controls
# exactly what runs on the client.
#
# Usage: tm_trigger_remote_dump <hostname>
# Sets:  _TM_DB_OUTPUT  — captured remote script output (for email)
# Returns: 0 on success, non-zero on failure
#
# IMPORTANT: This function uses set +e internally so that SSH
# failures are caught and reported instead of killing the caller
# via set -e (which would skip error handling and email notification).
tm_trigger_remote_dump() {
    local hostname="$1"
    local remote_user="${TM_USER}"
    local script_dir="${TM_INSTALL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
    local dump_script="${script_dir}/bin/dump_dbs.sh"
    local ssh_opts
    ssh_opts=$(_tm_ssh_opts)

    # Disable set -e so failures are caught and reported, not fatal.
    set +e

    tm_log "INFO" "Triggering remote database dump on ${hostname}"

    if [[ ! -f "${dump_script}" ]]; then
        tm_log "ERROR" "dump_dbs.sh not found at ${dump_script}"
        _TM_DB_OUTPUT="dump_dbs.sh not found at ${dump_script}"
        set -e
        return 1
    fi

    # Build the script to pipe: env var overrides + script body (skip self-restart block).
    # The self-restart block (lines 1-31) uses exec which doesn't work via stdin,
    # so we extract from "# CONFIGURATION" onward and prepend our env vars.
    tm_log "INFO" "Piping dump_dbs.sh to ${hostname} via SSH (TM_DB_TYPES=${TM_DB_TYPES})"
    local ssh_output ssh_rc
    ssh_output=$({
        echo "#!/usr/bin/env bash"
        echo "# Piped from backup server — no self-restart needed"
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
        echo "export TM_DB_COMPRESS='${TM_DB_COMPRESS:-true}'"
        sed -n '/^# CONFIGURATION/,$p' "${dump_script}"
    } | eval ssh ${ssh_opts} "${remote_user}@${hostname}" "bash -s" 2>&1)
    ssh_rc=$?

    # Store remote output for email/logging by the caller
    _TM_DB_OUTPUT="${ssh_output}"

    if [[ ${ssh_rc} -eq 0 ]]; then
        tm_log "INFO" "dump_dbs.sh completed successfully on ${hostname}"
    else
        tm_log "ERROR" "dump_dbs.sh failed on ${hostname} (exit code ${ssh_rc})"
    fi

    # Log remote output line by line for the backup log
    if [[ -n "${ssh_output}" ]]; then
        while IFS= read -r _line; do
            [[ -n "${_line}" ]] && tm_log "INFO" "  [remote] ${_line}"
        done <<< "${ssh_output}"
    fi

    set -e
    return ${ssh_rc}
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
