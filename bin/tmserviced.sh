#!/usr/bin/env bash
# ============================================================
# TimeMachine Backup - Service Daemon
# ============================================================
# Runs as a systemd service. Provides:
#   - Scheduled backup execution
#   - HTTP API for status, control, and SSH key distribution
#   - Web dashboard (serves static files from web/)
#
# Usage:
#   tmserviced.sh [--foreground]
#
# The service listens on TM_API_PORT (default: 7600).
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
source "${SCRIPT_DIR}/../lib/notify.sh"
source "${SCRIPT_DIR}/../lib/report.sh"

tm_load_config

: "${TM_API_PORT:=7600}"
: "${TM_API_BIND:=0.0.0.0}"

FOREGROUND=0
if [[ "${1:-}" == "--foreground" ]]; then
    FOREGROUND=1
fi

# ============================================================
# STATE DIRECTORY
# ============================================================

STATE_DIR="${TM_RUN_DIR}/state"
tm_ensure_dir "${STATE_DIR}"
tm_ensure_dir "${TM_LOG_DIR}"

# Write service PID
echo $$ > "${TM_RUN_DIR}/tmserviced.pid"

# ============================================================
# PROCESS TRACKING
# ============================================================

# Register a running backup process
# State format: pid|hostname|mode|started|status|logfile
_register_process() {
    local hostname="$1" pid="$2" mode="${3:-full}" logfile="${4:-}"
    local ts
    ts=$(date +'%Y-%m-%d %H:%M:%S')
    echo "${pid}|${hostname}|${mode}|${ts}|running|${logfile}" > "${STATE_DIR}/proc-${hostname}.state"
}

# Update process state
_update_process() {
    local hostname="$1" status="$2"
    local state_file="${STATE_DIR}/proc-${hostname}.state"
    if [[ -f "${state_file}" ]]; then
        local content
        content=$(cat "${state_file}")
        # Replace status field (5th field), keep logfile (6th)
        local f1 f2 f3 f4 f6
        f1=$(echo "${content}" | cut -d'|' -f1)
        f2=$(echo "${content}" | cut -d'|' -f2)
        f3=$(echo "${content}" | cut -d'|' -f3)
        f4=$(echo "${content}" | cut -d'|' -f4)
        f6=$(echo "${content}" | cut -d'|' -f6)
        echo "${f1}|${f2}|${f3}|${f4}|${status}|${f6}" > "${state_file}"
    fi
}

# Check if a finished process failed by inspecting its log file
_check_process_exit() {
    local hostname="$1"
    local state_file="${STATE_DIR}/proc-${hostname}.state"
    [[ -f "${state_file}" ]] || return
    local logfile
    logfile=$(cut -d'|' -f6 "${state_file}")
    if [[ -n "${logfile}" && -f "${logfile}" ]]; then
        # Check last 30 lines for ERROR/FAIL indicators
        if tail -30 "${logfile}" 2>/dev/null | grep -qiE '(\[ERROR\]|FAIL|fatal|Permission denied|cannot create)'; then
            _update_process "${hostname}" "failed"
            return 1
        fi
    fi
    _update_process "${hostname}" "completed"
    return 0
}

# Get all process states as JSON
_get_processes_json() {
    echo '['
    local first=1
    for state_file in "${STATE_DIR}"/proc-*.state; do
        [[ -f "${state_file}" ]] || continue
        local content
        content=$(cat "${state_file}")
        local pid hostname mode started status logfile
        pid=$(echo "${content}" | cut -d'|' -f1)
        hostname=$(echo "${content}" | cut -d'|' -f2)
        mode=$(echo "${content}" | cut -d'|' -f3)
        started=$(echo "${content}" | cut -d'|' -f4)
        status=$(echo "${content}" | cut -d'|' -f5)
        logfile=$(echo "${content}" | cut -d'|' -f6)

        # Check if process is actually still running
        if [[ "${status}" == "running" ]] && ! kill -0 "${pid}" 2>/dev/null; then
            _check_process_exit "${hostname}"
            status=$(cut -d'|' -f5 "${state_file}")
        fi

        [[ ${first} -eq 1 ]] && first=0 || echo ','
        printf '{"pid":%s,"hostname":"%s","mode":"%s","started":"%s","status":"%s","logfile":"%s"}' \
            "${pid}" "${hostname}" "${mode}" "${started}" "${status}" "$(basename "${logfile:-}" 2>/dev/null)"
    done
    echo ']'
}

# ============================================================
# BACKUP EXECUTION
# ============================================================

run_backup() {
    local hostname="$1"
    shift
    local opts="$*"

    tm_log "INFO" "Service: starting backup for ${hostname} ${opts}"

    # Per-backup timestamped log file
    local ts
    ts=$(date +'%Y-%m-%d_%H%M%S')
    local logfile="${TM_LOG_DIR}/backup-${hostname}-${ts}.log"

    # Wrapper subshell: runs backup, captures exit code, updates state, sends notification on failure
    (
        local exit_code=0
        "${SCRIPT_DIR}/timemachine.sh" ${hostname} ${opts} >> "${logfile}" 2>&1 || exit_code=$?

        if [[ ${exit_code} -ne 0 ]]; then
            echo "[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] Backup exited with code ${exit_code}" >> "${logfile}"
            echo "${exit_code}" > "${STATE_DIR}/exit-${hostname}.code"
            # Send failure notification
            if [[ "${TM_ALERT_ENABLED:-false}" == "true" ]]; then
                local body
                body="Backup for ${hostname} failed (exit code ${exit_code}).\n\nLast 20 lines of log:\n$(tail -20 "${logfile}" 2>/dev/null)"
                source "${SCRIPT_DIR}/../lib/notify.sh" 2>/dev/null || true
                tm_notify "Backup FAILED: ${hostname}" "${body}" "error" 2>/dev/null || true
            fi
        else
            echo "0" > "${STATE_DIR}/exit-${hostname}.code"
        fi
    ) &
    local pid=$!
    disown ${pid} 2>/dev/null || true

    local mode="full"
    [[ "${opts}" == *"--files-only"* ]] && mode="files-only"
    [[ "${opts}" == *"--db-only"* ]] && mode="db-only"

    _register_process "${hostname}" "${pid}" "${mode}" "${logfile}"
    tm_log "INFO" "Service: backup started for ${hostname} (PID ${pid}, log: ${logfile})"
    echo "${pid}"
}

# Kill a backup process
kill_backup() {
    local hostname="$1"
    local state_file="${STATE_DIR}/proc-${hostname}.state"

    if [[ ! -f "${state_file}" ]]; then
        tm_log "WARN" "No process found for ${hostname}"
        return 1
    fi

    local pid
    pid=$(cut -d'|' -f1 "${state_file}")

    if kill -0 "${pid}" 2>/dev/null; then
        kill "${pid}" 2>/dev/null
        # Wait briefly then force kill if needed
        sleep 2
        if kill -0 "${pid}" 2>/dev/null; then
            kill -9 "${pid}" 2>/dev/null
        fi
        _update_process "${hostname}" "killed"
        tm_log "INFO" "Service: killed backup for ${hostname} (PID ${pid})"
        return 0
    else
        _update_process "${hostname}" "completed"
        tm_log "WARN" "Process ${pid} for ${hostname} was not running"
        return 1
    fi
}

# ============================================================
# SCHEDULER
# ============================================================

# Parse --priority N from a server line (default 10)
_parse_priority() {
    local line="$1"
    if echo "${line}" | grep -qo '\-\-priority[[:space:]]\+[0-9]\+'; then
        echo "${line}" | grep -o '\-\-priority[[:space:]]\+[0-9]\+' | awk '{print $2}'
    else
        echo "10"
    fi
}

# Parse --db-interval Xh from a server line (returns hours, empty if not set)
_parse_db_interval() {
    local line="$1"
    if echo "${line}" | grep -qo '\-\-db-interval[[:space:]]\+[0-9]\+h'; then
        echo "${line}" | grep -o '\-\-db-interval[[:space:]]\+[0-9]\+h' | grep -o '[0-9]\+'
    fi
}

# Get sorted server lines (by priority, ascending)
_get_sorted_servers() {
    local servers_conf="$1"
    [[ -f "${servers_conf}" ]] || return 0
    grep -E '^\s*[^#\s]' "${servers_conf}" 2>/dev/null | \
        sed 's/^[[:space:]]*//' | \
        while IFS= read -r line; do
            local prio
            prio=$(_parse_priority "${line}")
            printf '%03d|%s\n' "${prio}" "${line}"
        done | sort -t'|' -k1,1n | cut -d'|' -f2-
}

# Wait until running jobs drop below parallel limit
_wait_for_slot() {
    local running
    running=$(find "${STATE_DIR}" -name "proc-*.state" -exec grep -l "|running$" {} \; 2>/dev/null | wc -l | tr -d ' ')
    while [[ ${running} -ge ${TM_PARALLEL_JOBS} ]]; do
        sleep 10
        running=$(find "${STATE_DIR}" -name "proc-*.state" -exec grep -l "|running$" {} \; 2>/dev/null | wc -l | tr -d ' ')
    done
}

