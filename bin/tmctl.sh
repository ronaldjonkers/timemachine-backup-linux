#!/usr/bin/env bash
# ============================================================
# TimeMachine Backup - CLI Control Tool
# ============================================================
# Command-line interface for managing the TimeMachine service.
#
# Usage:
#   tmctl <command> [OPTIONS]
#
# Commands:
#   status              Show service status and running processes
#   ps                  List all backup processes (running/completed)
#   kill <hostname>     Kill a running backup process
#   backup <hostname>   Start a backup for a host
#   restore <hostname>  Start a restore (passes args to restore.sh)
#   logs [hostname]     Show logs (all or per host)
#   servers             List configured servers
#   server add <host>   Add a server to the backup list
#   server remove <host> Remove a server from the backup list
#   snapshots <host>    List snapshots for a host
#   ssh-key             Show the SSH public key
#   setup-web           Setup Nginx + SSL + Auth for external access
#   update              Update TimeMachine to the latest version
#   fix-permissions     Fix all file/directory permissions (sudo)
#   uninstall           Remove TimeMachine completely
#   version             Show version
#
# Options:
#   --api <url>         API base URL (default: http://localhost:7600)
#   --verbose           Enable debug output
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
tm_load_config

: "${TM_API_PORT:=7600}"
TM_API_URL="${TM_API_URL:-http://localhost:${TM_API_PORT}}"

# ============================================================
# HELPERS
# ============================================================

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
NC=$'\033[0m'

_has_curl() { command -v curl &>/dev/null; }

# Try API first, fall back to direct file access
_api_get() {
    local endpoint="$1"
    if _has_curl; then
        curl -s --connect-timeout 3 "${TM_API_URL}${endpoint}" 2>/dev/null
    fi
}

_api_post() {
    local endpoint="$1"
    local body="${2:-}"
    if _has_curl; then
        if [[ -n "${body}" ]]; then
            curl -s --connect-timeout 3 -X POST \
                -H "Content-Type: application/json" \
                -d "${body}" "${TM_API_URL}${endpoint}" 2>/dev/null
        else
            curl -s --connect-timeout 3 -X POST "${TM_API_URL}${endpoint}" 2>/dev/null
        fi
    fi
}

_api_delete() {
    local endpoint="$1"
    if _has_curl; then
        curl -s --connect-timeout 3 -X DELETE "${TM_API_URL}${endpoint}" 2>/dev/null
    fi
}

# Check if service is running
_service_running() {
    local pidfile="${TM_RUN_DIR}/tmserviced.pid"
    if [[ -f "${pidfile}" ]]; then
        local pid
        pid=$(cat "${pidfile}")
        kill -0 "${pid}" 2>/dev/null && return 0
    fi
    return 1
}

# ============================================================
# COMMANDS
# ============================================================

cmd_status() {
    echo -e "${BOLD}TimeMachine Backup Status${NC}"
    echo "============================================"

    # Service status
    if _service_running; then
        local pid
        pid=$(cat "${TM_RUN_DIR}/tmserviced.pid")
        echo -e "  Service:  ${GREEN}running${NC} (PID ${pid})"
        echo -e "  API:      ${CYAN}${TM_API_URL}${NC}"

        # Try to get uptime from API
        local api_resp
        api_resp=$(_api_get "/api/status")
        if [[ -n "${api_resp}" ]]; then
            local uptime
            uptime=$(echo "${api_resp}" | grep -o '"uptime":[0-9]*' | cut -d: -f2)
            if [[ -n "${uptime}" ]]; then
                local hours=$((uptime / 3600))
                local mins=$(( (uptime % 3600) / 60 ))
                echo -e "  Uptime:   ${hours}h ${mins}m"
            fi
        fi
    else
        echo -e "  Service:  ${RED}stopped${NC}"
    fi

    echo ""

    # Running processes
    cmd_ps
}

