#!/usr/bin/env bash
# ============================================================
# TimeMachine Backup - Restore Script
# ============================================================
# Restore files and/or databases from backup snapshots.
# Can be initiated from the backup server OR from a client.
#
# Usage:
#   restore.sh <hostname> [OPTIONS]
#
# Options:
#   --date <YYYY-MM-DD>   Restore from specific date (default: latest)
#   --files-only          Only restore files
#   --db-only             Only restore databases
#   --db <name>           Restore specific database(s) (comma-separated)
#   --path <path>         Restore specific path(s) (comma-separated)
#   --target <dir>        Restore to custom directory instead of original
#   --dry-run             Show what would be restored
#   --list                List available snapshots
#   --list-files          List files in a snapshot
#   --list-dbs            List databases in a snapshot
#   --decrypt             Decrypt backup before restore
#   --no-confirm          Skip confirmation prompt
#   --verbose             Enable debug logging
#
# Examples:
#   restore.sh web1.example.com --list
#   restore.sh web1.example.com --date 2025-02-04 --files-only
#   restore.sh web1.example.com --db mydb --target /tmp/restore
#   restore.sh web1.example.com --path /etc/nginx --dry-run
# ============================================================

# Resolve symlinks to find real script directory
_src="$0"
while [[ -L "$_src" ]]; do
    _src_dir="$(cd -P "$(dirname "$_src")" && pwd)"
    _src="$(readlink "$_src")"
    [[ "$_src" != /* ]] && _src="$_src_dir/$_src"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_src")" && pwd)"

source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/../lib/rsync.sh"
source "${SCRIPT_DIR}/../lib/encrypt.sh"

tm_load_config

# ============================================================
# ARGUMENT PARSING
# ============================================================

HOSTNAME=""
RESTORE_DATE=""
FILES_ONLY=0
DB_ONLY=0
DB_NAMES=""
RESTORE_PATHS=""
TARGET_DIR=""
RESTORE_FORMAT="files"
DRY_RUN=0
LIST_SNAPSHOTS=0
LIST_FILES=0
LIST_DBS=0
DECRYPT=0
NO_CONFIRM=0

usage() {
    sed -n '3,34p' "$0" | sed 's/^# \?//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --date)         RESTORE_DATE="$2"; shift 2 ;;
        --files-only)   FILES_ONLY=1; shift ;;
        --db-only)      DB_ONLY=1; shift ;;
        --db)           DB_NAMES="$2"; shift 2 ;;
        --path)         RESTORE_PATHS="$2"; shift 2 ;;
        --target)       TARGET_DIR="$2"; shift 2 ;;
        --format)       RESTORE_FORMAT="$2"; shift 2 ;;
        --dry-run)      DRY_RUN=1; shift ;;
        --list)         LIST_SNAPSHOTS=1; shift ;;
        --list-files)   LIST_FILES=1; shift ;;
        --list-dbs)     LIST_DBS=1; shift ;;
        --decrypt)      DECRYPT=1; shift ;;
        --no-confirm)   NO_CONFIRM=1; shift ;;
        --verbose)      TM_LOG_LEVEL="DEBUG"; shift ;;
        --help|-h)      usage ;;
        -*)             echo "Unknown option: $1"; usage ;;
        *)
            if [[ -z "${HOSTNAME}" ]]; then
                HOSTNAME="$1"
            else
                echo "Unexpected argument: $1"; usage
            fi
            shift
            ;;
    esac
done

if [[ -z "${HOSTNAME}" ]]; then
    echo "Error: hostname is required"
    usage
fi

BACKUP_BASE="${TM_BACKUP_ROOT}/${HOSTNAME}"

# ============================================================
# SNAPSHOT DISCOVERY
# ============================================================

list_snapshots() {
    if [[ ! -d "${BACKUP_BASE}" ]]; then
        tm_log "ERROR" "No backups found for ${HOSTNAME}"
        return 1
    fi

    echo "Available snapshots for ${HOSTNAME}:"
    echo "============================================"

    for dir in "${BACKUP_BASE}"/????-??-??; do
        [[ -d "${dir}" ]] || continue
        local date_name
        date_name=$(basename "${dir}")
        local size
        size=$(du -sh "${dir}" 2>/dev/null | cut -f1)

        local has_files="no"
        local has_sql="no"
        local encrypted="no"
        [[ -d "${dir}/files" ]] && has_files="yes"
        [[ -d "${dir}/sql" ]] && has_sql="yes"
        [[ -f "${dir}.tar.gpg" ]] && encrypted="yes"

        printf "  %s  size=%-8s  files=%-3s  sql=%-3s  encrypted=%s\n" \
            "${date_name}" "${size}" "${has_files}" "${has_sql}" "${encrypted}"
    done

    # Check for encrypted-only snapshots
    for gpg_file in "${BACKUP_BASE}"/????-??-??.tar.gpg; do
        [[ -f "${gpg_file}" ]] || continue
        local base_name
        base_name=$(basename "${gpg_file}" .tar.gpg)
        if [[ ! -d "${BACKUP_BASE}/${base_name}" ]]; then
            local size
            size=$(du -sh "${gpg_file}" 2>/dev/null | cut -f1)
            printf "  %s  size=%-8s  [ENCRYPTED ONLY]\n" "${base_name}" "${size}"
        fi
    done

    local latest_target
    if [[ -L "${BACKUP_BASE}/latest" ]]; then
        latest_target=$(readlink "${BACKUP_BASE}/latest")
        echo ""
        echo "Latest: $(basename "${latest_target}")"
    fi
}

# Resolve which snapshot directory to use
resolve_snapshot() {
    local snapshot_dir

    if [[ -n "${RESTORE_DATE}" ]]; then
        snapshot_dir="${BACKUP_BASE}/${RESTORE_DATE}"
    elif [[ -L "${BACKUP_BASE}/latest" ]]; then
        snapshot_dir=$(readlink -f "${BACKUP_BASE}/latest" 2>/dev/null || \
                       readlink "${BACKUP_BASE}/latest")
    else
        # Find most recent date directory
        snapshot_dir=$(find "${BACKUP_BASE}" -maxdepth 1 -type d -name '????-??-??' | sort -r | head -1)
    fi

    # Handle encrypted-only snapshots
    if [[ ! -d "${snapshot_dir}" && -f "${snapshot_dir}.tar.gpg" ]]; then
        if [[ ${DECRYPT} -eq 1 ]]; then
            tm_log "INFO" "Decrypting snapshot: ${snapshot_dir}.tar.gpg"
            if ! tm_decrypt_backup "${snapshot_dir}.tar.gpg" "${snapshot_dir}"; then
                tm_log "ERROR" "Failed to decrypt snapshot"
                return 1
            fi
        else
            tm_log "ERROR" "Snapshot is encrypted. Use --decrypt to decrypt first."
            return 1
        fi
    fi

    if [[ ! -d "${snapshot_dir}" ]]; then
        tm_log "ERROR" "Snapshot not found: ${snapshot_dir}"
        return 1
    fi

    echo "${snapshot_dir}"
}

# ============================================================
# LIST OPERATIONS
# ============================================================

list_snapshot_files() {
    local snapshot_dir
    snapshot_dir=$(resolve_snapshot) || return 1

    if [[ ! -d "${snapshot_dir}/files" ]]; then
        tm_log "ERROR" "No file backup in snapshot $(basename "${snapshot_dir}")"
        return 1
    fi

    echo "Files in ${HOSTNAME} / $(basename "${snapshot_dir}"):"
    echo "============================================"
    find "${snapshot_dir}/files" -type f | head -100 | \
        sed "s|${snapshot_dir}/files||"

    local total
    total=$(find "${snapshot_dir}/files" -type f | wc -l | tr -d ' ')
    echo ""
    echo "Total files: ${total}"
    if [[ ${total} -gt 100 ]]; then
        echo "(showing first 100; use 'find ${snapshot_dir}/files' for full list)"
    fi
}

list_snapshot_dbs() {
    local snapshot_dir
    snapshot_dir=$(resolve_snapshot) || return 1

    if [[ ! -d "${snapshot_dir}/sql" ]]; then
        tm_log "ERROR" "No database backup in snapshot $(basename "${snapshot_dir}")"
        return 1
    fi

    echo "Databases in ${HOSTNAME} / $(basename "${snapshot_dir}"):"
    echo "============================================"
    for sql_file in "${snapshot_dir}/sql"/*.sql; do
        [[ -f "${sql_file}" ]] || continue
        local db_name size
        db_name=$(basename "${sql_file}" .sql)
        size=$(du -sh "${sql_file}" 2>/dev/null | cut -f1)
        printf "  %-30s  %s\n" "${db_name}" "${size}"
    done
}

# ============================================================
# RESTORE OPERATIONS
# ============================================================

confirm_restore() {
    if [[ ${NO_CONFIRM} -eq 1 || ${DRY_RUN} -eq 1 ]]; then
        return 0
    fi

    echo ""
    echo "WARNING: This will overwrite existing data!"
    echo -n "Continue? [y/N] "
    read -r answer
    if [[ "${answer}" != "y" && "${answer}" != "Y" ]]; then
        tm_log "INFO" "Restore cancelled by user"
        exit 0
    fi
}

restore_files() {
    local snapshot_dir="$1"
    local source_dir="${snapshot_dir}/files"

    if [[ ! -d "${source_dir}" ]]; then
        tm_log "ERROR" "No file backup found in $(basename "${snapshot_dir}")"
        return 1
    fi

    # Determine target
    local target="${TARGET_DIR:-}"
    if [[ -z "${target}" ]]; then
        target="${TM_HOME}/restores/${HOSTNAME}/$(basename "${snapshot_dir}")"
    fi

    # Ensure target directory is writable; fall back to TM_HOME/restores/
    if ! mkdir -p "${target}" 2>/dev/null; then
        local fallback="${TM_HOME}/restores/${HOSTNAME}/$(basename "${snapshot_dir}")"
        tm_log "WARN" "Cannot write to ${target} — falling back to ${fallback}"
        target="${fallback}"
        mkdir -p "${target}"
    fi

    # Archive format: create tar.gz or zip on the server
    if [[ "${RESTORE_FORMAT}" == "tar.gz" || "${RESTORE_FORMAT}" == "zip" ]]; then
        if [[ -n "${RESTORE_PATHS}" ]]; then
            # Archive only the specific path(s)
            local IFS=','
            for rpath in ${RESTORE_PATHS}; do
                rpath=$(echo "${rpath}" | sed 's|^/||')
                local src="${source_dir}/${rpath}"
                if [[ ! -e "${src}" ]]; then
                    tm_log "ERROR" "Path not found in backup: ${rpath}"
                    continue
                fi
                _restore_as_archive "${src}" "${target}" "${rpath}" "${snapshot_dir}"
            done
        else
            _restore_as_archive "${source_dir}" "${target}" "files" "${snapshot_dir}"
        fi
        return $?
    fi

    if [[ -n "${RESTORE_PATHS}" ]]; then
        # Restore specific paths as files
        local IFS=','
        for rpath in ${RESTORE_PATHS}; do
            rpath=$(echo "${rpath}" | sed 's|^/||')
            local src="${source_dir}/${rpath}"
            local dst="${target}/${rpath}"

            if [[ ! -e "${src}" ]]; then
                tm_log "ERROR" "Path not found in backup: ${rpath}"
                continue
            fi

            if [[ ${DRY_RUN} -eq 1 ]]; then
                tm_log "INFO" "[DRY-RUN] Would restore: ${src} -> ${dst}"
                continue
            fi

            tm_log "INFO" "Restoring: ${rpath}"
            if [[ -d "${src}" ]]; then
                mkdir -p "${dst}"
                rsync "${TM_RSYNC_FLAGS[@]}" "${src}/" "${dst}/"
            else
                mkdir -p "$(dirname "${dst}")"
                rsync "${TM_RSYNC_FLAGS[@]}" "${src}" "${dst}"
            fi
        done
    else
        if [[ ${DRY_RUN} -eq 1 ]]; then
            tm_log "INFO" "[DRY-RUN] Would restore all files from $(basename "${snapshot_dir}") to ${target}"
            rsync "${TM_RSYNC_FLAGS[@]}" --dry-run "${source_dir}/" "${target}/" 2>&1 | head -20
            return 0
        fi

        tm_log "INFO" "Restoring all files to ${target}"
        rsync "${TM_RSYNC_FLAGS[@]}" "${source_dir}/" "${target}/"
    fi
}

_restore_as_archive() {
    local source_dir="$1"
    local target_dir="$2"
    local label="$3"
    local snapshot_dir="$4"
    # Sanitize label for filename (replace / with -)
    local safe_label
    safe_label=$(echo "${label}" | sed 's|/|-|g')
    local archive_name="${HOSTNAME}-$(basename "${snapshot_dir}")-${safe_label}"

    mkdir -p "${target_dir}"

    local archive=""
    local rc=0
    if [[ "${RESTORE_FORMAT}" == "zip" ]]; then
        archive="${target_dir}/${archive_name}.zip"
        tm_log "INFO" "Creating zip archive: ${archive}"
        if command -v zip &>/dev/null; then
            (cd "$(dirname "${source_dir}")" && sudo zip -r "${archive}" "$(basename "${source_dir}")") >> "${TM_LOG_DIR}/restore-archive.log" 2>&1
            rc=$?
            sudo chown "$(id -u):$(id -g)" "${archive}" 2>/dev/null
        else
            tm_log "ERROR" "zip command not available on server"
            return 1
        fi
    else
        archive="${target_dir}/${archive_name}.tar.gz"
        tm_log "INFO" "Creating tar.gz archive: ${archive}"
        sudo tar -czf "${archive}" -C "$(dirname "${source_dir}")" "$(basename "${source_dir}")" 2>&1
        rc=$?
        sudo chown "$(id -u):$(id -g)" "${archive}" 2>/dev/null
    fi

    if [[ ${rc} -eq 0 && -f "${archive}" ]]; then
        local sz
        sz=$(du -sh "${archive}" 2>/dev/null | cut -f1)
        tm_log "INFO" "Archive created: ${archive} (${sz})"
    else
        tm_log "ERROR" "Failed to create archive (exit code: ${rc})"
        return 1
    fi
}

restore_databases() {
    local snapshot_dir="$1"
    local sql_dir="${snapshot_dir}/sql"

    if [[ ! -d "${sql_dir}" ]]; then
        tm_log "ERROR" "No database backup found in $(basename "${snapshot_dir}")"
        return 1
    fi

    local target_dir="${TARGET_DIR:-}"
    if [[ -z "${target_dir}" ]]; then
        target_dir="${TM_HOME}/restores/${HOSTNAME}/$(basename "${snapshot_dir}")"
    fi

    # Archive format: create tar.gz or zip of sql dumps on the server
    if [[ "${RESTORE_FORMAT}" == "tar.gz" || "${RESTORE_FORMAT}" == "zip" ]]; then
        _restore_as_archive "${sql_dir}" "${target_dir}" "sql" "${snapshot_dir}"
        return $?
    fi

    # Copy SQL files to target dir
    if ! mkdir -p "${target_dir}" 2>/dev/null; then
        local fallback="${TM_HOME}/restores/${HOSTNAME}/$(basename "${snapshot_dir}")/sql"
        tm_log "WARN" "Cannot write to ${target_dir} — falling back to ${fallback}"
        target_dir="${fallback}"
    fi
    tm_ensure_dir "${target_dir}"

    if [[ -n "${DB_NAMES}" ]]; then
        local IFS=','
        for db in ${DB_NAMES}; do
            db=$(echo "${db}" | tr -d ' ')
            local src="${sql_dir}/${db}.sql"
            if [[ ! -f "${src}" ]]; then
                tm_log "ERROR" "Database dump not found: ${db}"
                continue
            fi
            if [[ ${DRY_RUN} -eq 1 ]]; then
                tm_log "INFO" "[DRY-RUN] Would copy: ${src} -> ${target_dir}/"
            else
                cp "${src}" "${target_dir}/"
                tm_log "INFO" "Copied ${db}.sql to ${target_dir}/"
            fi
        done
    else
        if [[ ${DRY_RUN} -eq 1 ]]; then
            tm_log "INFO" "[DRY-RUN] Would copy all SQL dumps to ${target_dir}/"
        else
            cp "${sql_dir}"/*.sql "${target_dir}/" 2>/dev/null || true
            tm_log "INFO" "Copied all SQL dumps to ${target_dir}/"
        fi
    fi
    return 0
}

# ============================================================
# REMOTE RESTORE (initiated from client)
# ============================================================

# This function can be called from a client to request a restore
# from the backup server. It SSHs to the backup server and runs
# the restore there.
restore_from_client() {
    local backup_server="$1"
    shift

    tm_log "INFO" "Requesting restore from backup server: ${backup_server}"

    ssh -p "${TM_SSH_PORT}" -i "${TM_SSH_KEY}" \
        -o ConnectTimeout="${TM_SSH_TIMEOUT}" \
        -o StrictHostKeyChecking=no \
        "${TM_USER}@${backup_server}" \
        "bash ${TM_HOME}/bin/restore.sh $(hostname -f) $*"
}

# ============================================================
# MAIN
# ============================================================

main() {
    # List operations (no confirmation needed)
    if [[ ${LIST_SNAPSHOTS} -eq 1 ]]; then
        list_snapshots
        exit $?
    fi

    if [[ ${LIST_FILES} -eq 1 ]]; then
        list_snapshot_files
        exit $?
    fi

    if [[ ${LIST_DBS} -eq 1 ]]; then
        list_snapshot_dbs
        exit $?
    fi

    # Resolve snapshot
    local snapshot_dir
    snapshot_dir=$(resolve_snapshot) || exit 1

    tm_log "INFO" "=========================================="
    tm_log "INFO" "Restore from: ${HOSTNAME} / $(basename "${snapshot_dir}")"
    tm_log "INFO" "=========================================="

    # Confirm
    confirm_restore

    local exit_code=0

    # Restore files
    if [[ ${DB_ONLY} -eq 0 ]]; then
        if ! restore_files "${snapshot_dir}"; then
            exit_code=1
        fi
    fi

    # Restore databases
    if [[ ${FILES_ONLY} -eq 0 ]]; then
        if ! restore_databases "${snapshot_dir}"; then
            exit_code=1
        fi
    fi

    if [[ ${exit_code} -eq 0 ]]; then
        tm_log "INFO" "Restore completed successfully"
    else
        tm_log "ERROR" "Restore completed with errors"
    fi

    exit ${exit_code}
}

main