# Check and run DB-interval backups for servers that need them
_check_db_intervals() {
    local servers_conf="$1"
    [[ -f "${servers_conf}" ]] || return 0

    grep -E '^\s*[^#\s]' "${servers_conf}" 2>/dev/null | \
        sed 's/^[[:space:]]*//' | while IFS= read -r line; do
            local interval_hours
            interval_hours=$(_parse_db_interval "${line}")
            [[ -z "${interval_hours}" ]] && continue

            local srv_host
            srv_host=$(echo "${line}" | awk '{print $1}')
            local last_db_file="${STATE_DIR}/last-db-${srv_host}"
            local now
            now=$(date +%s)

            local last_db=0
            [[ -f "${last_db_file}" ]] && last_db=$(cat "${last_db_file}")

            local interval_secs=$(( interval_hours * 3600 ))
            local elapsed=$(( now - last_db ))

            if [[ ${elapsed} -ge ${interval_secs} ]]; then
                tm_log "INFO" "Scheduler: DB interval backup for ${srv_host} (every ${interval_hours}h)"
                _wait_for_slot
                local db_start
                db_start=$(date +%s)
                local db_pid
                db_pid=$(run_backup "${srv_host}" --db-only)
                echo "${now}" > "${last_db_file}"

                # Wait for DB backup to finish and report
                if [[ -n "${db_pid}" ]]; then
                    wait "${db_pid}" 2>/dev/null || true
                    local db_rc=$?
                    local db_end
                    db_end=$(date +%s)
                    local db_dur
                    db_dur=$(_tm_format_duration $(( db_end - db_start )))
                    if [[ ${db_rc} -eq 0 ]]; then
                        tm_notify "DB Interval OK: ${srv_host}" \
                            "Scheduled DB backup for ${srv_host} completed successfully (${db_dur})" "info"
                    else
                        tm_notify "DB Interval FAILED: ${srv_host}" \
                            "Scheduled DB backup for ${srv_host} failed (exit code ${db_rc}, ${db_dur})" "error"
                    fi
                fi
            fi
        done
}

