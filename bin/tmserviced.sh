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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/../lib/notify.sh"

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
# Usage: _register_process <hostname> <pid> <mode>
_register_process() {
    local hostname="$1" pid="$2" mode="${3:-full}"
    local ts
    ts=$(date +'%Y-%m-%d %H:%M:%S')
    echo "${pid}|${hostname}|${mode}|${ts}|running" > "${STATE_DIR}/proc-${hostname}.state"
}

# Update process state
_update_process() {
    local hostname="$1" status="$2"
    local state_file="${STATE_DIR}/proc-${hostname}.state"
    if [[ -f "${state_file}" ]]; then
        local content
        content=$(cat "${state_file}")
        # Replace status field (5th field)
        echo "${content}" | sed "s/|[^|]*$/|${status}/" > "${state_file}"
    fi
}

# Get all process states as JSON
_get_processes_json() {
    echo '['
    local first=1
    for state_file in "${STATE_DIR}"/proc-*.state; do
        [[ -f "${state_file}" ]] || continue
        local content
        content=$(cat "${state_file}")
        local pid hostname mode started status
        pid=$(echo "${content}" | cut -d'|' -f1)
        hostname=$(echo "${content}" | cut -d'|' -f2)
        mode=$(echo "${content}" | cut -d'|' -f3)
        started=$(echo "${content}" | cut -d'|' -f4)
        status=$(echo "${content}" | cut -d'|' -f5)

        # Check if process is actually still running
        if [[ "${status}" == "running" ]] && ! kill -0 "${pid}" 2>/dev/null; then
            status="completed"
            _update_process "${hostname}" "completed"
        fi

        [[ ${first} -eq 1 ]] && first=0 || echo ','
        printf '{"pid":%s,"hostname":"%s","mode":"%s","started":"%s","status":"%s"}' \
            "${pid}" "${hostname}" "${mode}" "${started}" "${status}"
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

    "${SCRIPT_DIR}/timemachine.sh" ${hostname} ${opts} \
        >> "${TM_LOG_DIR}/service-${hostname}.log" 2>&1 &
    local pid=$!

    local mode="full"
    [[ "${opts}" == *"--files-only"* ]] && mode="files-only"
    [[ "${opts}" == *"--db-only"* ]] && mode="db-only"

    _register_process "${hostname}" "${pid}" "${mode}"
    tm_log "INFO" "Service: backup started for ${hostname} (PID ${pid})"
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

_scheduler_loop() {
    local servers_conf="${TM_PROJECT_ROOT}/config/servers.conf"
    local schedule_file="${TM_PROJECT_ROOT}/config/schedule.conf"
    local last_run_file="${STATE_DIR}/last-daily-run"

    while true; do
        # Check if daily run is due
        local today
        today=$(tm_date_today)
        local last_run=""
        [[ -f "${last_run_file}" ]] && last_run=$(cat "${last_run_file}")

        local current_hour
        current_hour=$(date +'%H')
        local schedule_hour="${TM_SCHEDULE_HOUR:-11}"

        if [[ "${last_run}" != "${today}" && "${current_hour}" -ge "${schedule_hour}" ]]; then
            tm_log "INFO" "Scheduler: triggering daily backup run"

            if "${SCRIPT_DIR}/daily-jobs-check.sh" >> "${TM_LOG_DIR}/scheduler.log" 2>&1; then
                if [[ -f "${servers_conf}" ]]; then
                    grep -E '^\s*[^#\s]' "${servers_conf}" | \
                        sed 's/^[[:space:]]*//' | while read -r line; do
                            run_backup ${line}
                            # Respect parallel limit with simple delay
                            local running
                            running=$(find "${STATE_DIR}" -name "proc-*.state" -exec grep -l "|running$" {} \; 2>/dev/null | wc -l | tr -d ' ')
                            while [[ ${running} -ge ${TM_PARALLEL_JOBS} ]]; do
                                sleep 10
                                running=$(find "${STATE_DIR}" -name "proc-*.state" -exec grep -l "|running$" {} \; 2>/dev/null | wc -l | tr -d ' ')
                            done
                        done
                fi
                echo "${today}" > "${last_run_file}"
            else
                tm_log "ERROR" "Scheduler: pre-backup check failed"
            fi
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

    printf "HTTP/1.1 %s\r\n" "${status}"
    printf "Content-Type: %s\r\n" "${content_type}"
    printf "Content-Length: %d\r\n" "${body_length}"
    printf "Access-Control-Allow-Origin: *\r\n"
    printf "Access-Control-Allow-Methods: GET, POST, DELETE\r\n"
    printf "Access-Control-Allow-Headers: Content-Type\r\n"
    printf "Connection: close\r\n"
    printf "\r\n"
    printf "%s" "${body}"
}

_handle_request() {
    local request_line=""
    local content_length=0
    local body=""

    # Read request line
    read -r request_line
    request_line=$(echo "${request_line}" | tr -d '\r')

    local method path
    method=$(echo "${request_line}" | awk '{print $1}')
    path=$(echo "${request_line}" | awk '{print $2}')

    # Read headers
    while read -r header; do
        header=$(echo "${header}" | tr -d '\r')
        [[ -z "${header}" ]] && break
        if echo "${header}" | grep -qi "^content-length:"; then
            content_length=$(echo "${header}" | awk -F: '{print $2}' | tr -d ' ')
        fi
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
            resp=$(printf '{"status":"running","uptime":%d,"hostname":"%s","version":"0.2.0","processes":%s}' \
                "${uptime_secs}" "$(hostname)" "${procs}")
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
            if [[ -d "${snap_dir}" ]]; then
                for d in "${snap_dir}"/????-??-??; do
                    [[ -d "${d}" ]] || continue
                    local dn
                    dn=$(basename "${d}")
                    local sz
                    sz=$(du -sh "${d}" 2>/dev/null | cut -f1)
                    local hf="false" hs="false"
                    [[ -d "${d}/files" ]] && hf="true"
                    [[ -d "${d}/sql" ]] && hs="true"
                    [[ ${first} -eq 1 ]] && first=0 || snaps+=','
                    snaps+=$(printf '{"date":"%s","size":"%s","has_files":%s,"has_sql":%s}' \
                        "${dn}" "${sz}" "${hf}" "${hs}")
                done
            fi
            snaps+=']'
            _http_response "200 OK" "application/json" "${snaps}"
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
                    [[ ${first} -eq 1 ]] && first=0 || servers+=','
                    servers+=$(printf '{"hostname":"%s","options":"%s"}' "${srv_host}" "${srv_opts}")
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

        "DELETE /api/servers/"*)
            local servers_conf="${TM_PROJECT_ROOT}/config/servers.conf"
            local target_host="${path#/api/servers/}"

            if [[ ! -f "${servers_conf}" ]]; then
                _http_response "404 Not Found" "application/json" \
                    '{"error":"No servers.conf found"}'
            elif ! grep -qE "^\s*${target_host}(\s|$)" "${servers_conf}" 2>/dev/null; then
                _http_response "404 Not Found" "application/json" \
                    "{\"error\":\"Server '${target_host}' not found\"}"
            else
                sed -i.bak "/^[[:space:]]*${target_host}[[:space:]]*$/d;/^[[:space:]]*${target_host}[[:space:]]/d" "${servers_conf}" 2>/dev/null || \
                sed -i '' "/^[[:space:]]*${target_host}[[:space:]]*$/d;/^[[:space:]]*${target_host}[[:space:]]/d" "${servers_conf}"
                rm -f "${servers_conf}.bak"
                tm_log "INFO" "API: removed server ${target_host}"
                _http_response "200 OK" "application/json" \
                    "{\"status\":\"removed\",\"hostname\":\"${target_host}\"}"
            fi
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
            local logfile="${TM_LOG_DIR}/service-${target_host}.log"
            if [[ -f "${logfile}" ]]; then
                local content
                content=$(tail -100 "${logfile}")
                # Escape for JSON
                content=$(echo "${content}" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
                _http_response "200 OK" "application/json" \
                    "{\"hostname\":\"${target_host}\",\"lines\":\"${content}\"}"
            else
                _http_response "404 Not Found" "application/json" \
                    "{\"error\":\"No logs for ${target_host}\"}"
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

        "OPTIONS "*)
            _http_response "204 No Content" "text/plain" ""
            ;;

        *)
            _http_response "404 Not Found" "application/json" \
                "{\"error\":\"Not found: ${method} ${path}\"}"
            ;;
    esac
}