cmd_ps() {
    echo -e "${BOLD}Backup Processes${NC}"
    echo "============================================"
    printf "  ${BOLD}%-30s %-8s %-12s %-20s %s${NC}\n" \
        "HOSTNAME" "PID" "MODE" "STARTED" "STATUS"

    local found=0

    # Try API first
    if _service_running; then
        local procs
        procs=$(_api_get "/api/processes")
        if [[ -n "${procs}" && "${procs}" != "[]" ]]; then
            # Simple JSON parsing with grep/sed
            echo "${procs}" | tr '{}' '\n' | grep '"hostname"' | while IFS= read -r entry; do
                local hostname pid mode started status
                hostname=$(echo "${entry}" | grep -o '"hostname":"[^"]*"' | cut -d'"' -f4)
                pid=$(echo "${entry}" | grep -o '"pid":[0-9]*' | cut -d: -f2)
                mode=$(echo "${entry}" | grep -o '"mode":"[^"]*"' | cut -d'"' -f4)
                started=$(echo "${entry}" | grep -o '"started":"[^"]*"' | cut -d'"' -f4)
                status=$(echo "${entry}" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)

                local color="${NC}"
                case "${status}" in
                    running)   color="${GREEN}" ;;
                    completed) color="${CYAN}" ;;
                    failed)    color="${RED}" ;;
                    killed)    color="${YELLOW}" ;;
                esac

                printf "  %-30s %-8s %-12s %-20s ${color}%s${NC}\n" \
                    "${hostname}" "${pid}" "${mode}" "${started}" "${status}"
                found=1
            done
        fi
    fi

    # Fall back to PID files
    if [[ ${found} -eq 0 ]]; then
        for pidfile in "${TM_RUN_DIR}"/*.pid; do
            [[ -f "${pidfile}" ]] || continue
            local name
            name=$(basename "${pidfile}" .pid)
            [[ "${name}" == "tmserviced" ]] && continue

            local pid
            pid=$(cat "${pidfile}")
            local status="unknown"
            if kill -0 "${pid}" 2>/dev/null; then
                status="running"
            else
                status="stale"
            fi

            local color="${NC}"
            [[ "${status}" == "running" ]] && color="${GREEN}"
            [[ "${status}" == "stale" ]] && color="${RED}"

            printf "  %-30s %-8s %-12s %-20s ${color}%s${NC}\n" \
                "${name}" "${pid}" "-" "-" "${status}"
        done
    fi

    # State files
    for state_file in "${TM_STATE_DIR}"/proc-*.state; do
        [[ -f "${state_file}" ]] || continue
        local content
        content=$(cat "${state_file}")
        local pid hostname mode started status
        pid=$(echo "${content}" | cut -d'|' -f1)
        hostname=$(echo "${content}" | cut -d'|' -f2)
        mode=$(echo "${content}" | cut -d'|' -f3)
        started=$(echo "${content}" | cut -d'|' -f4)
        status=$(echo "${content}" | cut -d'|' -f5)

        if [[ "${status}" == "running" ]] && ! kill -0 "${pid}" 2>/dev/null; then
            status="completed"
        fi

        local color="${NC}"
        case "${status}" in
            running)   color="${GREEN}" ;;
            completed) color="${CYAN}" ;;
            failed)    color="${RED}" ;;
            killed)    color="${YELLOW}" ;;
        esac

        printf "  %-30s %-8s %-12s %-20s ${color}%s${NC}\n" \
            "${hostname}" "${pid}" "${mode}" "${started}" "${status}"
    done
}

cmd_kill() {
    local hostname="$1"
    if [[ -z "${hostname}" ]]; then
        echo "Usage: tmctl kill <hostname>"
        exit 1
    fi

    echo -e "Killing backup for ${BOLD}${hostname}${NC}..."

    if _service_running; then
        local resp
        resp=$(_api_delete "/api/backup/${hostname}")
        echo "${resp}"
    else
        # Direct kill via PID files
        local pidfile="${TM_RUN_DIR}/backup-${hostname}.pid"
        if [[ -f "${pidfile}" ]]; then
            local pid
            pid=$(cat "${pidfile}")
            if kill -0 "${pid}" 2>/dev/null; then
                kill "${pid}"
                sleep 1
                kill -0 "${pid}" 2>/dev/null && kill -9 "${pid}"
                echo -e "${GREEN}Killed${NC} (PID ${pid})"
            else
                echo -e "${YELLOW}Process not running${NC}"
            fi
            rm -f "${pidfile}"
        else
            echo -e "${RED}No process found for ${hostname}${NC}"
        fi
    fi
}

cmd_backup() {
    local hostname="$1"
    shift
    local opts="$*"

    if [[ -z "${hostname}" ]]; then
        echo "Usage: tmctl backup <hostname> [--files-only|--db-only|--dry-run]"
        exit 1
    fi

    echo -e "Starting backup for ${BOLD}${hostname}${NC}..."

    if _service_running; then
        local query=""
        [[ "${opts}" == *"--files-only"* ]] && query="?files-only"
        [[ "${opts}" == *"--db-only"* ]] && query="?db-only"
        local resp
        resp=$(_api_post "/api/backup/${hostname}${query}")
        echo "${resp}"
    else
        # Direct execution
        "${SCRIPT_DIR}/timemachine.sh" "${hostname}" ${opts} &
        echo -e "${GREEN}Started${NC} (PID $!)"
    fi
}

cmd_logs() {
    local hostname="${1:-}"

    if [[ -n "${hostname}" ]]; then
        local logfile="${TM_LOG_DIR}/service-${hostname}.log"
        if [[ -f "${logfile}" ]]; then
            tail -50 "${logfile}"
        else
            # Try general log
            logfile="${TM_LOG_DIR}/daily-$(tm_date_today).log"
            if [[ -f "${logfile}" ]]; then
                grep "${hostname}" "${logfile}" | tail -50
            else
                echo "No logs found for ${hostname}"
            fi
        fi
    else
        # Show recent logs from all sources
        local logdir="${TM_LOG_DIR}"
        if [[ -d "${logdir}" ]]; then
            echo -e "${BOLD}Recent log files:${NC}"
            ls -lt "${logdir}"/*.log 2>/dev/null | head -10
            echo ""
            echo -e "${BOLD}Latest entries:${NC}"
            tail -20 "${logdir}"/*.log 2>/dev/null
        else
            echo "No log directory found"
        fi
    fi
}

cmd_servers() {
    local servers_conf="${TM_PROJECT_ROOT}/config/servers.conf"

    echo -e "${BOLD}Configured Servers${NC}"
    echo "============================================"

    if [[ ! -f "${servers_conf}" ]]; then
        echo "  No servers.conf found"
        return 1
    fi

    printf "  ${BOLD}%-35s %s${NC}\n" "HOSTNAME" "OPTIONS"
    while IFS= read -r line; do
        line=$(echo "${line}" | sed 's/^[[:space:]]*//')
        [[ -z "${line}" || "${line}" == \#* ]] && continue
        local srv_host
        srv_host=$(echo "${line}" | awk '{print $1}')
        local srv_opts
        srv_opts=$(echo "${line}" | cut -d' ' -f2-)
        [[ "${srv_opts}" == "${srv_host}" ]] && srv_opts=""
        printf "  %-35s %s\n" "${srv_host}" "${srv_opts}"
    done < "${servers_conf}"
}

cmd_snapshots() {
    local hostname="$1"
    if [[ -z "${hostname}" ]]; then
        echo "Usage: tmctl snapshots <hostname>"
        exit 1
    fi

    "${SCRIPT_DIR}/restore.sh" "${hostname}" --list
}

cmd_ssh_key() {
    local pub_key="${TM_SSH_KEY}.pub"
    if [[ -f "${pub_key}" ]]; then
        echo -e "${BOLD}SSH Public Key${NC}"
        echo "============================================"
        echo ""
        cat "${pub_key}"
        echo ""
        echo "============================================"
        echo -e "Use this key with install.sh client:"
        echo -e "  ${CYAN}sudo ./install.sh client --ssh-key '$(cat "${pub_key}")'${NC}"
        echo ""
        echo -e "Or download from the API:"
        echo -e "  ${CYAN}curl -s http://<backup-server>:${TM_API_PORT}/api/ssh-key/raw${NC}"
    else
        echo -e "${RED}SSH public key not found at ${pub_key}${NC}"
        echo "Run install.sh first to generate SSH keys."
    fi
}

cmd_server_add() {
    local hostname="$1"
    local opts="${*:2}"

    if [[ -z "${hostname}" ]]; then
        echo "Usage: tmctl server add <hostname> [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --files-only      Only backup files (skip database dump)"
        echo "  --db-only         Only backup databases (skip file sync)"
        echo "  --no-rotate       Skip backup rotation"
        echo "  --priority N      Backup priority (1=highest, default=10)"
        echo "  --db-interval Xh  Extra DB backups every X hours (e.g. 4h)"
        exit 1
    fi

    local servers_conf="${TM_PROJECT_ROOT}/config/servers.conf"

    # Create file if it doesn't exist
    if [[ ! -f "${servers_conf}" ]]; then
        cp "${TM_PROJECT_ROOT}/config/servers.conf.example" "${servers_conf}" 2>/dev/null || \
            touch "${servers_conf}"
    fi

    # Check for duplicates
    if grep -qE "^\s*${hostname}(\s|$)" "${servers_conf}" 2>/dev/null; then
        echo -e "${YELLOW}Server '${hostname}' already exists in servers.conf${NC}"
        return 1
    fi

    # Append server
    local entry="${hostname}"
    [[ -n "${opts}" ]] && entry="${hostname} ${opts}"
    echo "${entry}" >> "${servers_conf}"
    echo -e "${GREEN}Added${NC} ${BOLD}${hostname}${NC} to servers.conf"

    # Notify API if running
    if _service_running; then
        _api_post "/api/servers" "{\"hostname\":\"${hostname}\",\"options\":\"${opts}\"}" &>/dev/null || true
    fi

    # Write skip marker so the daily runner won't auto-include this server today
    local state_dir="${TM_STATE_DIR:-${TM_HOME}/state}"
    tm_ensure_dir "${state_dir}"
    date +'%Y-%m-%d' > "${state_dir}/skip-daily-${hostname}"

    # Ask if user wants to start a backup now
    echo ""
    read -r -p "Start a backup for ${hostname} now? [y/N] " answer
    if [[ "${answer}" =~ ^[Yy]$ ]]; then
        echo -e "Starting backup for ${BOLD}${hostname}${NC}..."
        if _service_running; then
            _api_post "/api/backup/${hostname}" "{}" &>/dev/null && \
                echo -e "${GREEN}Backup started${NC}" || \
                echo -e "${RED}Failed to start backup via API${NC}"
        else
            "${TM_PROJECT_ROOT}/bin/timemachine.sh" "${hostname}" --trigger manual &
            echo -e "${GREEN}Backup started${NC} (PID $!)"
        fi
    else
        echo -e "No backup started. ${hostname} will be included in the next scheduled daily run."
    fi
}

cmd_server_remove() {
    local hostname="$1"

    if [[ -z "${hostname}" ]]; then
        echo "Usage: tmctl server remove <hostname>"
        exit 1
    fi

    local servers_conf="${TM_PROJECT_ROOT}/config/servers.conf"

    if [[ ! -f "${servers_conf}" ]]; then
        echo -e "${RED}No servers.conf found${NC}"
        return 1
    fi

    if ! grep -qE "^\s*${hostname}(\s|$)" "${servers_conf}" 2>/dev/null; then
        echo -e "${RED}Server '${hostname}' not found in servers.conf${NC}"
        return 1
    fi

    # Remove the line (macOS + Linux compatible sed)
    sed -i.bak "/^[[:space:]]*${hostname}[[:space:]]*$/d;/^[[:space:]]*${hostname}[[:space:]]/d" "${servers_conf}" 2>/dev/null || \
    sed -i '' "/^[[:space:]]*${hostname}[[:space:]]*$/d;/^[[:space:]]*${hostname}[[:space:]]/d" "${servers_conf}"
    rm -f "${servers_conf}.bak"
    echo -e "${GREEN}Removed${NC} ${BOLD}${hostname}${NC} from servers.conf"
}

cmd_server_edit() {
    local hostname="$1"
    shift 2>/dev/null || true

    if [[ -z "${hostname}" ]]; then
        echo "Usage: tmctl server edit <hostname> [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --priority N        Backup priority (1=highest, default=10)"
        echo "  --db-interval Xh    Extra DB backups every X hours (e.g. 4h, 0=off)"
        echo "  --files-only        Only backup files (skip database dump)"
        echo "  --db-only           Only backup databases (skip file sync)"
        echo "  --no-rotate         Skip backup rotation"
        echo "  --full              Reset to full backup (remove --files-only/--db-only)"
        echo "  --rotate            Re-enable rotation (remove --no-rotate)"
        echo ""
        echo "Examples:"
        echo "  tmctl server edit db1.example.com --db-interval 4h"
        echo "  tmctl server edit web1.example.com --priority 1 --files-only"
        echo "  tmctl server edit app1.example.com --full --priority 10"
        exit 1
    fi

    local servers_conf="${TM_PROJECT_ROOT}/config/servers.conf"

    if [[ ! -f "${servers_conf}" ]]; then
        echo -e "${RED}No servers.conf found${NC}"
        return 1
    fi

    # Find current line for this host
    local current_line
    current_line=$(grep -E "^\s*${hostname}(\s|$)" "${servers_conf}" 2>/dev/null | head -1)
    if [[ -z "${current_line}" ]]; then
        echo -e "${RED}Server '${hostname}' not found in servers.conf${NC}"
        return 1
    fi

    # Parse current options
    local cur_opts
    cur_opts=$(echo "${current_line}" | sed "s/^[[:space:]]*${hostname}//;s/^[[:space:]]*//")

    # Parse new options from arguments
    local new_priority="" new_db_interval="" set_files_only="" set_db_only="" set_no_rotate=""
    local set_full=0 set_rotate=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --priority)    new_priority="$2"; shift 2 ;;
            --db-interval) new_db_interval="$2"; shift 2 ;;
            --files-only)  set_files_only=1; shift ;;
            --db-only)     set_db_only=1; shift ;;
            --no-rotate)   set_no_rotate=1; shift ;;
            --full)        set_full=1; shift ;;
            --rotate)      set_rotate=1; shift ;;
            *)             echo "Unknown option: $1"; return 1 ;;
        esac
    done

    # Build new options string starting from current
    local opts="${cur_opts}"

    # Update priority
    if [[ -n "${new_priority}" ]]; then
        opts=$(echo "${opts}" | sed 's/--priority[[:space:]]\+[0-9]\+//')
        opts="${opts} --priority ${new_priority}"
    fi

    # Update db-interval
    if [[ -n "${new_db_interval}" ]]; then
        opts=$(echo "${opts}" | sed 's/--db-interval[[:space:]]\+[0-9]\+h//')
        if [[ "${new_db_interval}" != "0" && "${new_db_interval}" != "0h" ]]; then
            # Ensure format ends with 'h'
            new_db_interval="${new_db_interval%h}h"
            opts="${opts} --db-interval ${new_db_interval}"
        fi
    fi

    # Handle mode flags
    if [[ ${set_full} -eq 1 ]]; then
        opts=$(echo "${opts}" | sed 's/--files-only//;s/--db-only//')
    fi
    if [[ -n "${set_files_only}" ]]; then
        opts=$(echo "${opts}" | sed 's/--db-only//')
        if ! echo "${opts}" | grep -q '\-\-files-only'; then
            opts="${opts} --files-only"
        fi
    fi
    if [[ -n "${set_db_only}" ]]; then
        opts=$(echo "${opts}" | sed 's/--files-only//')
        if ! echo "${opts}" | grep -q '\-\-db-only'; then
            opts="${opts} --db-only"
        fi
    fi

    # Handle rotation
    if [[ ${set_rotate} -eq 1 ]]; then
        opts=$(echo "${opts}" | sed 's/--no-rotate//')
    fi
    if [[ -n "${set_no_rotate}" ]]; then
        if ! echo "${opts}" | grep -q '\-\-no-rotate'; then
            opts="${opts} --no-rotate"
        fi
    fi

    # Clean up whitespace
    opts=$(echo "${opts}" | sed 's/  */ /g;s/^ *//;s/ *$//')

    # Build new line
    local new_line="${hostname}"
    [[ -n "${opts}" ]] && new_line="${hostname} ${opts}"

    # Replace in file (escape special chars for sed)
    local escaped_current escaped_new
    escaped_current=$(printf '%s\n' "${current_line}" | sed 's/[&/\]/\\&/g;s/^[[:space:]]*//')
    escaped_new=$(printf '%s\n' "${new_line}" | sed 's/[&/\]/\\&/g')

    sed -i.bak "s/^[[:space:]]*${escaped_current}$/${escaped_new}/" "${servers_conf}" 2>/dev/null || \
    sed -i '' "s/^[[:space:]]*${escaped_current}$/${escaped_new}/" "${servers_conf}"
    rm -f "${servers_conf}.bak"

    echo -e "${GREEN}Updated${NC} ${BOLD}${hostname}${NC}"
    echo -e "  ${CYAN}${new_line}${NC}"
}