_scheduler_loop() {
    # CRITICAL: disable set -e inside the scheduler loop.
    # The loop runs in a background subshell and inherits set -euo pipefail
    # from common.sh. Any unhandled non-zero exit (e.g. grep finding no
    # matches, missing servers.conf, failed daily-jobs-check.sh) would
    # silently kill the entire scheduler, preventing all daily backups.
    set +e

    local servers_conf="${TM_PROJECT_ROOT}/config/servers.conf"
    local last_run_file="${STATE_DIR}/last-daily-run"
    local _loop_count=0

    while true; do
        _loop_count=$(( _loop_count + 1 ))

        # Heartbeat log every 30 minutes (every 30 iterations of 60s sleep)
        if [[ $(( _loop_count % 30 )) -eq 1 ]]; then
            tm_log "DEBUG" "Scheduler: heartbeat (loop #${_loop_count}, schedule=${TM_SCHEDULE_HOUR:-11}:$(printf '%02d' "${TM_SCHEDULE_MINUTE:-0}"))"
        fi

        # Check if daily run is due
        local today
        today=$(tm_date_today)
        local last_run=""
        [[ -f "${last_run_file}" ]] && last_run=$(cat "${last_run_file}" 2>/dev/null)

        local current_hour current_minute
        current_hour=$(date +'%H')
        current_minute=$(date +'%M')
        local schedule_hour="${TM_SCHEDULE_HOUR:-11}"
        local schedule_minute="${TM_SCHEDULE_MINUTE:-0}"
        local current_time=$((10#${current_hour} * 60 + 10#${current_minute}))
        local schedule_time=$((10#${schedule_hour} * 60 + 10#${schedule_minute}))

        if [[ "${last_run}" != "${today}" && ${current_time} -ge ${schedule_time} ]]; then
            tm_log "INFO" "Scheduler: triggering daily backup run (time=${current_hour}:${current_minute}, schedule=${schedule_hour}:$(printf '%02d' "${schedule_minute}"))"

            if "${SCRIPT_DIR}/daily-jobs-check.sh" >> "${TM_LOG_DIR}/scheduler.log" 2>&1; then
                # Use daily-runner.sh which handles priority sorting,
                # parallel execution, per-server tracking, and report generation
                "${SCRIPT_DIR}/daily-runner.sh" >> "${TM_LOG_DIR}/scheduler.log" 2>&1 || true
                echo "${today}" > "${last_run_file}"
                tm_log "INFO" "Scheduler: daily run completed, marked ${today}"

                # Reset DB interval timestamps after daily run
                # (daily run already includes DB backup)
                local now
                now=$(date +%s)
                grep -E '^\s*[^#\s]' "${servers_conf}" 2>/dev/null | \
                    sed 's/^[[:space:]]*//' | while IFS= read -r line; do
                        local interval_hours
                        interval_hours=$(_parse_db_interval "${line}")
                        [[ -z "${interval_hours}" ]] && continue
                        local srv_host
                        srv_host=$(echo "${line}" | awk '{print $1}')
                        echo "${now}" > "${STATE_DIR}/last-db-${srv_host}"
                    done
            else
                tm_log "ERROR" "Scheduler: pre-backup check failed (previous backups still running?)"
            fi
        fi

        # Check DB interval backups (runs every minute)
        _check_db_intervals "${servers_conf}" || true

        # Check if config reload was requested (e.g. after settings save)
        if [[ -f "${STATE_DIR}/.reload_config" ]]; then
            rm -f "${STATE_DIR}/.reload_config"
            tm_log "INFO" "Scheduler: reloading configuration"
            tm_load_config
            _generate_handler_script 2>/dev/null || true
            tm_log "INFO" "Scheduler: handler script regenerated with new config"
        fi

        sleep 60
    done
}

# ============================================================
# HTTP API SERVER (using bash + socat/nc)
# ============================================================

# Minimal HTTP server using bash
# For production, consider replacing with a proper HTTP server
_http_response() {
    local status="$1"
    local content_type="$2"
    local body="$3"
    local body_length=${#body}

    # Use byte count (not char count) for Content-Length
    body_length=$(printf '%s' "${body}" | wc -c)

    printf "HTTP/1.1 %s\r\n" "${status}"
    printf "Content-Type: %s\r\n" "${content_type}"
    printf "Content-Length: %d\r\n" "${body_length}"
    printf "Access-Control-Allow-Origin: *\r\n"
    printf "Access-Control-Allow-Methods: GET, POST, PUT, DELETE\r\n"
    printf "Access-Control-Allow-Headers: Content-Type\r\n"
    printf "Connection: close\r\n"
    printf "\r\n"
    printf "%s" "${body}"
}

_handle_request() {
    local request_line=""
    local content_length=0
    local body=""

    # Read request line (5s timeout to prevent hangs)
    if ! read -r -t 5 request_line; then
        _http_response "408 Request Timeout" "text/plain" "Request timeout"
        return
    fi
    request_line="${request_line//$'\r'/}"

    local method path
    method="${request_line%% *}"
    path="${request_line#* }"
    path="${path%% *}"

    # Read headers (5s timeout per line)
    while read -r -t 5 header; do
        header="${header//$'\r'/}"
        [[ -z "${header}" ]] && break
        case "${header,,}" in
            content-length:*) content_length="${header#*: }"; content_length="${content_length// /}" ;;
        esac
    done

    # Read body if present
    if [[ ${content_length} -gt 0 ]]; then
        body=$(head -c "${content_length}")
    fi

    # Route requests
    case "${method} ${path}" in
        "GET /api/status")
            local procs
            procs=$(_get_processes_json)
            local uptime_secs
            uptime_secs=$(( $(date +%s) - SERVICE_START_TIME ))
            local resp
            local ver
            ver=$(cat "${TM_PROJECT_ROOT}/VERSION" 2>/dev/null || echo "unknown")
            ver=$(echo "${ver}" | tr -d '[:space:]')
            resp=$(printf '{"status":"running","uptime":%d,"hostname":"%s","version":"%s","processes":%s}' \
                "${uptime_secs}" "$(hostname)" "${ver}" "${procs}")
            _http_response "200 OK" "application/json" "${resp}"
            ;;

        "GET /api/processes")
            local procs
            procs=$(_get_processes_json)
            _http_response "200 OK" "application/json" "${procs}"
            ;;

        "POST /api/backup/"*)
            local target_host="${path#/api/backup/}"
            target_host=$(echo "${target_host}" | cut -d'?' -f1)
            # Parse query params for options
            local opts=""
            local query="${path#*\?}"
            if [[ "${query}" != "${path}" ]]; then
                [[ "${query}" == *"files-only"* ]] && opts+=" --files-only"
                [[ "${query}" == *"db-only"* ]] && opts+=" --db-only"
            fi
            local pid
            pid=$(run_backup "${target_host}" ${opts})
            _http_response "200 OK" "application/json" \
                "{\"status\":\"started\",\"hostname\":\"${target_host}\",\"pid\":${pid}}"
            ;;

        "DELETE /api/backup/"*)
            local target_host="${path#/api/backup/}"
            if kill_backup "${target_host}"; then
                _http_response "200 OK" "application/json" \
                    "{\"status\":\"killed\",\"hostname\":\"${target_host}\"}"
            else
                _http_response "404 Not Found" "application/json" \
                    "{\"error\":\"No running process for ${target_host}\"}"
            fi
            ;;

        "GET /api/snapshots/"*)
            local target_host="${path#/api/snapshots/}"
            local snap_dir="${TM_BACKUP_ROOT}/${target_host}"
            local snaps='['
            local first=1
            # Only show snapshots from the last 3 months
            local cutoff_date
            cutoff_date=$(date -d '3 months ago' '+%Y-%m-%d' 2>/dev/null || \
                          date -v-3m '+%Y-%m-%d' 2>/dev/null || echo "0000-00-00")
            if [[ -d "${snap_dir}" ]]; then
                for d in "${snap_dir}"/????-??-??; do
                    [[ -d "${d}" ]] || continue
                    local dn
                    dn=$(basename "${d}")
                    # Skip snapshots older than 3 months
                    [[ "${dn}" < "${cutoff_date}" ]] && continue
                    local sz
                    sz=$(du -sh "${d}" 2>/dev/null | cut -f1)
                    local hf="false" hd="false"
                    [[ -d "${d}/files" ]] && hf="true"
                    # Only mark as having DB backups if sql/ contains actual dump files
                    if [[ -d "${d}/sql" ]]; then
                        local db_file_count
                        db_file_count=$(find "${d}/sql" -type f 2>/dev/null | wc -l | tr -d ' ')
                        [[ ${db_file_count} -gt 0 ]] && hd="true"
                    fi
                    [[ ${first} -eq 1 ]] && first=0 || snaps+=','
                    snaps+=$(printf '{"date":"%s","size":"%s","has_files":%s,"has_db":%s}' \
                        "${dn}" "${sz}" "${hf}" "${hd}")
                done
            fi
            snaps+=']'
            _http_response "200 OK" "application/json" "${snaps}"
            ;;

        "GET /api/browse/"*)
            # Browse files in a snapshot: /api/browse/<hostname>/<date>/<path>
            local browse_path="${path#/api/browse/}"
            local target_host="${browse_path%%/*}"
            browse_path="${browse_path#*/}"
            local snap_date="${browse_path%%/*}"
            local sub_path="${browse_path#*/}"
            # If sub_path equals snap_date, there's no sub_path
            [[ "${sub_path}" == "${snap_date}" ]] && sub_path=""

            local base_dir="${TM_BACKUP_ROOT}/${target_host}/${snap_date}"
            # Default to files/ subdirectory, but allow browsing sql/ too
            local browse_dir="${base_dir}/files"
            if [[ "${sub_path}" == sql* ]]; then
                browse_dir="${base_dir}/${sub_path}"
                sub_path=""
            elif [[ -n "${sub_path}" ]]; then
                browse_dir="${base_dir}/files/${sub_path}"
            fi

            # URL-decode the path (basic: replace %20 with space, etc.)
            browse_dir=$(printf '%b' "${browse_dir//%/\\x}")

            if [[ ! -d "${base_dir}" ]]; then
                _http_response "404 Not Found" "application/json" \
                    "{\"error\":\"Snapshot not found: ${target_host}/${snap_date}\"}"
            elif [[ ! -d "${browse_dir}" ]]; then
                _http_response "404 Not Found" "application/json" \
                    "{\"error\":\"Path not found\"}"
            else
                local items='['
                local first=1
                # List directories first, then files
                while IFS= read -r entry; do
                    [[ -z "${entry}" ]] && continue
                    local name type size
                    name=$(basename "${entry}")
                    if [[ -d "${entry}" ]]; then
                        type="dir"
                        size=$(du -sh "${entry}" 2>/dev/null | cut -f1)
                    else
                        type="file"
                        size=$(du -sh "${entry}" 2>/dev/null | cut -f1)
                    fi
                    name=$(echo "${name}" | sed 's/"/\\"/g')
                    [[ ${first} -eq 1 ]] && first=0 || items+=','
                    items+=$(printf '{"name":"%s","type":"%s","size":"%s"}' "${name}" "${type}" "${size}")
                done < <(find "${browse_dir}" -maxdepth 1 -mindepth 1 2>/dev/null | sort)
                items+=']'

                # Also include info about what we're browsing
                local rel_path="${browse_dir#${base_dir}/}"
                local resp
                resp=$(printf '{"hostname":"%s","snapshot":"%s","path":"%s","items":%s}' \
                    "${target_host}" "${snap_date}" "${rel_path}" "${items}")
                _http_response "200 OK" "application/json" "${resp}"
            fi
            ;;

        "GET /api/download/"*)
            # Download archive of a path: /api/download/<hostname>/<date>/<path>?format=zip|tar.gz
            local dl_path="${path#/api/download/}"
            local target_host="${dl_path%%/*}"
            dl_path="${dl_path#*/}"
            local snap_date="${dl_path%%/*}"
            local sub_path="${dl_path#*/}"
            # Strip query string from sub_path
            local dl_query="${sub_path#*\?}"
            sub_path="${sub_path%%\?*}"
            [[ "${sub_path}" == "${snap_date}" ]] && sub_path="files"

            # Parse format from query string (default: tar.gz)
            local dl_format="tar.gz"
            if [[ "${dl_query}" == *"format=zip"* ]]; then
                dl_format="zip"
            fi

            local base_dir="${TM_BACKUP_ROOT}/${target_host}/${snap_date}"
            local target_dir="${base_dir}/${sub_path}"
            target_dir=$(printf '%b' "${target_dir//%/\\x}")

            if [[ ! -e "${target_dir}" ]]; then
                _http_response "404 Not Found" "application/json" \
                    "{\"error\":\"Path not found\"}"
            else
                local base_name="${target_host}-${snap_date}-$(basename "${sub_path}")"
                local tmp_archive=""
                local content_type=""
                local archive_name=""

                if [[ "${dl_format}" == "zip" ]] && command -v zip &>/dev/null; then
                    tmp_archive="/tmp/tm-download-$$.zip"
                    archive_name="${base_name}.zip"
                    content_type="application/zip"
                    (cd "$(dirname "${target_dir}")" && zip -r "${tmp_archive}" "$(basename "${target_dir}")") &>/dev/null
                elif command -v tar &>/dev/null; then
                    tmp_archive="/tmp/tm-download-$$.tar.gz"
                    archive_name="${base_name}.tar.gz"
                    content_type="application/gzip"
                    tar -czf "${tmp_archive}" -C "$(dirname "${target_dir}")" "$(basename "${target_dir}")" 2>/dev/null
                else
                    _http_response "500 Internal Server Error" "application/json" \
                        '{"error":"Neither zip nor tar available on server"}'
                fi

                if [[ -n "${tmp_archive}" && -f "${tmp_archive}" ]]; then
                    local file_size
                    file_size=$(wc -c < "${tmp_archive}" | tr -d ' ')
                    printf "HTTP/1.1 200 OK\r\n"
                    printf "Content-Type: %s\r\n" "${content_type}"
                    printf "Content-Disposition: attachment; filename=\"%s\"\r\n" "${archive_name}"
                    printf "Content-Length: %d\r\n" "${file_size}"
                    printf "Access-Control-Allow-Origin: *\r\n"
                    printf "Connection: close\r\n"
                    printf "\r\n"
                    cat "${tmp_archive}"
                    rm -f "${tmp_archive}"
                elif [[ -n "${tmp_archive}" ]]; then
                    _http_response "500 Internal Server Error" "application/json" \
                        '{"error":"Failed to create archive"}'
                fi
            fi
            ;;

        "POST /api/restore/"*)
            # Restore files to server: /api/restore/<hostname>
            local target_host="${path#/api/restore/}"
            target_host=$(echo "${target_host}" | cut -d'?' -f1)

            # Parse JSON body: snapshot, path, target, mode, format
            local snap_date rest_path rest_target rest_mode rest_format
            snap_date=$(echo "${body}" | grep -o '"snapshot":"[^"]*"' | cut -d'"' -f4)
            rest_path=$(echo "${body}" | grep -o '"path":"[^"]*"' | cut -d'"' -f4)
            rest_target=$(echo "${body}" | grep -o '"target":"[^"]*"' | cut -d'"' -f4)
            rest_mode=$(echo "${body}" | grep -o '"mode":"[^"]*"' | cut -d'"' -f4)
            rest_format=$(echo "${body}" | grep -o '"format":"[^"]*"' | cut -d'"' -f4)

            if [[ -z "${snap_date}" ]]; then
                _http_response "400 Bad Request" "application/json" \
                    '{"error":"snapshot date is required"}'
            else
                local opts="--date ${snap_date} --no-confirm"
                [[ -n "${rest_path}" ]] && opts+=" --path ${rest_path}"
                [[ -n "${rest_target}" ]] && opts+=" --target ${rest_target}"
                [[ -n "${rest_format}" ]] && opts+=" --format ${rest_format}"
                case "${rest_mode}" in
                    files-only) opts+=" --files-only" ;;
                    db-only)    opts+=" --db-only" ;;
                esac

                # Run restore in background
                local ts
                ts=$(date +'%Y-%m-%d_%H%M%S')
                local logfile="${TM_LOG_DIR}/restore-${target_host}-${ts}.log"

                (
                    local exit_code=0
                    "${SCRIPT_DIR}/restore.sh" "${target_host}" ${opts} >> "${logfile}" 2>&1 || exit_code=$?
                    # Update state file when done
                    local state_file="${STATE_DIR}/restore-${target_host}-${ts}.state"
                    if [[ ${exit_code} -eq 0 ]]; then
                        sed -i.bak 's/|running|/|completed|/' "${state_file}" 2>/dev/null || \
                        sed -i '' 's/|running|/|completed|/' "${state_file}" 2>/dev/null
                    else
                        sed -i.bak 's/|running|/|failed|/' "${state_file}" 2>/dev/null || \
                        sed -i '' 's/|running|/|failed|/' "${state_file}" 2>/dev/null
                    fi
                    rm -f "${state_file}.bak"
                ) &
                local rpid=$!

                # Register restore process state
                local rest_desc="${snap_date}"
                [[ -n "${rest_path}" ]] && rest_desc+=" ${rest_path}"
                [[ -n "${rest_target}" ]] && rest_desc+=" -> ${rest_target}"
                local started_ts
                started_ts=$(date +'%Y-%m-%d %H:%M:%S')
                echo "${rpid}|${target_host}|${rest_desc}|${started_ts}|running|${logfile}" > "${STATE_DIR}/restore-${target_host}-${ts}.state"

                tm_log "INFO" "API: restore started for ${target_host} (PID ${rpid}, snapshot ${snap_date})"
                _http_response "200 OK" "application/json" \
                    "{\"status\":\"started\",\"hostname\":\"${target_host}\",\"pid\":${rpid},\"snapshot\":\"${snap_date}\",\"logfile\":\"$(basename "${logfile}")\"}"
            fi
            ;;

        "DELETE /api/restores")
            # Clear all finished restore tasks
            local cleared=0
            for sf in "${STATE_DIR}"/restore-*.state; do
                [[ -f "${sf}" ]] || continue
                local sf_status sf_pid
                sf_status=$(cut -d'|' -f5 "${sf}")
                sf_pid=$(cut -d'|' -f1 "${sf}")
                if [[ "${sf_status}" == "running" ]] && kill -0 "${sf_pid}" 2>/dev/null; then
                    continue
                fi
                rm -f "${sf}"
                cleared=$((cleared + 1))
            done
            _http_response "200 OK" "application/json" \
                "{\"status\":\"cleared\",\"count\":${cleared}}"
            ;;

        "GET /api/restores")
            # List all restore tasks from last 30 days
            local restores='['
            local first=1
            local cutoff_epoch
            cutoff_epoch=$(date -d '30 days ago' +%s 2>/dev/null || date -v-30d +%s 2>/dev/null || echo 0)
            for sf in $(ls -t "${STATE_DIR}"/restore-*.state 2>/dev/null); do
                [[ -f "${sf}" ]] || continue
                local content
                content=$(cat "${sf}")
                local rpid rhost rdesc rstarted rstatus rlogfile
                rpid=$(echo "${content}" | cut -d'|' -f1)
                rhost=$(echo "${content}" | cut -d'|' -f2)
                rdesc=$(echo "${content}" | cut -d'|' -f3)
                rstarted=$(echo "${content}" | cut -d'|' -f4)
                rstatus=$(echo "${content}" | cut -d'|' -f5)
                rlogfile=$(echo "${content}" | cut -d'|' -f6)

                # Skip entries older than 30 days
                if [[ -n "${rstarted}" && ${cutoff_epoch} -gt 0 ]]; then
                    local started_epoch
                    started_epoch=$(date -d "${rstarted}" +%s 2>/dev/null || date -j -f '%Y-%m-%d %H:%M:%S' "${rstarted}" +%s 2>/dev/null || echo 0)
                    [[ ${started_epoch} -lt ${cutoff_epoch} ]] && continue
                fi

                # Check if running process is actually still alive
                if [[ "${rstatus}" == "running" ]] && ! kill -0 "${rpid}" 2>/dev/null; then
                    # Check log for errors
                    if [[ -n "${rlogfile}" && -f "${rlogfile}" ]] && tail -30 "${rlogfile}" 2>/dev/null | grep -qiE '(\[ERROR\]|FAIL|fatal)'; then
                        rstatus="failed"
                    else
                        rstatus="completed"
                    fi
                    sed -i.bak "s/|running|/|${rstatus}|/" "${sf}" 2>/dev/null || \
                    sed -i '' "s/|running|/|${rstatus}|/" "${sf}" 2>/dev/null
                    rm -f "${sf}.bak"
                fi

                # Escape description for JSON
                rdesc=$(echo "${rdesc}" | sed 's/"/\\"/g')
                local rid
                rid=$(basename "${sf}" .state)
                [[ ${first} -eq 1 ]] && first=0 || restores+=','
                restores+=$(printf '{"id":"%s","pid":%s,"hostname":"%s","description":"%s","started":"%s","status":"%s","logfile":"%s"}' \
                    "${rid}" "${rpid}" "${rhost}" "${rdesc}" "${rstarted}" "${rstatus}" "$(basename "${rlogfile:-}" 2>/dev/null)")
            done
            restores+=']'
            _http_response "200 OK" "application/json" "${restores}"
            ;;

        "GET /api/restore-log/"*)
            # View a specific restore log file
            local log_name="${path#/api/restore-log/}"
            local logfile="${TM_LOG_DIR}/${log_name}"

            if [[ ! -f "${logfile}" ]]; then
                _http_response "404 Not Found" "application/json" \
                    "{\"error\":\"Log file not found: ${log_name}\"}"
            else
                local content
                content=$(tail -500 "${logfile}" | tr -d '\r' | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g' | sed ':a;N;$!ba;s/\n/\\n/g')

                # Check if restore is still running
                local is_running="false"
                for sf in "${STATE_DIR}"/restore-*.state; do
                    [[ -f "${sf}" ]] || continue
                    local sf_log sf_status sf_pid
                    sf_log=$(basename "$(cut -d'|' -f6 "${sf}")" 2>/dev/null)
                    sf_status=$(cut -d'|' -f5 "${sf}")
                    sf_pid=$(cut -d'|' -f1 "${sf}")
                    if [[ "${sf_log}" == "${log_name}" && "${sf_status}" == "running" ]] && kill -0 "${sf_pid}" 2>/dev/null; then
                        is_running="true"
                        break
                    fi
                done

                _http_response "200 OK" "application/json" \
                    "{\"logfile\":\"${log_name}\",\"lines\":\"${content}\",\"running\":${is_running}}"
            fi
            ;;

        "DELETE /api/restore/"*)
            # Delete a restore task state file (and optionally its log)
            local restore_id="${path#/api/restore/}"
            local found=0
            for sf in "${STATE_DIR}"/restore-*.state; do
                [[ -f "${sf}" ]] || continue
                local sf_base
                sf_base=$(basename "${sf}" .state)
                if [[ "${sf_base}" == "${restore_id}" ]]; then
                    # Don't delete running tasks
                    local sf_status sf_pid
                    sf_status=$(cut -d'|' -f5 "${sf}")
                    sf_pid=$(cut -d'|' -f1 "${sf}")
                    if [[ "${sf_status}" == "running" ]] && kill -0 "${sf_pid}" 2>/dev/null; then
                        _http_response "409 Conflict" "application/json" \
                            '{"error":"Cannot delete a running restore task"}'
                        found=2
                        break
                    fi
                    # Remove state file and optionally log file
                    local sf_log
                    sf_log=$(cut -d'|' -f6 "${sf}")
                    rm -f "${sf}"
                    [[ -n "${sf_log}" && -f "${sf_log}" ]] && rm -f "${sf_log}"
                    found=1
                    break
                fi
            done
            if [[ ${found} -eq 1 ]]; then
                _http_response "200 OK" "application/json" \
                    '{"status":"deleted"}'
            elif [[ ${found} -eq 0 ]]; then
                _http_response "404 Not Found" "application/json" \
                    '{"error":"Restore task not found"}'
            fi
            ;;

        "GET /api/servers")
            local servers_conf="${TM_PROJECT_ROOT}/config/servers.conf"
            local servers='['
            local first=1
            if [[ -f "${servers_conf}" ]]; then
                while IFS= read -r line; do
                    line=$(echo "${line}" | sed 's/^[[:space:]]*//')
                    [[ -z "${line}" || "${line}" == \#* ]] && continue
                    local srv_host
                    srv_host=$(echo "${line}" | awk '{print $1}')
                    local srv_opts
                    srv_opts=$(echo "${line}" | cut -d' ' -f2- | sed 's/^[[:space:]]*//')
                    [[ "${srv_opts}" == "${srv_host}" ]] && srv_opts=""
                    local srv_prio
                    srv_prio=$(_parse_priority "${line}")
                    local srv_db_int
                    srv_db_int=$(_parse_db_interval "${line}")
                    [[ -z "${srv_db_int}" ]] && srv_db_int="0"
                    local srv_files_only="false" srv_db_only="false" srv_no_rotate="false"
                    echo "${srv_opts}" | grep -q '\-\-files-only' && srv_files_only="true"
                    echo "${srv_opts}" | grep -q '\-\-db-only' && srv_db_only="true"
                    echo "${srv_opts}" | grep -q '\-\-no-rotate' && srv_no_rotate="true"
                    local srv_notify=""
                    srv_notify=$(echo "${srv_opts}" | grep -oP '(?<=--notify\s)\S+' 2>/dev/null || \
                        echo "${srv_opts}" | sed -n 's/.*--notify[[:space:]]\+\([^[:space:]]*\).*/\1/p')
                    [[ ${first} -eq 1 ]] && first=0 || servers+=','
                    servers+=$(printf '{"hostname":"%s","options":"%s","priority":%s,"db_interval":%s,"files_only":%s,"db_only":%s,"no_rotate":%s,"notify_email":"%s"}' \
                        "${srv_host}" "${srv_opts}" "${srv_prio}" "${srv_db_int}" "${srv_files_only}" "${srv_db_only}" "${srv_no_rotate}" "${srv_notify}")
                done < "${servers_conf}"
            fi
            servers+=']'
            _http_response "200 OK" "application/json" "${servers}"
            ;;

        "POST /api/servers")
            local servers_conf="${TM_PROJECT_ROOT}/config/servers.conf"
            # Parse hostname and options from JSON body
            local new_host new_opts
            new_host=$(echo "${body}" | grep -o '"hostname":"[^"]*"' | cut -d'"' -f4)
            new_opts=$(echo "${body}" | grep -o '"options":"[^"]*"' | cut -d'"' -f4)

            if [[ -z "${new_host}" ]]; then
                _http_response "400 Bad Request" "application/json" \
                    '{"error":"hostname is required"}'
            else
                # Create file if it doesn't exist
                [[ ! -f "${servers_conf}" ]] && touch "${servers_conf}"

                # Check for duplicates
                if grep -qE "^\s*${new_host}(\s|$)" "${servers_conf}" 2>/dev/null; then
                    _http_response "409 Conflict" "application/json" \
                        "{\"error\":\"Server '${new_host}' already exists\"}"
                else
                    local entry="${new_host}"
                    [[ -n "${new_opts}" ]] && entry="${new_host} ${new_opts}"
                    echo "${entry}" >> "${servers_conf}"
                    tm_log "INFO" "API: added server ${new_host}"
                    _http_response "201 Created" "application/json" \
                        "{\"status\":\"added\",\"hostname\":\"${new_host}\",\"options\":\"${new_opts}\"}"
                fi
            fi
            ;;

        "PUT /api/servers/"*)
            local servers_conf="${TM_PROJECT_ROOT}/config/servers.conf"
            local target_host="${path#/api/servers/}"

            if [[ ! -f "${servers_conf}" ]]; then
                _http_response "404 Not Found" "application/json" \
                    '{"error":"No servers.conf found"}'
            elif ! grep -qE "^\s*${target_host}(\s|$)" "${servers_conf}" 2>/dev/null; then
                _http_response "404 Not Found" "application/json" \
                    "{\"error\":\"Server '${target_host}' not found\"}"
            else
                # Parse settings from JSON body
                local new_prio new_db_int new_mode new_no_rotate new_notify
                new_prio=$(echo "${body}" | grep -o '"priority":[0-9]*' | cut -d: -f2)
                new_db_int=$(echo "${body}" | grep -o '"db_interval":[0-9]*' | cut -d: -f2)
                new_mode=$(echo "${body}" | grep -o '"mode":"[^"]*"' | cut -d'"' -f4)
                new_no_rotate=$(echo "${body}" | grep -o '"no_rotate":[a-z]*' | cut -d: -f2)
                new_notify=$(echo "${body}" | grep -o '"notify_email":"[^"]*"' | cut -d'"' -f4)

                # Build new options string
                local opts=""
                [[ -n "${new_prio}" ]] && opts+="--priority ${new_prio} "
                [[ -n "${new_db_int}" && "${new_db_int}" != "0" ]] && opts+="--db-interval ${new_db_int}h "
                case "${new_mode}" in
                    files-only) opts+="--files-only " ;;
                    db-only)    opts+="--db-only " ;;
                esac
                [[ "${new_no_rotate}" == "true" ]] && opts+="--no-rotate "
                [[ -n "${new_notify}" ]] && opts+="--notify ${new_notify} "
                opts=$(echo "${opts}" | sed 's/ *$//')

                # Build new line
                local new_line="${target_host}"
                [[ -n "${opts}" ]] && new_line="${target_host} ${opts}"

                # Replace in file
                sed -i.bak "/^[[:space:]]*${target_host}[[:space:]]*$/c\\${new_line}" "${servers_conf}" 2>/dev/null
                sed -i.bak "/^[[:space:]]*${target_host}[[:space:]]/c\\${new_line}" "${servers_conf}" 2>/dev/null
                rm -f "${servers_conf}.bak"

                tm_log "INFO" "API: updated server ${target_host}: ${opts}"
                _http_response "200 OK" "application/json" \
                    "{\"status\":\"updated\",\"hostname\":\"${target_host}\",\"options\":\"${opts}\"}"
            fi
            ;;

        "DELETE /api/servers/"*)
            local servers_conf="${TM_PROJECT_ROOT}/config/servers.conf"
            local archived_conf="${TM_PROJECT_ROOT}/config/archived.conf"
            local target_host="${path#/api/servers/}"
            # Strip query string from hostname
            target_host="${target_host%%\?*}"
            # Parse action from query string
            local qs="${path#*\?}"
            [[ "${qs}" == "${path}" ]] && qs=""
            local action="archive"
            [[ "${qs}" == *"action=delete"* ]] && action="delete"
            [[ "${qs}" == *"action=archive"* ]] && action="archive"

            if [[ "${action}" == "archive" ]]; then
                # Archive: move from servers.conf to archived.conf
                if [[ ! -f "${servers_conf}" ]] || ! grep -qE "^\s*${target_host}(\s|$)" "${servers_conf}" 2>/dev/null; then
                    _http_response "404 Not Found" "application/json" \
                        "{\"error\":\"Server '${target_host}' not found in servers.conf\"}"
                else
                    local line_to_archive
                    line_to_archive=$(grep -E "^\s*${target_host}(\s|$)" "${servers_conf}" | head -1)
                    sed -i.bak "/^[[:space:]]*${target_host}[[:space:]]*$/d;/^[[:space:]]*${target_host}[[:space:]]/d" "${servers_conf}" 2>/dev/null || \
                    sed -i '' "/^[[:space:]]*${target_host}[[:space:]]*$/d;/^[[:space:]]*${target_host}[[:space:]]/d" "${servers_conf}"
                    rm -f "${servers_conf}.bak"
                    echo "${line_to_archive}" >> "${archived_conf}"
                    tm_log "INFO" "API: archived server ${target_host}"
                    _http_response "200 OK" "application/json" \
                        "{\"status\":\"archived\",\"hostname\":\"${target_host}\"}"
                fi
            else
                # Full delete: remove from both configs, delete data in background
                sed -i.bak "/^[[:space:]]*${target_host}[[:space:]]*$/d;/^[[:space:]]*${target_host}[[:space:]]/d" "${servers_conf}" 2>/dev/null || \
                sed -i '' "/^[[:space:]]*${target_host}[[:space:]]*$/d;/^[[:space:]]*${target_host}[[:space:]]/d" "${servers_conf}" 2>/dev/null
                rm -f "${servers_conf}.bak"
                if [[ -f "${archived_conf}" ]]; then
                    sed -i.bak "/^[[:space:]]*${target_host}[[:space:]]*$/d;/^[[:space:]]*${target_host}[[:space:]]/d" "${archived_conf}" 2>/dev/null || \
                    sed -i '' "/^[[:space:]]*${target_host}[[:space:]]*$/d;/^[[:space:]]*${target_host}[[:space:]]/d" "${archived_conf}" 2>/dev/null
                    rm -f "${archived_conf}.bak"
                fi
                rm -f "${TM_PROJECT_ROOT}/config/exclude.${target_host}.conf"
                # Background delete
                local snap_dir="${TM_BACKUP_ROOT}/${target_host}"
                if [[ -d "${snap_dir}" ]]; then
                    local del_state="${STATE_DIR}/delete-${target_host}.state"
                    echo "running|${target_host}|$(date +%s)" > "${del_state}"
                    ( rm -rf "${snap_dir}" 2>/dev/null && echo "completed|${target_host}|$(date +%s)" > "${del_state}" || echo "failed|${target_host}|$(date +%s)" > "${del_state}" ) &
                fi
                tm_log "INFO" "API: full delete server ${target_host} (data deletion in background)"
                _http_response "200 OK" "application/json" \
                    "{\"status\":\"deleting\",\"hostname\":\"${target_host}\",\"message\":\"Server removed. Backup data is being deleted in the background.\"}"
            fi
            ;;

        "GET /api/archived")
            local archived_conf="${TM_PROJECT_ROOT}/config/archived.conf"
            local resp='{"servers":['
            local first=1
            if [[ -f "${archived_conf}" ]]; then
                while IFS= read -r line; do
                    line=$(echo "${line}" | sed 's/^[[:space:]]*//')
                    [[ -z "${line}" || "${line}" == \#* ]] && continue
                    local ahost
                    ahost=$(echo "${line}" | awk '{print $1}')
                    local snap_dir="${TM_BACKUP_ROOT}/${ahost}"
                    local snap_count=0 last_bk="--" total_sz="--"
                    if [[ -d "${snap_dir}" ]]; then
                        snap_count=$(find "${snap_dir}" -maxdepth 1 -type d -name '20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]*' 2>/dev/null | wc -l | tr -d ' ')
                        last_bk=$(ls -1d "${snap_dir}"/20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]* 2>/dev/null | sort -r | head -1 | xargs basename 2>/dev/null || echo "--")
                        total_sz=$(du -sh "${snap_dir}" 2>/dev/null | cut -f1 || echo "--")
                    fi
                    [[ ${first} -eq 1 ]] && first=0 || resp+=','
                    resp+=$(printf '{"hostname":"%s","snapshots":%d,"last_backup":"%s","total_size":"%s"}' \
                        "${ahost}" "${snap_count}" "${last_bk}" "${total_sz}")
                done < "${archived_conf}"
            fi
            resp+='],"delete_tasks":['
            first=1
            for sf in "${STATE_DIR}"/delete-*.state; do
                [[ -f "${sf}" ]] || continue
                local dc
                dc=$(cat "${sf}")
                local dstatus dhost dtime
                dstatus=$(echo "${dc}" | cut -d'|' -f1)
                dhost=$(echo "${dc}" | cut -d'|' -f2)
                dtime=$(echo "${dc}" | cut -d'|' -f3)
                [[ ${first} -eq 1 ]] && first=0 || resp+=','
                resp+=$(printf '{"hostname":"%s","status":"%s","started":%s}' "${dhost}" "${dstatus}" "${dtime:-0}")
            done
            resp+=']}'
            _http_response "200 OK" "application/json" "${resp}"
            ;;

        "POST /api/archived/"*)
            local arch_path="${path#/api/archived/}"
            if [[ "${arch_path}" == */unarchive ]]; then
                local uhost="${arch_path%/unarchive}"
                local archived_conf="${TM_PROJECT_ROOT}/config/archived.conf"
                local servers_conf="${TM_PROJECT_ROOT}/config/servers.conf"
                if [[ ! -f "${archived_conf}" ]] || ! grep -qE "^\s*${uhost}(\s|$)" "${archived_conf}" 2>/dev/null; then
                    _http_response "404 Not Found" "application/json" \
                        "{\"error\":\"Server '${uhost}' not found in archive\"}"
                else
                    local line_to_restore
                    line_to_restore=$(grep -E "^\s*${uhost}(\s|$)" "${archived_conf}" | head -1)
                    sed -i.bak "/^[[:space:]]*${uhost}[[:space:]]*$/d;/^[[:space:]]*${uhost}[[:space:]]/d" "${archived_conf}" 2>/dev/null || \
                    sed -i '' "/^[[:space:]]*${uhost}[[:space:]]*$/d;/^[[:space:]]*${uhost}[[:space:]]/d" "${archived_conf}"
                    rm -f "${archived_conf}.bak"
                    echo "${line_to_restore}" >> "${servers_conf}"
                    tm_log "INFO" "API: unarchived server ${uhost}"
                    _http_response "200 OK" "application/json" \
                        "{\"status\":\"unarchived\",\"hostname\":\"${uhost}\"}"
                fi
            else
                _http_response "404 Not Found" "application/json" '{"error":"Not found"}'
            fi
            ;;

        "DELETE /api/archived/"*)
            local dhost="${path#/api/archived/}"
            local archived_conf="${TM_PROJECT_ROOT}/config/archived.conf"
            if [[ -f "${archived_conf}" ]]; then
                sed -i.bak "/^[[:space:]]*${dhost}[[:space:]]*$/d;/^[[:space:]]*${dhost}[[:space:]]/d" "${archived_conf}" 2>/dev/null || \
                sed -i '' "/^[[:space:]]*${dhost}[[:space:]]*$/d;/^[[:space:]]*${dhost}[[:space:]]/d" "${archived_conf}"
                rm -f "${archived_conf}.bak"
            fi
            rm -f "${TM_PROJECT_ROOT}/config/exclude.${dhost}.conf"
            local snap_dir="${TM_BACKUP_ROOT}/${dhost}"
            if [[ -d "${snap_dir}" ]]; then
                local del_state="${STATE_DIR}/delete-${dhost}.state"
                echo "running|${dhost}|$(date +%s)" > "${del_state}"
                ( rm -rf "${snap_dir}" 2>/dev/null && echo "completed|${dhost}|$(date +%s)" > "${del_state}" || echo "failed|${dhost}|$(date +%s)" > "${del_state}" ) &
            fi
            tm_log "INFO" "API: permanently deleting archived server ${dhost}"
            _http_response "200 OK" "application/json" \
                "{\"status\":\"deleting\",\"hostname\":\"${dhost}\",\"message\":\"Archived server removed. Backup data is being deleted in the background.\"}"
            ;;

        "GET /api/settings")
            local env_file="${TM_PROJECT_ROOT}/.env"
            # Helper: read a var from .env or fall back to current env
            _env_val() {
                local key="$1" default="$2"
                if [[ -f "${env_file}" ]]; then
                    local v
                    v=$(grep -E "^${key}=" "${env_file}" 2>/dev/null | tail -1 | cut -d'=' -f2-)
                    [[ -n "${v}" ]] && { echo "${v}"; return; }
                fi
                echo "${default}"
            }
            local resp
            resp=$(printf '{
                "schedule_hour":%s,
                "schedule_minute":%s,
                "retention_days":%s,
                "parallel_jobs":%s,
                "alert_enabled":"%s",
                "alert_email":"%s",
                "notify_backup_ok":"%s",
                "notify_backup_fail":"%s",
                "notify_restore_ok":"%s",
                "notify_restore_fail":"%s",
                "alert_email_backup_ok":"%s",
                "alert_email_backup_fail":"%s",
                "alert_email_restore_ok":"%s",
                "alert_email_restore_fail":"%s"
            }' \
                "$(_env_val TM_SCHEDULE_HOUR "${TM_SCHEDULE_HOUR:-11}")" \
                "$(_env_val TM_SCHEDULE_MINUTE "${TM_SCHEDULE_MINUTE:-0}")" \
                "$(_env_val TM_RETENTION_DAYS "${TM_RETENTION_DAYS:-7}")" \
                "$(_env_val TM_PARALLEL_JOBS "${TM_PARALLEL_JOBS:-5}")" \
                "$(_env_val TM_ALERT_ENABLED "${TM_ALERT_ENABLED:-false}")" \
                "$(_env_val TM_ALERT_EMAIL "${TM_ALERT_EMAIL:-}")" \
                "$(_env_val TM_NOTIFY_BACKUP_OK "${TM_NOTIFY_BACKUP_OK:-true}")" \
                "$(_env_val TM_NOTIFY_BACKUP_FAIL "${TM_NOTIFY_BACKUP_FAIL:-true}")" \
                "$(_env_val TM_NOTIFY_RESTORE_OK "${TM_NOTIFY_RESTORE_OK:-true}")" \
                "$(_env_val TM_NOTIFY_RESTORE_FAIL "${TM_NOTIFY_RESTORE_FAIL:-true}")" \
                "$(_env_val TM_ALERT_EMAIL_BACKUP_OK "${TM_ALERT_EMAIL_BACKUP_OK:-}")" \
                "$(_env_val TM_ALERT_EMAIL_BACKUP_FAIL "${TM_ALERT_EMAIL_BACKUP_FAIL:-}")" \
                "$(_env_val TM_ALERT_EMAIL_RESTORE_OK "${TM_ALERT_EMAIL_RESTORE_OK:-}")" \
                "$(_env_val TM_ALERT_EMAIL_RESTORE_FAIL "${TM_ALERT_EMAIL_RESTORE_FAIL:-}")" \
            )
            # Compact JSON (remove whitespace)
            resp=$(echo "${resp}" | tr -d '\n' | sed 's/  */ /g')
            _http_response "200 OK" "application/json" "${resp}"
            ;;

        "PUT /api/settings")
            local env_file="${TM_PROJECT_ROOT}/.env"
            [[ ! -f "${env_file}" ]] && touch "${env_file}"

            # Helper: update or append a key=value in .env and export
            _env_set() {
                local key="$1" val="$2"
                [[ -z "${val}" ]] && return
                if grep -q "^${key}=" "${env_file}" 2>/dev/null; then
                    sed -i.bak "s|^${key}=.*|${key}=${val}|" "${env_file}" 2>/dev/null || \
                    sed -i '' "s|^${key}=.*|${key}=${val}|" "${env_file}" 2>/dev/null
                    rm -f "${env_file}.bak"
                else
                    echo "${key}=${val}" >> "${env_file}"
                fi
                export "${key}=${val}"
            }

            # Extract all possible fields from JSON body
            local jv
            jv=$(echo "${body}" | grep -o '"schedule_hour":[0-9]*' | cut -d: -f2)
            [[ -n "${jv}" ]] && _env_set TM_SCHEDULE_HOUR "${jv}"
            jv=$(echo "${body}" | grep -o '"schedule_minute":[0-9]*' | cut -d: -f2)
            [[ -n "${jv}" ]] && _env_set TM_SCHEDULE_MINUTE "${jv}"
            jv=$(echo "${body}" | grep -o '"retention_days":[0-9]*' | cut -d: -f2)
            [[ -n "${jv}" ]] && _env_set TM_RETENTION_DAYS "${jv}"
            jv=$(echo "${body}" | grep -o '"parallel_jobs":[0-9]*' | cut -d: -f2)
            [[ -n "${jv}" ]] && _env_set TM_PARALLEL_JOBS "${jv}"
            jv=$(echo "${body}" | grep -o '"alert_enabled":"[^"]*"' | cut -d'"' -f4)
            [[ -n "${jv}" ]] && _env_set TM_ALERT_ENABLED "${jv}"
            jv=$(echo "${body}" | grep -o '"alert_email":"[^"]*"' | cut -d'"' -f4)
            [[ -n "${jv}" ]] && _env_set TM_ALERT_EMAIL "${jv}"
            # Allow clearing email by setting to empty
            if echo "${body}" | grep -q '"alert_email":""'; then
                _env_set TM_ALERT_EMAIL ""
            fi
            jv=$(echo "${body}" | grep -o '"notify_backup_ok":"[^"]*"' | cut -d'"' -f4)
            [[ -n "${jv}" ]] && _env_set TM_NOTIFY_BACKUP_OK "${jv}"
            jv=$(echo "${body}" | grep -o '"notify_backup_fail":"[^"]*"' | cut -d'"' -f4)
            [[ -n "${jv}" ]] && _env_set TM_NOTIFY_BACKUP_FAIL "${jv}"
            jv=$(echo "${body}" | grep -o '"notify_restore_ok":"[^"]*"' | cut -d'"' -f4)
            [[ -n "${jv}" ]] && _env_set TM_NOTIFY_RESTORE_OK "${jv}"
            jv=$(echo "${body}" | grep -o '"notify_restore_fail":"[^"]*"' | cut -d'"' -f4)
            [[ -n "${jv}" ]] && _env_set TM_NOTIFY_RESTORE_FAIL "${jv}"
            jv=$(echo "${body}" | grep -o '"alert_email_backup_ok":"[^"]*"' | cut -d'"' -f4)
            [[ -n "${jv}" ]] && _env_set TM_ALERT_EMAIL_BACKUP_OK "${jv}"
            jv=$(echo "${body}" | grep -o '"alert_email_backup_fail":"[^"]*"' | cut -d'"' -f4)
            [[ -n "${jv}" ]] && _env_set TM_ALERT_EMAIL_BACKUP_FAIL "${jv}"
            jv=$(echo "${body}" | grep -o '"alert_email_restore_ok":"[^"]*"' | cut -d'"' -f4)
            [[ -n "${jv}" ]] && _env_set TM_ALERT_EMAIL_RESTORE_OK "${jv}"
            jv=$(echo "${body}" | grep -o '"alert_email_restore_fail":"[^"]*"' | cut -d'"' -f4)
            [[ -n "${jv}" ]] && _env_set TM_ALERT_EMAIL_RESTORE_FAIL "${jv}"

            # Signal the scheduler to reload config and regenerate handler script
            touch "${STATE_DIR}/.reload_config" 2>/dev/null || true

            tm_log "INFO" "API: settings updated (reload scheduled)"
            _http_response "200 OK" "application/json" '{"status":"saved"}'
            ;;

        "GET /api/excludes")
            local excl_file="${TM_PROJECT_ROOT}/config/exclude.conf"
            local excl_content=""
            [[ -f "${excl_file}" ]] && excl_content=$(cat "${excl_file}" 2>/dev/null)
            # JSON-escape the content
            excl_content=$(echo "${excl_content}" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo '""')
            _http_response "200 OK" "application/json" \
                "{\"hostname\":\"__global__\",\"content\":${excl_content},\"path\":\"${excl_file}\"}"
            ;;

        "GET /api/excludes/"*)
            local excl_host="${path#/api/excludes/}"
            local excl_file="${TM_PROJECT_ROOT}/config/exclude.${excl_host}.conf"
            local excl_content=""
            [[ -f "${excl_file}" ]] && excl_content=$(cat "${excl_file}" 2>/dev/null)
            excl_content=$(echo "${excl_content}" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo '""')
            _http_response "200 OK" "application/json" \
                "{\"hostname\":\"${excl_host}\",\"content\":${excl_content},\"path\":\"${excl_file}\"}"
            ;;

        "PUT /api/excludes")
            local excl_file="${TM_PROJECT_ROOT}/config/exclude.conf"
            local excl_content
            excl_content=$(echo "${body}" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("content",""))' 2>/dev/null || echo "")
            echo "${excl_content}" > "${excl_file}"
            _http_response "200 OK" "application/json" '{"status":"saved"}'
            ;;

        "PUT /api/excludes/"*)
            local excl_host="${path#/api/excludes/}"
            local excl_file="${TM_PROJECT_ROOT}/config/exclude.${excl_host}.conf"
            local excl_content
            excl_content=$(echo "${body}" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("content",""))' 2>/dev/null || echo "")
            echo "${excl_content}" > "${excl_file}"
            _http_response "200 OK" "application/json" '{"status":"saved"}'
            ;;

        "GET /api/ssh-key")
            local pub_key_file="${TM_SSH_KEY}.pub"
            if [[ -f "${pub_key_file}" ]]; then
                local key_content
                key_content=$(cat "${pub_key_file}")
                _http_response "200 OK" "application/json" \
                    "{\"ssh_public_key\":\"${key_content}\",\"hostname\":\"$(hostname)\"}"
            else
                _http_response "404 Not Found" "application/json" \
                    "{\"error\":\"SSH public key not found\"}"
            fi
            ;;

        "GET /api/ssh-key/raw")
            local pub_key_file="${TM_SSH_KEY}.pub"
            if [[ -f "${pub_key_file}" ]]; then
                _http_response "200 OK" "text/plain" "$(cat "${pub_key_file}")"
            else
                _http_response "404 Not Found" "text/plain" "SSH public key not found"
            fi
            ;;

        "GET /api/logs/"*)
            local target_host="${path#/api/logs/}"
            # Find the latest per-backup log, fall back to old service-<host>.log
            local logfile=""
            logfile=$(ls -t "${TM_LOG_DIR}"/backup-"${target_host}"-*.log 2>/dev/null | head -1)
            if [[ -z "${logfile}" || ! -f "${logfile}" ]]; then
                logfile="${TM_LOG_DIR}/service-${target_host}.log"
            fi
            if [[ -f "${logfile}" ]]; then
                local content
                content=$(tail -500 "${logfile}" | tr -d '\r' | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g' | sed ':a;N;$!ba;s/\n/\\n/g')
                local log_name
                log_name=$(basename "${logfile}")
                # Check if a backup is currently running for this host
                local is_running="false"
                for sf in "${STATE_DIR}"/proc-*.state; do
                    [[ -f "${sf}" ]] || continue
                    local sf_host sf_status sf_pid
                    sf_host=$(cut -d'|' -f2 "${sf}")
                    sf_status=$(cut -d'|' -f5 "${sf}")
                    sf_pid=$(cut -d'|' -f1 "${sf}")
                    if [[ "${sf_host}" == "${target_host}" && "${sf_status}" == "running" ]] && kill -0 "${sf_pid}" 2>/dev/null; then
                        is_running="true"
                        break
                    fi
                done
                # List all available log files for this host
                local log_list='['
                local lfirst=1
                local lf
                for lf in $(ls -t "${TM_LOG_DIR}"/backup-"${target_host}"-*.log 2>/dev/null | head -30); do
                    [[ ${lfirst} -eq 1 ]] && lfirst=0 || log_list+=','
                    log_list+="\"$(basename "${lf}")\""
                done
                log_list+=']'
                _http_response "200 OK" "application/json" \
                    "{\"hostname\":\"${target_host}\",\"logfile\":\"${log_name}\",\"lines\":\"${content}\",\"running\":${is_running},\"available\":${log_list}}"
            else
                _http_response "404 Not Found" "application/json" \
                    "{\"error\":\"No logs for ${target_host}\"}"
            fi
            ;;

        "GET /api/system")
            # System metrics: CPU, load, memory, OS
            local load1 load5 load15
            read -r load1 load5 load15 _ < /proc/loadavg 2>/dev/null || { load1="0"; load5="0"; load15="0"; }
            local cpu_count
            cpu_count=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo "1")
            # Memory (in MB)
            local mem_total mem_avail mem_used mem_pct
            if [[ -f /proc/meminfo ]]; then
                mem_total=$(awk '/^MemTotal:/ {printf "%.0f", $2/1024}' /proc/meminfo)
                mem_avail=$(awk '/^MemAvailable:/ {printf "%.0f", $2/1024}' /proc/meminfo)
                mem_used=$((mem_total - mem_avail))
                mem_pct=$((mem_used * 100 / (mem_total > 0 ? mem_total : 1)))
            else
                mem_total=0; mem_avail=0; mem_used=0; mem_pct=0
            fi
            # OS info
            local os_name
            os_name=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME}" || uname -s)
            local kernel
            kernel=$(uname -r)
            local sys_uptime
            sys_uptime=$(awk '{printf "%.0f", $1}' /proc/uptime 2>/dev/null || echo "0")
            _http_response "200 OK" "application/json" \
                "$(printf '{"load1":"%s","load5":"%s","load15":"%s","cpu_count":%s,"mem_total":%s,"mem_used":%s,"mem_available":%s,"mem_percent":%s,"os":"%s","kernel":"%s","sys_uptime":%s}' \
                    "${load1}" "${load5}" "${load15}" "${cpu_count}" \
                    "${mem_total}" "${mem_used}" "${mem_avail}" "${mem_pct}" \
                    "${os_name}" "${kernel}" "${sys_uptime}")"
            ;;

        "GET /api/failures")
            # Recent failed backups — check per-backup logs and state files
            local failures='['
            local first=1
            if [[ -d "${TM_LOG_DIR}" ]]; then
                # Collect unique hostnames from per-backup logs
                local seen_hosts=""
                local logfile
                for logfile in $(ls -t "${TM_LOG_DIR}"/backup-*.log 2>/dev/null | head -50); do
                    [[ -f "${logfile}" ]] || continue
                    local lname
                    lname=$(basename "${logfile}" .log)
                    # Extract hostname: backup-<hostname>-<timestamp>
                    local lhost
                    lhost=$(echo "${lname}" | sed 's/^backup-//;s/-[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}_[0-9]\{6\}$//')
                    # Only check latest log per host
                    if echo "${seen_hosts}" | grep -qw "${lhost}" 2>/dev/null; then
                        continue
                    fi
                    seen_hosts="${seen_hosts} ${lhost}"
                    # Extract timestamp from log filename (backup-host-YYYY-MM-DD_HHMMSS)
                    local log_ts
                    log_ts=$(echo "${lname}" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$' | sed 's/_/ /;s/\(..\)\(..\)$/:\1:\2/')
                    [[ -z "${log_ts}" ]] && log_ts=$(stat -c '%Y' "${logfile}" 2>/dev/null | xargs -I{} date -d @{} +'%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "${logfile}" +'%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "")
                    # Check for errors in this log
                    local fail_lines
                    fail_lines=$(tail -50 "${logfile}" 2>/dev/null | grep -iE "(\[ERROR\]|FAIL|fatal|Permission denied|cannot create)" | tail -3)
                    while IFS= read -r fline; do
                        [[ -z "${fline}" ]] && continue
                        # Extract timestamp from log line if present [YYYY-MM-DD HH:MM:SS]
                        local line_ts
                        line_ts=$(echo "${fline}" | grep -oE '^\[?[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\]?' | tr -d '[]')
                        [[ -z "${line_ts}" ]] && line_ts="${log_ts}"
                        fline=$(echo "${fline}" | sed 's/"/\\"/g' | tr -d '\n')
                        [[ ${first} -eq 1 ]] && first=0 || failures+=','
                        failures+=$(printf '{"hostname":"%s","message":"%s","logfile":"%s","timestamp":"%s"}' "${lhost}" "${fline}" "$(basename "${logfile}")" "${line_ts}")
                    done <<< "${fail_lines}"
                done
                # Also check old-style service-*.log for hosts not yet seen
                for logfile in "${TM_LOG_DIR}"/service-*.log; do
                    [[ -f "${logfile}" ]] || continue
                    local lhost
                    lhost=$(basename "${logfile}" .log)
                    lhost="${lhost#service-}"
                    echo "${seen_hosts}" | grep -qw "${lhost}" 2>/dev/null && continue
                    local fail_lines
                    fail_lines=$(tail -50 "${logfile}" 2>/dev/null | grep -iE "(\[ERROR\]|FAIL|fatal|Permission denied)" | tail -3)
                    while IFS= read -r fline; do
                        [[ -z "${fline}" ]] && continue
                        local line_ts
                        line_ts=$(echo "${fline}" | grep -oE '^\[?[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\]?' | tr -d '[]')
                        fline=$(echo "${fline}" | sed 's/"/\\"/g' | tr -d '\n')
                        [[ ${first} -eq 1 ]] && first=0 || failures+=','
                        failures+=$(printf '{"hostname":"%s","message":"%s","timestamp":"%s"}' "${lhost}" "${fline}" "${line_ts}")
                    done <<< "${fail_lines}"
                done
            fi
            failures+=']'
            _http_response "200 OK" "application/json" "${failures}"
            ;;

        "GET /api/history")
            # Last backup date and status per server
            local history='['
            local first=1
            local servers_conf="${TM_PROJECT_ROOT}/config/servers.conf"
            if [[ -f "${servers_conf}" ]]; then
                while IFS= read -r line; do
                    line=$(echo "${line}" | sed 's/^[[:space:]]*//')
                    [[ -z "${line}" || "${line}" == \#* ]] && continue
                    local hist_host
                    hist_host=$(echo "${line}" | awk '{print $1}')
                    local snap_dir="${TM_BACKUP_ROOT}/${hist_host}"
                    local last_backup="never"
                    local last_backup_time=""
                    local snap_count=0
                    local total_size="0"
                    if [[ -d "${snap_dir}" ]]; then
                        # Count snapshots
                        snap_count=$(find "${snap_dir}" -maxdepth 1 -type d -name '????-??-??' 2>/dev/null | wc -l)
                        snap_count=$(echo "${snap_count}" | tr -d ' ')
                        # Latest snapshot date
                        local latest
                        latest=$(find "${snap_dir}" -maxdepth 1 -type d -name '????-??-??' 2>/dev/null | sort -r | head -1)
                        if [[ -n "${latest}" ]]; then
                            last_backup=$(basename "${latest}")
                        fi
                        # Total size
                        total_size=$(du -sh "${snap_dir}" 2>/dev/null | cut -f1)
                    fi
                    # Check if last backup had errors (check per-backup log first, then old format)
                    local last_status="ok"
                    local latest_log
                    latest_log=$(ls -t "${TM_LOG_DIR}"/backup-"${hist_host}"-*.log 2>/dev/null | head -1)
                    if [[ -z "${latest_log}" ]]; then
                        latest_log="${TM_LOG_DIR}/service-${hist_host}.log"
                    fi
                    if [[ -f "${latest_log}" ]]; then
                        local last_lines
                        last_lines=$(tail -30 "${latest_log}" 2>/dev/null)
                        if echo "${last_lines}" | grep -qiE "(\[ERROR\]|FAIL|fatal|Permission denied)"; then
                            last_status="error"
                        fi
                        # Extract timestamp from log filename or last line
                        local log_bn
                        log_bn=$(basename "${latest_log}" .log)
                        last_backup_time=$(echo "${log_bn}" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$' | sed 's/_/ /;s/\(..\)\(..\)$/:\1:\2/')
                        if [[ -z "${last_backup_time}" ]]; then
                            last_backup_time=$(tail -1 "${latest_log}" 2>/dev/null | grep -oE '^\[?[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\]?' | tr -d '[]')
                        fi
                    fi
                    [[ ${first} -eq 1 ]] && first=0 || history+=','
                    history+=$(printf '{"hostname":"%s","last_backup":"%s","last_backup_time":"%s","snapshots":%s,"total_size":"%s","status":"%s"}' \
                        "${hist_host}" "${last_backup}" "${last_backup_time}" "${snap_count}" "${total_size}" "${last_status}")
                done < "${servers_conf}"
            fi
            history+=']'
            _http_response "200 OK" "application/json" "${history}"
            ;;

        "GET /api/disk")
            local disk_line
            disk_line=$(df -h "${TM_BACKUP_ROOT}" 2>/dev/null | tail -1)
            if [[ -n "${disk_line}" ]]; then
                local d_total d_used d_avail d_pct d_mount
                d_total=$(echo "${disk_line}" | awk '{print $2}')
                d_used=$(echo "${disk_line}" | awk '{print $3}')
                d_avail=$(echo "${disk_line}" | awk '{print $4}')
                d_pct=$(echo "${disk_line}" | awk '{print $5}' | tr -d '%')
                d_mount=$(echo "${disk_line}" | awk '{print $6}')
                _http_response "200 OK" "application/json" \
                    "{\"total\":\"${d_total}\",\"used\":\"${d_used}\",\"available\":\"${d_avail}\",\"percent\":${d_pct:-0},\"mount\":\"${d_mount:-${TM_BACKUP_ROOT}}\",\"path\":\"${TM_BACKUP_ROOT}\"}"
            else
                _http_response "200 OK" "application/json" \
                    "{\"total\":\"--\",\"used\":\"--\",\"available\":\"--\",\"percent\":0,\"mount\":\"${TM_BACKUP_ROOT}\",\"path\":\"${TM_BACKUP_ROOT}\"}"
            fi
            ;;

        "GET /"|"GET /index.html")
            local web_dir="${TM_PROJECT_ROOT}/web"
            if [[ -f "${web_dir}/index.html" ]]; then
                _http_response "200 OK" "text/html" "$(cat "${web_dir}/index.html")"
            else
                _http_response "404 Not Found" "text/html" "<h1>Dashboard not found</h1>"
            fi
            ;;

        "GET /style.css")
            local web_dir="${TM_PROJECT_ROOT}/web"
            if [[ -f "${web_dir}/style.css" ]]; then
                _http_response "200 OK" "text/css" "$(cat "${web_dir}/style.css")"
            else
                _http_response "404 Not Found" "text/plain" "Not found"
            fi
            ;;

        "GET /app.js")
            local web_dir="${TM_PROJECT_ROOT}/web"
            if [[ -f "${web_dir}/app.js" ]]; then
                _http_response "200 OK" "application/javascript" "$(cat "${web_dir}/app.js")"
            else
                _http_response "404 Not Found" "text/plain" "Not found"
            fi
            ;;

        "GET /favicon.ico")
            _http_response "204 No Content" "image/x-icon" ""
            ;;

        "OPTIONS "*)
            _http_response "204 No Content" "text/plain" ""
            ;;

        *)
            _http_response "404 Not Found" "application/json" \
                "{\"error\":\"Not found: ${method} ${path}\"}"
            ;;
    esac
}