_start_http_server() {
    tm_log "INFO" "Starting HTTP API on ${TM_API_BIND}:${TM_API_PORT}"

    if command -v socat &>/dev/null; then
        socat TCP-LISTEN:${TM_API_PORT},bind=${TM_API_BIND},reuseaddr,fork \
            SYSTEM:"bash -c '_handle_request'" &
        HTTP_PID=$!
    elif command -v ncat &>/dev/null; then
        while true; do
            ncat -l -p ${TM_API_PORT} -k -c "bash -c '_handle_request'" &
            HTTP_PID=$!
            wait ${HTTP_PID}
        done &
        HTTP_PID=$!
    else
        tm_log "WARN" "Neither socat nor ncat found. HTTP API disabled."
        tm_log "WARN" "Install socat: apt install socat / yum install socat"
        return 1
    fi

    tm_log "INFO" "HTTP API started (PID ${HTTP_PID})"
}

# Export functions for socat subshell
export -f _handle_request _http_response _get_processes_json
export -f _register_process _update_process kill_backup run_backup
export -f tm_log _tm_log_level_num tm_ensure_dir tm_date_today
export -f tm_acquire_lock tm_release_lock
export STATE_DIR TM_RUN_DIR TM_LOG_DIR TM_BACKUP_ROOT TM_PROJECT_ROOT
export TM_SSH_KEY TM_SSH_PORT TM_SSH_TIMEOUT TM_USER TM_HOME
export TM_PARALLEL_JOBS TM_LOG_LEVEL TM_ALERT_SUBJECT_PREFIX
export SERVICE_START_TIME

# ============================================================
# MAIN
# ============================================================

main() {
    SERVICE_START_TIME=$(date +%s)
    export SERVICE_START_TIME

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
    [[ -n "${HTTP_PID:-}" ]] && kill "${HTTP_PID}" 2>/dev/null
    [[ -n "${SCHEDULER_PID:-}" ]] && kill "${SCHEDULER_PID}" 2>/dev/null
    rm -f "${TM_RUN_DIR}/tmserviced.pid"
    tm_log "INFO" "Service stopped"
}

main "$@"