cmd_version() {
    echo "TimeMachine Backup v3.7.4"
}

cmd_fix_permissions() {
    # Must be root
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "  ${RED:-}Error: Must be run as root (use: sudo tmctl fix-permissions)${NC:-}"
        exit 1
    fi

    local project_root
    project_root=$(cd "${SCRIPT_DIR}/.." && pwd)
    local tm_user="${TM_USER:-timemachine}"
    local tm_home="${TM_HOME:-/home/timemachine}"
    local backup_root="${TM_BACKUP_ROOT:-/backups}"
    local run_dir="${TM_RUN_DIR:-/var/run/timemachine}"
    local install_dir="${TM_INSTALL_DIR:-${project_root}}"

    echo ""
    echo "  Fixing all permissions for '${tm_user}'..."
    echo ""

    # 1. Install directory — owned by timemachine, scripts executable
    chown -R "${tm_user}:${tm_user}" "${install_dir}"
    find "${install_dir}/bin" -name "*.sh" -exec chmod +x {} \;
    chmod 600 "${install_dir}/.env" 2>/dev/null || true
    echo "  ✓ Install directory: ${install_dir}"

    # 2. Home directory
    if [[ -d "${tm_home}" ]]; then
        chown -R "${tm_user}:${tm_user}" "${tm_home}"
        chmod 750 "${tm_home}"
        echo "  ✓ Home directory: ${tm_home}"
    fi

    # 3. SSH directory
    if [[ -d "${tm_home}/.ssh" ]]; then
        chmod 700 "${tm_home}/.ssh"
        chmod 600 "${tm_home}/.ssh"/* 2>/dev/null || true
        chmod 644 "${tm_home}/.ssh/id_rsa.pub" 2>/dev/null || true
        chmod 644 "${tm_home}/.ssh/authorized_keys" 2>/dev/null || true
        echo "  ✓ SSH directory: ${tm_home}/.ssh"
    fi

    # 4. Logs directory
    if [[ -d "${tm_home}/logs" ]]; then
        chown -R "${tm_user}:${tm_user}" "${tm_home}/logs"
        chmod 750 "${tm_home}/logs"
        echo "  ✓ Logs directory: ${tm_home}/logs"
    fi

    # 5. Credentials directory
    if [[ -d "${tm_home}/.credentials" ]]; then
        chown -R "${tm_user}:${tm_user}" "${tm_home}/.credentials"
        chmod 700 "${tm_home}/.credentials"
        find "${tm_home}/.credentials" -type f -exec chmod 600 {} \;
        echo "  ✓ Credentials directory: ${tm_home}/.credentials"
    fi

    # 6. Backup root
    if [[ -d "${backup_root}" ]]; then
        chown "${tm_user}:${tm_user}" "${backup_root}"
        chmod 750 "${backup_root}"
        find "${backup_root}" -maxdepth 1 -type d -exec chown "${tm_user}:${tm_user}" {} \;
        echo "  ✓ Backup root: ${backup_root}"
    fi

    # 7. Runtime directory
    mkdir -p "${run_dir}" "${run_dir}/state"
    chown -R "${tm_user}:${tm_user}" "${run_dir}"
    chmod 750 "${run_dir}"
    echo "  ✓ Runtime directory: ${run_dir}"

    # 8. tmpfiles.d for runtime dir persistence across reboots
    if [[ -d /etc/tmpfiles.d ]]; then
        echo "d /run/timemachine 0750 ${tm_user} ${tm_user} -" > /etc/tmpfiles.d/timemachine.conf
        echo "  ✓ tmpfiles.d: /etc/tmpfiles.d/timemachine.conf"
    fi

    # 9. Sudoers — verify it exists and is valid
    if [[ -f /etc/sudoers.d/timemachine ]]; then
        chmod 440 /etc/sudoers.d/timemachine
        if visudo -cf /etc/sudoers.d/timemachine &>/dev/null; then
            echo "  ✓ Sudoers: /etc/sudoers.d/timemachine (valid)"
        else
            echo "  ✗ Sudoers: /etc/sudoers.d/timemachine (INVALID — re-run install)"
        fi
    else
        echo "  ✗ Sudoers: /etc/sudoers.d/timemachine (MISSING — re-run install)"
    fi

    # 10. Clean up stale self-restart temp dirs
    rm -rf /tmp/tm-self-restart 2>/dev/null || true

    echo ""
    echo "  All permissions fixed."
    echo ""
}

cmd_uninstall() {
    local project_root
    project_root=$(cd "${SCRIPT_DIR}/.." && pwd)

    echo ""
    echo "  ${BOLD}TimeMachine Backup — Uninstall${NC}"
    echo ""

    # Must be root
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "  ${RED}Error:${NC} Must be run as root (use: sudo tmctl uninstall)"
        exit 1
    fi

    echo "  ${YELLOW}WARNING: This will remove the TimeMachine service, user, and all configuration.${NC}"
    echo "  ${YELLOW}Backup data in ${TM_BACKUP_ROOT:-/backups} will NOT be deleted.${NC}"
    echo ""

    # Confirmation
    read -r -p "  Type 'yes' to confirm uninstall: " confirm
    if [[ "${confirm}" != "yes" ]]; then
        echo "  Aborted."
        exit 0
    fi

    echo ""

    # 1. Stop and disable systemd service
    if command -v systemctl &>/dev/null; then
        if systemctl is-active timemachine &>/dev/null; then
            echo "  Stopping timemachine service..."
            systemctl stop timemachine
        fi
        if systemctl is-enabled timemachine &>/dev/null 2>&1; then
            echo "  Disabling timemachine service..."
            systemctl disable timemachine 2>/dev/null || true
        fi
        rm -f /etc/systemd/system/timemachine.service
        systemctl daemon-reload 2>/dev/null || true
        echo "  ${GREEN}✓${NC} Systemd service removed"
    fi

    # 2. Remove cron jobs
    rm -f /etc/cron.d/timemachine
    rm -f /etc/cron.d/timemachine-dump
    echo "  ${GREEN}✓${NC} Cron jobs removed"

    # 3. Remove sudoers
    rm -f /etc/sudoers.d/timemachine
    echo "  ${GREEN}✓${NC} Sudoers rules removed"

    # 4. Remove symlinks
    rm -f /usr/bin/tmctl /usr/bin/timemachine /usr/bin/tm-restore
    rm -f /usr/local/bin/tmctl /usr/local/bin/timemachine /usr/local/bin/tm-restore 2>/dev/null || true
    echo "  ${GREEN}✓${NC} Symlinks removed"

    # 5. Remove nginx config (if setup-web was used)
    if [[ -f /etc/nginx/sites-enabled/timemachine ]]; then
        rm -f /etc/nginx/sites-enabled/timemachine
        rm -f /etc/nginx/sites-available/timemachine
        rm -f /etc/nginx/.timemachine_htpasswd
        nginx -t &>/dev/null && nginx -s reload &>/dev/null || true
        echo "  ${GREEN}✓${NC} Nginx configuration removed"
    fi

    # 6. Remove run/state directory and tmpfiles.d
    rm -rf /var/run/timemachine
    rm -f /etc/tmpfiles.d/timemachine.conf 2>/dev/null || true
    echo "  ${GREEN}✓${NC} Runtime directory removed"

    # 7. Remove user (but not backup data)
    local tm_user="${TM_USER:-timemachine}"
    if id "${tm_user}" &>/dev/null; then
        # Kill any remaining processes
        pkill -u "${tm_user}" 2>/dev/null || true
        sleep 1
        userdel -r "${tm_user}" 2>/dev/null || userdel "${tm_user}" 2>/dev/null || true
        echo "  ${GREEN}✓${NC} User '${tm_user}' removed"
    fi

    # 8. Remove installation directory
    if [[ -d "${project_root}" && -f "${project_root}/bin/tmctl.sh" ]]; then
        echo "  Removing ${project_root}..."
        rm -rf "${project_root}"
        echo "  ${GREEN}✓${NC} Installation directory removed"
    fi

    echo ""
    echo "  ${GREEN}Uninstall complete.${NC}"
    echo ""
    echo "  Backup data was preserved in: ${TM_BACKUP_ROOT:-/backups}"
    echo "  To also remove backup data:   rm -rf ${TM_BACKUP_ROOT:-/backups}/timemachine"
    echo ""
}

_get_current_version() {
    local project_root="$1"
    local ver

    # 1. VERSION file (single source of truth)
    if [[ -f "${project_root}/VERSION" ]]; then
        ver=$(cat "${project_root}/VERSION" 2>/dev/null | tr -d '[:space:]')
        if [[ -n "${ver}" ]]; then
            echo "v${ver#v}"
            return
        fi
    fi

    # 2. Git tags
    ver=$(cd "${project_root}" && git describe --tags --abbrev=0 2>/dev/null || true)
    if [[ -n "${ver}" ]]; then
        echo "${ver}"
        return
    fi

    # 3. CHANGELOG.md
    if [[ -f "${project_root}/CHANGELOG.md" ]]; then
        ver=$(grep -m1 '^## \[' "${project_root}/CHANGELOG.md" | sed 's/^## \[\(.*\)\].*/v\1/' || true)
        if [[ -n "${ver}" ]]; then
            echo "${ver}"
            return
        fi
    fi

    echo "unknown"
}