_generate_handler_script() {
    local script="${TM_RUN_DIR}/_http_handler.sh"
    {
        echo '#!/usr/bin/env bash'
        echo "# Auto-generated by tmserviced.sh — $(date +'%Y-%m-%d %H:%M:%S')"
        echo "# Do not edit; regenerated on every service start."
        echo ""
        echo "SCRIPT_DIR='${SCRIPT_DIR}'"
        echo "STATE_DIR='${STATE_DIR}'"
        echo "SERVICE_START_TIME='${SERVICE_START_TIME}'"
        echo "TM_RUN_DIR='${TM_RUN_DIR}'"
        echo "TM_LOG_DIR='${TM_LOG_DIR}'"
        echo "TM_BACKUP_ROOT='${TM_BACKUP_ROOT}'"
        echo "TM_PROJECT_ROOT='${TM_PROJECT_ROOT}'"
        echo "TM_SSH_KEY='${TM_SSH_KEY}'"
        echo "TM_SSH_PORT='${TM_SSH_PORT}'"
        echo "TM_SSH_TIMEOUT='${TM_SSH_TIMEOUT}'"
        echo "TM_USER='${TM_USER}'"
        echo "TM_HOME='${TM_HOME}'"
        echo "TM_PARALLEL_JOBS='${TM_PARALLEL_JOBS}'"
        echo "TM_LOG_LEVEL='${TM_LOG_LEVEL}'"
        echo "TM_API_PORT='${TM_API_PORT}'"
        echo ""
        # Embed all required function definitions
        declare -f tm_log
        declare -f _tm_log_level_num
        declare -f _http_response
        declare -f _get_processes_json
        declare -f _register_process
        declare -f _update_process
        declare -f _check_process_exit
        declare -f run_backup
        declare -f kill_backup
        declare -f _parse_priority
        declare -f _parse_db_interval
        declare -f _handle_request
        echo ""
        echo '_handle_request'
    } > "${script}"
    chmod 700 "${script}"
    tm_log "DEBUG" "Handler script generated: ${script}"
}

