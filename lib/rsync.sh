#!/usr/bin/env bash
# ============================================================
# TimeMachine Backup - Rsync Functions
# ============================================================
# Provides rsync-based file synchronization with hardlink
# rotation (Time Machine-style snapshots).
# ============================================================

# Build the base rsync command with common options
_tm_rsync_base_cmd() {
    local rsync_flags="${TM_RSYNC_FLAGS[*]}"
    local cmd="rsync ${rsync_flags} --delete"

    if [[ "${TM_RSYNC_BW_LIMIT:-0}" -gt 0 ]]; then
        cmd+=" --bwlimit=${TM_RSYNC_BW_LIMIT}"
    fi

    cmd+=" -e 'ssh -p ${TM_SSH_PORT} -i ${TM_SSH_KEY} -o ConnectTimeout=${TM_SSH_TIMEOUT} -o StrictHostKeyChecking=no'"

    if [[ -n "${TM_RSYNC_EXTRA_OPTS:-}" ]]; then
        cmd+=" ${TM_RSYNC_EXTRA_OPTS}"
    fi

    echo "${cmd}"
}

# Sync files from a remote host using rsync with hardlink rotation
# Usage: tm_rsync_backup <hostname> <remote_paths> <backup_dest>
tm_rsync_backup() {
    local hostname="$1"
    local remote_user="${TM_USER}"
    local backup_base="$2"

    local today
    today=$(tm_date_today)
    local latest_link="${backup_base}/latest"
    local target_dir="${backup_base}/${today}"

    tm_ensure_dir "${backup_base}"

    # Build rsync command
    local rsync_cmd
    rsync_cmd=$(_tm_rsync_base_cmd)

    # Use hardlinks to previous backup if available
    if [[ -d "${latest_link}" ]]; then
        rsync_cmd+=" --link-dest=${latest_link}"
    fi

    # Default paths to sync
    local default_paths=(
        "/etc/"
        "/home/"
        "/root/"
        "/var/spool/cron/"
        "/opt/"
    )

    # Exclude patterns
    local excludes=(
        "--exclude=/proc"
        "--exclude=/sys"
        "--exclude=/dev"
        "--exclude=/tmp"
        "--exclude=/run"
        "--exclude=/var/tmp"
        "--exclude=/var/cache"
        "--exclude=lost+found"
        "--exclude=.cache"
    )

    tm_ensure_dir "${target_dir}/files"

    tm_log "INFO" "Starting file backup: ${hostname} -> ${target_dir}/files"

    local exit_code=0
    for path in "${default_paths[@]}"; do
        local dest_subdir="${target_dir}/files${path}"
        tm_ensure_dir "${dest_subdir}"

        tm_log "DEBUG" "Syncing ${hostname}:${path}"

        eval ${rsync_cmd} "${excludes[@]}" \
            "${remote_user}@${hostname}:${path}" \
            "${dest_subdir}" 2>&1 || {
                local rc=$?
                # rsync exit code 24 = "vanished source files" (non-fatal)
                if [[ ${rc} -eq 24 ]]; then
                    tm_log "WARN" "Some files vanished during transfer from ${hostname}:${path}"
                else
                    tm_log "ERROR" "rsync failed for ${hostname}:${path} (exit code ${rc})"
                    exit_code=${rc}
                fi
            }
    done

    # Update the 'latest' symlink
    if [[ ${exit_code} -eq 0 ]]; then
        rm -f "${latest_link}"
        ln -s "${target_dir}" "${latest_link}"
        tm_log "INFO" "Updated latest symlink -> ${today}"
    fi

    return ${exit_code}
}

# Sync SQL dump directory from remote host
tm_rsync_sql() {
    local hostname="$1"
    local backup_base="$2"
    local remote_user="${TM_USER}"

    local today
    today=$(tm_date_today)
    local target_dir="${backup_base}/${today}/sql"

    tm_ensure_dir "${target_dir}"

    local rsync_cmd
    rsync_cmd=$(_tm_rsync_base_cmd)

    tm_log "INFO" "Starting SQL backup: ${hostname} -> ${target_dir}"

    eval ${rsync_cmd} \
        "${remote_user}@${hostname}:/home/${TM_USER}/sql/" \
        "${target_dir}/" 2>&1 || {
            local rc=$?
            tm_log "ERROR" "rsync SQL failed for ${hostname} (exit code ${rc})"
            return ${rc}
        }

    tm_log "INFO" "SQL backup complete for ${hostname}"
    return 0
}

# Rotate old backups beyond retention period
tm_rotate_backups() {
    local backup_base="$1"
    local retention="${TM_RETENTION_DAYS:-7}"

    tm_log "INFO" "Rotating backups in ${backup_base} (keeping ${retention} days)"

    # Find date-named directories older than retention
    local cutoff_date
    cutoff_date=$(date -d "-${retention} days" +'%Y-%m-%d' 2>/dev/null || \
                  date -v-${retention}d +'%Y-%m-%d' 2>/dev/null)

    if [[ -z "${cutoff_date}" ]]; then
        tm_log "ERROR" "Could not calculate cutoff date for rotation"
        return 1
    fi

    local count=0
    for dir in "${backup_base}"/????-??-??; do
        [[ -d "${dir}" ]] || continue
        local dir_date
        dir_date=$(basename "${dir}")

        if [[ "${dir_date}" < "${cutoff_date}" ]]; then
            tm_log "INFO" "Removing old backup: ${dir}"
            rm -rf "${dir}"
            ((count++))
        fi
    done

    tm_log "INFO" "Rotation complete: removed ${count} old backup(s)"
}
