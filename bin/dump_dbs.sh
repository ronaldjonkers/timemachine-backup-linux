#!/usr/bin/env bash
# ============================================================
# TimeMachine Backup - Database Dump Script (Client-Side)
# ============================================================
# This script runs ON THE REMOTE SERVER to dump databases to
# /home/timemachine/sql/. It is deployed to clients via
# install.sh (client mode) and triggered remotely by timemachine.sh.
#
# Supported databases:
#   - MySQL / MariaDB
#   - PostgreSQL
#   - MongoDB
#   - Redis
#   - SQLite
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
TM_DB_TYPES="${TM_DB_TYPES:-auto}"
TM_MYSQL_PW_FILE="${TM_MYSQL_PW_FILE:-/root/mysql.pw}"
TM_MYSQL_HOST="${TM_MYSQL_HOST:-}"
TM_PG_USER="${TM_PG_USER:-postgres}"
TM_PG_HOST="${TM_PG_HOST:-}"
TM_MONGO_HOST="${TM_MONGO_HOST:-}"
TM_MONGO_AUTH_DB="${TM_MONGO_AUTH_DB:-admin}"
TM_REDIS_HOST="${TM_REDIS_HOST:-}"
TM_REDIS_PORT="${TM_REDIS_PORT:-6379}"
TM_SQLITE_PATHS="${TM_SQLITE_PATHS:-}"
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
# SETUP
# ============================================================

FAILED=0
SQL_DIR="${TM_HOME}/sql"