_start_http_server() {
    tm_log "INFO" "Starting HTTP API on ${TM_API_BIND}:${TM_API_PORT}"

    local api_server="${SCRIPT_DIR}/tm-api-server.py"
    local python_bin=""

    # Find Python 3 interpreter
    for p in python3 python; do
        if command -v "${p}" &>/dev/null && "${p}" -c 'import sys; sys.exit(0 if sys.version_info[0]>=3 else 1)' 2>/dev/null; then
            python_bin="${p}"
            break
        fi
    done

    if [[ -n "${python_bin}" && -f "${api_server}" ]]; then
        # Python API server — production-grade threaded HTTP server
        "${python_bin}" "${api_server}" \
            --bind "${TM_API_BIND}" \
            --port "${TM_API_PORT}" \
            --project-root "${TM_PROJECT_ROOT}" \
            >> "${TM_LOG_DIR}/api-server.log" 2>&1 &
        HTTP_PID=$!
        tm_log "INFO" "HTTP API started via Python (PID ${HTTP_PID})"
    elif command -v socat &>/dev/null; then
        # Fallback: socat + bash handler (limited concurrency)
        tm_log "WARN" "Python 3 not found, falling back to socat (limited concurrency)"
        _generate_handler_script
        local handler="${TM_RUN_DIR}/_http_handler.sh"
        socat TCP-LISTEN:${TM_API_PORT},bind=${TM_API_BIND},reuseaddr,fork,max-children=10 \
            EXEC:"${handler}" &
        HTTP_PID=$!
        tm_log "INFO" "HTTP API started via socat (PID ${HTTP_PID})"
    elif command -v ncat &>/dev/null; then
        tm_log "WARN" "Python 3 not found, falling back to ncat (limited concurrency)"
        _generate_handler_script
        local handler="${TM_RUN_DIR}/_http_handler.sh"
        if ncat --help 2>&1 | grep -q "\-\-keep-open"; then
            ncat --keep-open -l -p ${TM_API_PORT} --sh-exec "${handler}" &
        else
            _ncat_respawn_loop "${handler}" &
        fi
        HTTP_PID=$!
        tm_log "INFO" "HTTP API started via ncat (PID ${HTTP_PID})"
    else
        tm_log "ERROR" "No Python 3, socat, or ncat found. Dashboard will not be available."
        tm_log "ERROR" "Install Python 3: dnf install python3 / apt install python3"
        return 1
    fi
}