_update_via_curl() {
    local project_root="$1"
    local tarball_url="https://github.com/ronaldjonkers/timemachine-backup-linux/archive/refs/heads/main.tar.gz"

    echo "  Downloading latest version via curl..."
    local tmp_dir
    tmp_dir=$(mktemp -d)

    if ! curl -sSL "${tarball_url}" | tar -xz -C "${tmp_dir}" 2>/dev/null; then
        rm -rf "${tmp_dir}"
        echo "  ${RED}Error:${NC} Download failed. Check internet connectivity."
        return 1
    fi

    local extracted="${tmp_dir}/timemachine-backup-linux-main"
    if [[ ! -d "${extracted}" ]]; then
        rm -rf "${tmp_dir}"
        echo "  ${RED}Error:${NC} Unexpected archive structure."
        return 1
    fi

    # Preserve .env, servers.conf, and .git
    echo "  Updating files..."
    rsync -a --exclude='.env' --exclude='config/servers.conf' --exclude='.git' \
        "${extracted}/" "${project_root}/"

    rm -rf "${tmp_dir}"
    return 0
}

cmd_update() {
    local project_root
    project_root=$(cd "${SCRIPT_DIR}/.." && pwd)
    local tm_user="${TM_USER:-timemachine}"

    echo "  ${BOLD}TimeMachine Backup — Update${NC}"
    echo ""

    # Determine current version
    local current_version
    current_version=$(_get_current_version "${project_root}")
    echo "  Current version: ${BOLD}${current_version}${NC}"

    local git_ok=0

    # Method 1: git-based update (preferred)
    if command -v git &>/dev/null && [[ -d "${project_root}/.git" ]]; then

        # Fix "dubious ownership" when running as root on a timemachine-owned repo
        git config --global --add safe.directory "${project_root}" 2>/dev/null || true

        # Unshallow if needed (shallow clones can't describe tags)
        if [[ -f "${project_root}/.git/shallow" ]]; then
            echo "  Unshallowing repository..."
            (cd "${project_root}" && git fetch --unshallow --quiet 2>/dev/null) || true
        fi

        # Fetch latest tags and commits
        echo "  Fetching latest version..."
        local fetch_output
        fetch_output=$(cd "${project_root}" && git fetch --tags 2>&1) || true

        # Check if fetch succeeded (remote reachable)
        if (cd "${project_root}" && git rev-parse origin/main &>/dev/null 2>&1); then
            git_ok=1
            local latest_version
            latest_version=$(cd "${project_root}" && git describe --tags --abbrev=0 origin/main 2>/dev/null || echo "unknown")

            if [[ "${current_version}" == "${latest_version}" ]]; then
                echo "  ${GREEN}Already up to date${NC} (${current_version})"
                return 0
            fi

            echo "  New version available: ${BOLD}${latest_version}${NC}"
            echo ""

            # Pull changes (handle dirty working tree)
            if ! (cd "${project_root}" && git reset --hard origin/main --quiet 2>/dev/null); then
                echo "  ${YELLOW}Warning:${NC} git reset failed, trying pull..."
                if ! (cd "${project_root}" && git pull --force --quiet 2>/dev/null); then
                    echo "  ${RED}Error:${NC} git pull failed."
                    echo "  Falling back to curl-based update..."
                    echo ""
                    _update_via_curl "${project_root}" || exit 1
                fi
            fi

            # Ensure tags are available locally
            (cd "${project_root}" && git fetch --tags --quiet 2>/dev/null) || true
        fi

        if [[ ${git_ok} -eq 0 ]]; then
            # git fetch failed — show the actual error and fall through to curl
            echo "  ${YELLOW}Warning:${NC} Could not reach git remote"
            if [[ -n "${fetch_output}" ]]; then
                echo "${fetch_output}" | head -3 | sed 's/^/    /'
            fi
            echo ""
            echo "  Falling back to curl-based update..."
            echo ""
        fi
    fi

    # Method 2: curl-based update (fallback — no git needed)
    if [[ ${git_ok} -eq 0 ]]; then
        if ! command -v curl &>/dev/null; then
            echo "  ${RED}Error:${NC} Neither git nor curl available. Install one and retry."
            exit 1
        fi
        _update_via_curl "${project_root}" || exit 1
    fi

    # Re-set script permissions
    find "${project_root}/bin" -name "*.sh" -exec chmod +x {} \;
    find "${project_root}/bin" -name "*.py" -exec chmod +x {} \;
    chmod +x "${project_root}/get.sh" "${project_root}/install.sh" "${project_root}/uninstall.sh" 2>/dev/null || true

    # Install missing dependencies
    if [[ "$(id -u)" -eq 0 ]]; then
        # Mail tool (added in v2.2.2)
        if ! command -v mail &>/dev/null && ! command -v mailx &>/dev/null; then
            echo "  Installing mail tool..."
            if command -v dnf &>/dev/null; then
                dnf install -y -q s-nail 2>/dev/null || dnf install -y -q mailx 2>/dev/null || true
            elif command -v yum &>/dev/null; then
                yum install -y -q s-nail 2>/dev/null || yum install -y -q mailx 2>/dev/null || true
            elif command -v apt-get &>/dev/null; then
                apt-get install -y -qq mailutils 2>/dev/null || true
            fi
            if command -v mail &>/dev/null || command -v mailx &>/dev/null; then
                echo "  ${GREEN}Mail tool installed${NC}"
            else
                echo "  ${YELLOW}Warning:${NC} Could not install mail tool. Install manually: s-nail, mailx, or mailutils"
            fi
        fi

        # Python 3 for API server (added in v2.14.0)
        local python_found=0
        for p in python3 python; do
            if command -v "${p}" &>/dev/null && "${p}" -c 'import sys; sys.exit(0 if sys.version_info[0]>=3 else 1)' 2>/dev/null; then
                python_found=1
                break
            fi
        done
        if [[ ${python_found} -eq 0 ]]; then
            echo "  Installing Python 3 (required for API server)..."
            if command -v apt-get &>/dev/null; then
                apt-get update -qq 2>/dev/null || true
                apt-get install -y -qq python3 2>/dev/null || true
            elif command -v dnf &>/dev/null; then
                dnf install -y -q python3 2>/dev/null || true
            elif command -v yum &>/dev/null; then
                yum install -y -q python3 2>/dev/null || true
            elif command -v zypper &>/dev/null; then
                zypper --non-interactive install python3 2>/dev/null || true
            elif command -v pacman &>/dev/null; then
                pacman -Sy --noconfirm --needed python 2>/dev/null || true
            elif command -v apk &>/dev/null; then
                apk add --no-cache python3 2>/dev/null || true
            fi
            if command -v python3 &>/dev/null; then
                echo "  ${GREEN}Python 3 installed${NC}"
            else
                echo "  ${YELLOW}Warning:${NC} Could not install Python 3. API server will fall back to socat."
            fi
        fi
    fi

    # Apply all configuration changes (sudoers, permissions, symlinks, service)
    if [[ "$(id -u)" -eq 0 ]]; then
        echo ""
        echo "  ${BOLD}Applying configuration changes...${NC}"
        bash "${project_root}/install.sh" --reconfigure
    else
        echo ""
        echo "  ${YELLOW}Warning:${NC} Not running as root — skipping reconfiguration."
        echo "  Run 'sudo tmctl update' to apply all configuration changes."
    fi

    local new_version
    new_version=$(_get_current_version "${project_root}")
    echo ""
    echo "  ${GREEN}Updated successfully:${NC} ${current_version} → ${new_version}"

    # Show changelog
    if [[ -f "${project_root}/CHANGELOG.md" ]]; then
        echo ""
        echo "  ${BOLD}What's new:${NC}"
        sed -n "/^## \[${new_version#v}\]/,/^## \[/p" "${project_root}/CHANGELOG.md" | head -20 | sed '$d' | sed 's/^/  /'
    fi
}

