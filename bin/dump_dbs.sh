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
# CONFIGURATION (standalone defaults for client-side execution)
# ============================================================

TM_USER="${TM_USER:-timemachine}"
TM_HOME="${TM_HOME:-/home/timemachine}"
TM_DB_TYPES="${TM_DB_TYPES:-auto}"
TM_CREDENTIALS_DIR="${TM_CREDENTIALS_DIR:-${TM_HOME}/.credentials}"
TM_MYSQL_PW_FILE="${TM_MYSQL_PW_FILE:-${TM_CREDENTIALS_DIR}/mysql.pw}"
TM_MYSQL_CNF_FILE="${TM_MYSQL_CNF_FILE:-${TM_CREDENTIALS_DIR}/mysql.cnf}"
TM_MYSQL_HOST="${TM_MYSQL_HOST:-}"
TM_MYSQL_USER="${TM_MYSQL_USER:-root}"
TM_MYSQL_ALLOW_SUDO_SOCKET="${TM_MYSQL_ALLOW_SUDO_SOCKET:-true}"
TM_MYSQL_DEBUG="${TM_MYSQL_DEBUG:-false}"
TM_MYSQL_EXCLUDE_DATABASES="${TM_MYSQL_EXCLUDE_DATABASES:-information_schema,performance_schema,sys,mysql}"
TM_PG_USER="${TM_PG_USER:-postgres}"
TM_PG_HOST="${TM_PG_HOST:-}"
TM_MONGO_HOST="${TM_MONGO_HOST:-}"
TM_MONGO_AUTH_DB="${TM_MONGO_AUTH_DB:-admin}"
TM_REDIS_HOST="${TM_REDIS_HOST:-}"
TM_REDIS_PORT="${TM_REDIS_PORT:-6379}"
TM_SQLITE_PATHS="${TM_SQLITE_PATHS:-}"
TM_DB_DUMP_RETRIES="${TM_DB_DUMP_RETRIES:-3}"
TM_DB_COMPRESS="${TM_DB_COMPRESS:-true}"
TM_RUN_DIR="${TM_RUN_DIR:-/var/run/timemachine}"