_ncat_respawn_loop() {
    local handler="$1"
    # Single-connection listener loop (fallback when --keep-open unavailable)
    # Respawns immediately after each connection
    while true; do
        if command -v ncat &>/dev/null; then
            ncat -l -p ${TM_API_PORT} -c "${handler}" 2>/dev/null
        elif command -v nc &>/dev/null; then
            nc -l -p ${TM_API_PORT} -c "${handler}" 2>/dev/null
        else
            sleep 1
        fi
    done
}

# ============================================================
# MAIN
# ============================================================

main() {
    SERVICE_START_TIME=$(date +%s)

    tm_log "INFO" "=========================================="
    tm_log "INFO" "TimeMachine Service starting"
    tm_log "INFO" "  API: http://${TM_API_BIND}:${TM_API_PORT}"
    tm_log "INFO" "  PID: $$"
    tm_log "INFO" "=========================================="

    # Cleanup on exit
    trap '_cleanup' EXIT INT TERM

    # Start HTTP API
    _start_http_server

    # Start scheduler in background
    _scheduler_loop &
    SCHEDULER_PID=$!

    tm_log "INFO" "Scheduler started (PID ${SCHEDULER_PID})"

    # Wait for signals
    if [[ ${FOREGROUND} -eq 1 ]]; then
        wait
    else
        # Daemonize
        wait
    fi
}

_cleanup() {
    tm_log "INFO" "Service shutting down..."
    # Hard kill — no grace period
    [[ -n "${HTTP_PID:-}" ]] && kill -9 "${HTTP_PID}" 2>/dev/null
    [[ -n "${SCHEDULER_PID:-}" ]] && kill -9 "${SCHEDULER_PID}" 2>/dev/null
    wait "${HTTP_PID}" 2>/dev/null || true
    wait "${SCHEDULER_PID}" 2>/dev/null || true
    rm -f "${TM_RUN_DIR}/tmserviced.pid"
    tm_log "INFO" "Service stopped"
    exit 0
}

main "$@"