# ============================================================
# AUTO-UPDATE
# ============================================================

cmd_auto_update() {
    local action="${1:-status}"
    local cron_file="/etc/cron.d/timemachine-update"
    local project_root="${SCRIPT_DIR}/.."
    local tmctl_path="/usr/bin/tmctl"
    local log_file

    # Resolve log path from config
    if [[ -f "${project_root}/.env" ]]; then
        # shellcheck disable=SC1091
        source "${project_root}/.env" 2>/dev/null || true
    fi
    log_file="${TM_HOME:-/home/timemachine}/logs/auto-update.log"

    if [[ ! -x "${tmctl_path}" ]]; then
        tmctl_path="${SCRIPT_DIR}/tmctl.sh"
    fi

    case "${action}" in
        on|enable)
            if [[ "$(id -u)" -ne 0 ]]; then
                echo "  ${RED}Error:${NC} Run with sudo to enable auto-update"
                exit 1
            fi
            cat > "${cron_file}" <<CRON_EOF
# TimeMachine Backup — Weekly auto-update (Sunday 04:00)
MAILTO=""
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 4 * * 0 root ${tmctl_path} update >> ${log_file} 2>&1
CRON_EOF
            chmod 644 "${cron_file}"
            echo "  ${GREEN}Auto-update enabled${NC} (every Sunday at 04:00)"
            echo "  Log: ${log_file}"
            ;;
        off|disable)
            if [[ "$(id -u)" -ne 0 ]]; then
                echo "  ${RED}Error:${NC} Run with sudo to disable auto-update"
                exit 1
            fi
            if [[ -f "${cron_file}" ]]; then
                rm -f "${cron_file}"
                echo "  ${YELLOW}Auto-update disabled${NC}"
            else
                echo "  Auto-update is already disabled"
            fi
            ;;
        status)
            if [[ -f "${cron_file}" ]]; then
                echo "  Auto-update: ${GREEN}enabled${NC} (every Sunday at 04:00)"
                if [[ -f "${log_file}" ]]; then
                    local last_line
                    last_line=$(tail -1 "${log_file}" 2>/dev/null || true)
                    if [[ -n "${last_line}" ]]; then
                        echo "  Last log entry: ${last_line}"
                    fi
                fi
            else
                echo "  Auto-update: ${YELLOW}disabled${NC}"
                echo "  Enable with: sudo tmctl auto-update on"
            fi
            ;;
        *)
            echo "Usage: tmctl auto-update <on|off|status>"
            exit 1
            ;;
    esac
}

