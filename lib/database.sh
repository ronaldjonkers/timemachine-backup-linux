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

# Trigger remote database dump via SSH
# Deploys the latest dump_dbs.sh to the remote server, then runs it.
# This ensures the remote always has the latest version of the script
# and performs a fresh database dump before rsync pulls the files back.
tm_trigger_remote_dump() {
    local hostname="$1"
    local remote_user="${TM_USER}"
    local script_dir="${TM_INSTALL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
    local dump_script="${script_dir}/bin/dump_dbs.sh"
    local remote_home="/home/${remote_user}"
    local ssh_opts
    ssh_opts=$(_tm_ssh_opts)

    tm_log "INFO" "Triggering remote database dump on ${hostname}"

    if [[ ! -f "${dump_script}" ]]; then
        tm_log "ERROR" "dump_dbs.sh not found at ${dump_script}"
        return 1
    fi

    # Step 1: Deploy latest dump_dbs.sh to the remote server via SCP.
    # This ensures the remote always runs the current version, avoiding
    # version mismatch issues between server and client.
    tm_log "INFO" "Step 1/2: Deploying dump_dbs.sh to ${hostname}:${remote_home}/"
    local scp_output
    scp_output=$(eval scp ${ssh_opts} \
        "${dump_script}" \
        "${remote_user}@${hostname}:${remote_home}/dump_dbs.sh" 2>&1) || {
            local rc=$?
            tm_log "ERROR" "Failed to deploy dump_dbs.sh to ${hostname} (exit code ${rc})"
            [[ -n "${scp_output}" ]] && tm_log "ERROR" "SCP output: ${scp_output}"
            return ${rc}
        }
    tm_log "INFO" "Step 1/2: dump_dbs.sh deployed successfully to ${hostname}"

    # Step 2: Run dump_dbs.sh on the remote server via SSH.
    # Pass DB configuration as environment variables so the remote script
    # uses the server's settings (not whatever the client has locally).
    tm_log "INFO" "Step 2/2: Running dump_dbs.sh on ${hostname} (TM_DB_TYPES=${TM_DB_TYPES})"
    local ssh_output
    ssh_output=$(eval ssh ${ssh_opts} \
        "${remote_user}@${hostname}" \
        "TM_DB_TYPES='${TM_DB_TYPES}' \
         TM_MYSQL_PW_FILE='${TM_MYSQL_PW_FILE}' \
         TM_MYSQL_HOST='${TM_MYSQL_HOST}' \
         TM_PG_USER='${TM_PG_USER}' \
         TM_PG_HOST='${TM_PG_HOST}' \
         TM_MONGO_HOST='${TM_MONGO_HOST}' \
         TM_MONGO_AUTH_DB='${TM_MONGO_AUTH_DB}' \
         TM_REDIS_HOST='${TM_REDIS_HOST}' \
         TM_REDIS_PORT='${TM_REDIS_PORT}' \
         TM_SQLITE_PATHS='${TM_SQLITE_PATHS}' \
         TM_DB_DUMP_RETRIES='${TM_DB_DUMP_RETRIES}' \
         bash ${remote_home}/dump_dbs.sh" 2>&1)
    local ssh_rc=$?

    # Always output the remote script's output for the caller to log
    [[ -n "${ssh_output}" ]] && echo "${ssh_output}"

    if [[ ${ssh_rc} -eq 0 ]]; then
        tm_log "INFO" "Step 2/2: dump_dbs.sh completed successfully on ${hostname}"
    else
        tm_log "ERROR" "Step 2/2: dump_dbs.sh failed on ${hostname} (exit code ${ssh_rc})"
    fi

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
