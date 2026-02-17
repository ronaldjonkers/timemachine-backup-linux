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

    # Run rsync on the remote (sender) side with sudo so it can read all files
    cmd+=" --rsync-path='sudo rsync'"

    if [[ -n "${TM_RSYNC_EXTRA_OPTS:-}" ]]; then
        cmd+=" ${TM_RSYNC_EXTRA_OPTS}"
    fi

    echo "${cmd}"
}

# Build exclude arguments for rsync
# Loads global exclude.conf + per-server exclude.<hostname>.conf
_tm_rsync_excludes() {
    local hostname="${1:-}"
    local script_dir="${TM_INSTALL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
    local global_exclude="${script_dir}/config/exclude.conf"
    local server_exclude="${script_dir}/config/exclude.${hostname}.conf"
    local excludes=""

    # Global exclude file
    if [[ -f "${global_exclude}" ]]; then
        excludes+=" --exclude-from='${global_exclude}'"
        tm_log "DEBUG" "Using global excludes: ${global_exclude}"
    fi

    # Per-server exclude file (additive)
    if [[ -n "${hostname}" && -f "${server_exclude}" ]]; then
        excludes+=" --exclude-from='${server_exclude}'"
        tm_log "DEBUG" "Using server excludes: ${server_exclude}"
    fi

    echo "${excludes}"
}

# Sync files from a remote host using rsync with hardlink rotation
# Usage: tm_rsync_backup <hostname> <backup_dest>
tm_rsync_backup() {
    local hostname="$1"
    local remote_user="${TM_USER}"
    local backup_base="$2"

    # Use shared snapshot ID so SQL sync goes into the same directory
    _TM_SNAP_ID=$(tm_snapshot_id)
    local latest_link="${backup_base}/latest"
    local target_dir="${backup_base}/${_TM_SNAP_ID}"

    tm_ensure_dir "${backup_base}"

    # Build rsync command
    local rsync_cmd
    rsync_cmd=$(_tm_rsync_base_cmd)

    # Use hardlinks to previous backup if available
    # --link-dest must point to the files/ subdir of the previous snapshot
    # (resolved to absolute path) so rsync can match relative paths and
    # create hardlinks for unchanged files instead of copying them again.
    local link_dest=""
    if [[ -L "${latest_link}" ]]; then
        local prev_snap
        prev_snap=$(readlink -f "${latest_link}" 2>/dev/null || readlink "${latest_link}")
        [[ -d "${prev_snap}/files" ]] && link_dest="${prev_snap}/files"
    elif [[ -d "${latest_link}" ]]; then
        local prev_snap
        prev_snap=$(cd "${latest_link}" && pwd)
        [[ -d "${prev_snap}/files" ]] && link_dest="${prev_snap}/files"
    fi
    if [[ -n "${link_dest}" ]]; then
        rsync_cmd+=" --link-dest=${link_dest}"
        tm_log "INFO" "Using hardlink source: ${link_dest}"
    else
        tm_log "WARN" "No previous backup found for hardlinking — full copy will be performed"
    fi

    # Build exclude arguments (global + per-server)
    local exclude_args
    exclude_args=$(_tm_rsync_excludes "${hostname}")

    tm_ensure_dir "${target_dir}/files"

    # Sync entire filesystem from / — excludes determine what is skipped
    local source_path="${TM_BACKUP_SOURCE:-/}"
    source_path="${source_path%/}/"

    tm_log "INFO" "Starting file backup: ${hostname}:${source_path} -> ${target_dir}/files"

    # Save detailed rsync transfer log for live viewing in the dashboard
    _TM_RSYNC_LOGFILE="${TM_LOG_DIR:-${TM_HOME}/logs}/rsync-${hostname}-$(date +'%Y-%m-%d_%H%M%S').log"
    rsync_cmd+=" --log-file='${_TM_RSYNC_LOGFILE}'"

    local exit_code=0
    eval ${rsync_cmd} ${exclude_args} \
        "${remote_user}@${hostname}:${source_path}" \
        "${target_dir}/files/" 2>&1 || {
            local rc=$?
            # rsync exit code 24 = "vanished source files" (non-fatal)
            if [[ ${rc} -eq 24 ]]; then
                tm_log "WARN" "Some files vanished during transfer from ${hostname}"
            else
                tm_log "ERROR" "rsync failed for ${hostname} (exit code ${rc})"
                exit_code=${rc}
            fi
        }

    # Update the 'latest' symlink
    if [[ ${exit_code} -eq 0 ]]; then
        rm -f "${latest_link}"
        ln -s "${target_dir}" "${latest_link}"
        tm_log "INFO" "Updated latest symlink -> ${_TM_SNAP_ID}"
    fi

    return ${exit_code}
}