# Create or clean dump directory
mkdir -p "${SQL_DIR}"
rm -rf "${SQL_DIR:?}"/*

# ============================================================
# AUTO-DETECT DATABASE ENGINES
# ============================================================

detect_db_types() {
    local detected=""

    if command -v mysql &>/dev/null || command -v mariadb &>/dev/null; then
        detected+="mysql,"
    fi
    if command -v psql &>/dev/null; then
        detected+="postgresql,"
    fi
    if command -v mongodump &>/dev/null; then
        detected+="mongodb,"
    fi
    if command -v redis-cli &>/dev/null; then
        detected+="redis,"
    fi
    if [[ -n "${TM_SQLITE_PATHS}" ]]; then
        detected+="sqlite,"
    fi

    # Remove trailing comma
    detected="${detected%,}"

    if [[ -z "${detected}" ]]; then
        log "WARN" "No supported database engines detected"
    else
        log "INFO" "Detected database engines: ${detected}"
    fi

    echo "${detected}"
}

# Resolve which DB types to dump
if [[ "${TM_DB_TYPES}" == "auto" ]]; then
    DB_TYPES=$(detect_db_types)
else
    DB_TYPES="${TM_DB_TYPES}"
fi

# ============================================================
# MYSQL / MARIADB
# ============================================================

dump_mysql() {
    log "INFO" "=== MySQL/MariaDB dumps ==="

    local mysql_cmd="mysql"
    if ! command -v mysql &>/dev/null; then
        if command -v mariadb &>/dev/null; then
            mysql_cmd="mariadb"
        else
            log "ERROR" "mysql/mariadb client not found"
            return 1
        fi
    fi

    local mysqldump_cmd="mysqldump"
    if ! command -v mysqldump &>/dev/null; then
        if command -v mariadb-dump &>/dev/null; then
            mysqldump_cmd="mariadb-dump"
        else
            log "ERROR" "mysqldump/mariadb-dump not found"
            return 1
        fi
    fi

    # Read password from file
    local dbpass
    dbpass=$(sudo cat "${TM_MYSQL_PW_FILE}" 2>/dev/null) || true
    if [[ -z "${dbpass}" ]]; then
        log "ERROR" "No MySQL password found at ${TM_MYSQL_PW_FILE}"
        log "INFO" "Create the file: echo 'yourpassword' | sudo tee ${TM_MYSQL_PW_FILE} && sudo chmod 600 ${TM_MYSQL_PW_FILE}"
        return 1
    fi

    local host_opt=""
    if [[ -n "${TM_MYSQL_HOST}" ]]; then
        host_opt="-h ${TM_MYSQL_HOST}"
    fi

    # Get list of databases
    local dblist
    dblist=$(echo 'SHOW DATABASES;' | \
        ${mysql_cmd} --defaults-extra-file=<(printf "[client]\nuser=root\npassword=%s" "${dbpass}") \
        ${host_opt} 2>/dev/null | \
        grep -Ev '^(Database|information_schema|performance_schema|sys|mysql)$') || {
            log "ERROR" "Failed to retrieve MySQL database list"
            return 1
        }

    local mysql_dir="${SQL_DIR}/mysql"
    mkdir -p "${mysql_dir}"

    local failed=0
    for db in ${dblist}; do
        local dumpfile="${mysql_dir}/${db}.sql"
        log "INFO" "  Dumping MySQL: ${db}"

        local tries=0
        local result=1
        while [[ ${tries} -lt ${TM_DB_DUMP_RETRIES} ]]; do
            if [[ ${tries} -gt 0 ]]; then
                log "WARN" "  Retry ${tries}/${TM_DB_DUMP_RETRIES} for ${db}"
            fi

            ${mysqldump_cmd} \
                --defaults-extra-file=<(printf "[client]\nuser=root\npassword=%s" "${dbpass}") \
                ${host_opt} \
                --force --opt --single-transaction \
                --disable-keys --skip-add-locks \
                --routines --triggers --events \
                "${db}" > "${dumpfile}" 2>/dev/null

            result=$?
            if [[ ${result} -eq 0 ]]; then break; fi
            tries=$((tries + 1))
        done

        if [[ ${result} -ne 0 ]]; then
            log "ERROR" "  Failed to dump MySQL database: ${db}"
            failed=1
        fi
    done

    return ${failed}
}

# ============================================================
# POSTGRESQL
# ============================================================

dump_postgresql() {
    log "INFO" "=== PostgreSQL dumps ==="

    if ! command -v pg_dump &>/dev/null; then
        log "ERROR" "pg_dump not found"
        return 1
    fi

    local pg_host_opt=""
    if [[ -n "${TM_PG_HOST}" ]]; then
        pg_host_opt="-h ${TM_PG_HOST}"
    fi

    # Get list of databases (exclude templates and postgres system db)
    local dblist
    dblist=$(sudo -u "${TM_PG_USER}" psql ${pg_host_opt} -At -c \
        "SELECT datname FROM pg_database WHERE datistemplate = false AND datname != 'postgres';" 2>/dev/null) || {
            log "ERROR" "Failed to retrieve PostgreSQL database list"
            log "INFO" "Ensure the '${TM_PG_USER}' user can connect. See: sudo -u ${TM_PG_USER} psql -c '\\l'"
            return 1
        }

    local pg_dir="${SQL_DIR}/postgresql"
    mkdir -p "${pg_dir}"

    local failed=0
    for db in ${dblist}; do
        local dumpfile="${pg_dir}/${db}.sql"
        log "INFO" "  Dumping PostgreSQL: ${db}"

        local tries=0
        local result=1
        while [[ ${tries} -lt ${TM_DB_DUMP_RETRIES} ]]; do
            if [[ ${tries} -gt 0 ]]; then
                log "WARN" "  Retry ${tries}/${TM_DB_DUMP_RETRIES} for ${db}"
            fi

            sudo -u "${TM_PG_USER}" pg_dump ${pg_host_opt} \
                --no-owner --no-acl \
                "${db}" > "${dumpfile}" 2>/dev/null

            result=$?
            if [[ ${result} -eq 0 ]]; then break; fi
            tries=$((tries + 1))
        done

        if [[ ${result} -ne 0 ]]; then
            log "ERROR" "  Failed to dump PostgreSQL database: ${db}"
            failed=1
        fi
    done

    # Also dump roles/globals
    log "INFO" "  Dumping PostgreSQL globals (roles, tablespaces)"
    sudo -u "${TM_PG_USER}" pg_dumpall ${pg_host_opt} \
        --globals-only > "${pg_dir}/_globals.sql" 2>/dev/null || {
            log "WARN" "  Failed to dump PostgreSQL globals"
        }

    return ${failed}
}

# ============================================================
# MONGODB
# ============================================================

dump_mongodb() {
    log "INFO" "=== MongoDB dumps ==="

    if ! command -v mongodump &>/dev/null; then
        log "ERROR" "mongodump not found"
        return 1
    fi

    local mongo_dir="${SQL_DIR}/mongodb"
    mkdir -p "${mongo_dir}"

    local mongo_opts=""
    if [[ -n "${TM_MONGO_HOST}" ]]; then
        mongo_opts+=" --host ${TM_MONGO_HOST}"
    fi

    # Check for credentials file
    local mongo_cred_file="${TM_HOME}/.mongo_credentials"
    if [[ -f "${mongo_cred_file}" ]]; then
        # File format: username:password
        local mongo_user mongo_pass
        mongo_user=$(cut -d: -f1 "${mongo_cred_file}")
        mongo_pass=$(cut -d: -f2- "${mongo_cred_file}")
        if [[ -n "${mongo_user}" && -n "${mongo_pass}" ]]; then
            mongo_opts+=" --username ${mongo_user} --password ${mongo_pass} --authenticationDatabase ${TM_MONGO_AUTH_DB}"
        fi
    fi

    log "INFO" "  Running mongodump (all databases)"

    local tries=0
    local result=1
    while [[ ${tries} -lt ${TM_DB_DUMP_RETRIES} ]]; do
        if [[ ${tries} -gt 0 ]]; then
            log "WARN" "  Retry ${tries}/${TM_DB_DUMP_RETRIES}"
        fi

        mongodump ${mongo_opts} \
            --out "${mongo_dir}" \
            --quiet 2>/dev/null

        result=$?
        if [[ ${result} -eq 0 ]]; then break; fi
        tries=$((tries + 1))
    done

    if [[ ${result} -ne 0 ]]; then
        log "ERROR" "  mongodump failed"
        return 1
    fi

    log "INFO" "  MongoDB dump complete"
    return 0
}

# ============================================================
# REDIS
# ============================================================

dump_redis() {
    log "INFO" "=== Redis dumps ==="

    if ! command -v redis-cli &>/dev/null; then
        log "ERROR" "redis-cli not found"
        return 1
    fi

    local redis_dir="${SQL_DIR}/redis"
    mkdir -p "${redis_dir}"

    local redis_opts=""
    if [[ -n "${TM_REDIS_HOST}" ]]; then
        redis_opts+="-h ${TM_REDIS_HOST} "
    fi
    redis_opts+="-p ${TM_REDIS_PORT}"

    # Check for password file
    local redis_pw_file="${TM_HOME}/.redis_password"
    if [[ -f "${redis_pw_file}" ]]; then
        local redis_pass
        redis_pass=$(cat "${redis_pw_file}" 2>/dev/null)
        if [[ -n "${redis_pass}" ]]; then
            redis_opts+=" -a ${redis_pass}"
        fi
    fi

    # Trigger BGSAVE and wait
    log "INFO" "  Triggering Redis BGSAVE"
    redis-cli ${redis_opts} BGSAVE &>/dev/null || {
        log "ERROR" "  Failed to trigger Redis BGSAVE"
        return 1
    }

    # Wait for BGSAVE to complete (max 60 seconds)
    local wait=0
    while [[ ${wait} -lt 60 ]]; do
        local status
        status=$(redis-cli ${redis_opts} LASTSAVE 2>/dev/null)
        sleep 2
        local new_status
        new_status=$(redis-cli ${redis_opts} LASTSAVE 2>/dev/null)
        if [[ "${new_status}" != "${status}" || ${wait} -gt 5 ]]; then
            break
        fi
        wait=$((wait + 2))
    done

    # Find and copy the RDB file
    local rdb_dir
    rdb_dir=$(redis-cli ${redis_opts} CONFIG GET dir 2>/dev/null | tail -1)
    local rdb_file
    rdb_file=$(redis-cli ${redis_opts} CONFIG GET dbfilename 2>/dev/null | tail -1)

    if [[ -n "${rdb_dir}" && -n "${rdb_file}" && -f "${rdb_dir}/${rdb_file}" ]]; then
        cp "${rdb_dir}/${rdb_file}" "${redis_dir}/dump.rdb"
        log "INFO" "  Redis RDB snapshot saved"
    else
        log "WARN" "  Could not locate Redis RDB file"
        return 1
    fi

    return 0
}

# ============================================================
# SQLITE
# ============================================================

dump_sqlite() {
    log "INFO" "=== SQLite dumps ==="

    if ! command -v sqlite3 &>/dev/null; then
        log "ERROR" "sqlite3 not found"
        return 1
    fi

    if [[ -z "${TM_SQLITE_PATHS}" ]]; then
        log "WARN" "  No SQLite paths configured (TM_SQLITE_PATHS is empty)"
        return 0
    fi

    local sqlite_dir="${SQL_DIR}/sqlite"
    mkdir -p "${sqlite_dir}"

    local failed=0
    local IFS=','
    for db_path in ${TM_SQLITE_PATHS}; do
        db_path=$(echo "${db_path}" | sed 's/^ *//;s/ *$//')
        if [[ ! -f "${db_path}" ]]; then
            log "WARN" "  SQLite file not found: ${db_path}"
            continue
        fi

        local db_name
        db_name=$(basename "${db_path}")
        local dumpfile="${sqlite_dir}/${db_name}.sql"

        log "INFO" "  Dumping SQLite: ${db_path}"

        sqlite3 "${db_path}" ".backup '${sqlite_dir}/${db_name}'" 2>/dev/null
        if [[ $? -ne 0 ]]; then
            # Fallback to SQL dump
            sqlite3 "${db_path}" ".dump" > "${dumpfile}" 2>/dev/null
            if [[ $? -ne 0 ]]; then
                log "ERROR" "  Failed to dump SQLite: ${db_path}"
                failed=1
            fi
        fi
    done

    return ${failed}
}

# ============================================================
# MAIN
# ============================================================

log "INFO" "Database types to dump: ${DB_TYPES:-none}"

IFS=',' read -ra DB_TYPE_ARRAY <<< "${DB_TYPES}"
for db_type in "${DB_TYPE_ARRAY[@]}"; do
    db_type=$(echo "${db_type}" | sed 's/^ *//;s/ *$//')
    case "${db_type}" in
        mysql|mariadb)
            dump_mysql || FAILED=1
            ;;
        postgresql|postgres|pg)
            dump_postgresql || FAILED=1
            ;;
        mongodb|mongo)
            dump_mongodb || FAILED=1
            ;;
        redis)
            dump_redis || FAILED=1
            ;;
        sqlite)
            dump_sqlite || FAILED=1
            ;;
        "")
            ;;
        *)
            log "WARN" "Unknown database type: ${db_type}"
            ;;
    esac
done

# Summary
if [[ ${FAILED} -eq 1 ]]; then
    log "WARN" "One or more database dumps failed"
else
    log "INFO" "All database dumps completed successfully"
fi

rm -f "${PIDFILE}"
exit ${FAILED}
