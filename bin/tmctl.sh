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
#   uninstall           Remove TimeMachine completely
#   version             Show version
#
# Options:
#   --api <url>         API base URL (default: http://localhost:7600)
#   --verbose           Enable debug output
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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
    for state_file in "${TM_RUN_DIR}/state"/proc-*.state; do
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

cmd_version() {
    echo "TimeMachine Backup v0.6.0"
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
    rm -f /usr/local/bin/tmctl
    rm -f /usr/local/bin/timemachine
    rm -f /usr/local/bin/tm-restore
    echo "  ${GREEN}✓${NC} Symlinks removed"

    # 5. Remove nginx config (if setup-web was used)
    if [[ -f /etc/nginx/sites-enabled/timemachine ]]; then
        rm -f /etc/nginx/sites-enabled/timemachine
        rm -f /etc/nginx/sites-available/timemachine
        rm -f /etc/nginx/.timemachine_htpasswd
        nginx -t &>/dev/null && nginx -s reload &>/dev/null || true
        echo "  ${GREEN}✓${NC} Nginx configuration removed"
    fi

    # 6. Remove run/state directory
    rm -rf /var/run/timemachine
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

cmd_update() {
    local project_root="${SCRIPT_DIR}/.."

    echo "  ${BOLD}TimeMachine Backup — Update${NC}"
    echo ""

    # Check if git is available
    if ! command -v git &>/dev/null; then
        echo "  ${RED}Error:${NC} git is not installed"
        exit 1
    fi

    # Check if this is a git repo
    if [[ ! -d "${project_root}/.git" ]]; then
        echo "  ${RED}Error:${NC} Not a git repository. Was TimeMachine installed via get.sh?"
        echo "  Re-install with:"
        echo "    curl -sSL https://raw.githubusercontent.com/ronaldjonkers/timemachine-backup-linux/main/get.sh | sudo bash"
        exit 1
    fi

    # Show current version
    local current_version
    current_version=$(cd "${project_root}" && git describe --tags --abbrev=0 2>/dev/null || echo "unknown")
    echo "  Current version: ${BOLD}${current_version}${NC}"

    # Pull latest
    echo "  Fetching latest version..."
    if ! (cd "${project_root}" && git fetch --tags --quiet 2>/dev/null); then
        echo "  ${RED}Error:${NC} Could not reach remote repository (offline?)"
        exit 1
    fi

    local latest_version
    latest_version=$(cd "${project_root}" && git describe --tags --abbrev=0 origin/main 2>/dev/null || echo "unknown")

    if [[ "${current_version}" == "${latest_version}" ]]; then
        echo "  ${GREEN}Already up to date${NC} (${current_version})"
        return 0
    fi

    echo "  New version available: ${BOLD}${latest_version}${NC}"
    echo ""

    # Pull changes
    if ! (cd "${project_root}" && git pull --quiet 2>/dev/null); then
        echo "  ${RED}Error:${NC} git pull failed. Check for local changes."
        exit 1
    fi

    # Re-set script permissions
    find "${project_root}/bin" -name "*.sh" -exec chmod +x {} \;

    # Restart service if running
    if command -v systemctl &>/dev/null && systemctl is-active timemachine &>/dev/null; then
        echo "  Restarting timemachine service..."
        systemctl restart timemachine
        echo "  ${GREEN}Service restarted${NC}"
    fi

    echo ""
    echo "  ${GREEN}Updated successfully:${NC} ${current_version} → ${latest_version}"

    # Show changelog for new version
    if [[ -f "${project_root}/CHANGELOG.md" ]]; then
        echo ""
        echo "  ${BOLD}What's new:${NC}"
        # Show lines between the latest version header and the next version header
        sed -n "/^## \[${latest_version#v}\]/,/^## \[/p" "${project_root}/CHANGELOG.md" | head -20 | sed '$d' | sed 's/^/  /'
    fi
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
    echo "  server remove <host> Remove a server"
    echo "  snapshots <host>    List snapshots"
    echo "  ssh-key             Show SSH public key"
    echo "  setup-web           Setup Nginx + SSL + Auth for web dashboard"
    echo "  update              Update to the latest version"
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
            *)      echo "Usage: tmctl server <add|remove> <hostname>"; exit 1 ;;
        esac
        ;;
    snapshots)  cmd_snapshots "$@" ;;
    ssh-key)    cmd_ssh_key ;;
    setup-web)  exec "${SCRIPT_DIR}/setup-web.sh" "$@" ;;
    update)     cmd_update ;;
    uninstall)  cmd_uninstall ;;
    version|-v|--version) cmd_version ;;
    help|--help|-h|"")    usage ;;
    *)          echo "Unknown command: ${COMMAND}"; usage ;;
esac