# Sync SQL dump directory from remote host
tm_rsync_sql() {
    local hostname="$1"
    local backup_base="$2"
    local remote_user="${TM_USER}"

    # Reuse snapshot ID from tm_rsync_backup if available.
    # For DB-only runs (no file backup), find today's latest snapshot to avoid
    # creating extra directories that inflate the version count during rotation.
    local is_db_only=0
    local snap_id="${_TM_SNAP_ID:-}"
    if [[ -z "${snap_id}" ]]; then
        is_db_only=1
        local today_prefix
        today_prefix=$(date +'%Y-%m-%d')
        local latest_today
        latest_today=$(ls -1d "${backup_base}/${today_prefix}"* 2>/dev/null | sort -r | head -1)
        if [[ -n "${latest_today}" && -d "${latest_today}" ]]; then
            snap_id=$(basename "${latest_today}")
            tm_log "INFO" "DB-only: reusing today's snapshot ${snap_id}"
        else
            snap_id=$(tm_snapshot_id)
            tm_log "INFO" "DB-only: no existing snapshot today, creating ${snap_id}"
        fi
    fi
    # Export snap_id so timemachine.sh summary can find the snapshot dir
    _TM_SNAP_ID="${snap_id}"
    local snap_dir="${backup_base}/${snap_id}"
    local base_sql_dir="${snap_dir}/sql"

    # For DB-only interval runs, store each version in a timestamped subdir
    # so multiple DB backups per day are individually browsable/downloadable.
    # Full/daily backups go into sql/ directly (the "base" version).
    local target_dir="${base_sql_dir}"
    if [[ ${is_db_only} -eq 1 && -d "${base_sql_dir}" ]]; then
        # This is a DB-only interval run and sql/ already exists from an
        # earlier backup today — store in a timestamped subdir.
        local ts
        ts=$(date +'%H%M%S')
        target_dir="${base_sql_dir}/${ts}"
        tm_log "INFO" "DB interval: storing version in ${snap_id}/sql/${ts}"
    fi

    tm_ensure_dir "${target_dir}"

    local rsync_cmd
    rsync_cmd=$(_tm_rsync_base_cmd)

    tm_log "INFO" "Starting database backup sync: ${hostname} -> ${target_dir}"

    eval ${rsync_cmd} \
        "${remote_user}@${hostname}:/home/${TM_USER}/sql/" \
        "${target_dir}/" 2>&1 || {
            local rc=$?
            tm_log "ERROR" "rsync database sync failed for ${hostname} (exit code ${rc})"
            return ${rc}
        }

    tm_log "INFO" "Database backup sync complete for ${hostname}"
    return 0
}

# Rotate old backups beyond retention period
# Handles:
#   YYYY-MM-DD          (date-only)
#   YYYY-MM-DD_HHMMSS   (timestamped)
#   daily.YYYY-MM-DD    (legacy format from old backup script)
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

    # Current format: YYYY-MM-DD and YYYY-MM-DD_HHMMSS
    for dir in "${backup_base}"/????-??-??*; do
        [[ -d "${dir}" ]] || continue
        local dir_name dir_date
        dir_name=$(basename "${dir}")
        # Extract date portion (first 10 chars: YYYY-MM-DD)
        dir_date="${dir_name:0:10}"

        if [[ "${dir_date}" < "${cutoff_date}" ]]; then
            tm_log "INFO" "Removing old backup: ${dir}"
            rm -rf "${dir}"
            ((count++))
        fi
    done

    # Legacy format: daily.YYYY-MM-DD (from old backup script)
    for dir in "${backup_base}"/daily.????-??-??; do
        [[ -d "${dir}" ]] || continue
        local dir_name dir_date
        dir_name=$(basename "${dir}")
        # Extract date: strip "daily." prefix
        dir_date="${dir_name#daily.}"

        if [[ "${dir_date}" < "${cutoff_date}" ]]; then
            tm_log "INFO" "Removing legacy backup: ${dir}"
            rm -rf "${dir}"
            ((count++))
        fi
    done

    # Clean up stale legacy symlink (latest-daily)
    local legacy_link="${backup_base}/latest-daily"
    if [[ -L "${legacy_link}" ]]; then
        local link_target
        link_target=$(readlink "${legacy_link}" 2>/dev/null)
        if [[ ! -d "${link_target}" ]]; then
            tm_log "INFO" "Removing stale legacy symlink: ${legacy_link}"
            rm -f "${legacy_link}"
        fi
    fi

    tm_log "INFO" "Rotation complete: removed ${count} old backup(s)"
}