# ============================================================
# MAIN
# ============================================================

usage() {
    echo "TimeMachine Backup - CLI Control Tool"
    echo ""
    echo "Usage: tmctl <command> [OPTIONS]"
    echo ""
    echo "Commands:"
    echo "  status              Show service status and processes"
    echo "  ps                  List backup processes"
    echo "  kill <hostname>     Kill a running backup"
    echo "  backup <hostname>   Start a backup"
    echo "  restore <hostname>  Restore from backup"
    echo "  logs [hostname]     Show logs"
    echo "  servers             List configured servers"
    echo "  server add <host>   Add a server [OPTIONS]"
    echo "  server edit <host>  Edit server settings [OPTIONS]"
    echo "  server remove <host> Remove a server"
    echo "  snapshots <host>    List snapshots"
    echo "  ssh-key             Show SSH public key"
    echo "  setup-web           Setup Nginx + SSL + Auth for web dashboard"
    echo "  update              Update to the latest version"
    echo "  auto-update <on|off|status>  Manage weekly auto-updates"
    echo "  fix-permissions      Fix all file/directory permissions (sudo)"
    echo "  uninstall           Remove TimeMachine completely (sudo)"
    echo "  version             Show version"
    exit 1
}

COMMAND="${1:-}"
shift 2>/dev/null || true

