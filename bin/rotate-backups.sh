#!/usr/bin/env bash
# ============================================================
# TimeMachine Backup - Standalone Rotation & Disk Guard
# ============================================================
# Rotates ALL configured servers' backups down to TM_RETENTION_DAYS,
# independent of whether backups ran, failed, or are db-only.
# This is the guarantee that the backup disk cannot silently fill up:
#   - timemachine.sh only rotates after a file backup, so --db-only
#     servers and aborted daily runs never rotated at all.
#   - This script is triggered daily by tmserviced.sh, and can also be
#     run manually or from cron.
#
# After rotation it checks disk usage of TM_BACKUP_ROOT:
#   - usage >= TM_DISK_ALERT_PCT (default 90): error notification.
#   - usage >= TM_DISK_AUTOPURGE_PCT (default 0 = disabled): removes
#     oldest snapshot dates across all servers (always keeping the
#     TM_DISK_AUTOPURGE_MIN_KEEP most recent dates per server, default 3)
#     until usage drops below the threshold.
#
# Usage: rotate-backups.sh [--dry-run]
# ============================================================

_src="$0"
while [[ -L "$_src" ]]; do
    _src_dir="$(cd -P "$(dirname "$_src")" && pwd)"
    _src="$(readlink "$_src")"
    [[ "$_src" != /* ]] && _src="$_src_dir/$_src"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_src")" && pwd)"

source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/../lib/notify.sh"
source "${SCRIPT_DIR}/../lib/rsync.sh"

tm_load_config

# Rotation must never die halfway (set -e inherited from common.sh):
# one host failing to rotate must not stop cleanup of the others.
set +e

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

SERVERS_CONF="${TM_PROJECT_ROOT}/config/servers.conf"

if ! tm_acquire_lock "rotate-backups"; then
    tm_log "WARN" "Another rotate-backups.sh is already running — skipping"
    exit 0
fi
trap 'tm_release_lock "rotate-backups"' EXIT

# ============================================================
# 1. ROTATE ALL CONFIGURED SERVERS
# ============================================================

ROTATE_ERRORS=0
ROTATED_HOSTS=0

if [[ -f "${SERVERS_CONF}" ]]; then
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        srv_host=$(echo "${line}" | awk '{print $1}')
        [[ -z "${srv_host}" ]] && continue

        # Respect per-server --no-rotate
        if echo "${line}" | grep -q '\-\-no-rotate'; then
            tm_log "INFO" "Skipping rotation for ${srv_host} (--no-rotate)"
            continue
        fi

        backup_base="${TM_BACKUP_ROOT}/${srv_host}"
        [[ -d "${backup_base}" ]] || continue

        if [[ ${DRY_RUN} -eq 1 ]]; then
            tm_log "INFO" "[DRY-RUN] Would rotate ${backup_base} (keep ${TM_RETENTION_DAYS:-7} days)"
            continue
        fi

        ROTATED_HOSTS=$((ROTATED_HOSTS + 1))
        tm_rotate_backups "${backup_base}" || ROTATE_ERRORS=$((ROTATE_ERRORS + 1))
    done < <(grep -E '^\s*[^#\s]' "${SERVERS_CONF}" 2>/dev/null | sed 's/^[[:space:]]*//')
else
    tm_log "WARN" "No servers.conf found at ${SERVERS_CONF} — nothing to rotate"
fi

tm_log "INFO" "Rotation sweep done: ${ROTATED_HOSTS} host(s) rotated, ${ROTATE_ERRORS} error(s)"

if [[ ${ROTATE_ERRORS} -gt 0 ]]; then
    tm_notify "Backup rotation FAILED on $(hostname)" \
        "Rotation failed for ${ROTATE_ERRORS} host(s) on $(hostname).

Old snapshots could NOT be removed — the backup disk will keep filling up
until this is fixed. Most common cause: missing NOPASSWD sudoers rule for rm.

Fix:
  sudo /opt/timemachine-backup-linux/install.sh --reconfigure

Check the log:
  tail -50 ${TM_LOG_DIR}/rotation.log" "error" "backup_fail" || true
fi

# ============================================================
# 2. DISK GUARD
# ============================================================

_disk_usage_pct() {
    df -P "${TM_BACKUP_ROOT}" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}'
}

USAGE_PCT=$(_disk_usage_pct)
if [[ -z "${USAGE_PCT}" ]]; then
    tm_log "WARN" "Could not determine disk usage for ${TM_BACKUP_ROOT}"
    exit $(( ROTATE_ERRORS > 0 ? 1 : 0 ))
fi

ALERT_PCT="${TM_DISK_ALERT_PCT:-90}"
AUTOPURGE_PCT="${TM_DISK_AUTOPURGE_PCT:-0}"
MIN_KEEP="${TM_DISK_AUTOPURGE_MIN_KEEP:-3}"

tm_log "INFO" "Disk usage of ${TM_BACKUP_ROOT}: ${USAGE_PCT}% (alert at ${ALERT_PCT}%)"

# ── 2a. Emergency auto-purge (opt-in via TM_DISK_AUTOPURGE_PCT > 0) ──
PURGED=0
if [[ ${AUTOPURGE_PCT} -gt 0 && ${USAGE_PCT} -ge ${AUTOPURGE_PCT} && ${DRY_RUN} -eq 0 ]]; then
    tm_log "ERROR" "Disk usage ${USAGE_PCT}% >= autopurge threshold ${AUTOPURGE_PCT}% — removing oldest snapshots (keeping at least ${MIN_KEEP} dates per server)"

    # Hosts marked --no-rotate are explicitly protected — never autopurge
    # them, not even in an emergency.
    NO_ROTATE_HOSTS=$(grep -E '^\s*[^#\s]' "${SERVERS_CONF}" 2>/dev/null | \
        grep -- '--no-rotate' | awk '{print $1}')

    # Build a global list of "date|snapshot-dir" candidates, oldest first.
    # Per server, the MIN_KEEP most recent unique dates are never touched.
    # Includes archived/orphaned host dirs: when the disk is about to run
    # full, old snapshots of inactive servers go first-come like the rest.
    _purge_candidates() {
        local host_dir host date
        for host_dir in "${TM_BACKUP_ROOT}"/*/; do
            host_dir="${host_dir%/}"
            [[ -d "${host_dir}" ]] || continue
            host=$(basename "${host_dir}")
            if echo "${NO_ROTATE_HOSTS}" | grep -qx "${host}"; then
                continue
            fi
            # Unique dates for this host, newest first
            local dates
            dates=$( { ls -1d "${host_dir}"/????-??-??* 2>/dev/null; ls -1d "${host_dir}"/daily.????-??-?? 2>/dev/null; } | \
                sed 's|.*/||; s|^daily\.||; s|_.*||' | sort -ur )
            local keep_seen=0
            while IFS= read -r date; do
                [[ -z "${date}" ]] && continue
                keep_seen=$((keep_seen + 1))
                [[ ${keep_seen} -le ${MIN_KEEP} ]] && continue
                # All snapshot dirs of this host for this date are candidates
                local d
                for d in "${host_dir}/${date}" "${host_dir}/${date}"_?????? "${host_dir}/daily.${date}"; do
                    [[ -d "${d}" ]] && echo "${date}|${d}"
                done
            done <<< "${dates}"
        done
    }

    # Delete oldest dates first, re-checking usage after every date
    while IFS= read -r candidate; do
        [[ -z "${candidate}" ]] && continue
        USAGE_PCT=$(_disk_usage_pct)
        [[ ${USAGE_PCT} -lt ${AUTOPURGE_PCT} ]] && break
        purge_dir="${candidate#*|}"
        tm_log "ERROR" "AUTOPURGE: removing ${purge_dir} (disk at ${USAGE_PCT}%)"
        _tm_remove_backup_dir "${purge_dir}" && PURGED=$((PURGED + 1))
    done < <(_purge_candidates | sort -t'|' -k1,1)

    USAGE_PCT=$(_disk_usage_pct)
    if [[ ${PURGED} -gt 0 ]]; then
        tm_notify "Backup disk AUTOPURGE ran on $(hostname)" \
            "Disk usage reached ${AUTOPURGE_PCT}%+ on $(hostname).

${PURGED} old snapshot dir(s) beyond the ${MIN_KEEP} most recent dates per server
were removed. Disk usage is now ${USAGE_PCT}%.

This is an emergency measure — consider lowering TM_RETENTION_DAYS, adding disk
space, or reducing the number/size of backups." "error" "disk_full" || true
    fi
fi

# ── 2b. Alert when the disk is (still) nearly full ──
if [[ ${USAGE_PCT} -ge ${ALERT_PCT} ]]; then
    tm_log "ERROR" "Backup disk nearly full: ${USAGE_PCT}% used on ${TM_BACKUP_ROOT}"
    DISK_INFO=$(df -h "${TM_BACKUP_ROOT}" 2>/dev/null | tail -2)
    tm_notify "Backup disk ${USAGE_PCT}% FULL on $(hostname)" \
        "The backup disk on $(hostname) is at ${USAGE_PCT}% capacity (alert threshold ${ALERT_PCT}%).

${DISK_INFO}

When the disk fills up completely, ALL backups will start failing.

Options:
  - Lower TM_RETENTION_DAYS in .env (current: ${TM_RETENTION_DAYS:-7})
  - Add disk space
  - Enable emergency purge: set TM_DISK_AUTOPURGE_PCT=95 in .env
  - Remove archived servers' snapshots you no longer need" "error" "disk_full" || true
fi

exit $(( ROTATE_ERRORS > 0 ? 1 : 0 ))