# Minimal logging function (standalone; no lib dependency on client)
log() {
    printf "[%s] [%-5s] %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$1" "$2" >&2
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

if [[ ${DB_CRONJOB} -eq 1 ]]; then
    mkdir -p "${TM_RUN_DIR}"
    PIDFILE="${TM_RUN_DIR}/dump_dbs.pid"
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

# Clean up stale .sql files from old script versions that dumped to TM_HOME directly
if ls "${TM_HOME}"/*.sql 2>/dev/null | head -1 &>/dev/null; then
    log "INFO" "Cleaning stale .sql files from ${TM_HOME}/"
    rm -f "${TM_HOME}"/*.sql
fi

# Create or clean dump directory (removes old root-level dumps + subdirs)
mkdir -p "${SQL_DIR}"
if [[ -d "${SQL_DIR}" ]] && ls "${SQL_DIR}"/ 2>/dev/null | head -1 &>/dev/null; then
    log "INFO" "Cleaning previous dumps from ${SQL_DIR}/"
fi
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

    # ---- Detect client commands (prefer MariaDB on modern systems) ----
    local mysql_cmd="" mysqldump_cmd=""
    if command -v mariadb &>/dev/null; then
        mysql_cmd="mariadb"
    elif command -v mysql &>/dev/null; then
        mysql_cmd="mysql"
    else
        log "ERROR" "mysql/mariadb client not found"
        return 1
    fi
    if command -v mariadb-dump &>/dev/null; then
        mysqldump_cmd="mariadb-dump"
    elif command -v mysqldump &>/dev/null; then
        mysqldump_cmd="mysqldump"
    else
        log "ERROR" "mysqldump/mariadb-dump client not found"
        return 1
    fi
    log "INFO" "Using ${mysql_cmd} / ${mysqldump_cmd}"

    # ---- Host args as safe array ----
    local -a host_args=()
    if [[ -n "${TM_MYSQL_HOST}" ]]; then
        host_args=(-h "${TM_MYSQL_HOST}")
    fi

    # ---- Auth state (populated by the successful login method) ----
    local auth_kind=""   # "cnf" or "sudo"
    local auth_cnf=""    # path to defaults-extra-file when auth_kind=cnf
    local auth_desc=""   # human-readable label for logs (no secrets)
    local raw_dblist=""
    local tmp_cnf=""     # tracked for explicit cleanup at function exit
    local rc=0

    # ---- Helper: write a temporary [client] section file (chmod 600) ----
    _mysql_write_cnf() {
        local out="$1" user="$2" password="$3"
        ( umask 077; : > "${out}" ) || return 1
        chmod 600 "${out}" 2>/dev/null || true
        printf '[client]\nuser=%s\npassword=%s\n' "${user}" "${password}" > "${out}"
    }

    # ---- Helper: run SHOW DATABASES with a given auth kind ----
    # Args: $1=kind ("cnf"|"sudo"), $2=cnf path (when kind=cnf), $3=desc for logs
    # Sets raw_dblist/auth_kind/auth_cnf/auth_desc on success; logs stderr on fail.
    _mysql_try_login() {
        local kind="$1" cnf="$2" desc="$3"
        local tmp_out tmp_err err rc_local
        tmp_out=$(mktemp 2>/dev/null) || return 1
        tmp_err=$(mktemp 2>/dev/null) || { rm -f "${tmp_out}"; return 1; }
        if [[ "${kind}" == "cnf" ]]; then
            "${mysql_cmd}" --defaults-extra-file="${cnf}" "${host_args[@]}" \
                -N -B -e "SHOW DATABASES;" >"${tmp_out}" 2>"${tmp_err}"
            rc_local=$?
        else
            sudo -n "${mysql_cmd}" "${host_args[@]}" \
                -N -B -e "SHOW DATABASES;" >"${tmp_out}" 2>"${tmp_err}"
            rc_local=$?
        fi
        err=$(<"${tmp_err}")
        if [[ ${rc_local} -eq 0 ]]; then
            raw_dblist=$(<"${tmp_out}")
            auth_kind="${kind}"; auth_cnf="${cnf}"; auth_desc="${desc}"
            rm -f "${tmp_out}" "${tmp_err}"
            log "INFO" "MySQL/MariaDB login OK via ${desc}"
            return 0
        else
            rm -f "${tmp_out}" "${tmp_err}"
            local detail="${err}"
            [[ -z "${detail}" ]] && detail="exit ${rc_local}"
            log "WARN" "MySQL/MariaDB login failed via ${desc}: ${detail}"
            return 1
        fi
    }

    # ---- METHOD 1: user-supplied cnf file ----
    if [[ -r "${TM_MYSQL_CNF_FILE}" ]]; then
        [[ "${TM_MYSQL_DEBUG}" == "true" ]] && log "DEBUG" "Trying ${TM_MYSQL_CNF_FILE}"
        _mysql_try_login "cnf" "${TM_MYSQL_CNF_FILE}" "${TM_MYSQL_CNF_FILE}" || true
    fi

    # ---- METHOD 2: TM_MYSQL_PW_FILE with TM_MYSQL_USER ----
    if [[ -z "${auth_kind}" && -f "${TM_MYSQL_PW_FILE}" ]]; then
        local dbpass=""
        if [[ -r "${TM_MYSQL_PW_FILE}" ]]; then
            dbpass=$(cat "${TM_MYSQL_PW_FILE}" 2>/dev/null) || true
        fi
        if [[ -z "${dbpass}" ]] && sudo -n true 2>/dev/null; then
            dbpass=$(sudo -n cat "${TM_MYSQL_PW_FILE}" 2>/dev/null) || true
        fi
        dbpass="${dbpass%$'\n'}"   # strip trailing newline if present
        if [[ -n "${dbpass}" ]]; then
            tmp_cnf=$(mktemp 2>/dev/null) || tmp_cnf=""
            if [[ -n "${tmp_cnf}" ]] && _mysql_write_cnf "${tmp_cnf}" "${TM_MYSQL_USER}" "${dbpass}"; then
                _mysql_try_login "cnf" "${tmp_cnf}" "${TM_MYSQL_PW_FILE} (user ${TM_MYSQL_USER})" || true
            else
                log "WARN" "Could not create temporary credentials file"
            fi
        else
            log "WARN" "MySQL/MariaDB password file ${TM_MYSQL_PW_FILE} unreadable or empty"
        fi
    fi

    # ---- METHOD 3: /root/mysql.pw via sudo -n ----
    if [[ -z "${auth_kind}" ]]; then
        if sudo -n true 2>/dev/null; then
            local dbpass=""
            dbpass=$(sudo -n cat /root/mysql.pw 2>/dev/null) || true
            dbpass="${dbpass%$'\n'}"
            if [[ -n "${dbpass}" ]]; then
                if [[ -n "${tmp_cnf}" && -f "${tmp_cnf}" ]]; then rm -f "${tmp_cnf}"; fi
                tmp_cnf=$(mktemp 2>/dev/null) || tmp_cnf=""
                if [[ -n "${tmp_cnf}" ]] && _mysql_write_cnf "${tmp_cnf}" "${TM_MYSQL_USER}" "${dbpass}"; then
                    _mysql_try_login "cnf" "${tmp_cnf}" "/root/mysql.pw (user ${TM_MYSQL_USER})" || true
                fi
            else
                log "WARN" "Cannot read /root/mysql.pw using sudo -n"
            fi
        else
            log "WARN" "sudo -n unavailable; skipping /root/mysql.pw fallback"
        fi
    fi

    # ---- METHOD 4: sudo socket login (MariaDB unix_socket auth) ----
    if [[ -z "${auth_kind}" && "${TM_MYSQL_ALLOW_SUDO_SOCKET}" == "true" ]]; then
        if sudo -n true 2>/dev/null; then
            _mysql_try_login "sudo" "" "sudo socket (${mysql_cmd})" || true
        else
            log "WARN" "sudo -n unavailable; cannot attempt socket login"
        fi
    fi

    # ---- All methods exhausted ----
    if [[ -z "${auth_kind}" ]]; then
        log "ERROR" "Failed to retrieve MySQL/MariaDB database list using all supported login methods"
        log "INFO"  "Tried:"
        log "INFO"  "  - ${TM_MYSQL_CNF_FILE}"
        log "INFO"  "  - ${TM_MYSQL_PW_FILE} with user ${TM_MYSQL_USER}"
        log "INFO"  "  - /root/mysql.pw with user ${TM_MYSQL_USER}"
        log "INFO"  "  - sudo socket login"
        log "INFO"  "Suggested checks:"
        log "INFO"  "  sudo ${mysql_cmd} -e \"SELECT User, Host, plugin FROM mysql.user;\""
        log "INFO"  "  ${mysql_cmd} -u ${TM_MYSQL_USER} -p -e \"SHOW DATABASES;\""
        log "INFO"  "  sudo -n ${mysql_cmd} -e \"SHOW DATABASES;\""
        rc=1
    else
        # ---- Filter system databases ----
        local exclude_pattern=""
        if [[ -n "${TM_MYSQL_EXCLUDE_DATABASES}" ]]; then
            exclude_pattern=$(echo "${TM_MYSQL_EXCLUDE_DATABASES}" | tr ',' '|' | tr -d '[:space:]')
        fi
        local -a db_array=()
        local dbname
        while IFS= read -r dbname; do
            [[ -z "${dbname}" ]] && continue
            [[ "${dbname}" == "Database" ]] && continue
            if [[ -n "${exclude_pattern}" ]] && [[ "${dbname}" =~ ^(${exclude_pattern})$ ]]; then
                [[ "${TM_MYSQL_DEBUG}" == "true" ]] && log "DEBUG" "Excluding system database: ${dbname}"
                continue
            fi
            db_array+=("${dbname}")
        done <<< "${raw_dblist}"

        if [[ ${#db_array[@]} -eq 0 ]]; then
            log "INFO" "No user MySQL/MariaDB databases found to dump after filtering system databases"
            rc=0
        else
            local mysql_dir="${SQL_DIR}/mysql"
            mkdir -p "${mysql_dir}"
            local failed=0 db dumpfile tries result err_tmp err_msg
            err_tmp=$(mktemp 2>/dev/null) || err_tmp="/tmp/.mysqldump_err.$$"
            for db in "${db_array[@]}"; do
                dumpfile="${mysql_dir}/${db}.sql"
                log "INFO" "  Dumping MySQL/MariaDB: ${db}"
                tries=0; result=1
                while [[ ${tries} -lt ${TM_DB_DUMP_RETRIES} ]]; do
                    [[ ${tries} -gt 0 ]] && log "WARN" "  Retry ${tries}/${TM_DB_DUMP_RETRIES} for ${db}"
                    _mysql_dump_one "${mysqldump_cmd}" "${db}" "${dumpfile}" yes 2>"${err_tmp}"
                    result=$?
                    [[ ${result} -eq 0 ]] && break
                    tries=$((tries + 1))
                done
                if [[ ${result} -ne 0 ]]; then
                    err_msg=$(<"${err_tmp}")
                    log "WARN" "  Full dump failed for database ${db}, retrying without routines/triggers/events"
                    [[ "${TM_MYSQL_DEBUG}" == "true" && -n "${err_msg}" ]] && log "DEBUG" "  stderr: ${err_msg}"
                    _mysql_dump_one "${mysqldump_cmd}" "${db}" "${dumpfile}" no 2>"${err_tmp}"
                    result=$?
                    if [[ ${result} -ne 0 ]]; then
                        err_msg=$(<"${err_tmp}")
                        log "ERROR" "  Failed to dump MySQL/MariaDB database: ${db}"
                        [[ -n "${err_msg}" ]] && log "ERROR" "  stderr: ${err_msg}"
                        failed=1
                    fi
                fi
            done
            rm -f "${err_tmp}"
            rc=${failed}
        fi
    fi

    # ---- Cleanup (single exit point) ----
    if [[ -n "${tmp_cnf}" && -f "${tmp_cnf}" ]]; then
        rm -f "${tmp_cnf}"
    fi
    return ${rc}
}

# Run a single mysqldump/mariadb-dump using the auth method discovered by
# dump_mysql(). Accesses auth_kind/auth_cnf/host_args from caller via bash
# dynamic scoping. with_routines="yes" includes --routines/--triggers/--events.
_mysql_dump_one() {
    local cmd="$1" db="$2" outfile="$3" with_routines="$4"
    local -a extra=()
    [[ "${with_routines}" == "yes" ]] && extra=(--routines --triggers --events)
    if [[ "${auth_kind}" == "cnf" ]]; then
        "${cmd}" \
            --defaults-extra-file="${auth_cnf}" \
            "${host_args[@]}" \
            --force --opt --single-transaction \
            --disable-keys --skip-add-locks \
            "${extra[@]}" \
            "${db}" > "${outfile}"
    else
        sudo -n "${cmd}" \
            "${host_args[@]}" \
            --force --opt --single-transaction \
            --disable-keys --skip-add-locks \
            "${extra[@]}" \
            "${db}" > "${outfile}"
    fi
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
    local mongo_cred_file="${TM_CREDENTIALS_DIR}/mongodb.conf"
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

    # Require opt-in via credential file — skip if not present
    local redis_conf="${TM_CREDENTIALS_DIR}/redis.conf"
    if [[ ! -f "${redis_conf}" && ! -f "${TM_CREDENTIALS_DIR}/redis.pw" ]]; then
        log "INFO" "  Skipping Redis: no credential file found in ${TM_CREDENTIALS_DIR}/"
        log "INFO" "  To enable Redis backup, create: touch ${TM_CREDENTIALS_DIR}/redis.conf"
        return 0
    fi

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
    local redis_pw_file="${TM_CREDENTIALS_DIR}/redis.pw"
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

# Exit early if no databases detected
if [[ -z "${DB_TYPES}" ]]; then
    log "INFO" "No databases to dump — skipping"
    [[ -n "${PIDFILE:-}" ]] && rm -f "${PIDFILE}"
    exit 0
fi

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

# Compress dumps if enabled
if [[ "${TM_DB_COMPRESS}" == "true" ]] && command -v gzip &>/dev/null; then
    local_count=0
    local_saved=0
    while IFS= read -r -d '' sqlfile; do
        orig_size=$(stat -c%s "${sqlfile}" 2>/dev/null || stat -f%z "${sqlfile}" 2>/dev/null || echo 0)
        if gzip -f "${sqlfile}" 2>/dev/null; then
            gz_size=$(stat -c%s "${sqlfile}.gz" 2>/dev/null || stat -f%z "${sqlfile}.gz" 2>/dev/null || echo 0)
            local_saved=$(( local_saved + orig_size - gz_size ))
            local_count=$(( local_count + 1 ))
        fi
    done < <(find "${SQL_DIR}" -type f \( -name '*.sql' -o -name '*.bson' \) -print0 2>/dev/null)
    if [[ ${local_count} -gt 0 ]]; then
        local_saved_mb=$(( local_saved / 1024 / 1024 ))
        log "INFO" "Compressed ${local_count} dump files (saved ~${local_saved_mb}MB)"
    fi
fi

# Summary
if [[ ${FAILED} -eq 1 ]]; then
    log "WARN" "One or more database dumps failed"
else
    log "INFO" "All database dumps completed successfully"
fi

[[ -n "${PIDFILE:-}" ]] && rm -f "${PIDFILE}"
exit ${FAILED}
