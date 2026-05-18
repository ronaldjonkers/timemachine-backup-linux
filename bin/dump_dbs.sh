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
TM_MYSQL_HOST="${TM_MYSQL_HOST:-}"
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

    # ---- Pick client + dump binaries (prefer mariadb* on MariaDB 11.x) ----
    local mysql_cmd mysqldump_cmd
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
        log "ERROR" "mysqldump/mariadb-dump not found"
        return 1
    fi
    log "INFO" "  Using ${mysql_cmd} / ${mysqldump_cmd}"

    # ---- Resolve password ----
    local dbpass
    dbpass=$(sudo cat "${TM_MYSQL_PW_FILE}" 2>/dev/null) || true
    if [[ -z "${dbpass}" ]]; then
        log "INFO" "No password at ${TM_MYSQL_PW_FILE}, trying /root/mysql.pw"
        dbpass=$(sudo cat /root/mysql.pw 2>/dev/null) || true
    fi
    if [[ -z "${dbpass}" ]]; then
        log "ERROR" "No MySQL password found at ${TM_MYSQL_PW_FILE} or /root/mysql.pw"
        log "INFO" "Create the file: echo 'yourpassword' | sudo tee ${TM_MYSQL_PW_FILE} && sudo chmod 600 ${TM_MYSQL_PW_FILE}"
        return 1
    fi

    local host_opt=""
    if [[ -n "${TM_MYSQL_HOST}" ]]; then
        host_opt="-h ${TM_MYSQL_HOST}"
    fi

    # ---- Probe optional flags (varies by client/server) ----
    local extra_flags=()
    local dump_help
    dump_help=$(${mysqldump_cmd} --help 2>/dev/null || true)
    # --column-statistics: only mysqldump 8 has it; required against MariaDB to avoid
    # "Unknown table COLUMN_STATISTICS in information_schema" which (with --force) silently
    # skipped INSERTs and produced CREATE-TABLE-only dumps.
    if grep -q -- '--column-statistics' <<<"${dump_help}"; then
        extra_flags+=(--column-statistics=0)
    fi
    # --set-gtid-purged: MySQL-only. OFF prevents emitting SET @@GLOBAL.GTID_PURGED which
    # breaks restore on a fresh server.
    if grep -q -- '--set-gtid-purged' <<<"${dump_help}"; then
        extra_flags+=(--set-gtid-purged=OFF)
    fi

    # ---- Database list (explicit batch mode; no headers/borders) ----
    local dblist_raw
    dblist_raw=$(${mysql_cmd} --defaults-extra-file=<(printf "[client]\nuser=root\npassword=%s\n" "${dbpass}") \
        ${host_opt} -N -B -e 'SHOW DATABASES;' 2>&1) || {
            log "ERROR" "Failed to retrieve MySQL database list"
            while IFS= read -r _line; do
                [[ -n "${_line}" ]] && log "ERROR" "  ${_line}"
            done <<< "${dblist_raw}"
            return 1
        }
    local dblist
    dblist=$(echo "${dblist_raw}" | grep -Ev '^(information_schema|performance_schema|sys|mysql)$' || true)

    if [[ -z "${dblist}" ]]; then
        log "INFO" "  No user databases found"
        return 0
    fi

    local mysql_dir="${SQL_DIR}/mysql"
    mkdir -p "${mysql_dir}"

    local failed=0
    for db in ${dblist}; do
        local target="${mysql_dir}/${db}.sql"
        local tmpfile="${target}.tmp"
        local errfile="${target}.err"
        log "INFO" "  Dumping MySQL: ${db}"

        local tries=0 result=1 marker_ok=0
        while [[ ${tries} -lt ${TM_DB_DUMP_RETRIES} ]]; do
            if [[ ${tries} -gt 0 ]]; then
                log "WARN" "  Retry ${tries}/${TM_DB_DUMP_RETRIES} for ${db}"
            fi

            # Per-try fallback strategy (best-effort):
            #   0: full flags
            #   1: drop --routines/--triggers/--events (typical DEFINER/grant issue)
            #   2: also drop --single-transaction → --lock-tables=false (mixed engines)
            local objflags=(--routines --triggers --events)
            local txflags=(--single-transaction)
            [[ ${tries} -ge 1 ]] && objflags=()
            [[ ${tries} -ge 2 ]] && txflags=(--lock-tables=false)

            ${mysqldump_cmd} \
                --defaults-extra-file=<(printf "[client]\nuser=root\npassword=%s\n" "${dbpass}") \
                ${host_opt} \
                --opt --hex-blob \
                --default-character-set=utf8mb4 \
                --max-allowed-packet=1G \
                "${extra_flags[@]}" \
                "${txflags[@]}" \
                "${objflags[@]}" \
                "${db}" > "${tmpfile}" 2> "${errfile}"
            result=$?

            # mysqldump/mariadb-dump appends "-- Dump completed on …" ONLY on success.
            # Missing marker == truncated dump even if exit code happens to be 0.
            marker_ok=0
            if [[ -s "${tmpfile}" ]] && tail -1 "${tmpfile}" | grep -q '^-- Dump completed'; then
                marker_ok=1
            fi

            if [[ ${result} -eq 0 && ${marker_ok} -eq 1 ]]; then
                break
            fi

            if [[ -s "${errfile}" ]]; then
                log "WARN" "  ${db} dump issues (rc=${result}, marker_ok=${marker_ok}):"
                while IFS= read -r _line; do
                    log "WARN" "    ${_line}"
                done < <(tail -20 "${errfile}")
            else
                log "WARN" "  ${db} dump failed (rc=${result}, marker_ok=${marker_ok}, no stderr)"
            fi
            tries=$((tries + 1))
        done

        if [[ ${result} -eq 0 && ${marker_ok} -eq 1 ]]; then
            mv "${tmpfile}" "${target}"
            rm -f "${errfile}"
            local sz
            sz=$(stat -c%s "${target}" 2>/dev/null || stat -f%z "${target}" 2>/dev/null || echo 0)
            if [[ ${sz} -lt 1024 ]]; then
                log "WARN" "  ${db}.sql is suspiciously small (${sz} bytes)"
            fi
        else
            # Best-effort: keep the partial output, but mark it so restore tooling
            # and the operator can see at a glance that it is NOT trustworthy.
            mv "${tmpfile}" "${target}.partial" 2>/dev/null || true
            log "ERROR" "  ${db} dump INCOMPLETE — saved as ${db}.sql.partial (do NOT use for restore)"
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

    # ---- Database list (exclude templates + the postgres maintenance db) ----
    local dblist dblist_err
    dblist_err=$(mktemp)
    dblist=$(sudo -u "${TM_PG_USER}" psql ${pg_host_opt} -At -c \
        "SELECT datname FROM pg_database WHERE datistemplate = false AND datname != 'postgres';" 2>"${dblist_err}") || {
            log "ERROR" "Failed to retrieve PostgreSQL database list"
            while IFS= read -r _line; do
                [[ -n "${_line}" ]] && log "ERROR" "  ${_line}"
            done < "${dblist_err}"
            log "INFO" "Ensure the '${TM_PG_USER}' user can connect. See: sudo -u ${TM_PG_USER} psql -c '\\l'"
            rm -f "${dblist_err}"
            return 1
        }
    rm -f "${dblist_err}"

    if [[ -z "${dblist}" ]]; then
        log "INFO" "  No user databases found"
        return 0
    fi

    local pg_dir="${SQL_DIR}/postgresql"
    mkdir -p "${pg_dir}"

    local failed=0
    for db in ${dblist}; do
        local target="${pg_dir}/${db}.sql"
        local tmpfile="${target}.tmp"
        local errfile="${target}.err"
        log "INFO" "  Dumping PostgreSQL: ${db}"

        local tries=0 result=1 marker_ok=0
        while [[ ${tries} -lt ${TM_DB_DUMP_RETRIES} ]]; do
            if [[ ${tries} -gt 0 ]]; then
                log "WARN" "  Retry ${tries}/${TM_DB_DUMP_RETRIES} for ${db}"
            fi

            # --clean --if-exists makes the dump idempotent (DROP IF EXISTS before CREATE)
            # so restore over an existing DB doesn't fail. --no-owner/--no-acl avoid
            # role-membership errors on a different cluster.
            sudo -u "${TM_PG_USER}" pg_dump ${pg_host_opt} \
                --no-owner --no-acl \
                --clean --if-exists \
                --encoding=UTF8 \
                "${db}" > "${tmpfile}" 2> "${errfile}"
            result=$?

            # pg_dump's plain output ends with "-- PostgreSQL database dump complete"
            marker_ok=0
            if [[ -s "${tmpfile}" ]] && tail -5 "${tmpfile}" | grep -q 'PostgreSQL database dump complete'; then
                marker_ok=1
            fi

            if [[ ${result} -eq 0 && ${marker_ok} -eq 1 ]]; then
                break
            fi

            if [[ -s "${errfile}" ]]; then
                log "WARN" "  ${db} dump issues (rc=${result}, marker_ok=${marker_ok}):"
                while IFS= read -r _line; do
                    log "WARN" "    ${_line}"
                done < <(tail -20 "${errfile}")
            else
                log "WARN" "  ${db} dump failed (rc=${result}, marker_ok=${marker_ok}, no stderr)"
            fi
            tries=$((tries + 1))
        done

        if [[ ${result} -eq 0 && ${marker_ok} -eq 1 ]]; then
            mv "${tmpfile}" "${target}"
            rm -f "${errfile}"
            local sz
            sz=$(stat -c%s "${target}" 2>/dev/null || stat -f%z "${target}" 2>/dev/null || echo 0)
            if [[ ${sz} -lt 1024 ]]; then
                log "WARN" "  ${db}.sql is suspiciously small (${sz} bytes)"
            fi
        else
            mv "${tmpfile}" "${target}.partial" 2>/dev/null || true
            log "ERROR" "  ${db} dump INCOMPLETE — saved as ${db}.sql.partial (do NOT use for restore)"
            failed=1
        fi
    done

    # ---- Globals (roles, tablespaces) with same atomic+verify treatment ----
    log "INFO" "  Dumping PostgreSQL globals (roles, tablespaces)"
    local g_target="${pg_dir}/_globals.sql"
    local g_tmp="${g_target}.tmp"
    local g_err="${g_target}.err"
    sudo -u "${TM_PG_USER}" pg_dumpall ${pg_host_opt} \
        --globals-only > "${g_tmp}" 2> "${g_err}"
    local g_rc=$?
    if [[ ${g_rc} -eq 0 ]] && tail -5 "${g_tmp}" 2>/dev/null | grep -q 'PostgreSQL database cluster dump complete\|PostgreSQL database dump complete'; then
        mv "${g_tmp}" "${g_target}"
        rm -f "${g_err}"
    else
        if [[ -s "${g_err}" ]]; then
            while IFS= read -r _line; do
                [[ -n "${_line}" ]] && log "WARN" "    ${_line}"
            done < <(tail -20 "${g_err}")
        fi
        mv "${g_tmp}" "${g_target}.partial" 2>/dev/null || true
        log "WARN" "  PostgreSQL globals dump INCOMPLETE — saved as _globals.sql.partial"
    fi

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

    local mongo_final="${SQL_DIR}/mongodb"
    local mongo_tmp="${SQL_DIR}/mongodb.tmp"
    local mongo_err="${SQL_DIR}/mongodb.err"
    # Start from a clean tmp dir each run so a previous failure doesn't leak files in.
    rm -rf "${mongo_tmp}" "${mongo_final}.partial"
    mkdir -p "${mongo_tmp}"

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

    local tries=0 result=1
    while [[ ${tries} -lt ${TM_DB_DUMP_RETRIES} ]]; do
        if [[ ${tries} -gt 0 ]]; then
            log "WARN" "  Retry ${tries}/${TM_DB_DUMP_RETRIES}"
            # Wipe partial output between retries so we don't conflate runs
            rm -rf "${mongo_tmp:?}"/*
        fi

        mongodump ${mongo_opts} --out "${mongo_tmp}" 2> "${mongo_err}"
        result=$?
        if [[ ${result} -eq 0 ]]; then break; fi

        if [[ -s "${mongo_err}" ]]; then
            log "WARN" "  mongodump issues (rc=${result}):"
            while IFS= read -r _line; do
                log "WARN" "    ${_line}"
            done < <(tail -20 "${mongo_err}")
        fi
        tries=$((tries + 1))
    done

    # Sanity check: did mongodump actually produce any bson files?
    local bson_count
    bson_count=$(find "${mongo_tmp}" -type f -name '*.bson' 2>/dev/null | wc -l | tr -d ' ')

    if [[ ${result} -eq 0 && ${bson_count} -gt 0 ]]; then
        mv "${mongo_tmp}" "${mongo_final}"
        rm -f "${mongo_err}"
        log "INFO" "  MongoDB dump complete (${bson_count} bson files)"
        return 0
    else
        # Best-effort: keep partial output under .partial so the operator can inspect
        mv "${mongo_tmp}" "${mongo_final}.partial" 2>/dev/null || true
        log "ERROR" "  MongoDB dump INCOMPLETE (rc=${result}, bson_count=${bson_count}) — saved as mongodb.partial"
        return 1
    fi
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
        local bin_target="${sqlite_dir}/${db_name}.sqlite"
        local sql_target="${sqlite_dir}/${db_name}.sql"
        local bin_tmp="${bin_target}.tmp"
        local sql_tmp="${sql_target}.tmp"
        local errfile="${sqlite_dir}/${db_name}.err"

        log "INFO" "  Dumping SQLite: ${db_path}"

        # ---- Method 1: .backup (canonical online binary backup; safe vs concurrent writes) ----
        sqlite3 "${db_path}" ".backup '${bin_tmp//\'/\'\'}'" 2> "${errfile}"
        local rc=$?

        # Verify the binary backup with PRAGMA integrity_check; expected output is "ok".
        local integrity=""
        if [[ ${rc} -eq 0 && -s "${bin_tmp}" ]]; then
            integrity=$(sqlite3 "${bin_tmp}" "PRAGMA integrity_check;" 2>>"${errfile}" | head -1)
        fi

        if [[ ${rc} -eq 0 && "${integrity}" == "ok" ]]; then
            mv "${bin_tmp}" "${bin_target}"
            rm -f "${errfile}"
            continue
        fi

        log "WARN" "  ${db_name} .backup failed (rc=${rc}, integrity='${integrity:-<none>}'), trying .dump fallback"
        rm -f "${bin_tmp}"

        # ---- Method 2: .dump (text SQL); last resort, won't work for fully corrupt DBs ----
        sqlite3 "${db_path}" ".dump" > "${sql_tmp}" 2>> "${errfile}"
        local rc2=$?

        # sqlite3 .dump output starts with BEGIN TRANSACTION; and ends with COMMIT;
        local marker_ok=0
        if [[ -s "${sql_tmp}" ]] && tail -3 "${sql_tmp}" | grep -q '^COMMIT;'; then
            marker_ok=1
        fi

        if [[ ${rc2} -eq 0 && ${marker_ok} -eq 1 ]]; then
            mv "${sql_tmp}" "${sql_target}"
            rm -f "${errfile}"
            log "WARN" "  ${db_name} backed up via .dump fallback (no binary copy)"
            continue
        fi

        if [[ -s "${errfile}" ]]; then
            log "ERROR" "  ${db_name} dump issues:"
            while IFS= read -r _line; do
                log "ERROR" "    ${_line}"
            done < <(tail -20 "${errfile}")
        fi

        # Best-effort: keep whichever last output we have, marked as partial
        if [[ -s "${sql_tmp}" ]]; then
            mv "${sql_tmp}" "${sql_target}.partial"
            log "ERROR" "  ${db_name} dump INCOMPLETE — saved as ${db_name}.sql.partial"
        else
            rm -f "${sql_tmp}"
            log "ERROR" "  ${db_name} dump FAILED — no output"
        fi
        failed=1
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

# Compress dumps if enabled (verified with gunzip -t; corrupt .gz removed)
if [[ "${TM_DB_COMPRESS}" == "true" ]] && command -v gzip &>/dev/null; then
    local_count=0
    local_saved=0
    local_bad=0
    while IFS= read -r -d '' sqlfile; do
        orig_size=$(stat -c%s "${sqlfile}" 2>/dev/null || stat -f%z "${sqlfile}" 2>/dev/null || echo 0)
        if gzip -f "${sqlfile}" 2>/dev/null && gunzip -t "${sqlfile}.gz" 2>/dev/null; then
            gz_size=$(stat -c%s "${sqlfile}.gz" 2>/dev/null || stat -f%z "${sqlfile}.gz" 2>/dev/null || echo 0)
            local_saved=$(( local_saved + orig_size - gz_size ))
            local_count=$(( local_count + 1 ))
        else
            log "ERROR" "Corrupt or failed gzip for ${sqlfile} — removing .gz"
            rm -f "${sqlfile}.gz"
            local_bad=$(( local_bad + 1 ))
            FAILED=1
        fi
    done < <(find "${SQL_DIR}" -type f \
        \( -name '*.sql' -o -name '*.sql.partial' \
           -o -name '*.sqlite' -o -name '*.sqlite.partial' \
           -o -name '*.bson' \) -print0 2>/dev/null)
    if [[ ${local_count} -gt 0 ]]; then
        local_saved_mb=$(( local_saved / 1024 / 1024 ))
        log "INFO" "Compressed ${local_count} dump files (saved ~${local_saved_mb}MB)"
    fi
    if [[ ${local_bad} -gt 0 ]]; then
        log "WARN" "${local_bad} dump file(s) failed gzip verification"
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