case "${COMMAND}" in
    status)     cmd_status ;;
    ps)         cmd_ps ;;
    kill)       cmd_kill "$@" ;;
    backup)     cmd_backup "$@" ;;
    restore)    exec "${SCRIPT_DIR}/restore.sh" "$@" ;;
    logs|log)   cmd_logs "$@" ;;
    servers)    cmd_servers ;;
    server)
        SUBCMD="${1:-}"
        shift 2>/dev/null || true
        case "${SUBCMD}" in
            add)    cmd_server_add "$@" ;;
            remove|rm|del) cmd_server_remove "$@" ;;
            edit|set) cmd_server_edit "$@" ;;
            *)      echo "Usage: tmctl server <add|edit|remove> <hostname>"; exit 1 ;;
        esac
        ;;
    snapshots)  cmd_snapshots "$@" ;;
    ssh-key)    cmd_ssh_key ;;
    setup-web)  exec "${SCRIPT_DIR}/setup-web.sh" "$@" ;;
    update)     cmd_update ;;
    auto-update) cmd_auto_update "$@" ;;
    fix-permissions|fix-perms) cmd_fix_permissions ;;
    uninstall)  cmd_uninstall ;;
    version|-v|--version) cmd_version ;;
    help|--help|-h|"")    usage ;;
    *)          echo "Unknown command: ${COMMAND}"; usage ;;
esac
