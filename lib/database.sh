#!/usr/bin/env bash
# ============================================================
# TimeMachine Backup - Database Dump Functions
# ============================================================
# Functions for dumping MySQL/MariaDB databases on remote hosts.
# These run ON the remote server (deployed via install-client.sh).
# ============================================================

# Dump all databases on the local machine
# This function is designed to run on the CLIENT (remote server).
tm_dump_databases() {
    local sql_dir="${TM_HOME:-/home/timemachine}/sql"
    local pw_file="${TM_MYSQL_PW_FILE:-/root/mysql.pw}"
    local mysql_host="${TM_MYSQL_HOST:-}"
    local max_retries="${TM_DB_DUMP_RETRIES:-3}"
    local failed=0

    # Create or clean SQL dump directory
    mkdir -p "${sql_dir}"
    rm -rf "${sql_dir:?}"/*

    # Read database root password
    local dbpass
    dbpass=$(sudo cat "${pw_file}" 2>/dev/null) || true
    if [[ -z "${dbpass}" ]]; then
        tm_log "ERROR" "No database root password found at ${pw_file}"
        return 1
    fi

    # Build MySQL host option
    local host_opt=""
    if [[ -n "${mysql_host}" ]]; then
        host_opt="-h ${mysql_host}"
    fi

    # Get list of databases (excluding system databases)
    local dblist
    dblist=$(echo 'SHOW DATABASES;' | \
        mysql --defaults-extra-file=<(printf "[client]\nuser=root\npassword=%s" "${dbpass}") \
        ${host_opt} 2>/dev/null | \
        grep -Ev '^(Database|information_schema|performance_schema|sys)$') || {
            tm_log "ERROR" "Failed to retrieve database list"
            return 1
        }

    # Dump each database
    for db in ${dblist}; do
        local dumpfile="${sql_dir}/${db}.sql"
        tm_log "INFO" "Dumping database: ${db}"

        local tries=0
        local result=1
        while [[ ${tries} -lt ${max_retries} ]]; do
            if [[ ${tries} -gt 0 ]]; then
                tm_log "WARN" "Dump failed for ${db}; retrying (${tries}/${max_retries})..."
            fi

            mysqldump \
                --defaults-extra-file=<(printf "[client]\nuser=root\npassword=%s" "${dbpass}") \
                ${host_opt} \
                --force --opt --single-transaction \
                --disable-keys --skip-add-locks \
                --ignore-table=mysql.event \
                --routines "${db}" > "${dumpfile}" 2>/dev/null

            result=$?
            if [[ ${result} -eq 0 ]]; then
                break
            fi
            tries=$((tries + 1))
        done

        if [[ ${result} -ne 0 ]]; then
            tm_log "ERROR" "Failed to dump database: ${db} after ${max_retries} attempts"
            failed=1
        fi
    done

    if [[ ${failed} -eq 1 ]]; then
        tm_log "WARN" "One or more database dumps failed"
    else
        tm_log "INFO" "All database dumps completed successfully"
    fi

    return ${failed}
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
