#!/usr/bin/env bash
# ============================================================
# TimeMachine Backup - Uninstaller
# ============================================================
# Completely removes TimeMachine from server or client.
#
# Single-line uninstall:
#   curl -sSL https://raw.githubusercontent.com/ronaldjonkers/timemachine-backup-linux/main/uninstall.sh | sudo bash
#
# Options:
#   --force           Skip confirmation prompt
#   --remove-backups  Also remove backup data (DANGEROUS)
#
# Supports: Debian/Ubuntu, RHEL/CentOS/Fedora, openSUSE, Arch, Alpine, macOS
# ============================================================

set -euo pipefail

# ============================================================
# CONSTANTS
# ============================================================

TM_USER="${TM_USER:-timemachine}"
TM_HOME="/home/${TM_USER}"
TM_RUN_DIR="/var/run/timemachine"
INSTALL_DIR="${TM_INSTALL_DIR:-/opt/timemachine-backup-linux}"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
MAGENTA=$'\033[0;35m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
NC=$'\033[0m'

# ============================================================
# HELPERS
# ============================================================

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

step() {
    local num="$1" total="$2"
    shift 2
    echo ""
    echo -e "  ${RED}▶ [${num}/${total}]${NC} ${BOLD}$*${NC}"
    echo -e "  ${RED}─────────────────────────────────────────────────────${NC}"
}

step_done() {
    echo -e "  ${GREEN}✔${NC} $*"
}

step_skip() {
    echo -e "  ${DIM}○ $* (not found, skipping)${NC}"
}

# Read user input — works both interactively and when piped via curl
read_input() {
    local prompt="$1" default="$2" result
    if [[ -t 0 ]]; then
        read -r -p "${prompt}" result
    elif [[ -e /dev/tty ]]; then
        read -r -p "${prompt}" result < /dev/tty
    else
        result=""
    fi
    echo "${result:-${default}}"
}

# ============================================================
# BANNER
# ============================================================

show_uninstall_banner() {
    echo ""
    echo -e "${RED}"
    echo '    ████████╗██╗███╗   ███╗███████╗'
    echo '    ╚══██╔══╝██║████╗ ████║██╔════╝'
    echo '       ██║   ██║██╔████╔██║█████╗  '
    echo '       ██║   ██║██║╚██╔╝██║██╔══╝  '
    echo '       ██║   ██║██║ ╚═╝ ██║███████╗'
    echo '       ╚═╝   ╚═╝╚═╝     ╚═╝╚══════╝'
    echo -e "${YELLOW}"
    echo '    ███╗   ███╗ █████╗  ██████╗██╗  ██╗██╗███╗   ██╗███████╗'
    echo '    ████╗ ████║██╔══██╗██╔════╝██║  ██║██║████╗  ██║██╔════╝'
    echo '    ██╔████╔██║███████║██║     ███████║██║██╔██╗ ██║█████╗  '
    echo '    ██║╚██╔╝██║██╔══██║██║     ██╔══██║██║██║╚██╗██║██╔══╝  '
    echo '    ██║ ╚═╝ ██║██║  ██║╚██████╗██║  ██║██║██║ ╚████║███████╗'
    echo '    ╚═╝     ╚═╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝╚═╝╚═╝  ╚═══╝╚══════╝'
    echo -e "${NC}"
    echo -e "    ${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "    ${BOLD}⚠  U N I N S T A L L E R${NC}"
    echo -e "    ${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# ============================================================
# ARGUMENT PARSING
# ============================================================

FORCE=0
REMOVE_BACKUPS=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force|-f)     FORCE=1; shift ;;
        --remove-backups) REMOVE_BACKUPS=1; shift ;;
        *)              error "Unknown option: $1" ;;
    esac
done

# ============================================================
# DETECTION
# ============================================================

detect_install_type() {
    local type="none"

    # Check for server indicators
    if [[ -f /etc/systemd/system/timemachine.service ]] || \
       [[ -f /etc/cron.d/timemachine ]] || \
       [[ -d "${INSTALL_DIR}/bin" ]]; then
        type="server"
    # Check for client indicators
    elif id "${TM_USER}" &>/dev/null; then
        type="client"
    fi

    echo "${type}"
}

# ============================================================
# PRE-FLIGHT
# ============================================================

if [[ "$(id -u)" -ne 0 ]]; then
    error "This script must be run as root (use sudo)"
fi

show_uninstall_banner

INSTALL_TYPE=$(detect_install_type)

if [[ "${INSTALL_TYPE}" == "none" ]]; then
    info "No TimeMachine installation detected on this system."
    info "Nothing to uninstall."
    exit 0
fi

echo -e "  ${BOLD}Detected installation type:${NC} ${CYAN}${INSTALL_TYPE}${NC}"
echo ""

# ============================================================
# WHAT WILL BE REMOVED
# ============================================================

echo -e "  ${BOLD}The following will be removed:${NC}"
echo ""

if [[ "${INSTALL_TYPE}" == "server" ]]; then
    [[ -f /etc/systemd/system/timemachine.service ]] && \
        echo "    - Systemd service (timemachine.service)"
    [[ -f /etc/cron.d/timemachine ]] && \
        echo "    - Cron job (/etc/cron.d/timemachine)"
    [[ -f /etc/sudoers.d/timemachine ]] && \
        echo "    - Sudoers rules (/etc/sudoers.d/timemachine)"
    [[ -L /usr/local/bin/tmctl ]] && \
        echo "    - Symlink /usr/local/bin/tmctl"
    [[ -L /usr/local/bin/timemachine ]] && \
        echo "    - Symlink /usr/local/bin/timemachine"
    [[ -L /usr/local/bin/tm-restore ]] && \
        echo "    - Symlink /usr/local/bin/tm-restore"
    [[ -f /etc/nginx/sites-enabled/timemachine ]] && \
        echo "    - Nginx config (/etc/nginx/sites-*/timemachine)"
    id "${TM_USER}" &>/dev/null && \
        echo "    - User '${TM_USER}' and home directory (${TM_HOME})"
    [[ -d "${TM_RUN_DIR}" ]] && \
        echo "    - Runtime directory (${TM_RUN_DIR})"
    [[ -d "${INSTALL_DIR}" ]] && \
        echo "    - Installation directory (${INSTALL_DIR})"
else
    [[ -f /etc/cron.d/timemachine-dump ]] && \
        echo "    - Cron job (/etc/cron.d/timemachine-dump)"
    [[ -f /etc/sudoers.d/timemachine ]] && \
        echo "    - Sudoers rules (/etc/sudoers.d/timemachine)"
    id "${TM_USER}" &>/dev/null && \
        echo "    - User '${TM_USER}' and home directory (${TM_HOME})"
    [[ -d "${TM_RUN_DIR}" ]] && \
        echo "    - Runtime directory (${TM_RUN_DIR})"
fi

if [[ ${REMOVE_BACKUPS} -eq 1 ]]; then
    echo ""
    echo -e "    ${RED}${BOLD}⚠  BACKUP DATA WILL ALSO BE REMOVED!${NC}"
fi

echo ""
echo -e "  ${YELLOW}${BOLD}Backup data will NOT be removed unless --remove-backups is specified.${NC}"
echo ""

# ============================================================
# CONFIRMATION
# ============================================================

if [[ ${FORCE} -eq 0 ]]; then
    local_confirm=$(read_input "  ${BOLD}Are you sure you want to uninstall? [y/N]:${NC} " "n")
    case "${local_confirm}" in
        y|Y|yes|YES) ;;
        *) info "Uninstall cancelled."; exit 0 ;;
    esac
fi

# ============================================================
# SERVER UNINSTALL
# ============================================================

uninstall_server() {
    local total=8
    [[ ${REMOVE_BACKUPS} -eq 1 ]] && total=9

    step 1 ${total} "Stopping TimeMachine service"
    if command -v systemctl &>/dev/null && systemctl is-active timemachine.service &>/dev/null; then
        systemctl stop timemachine.service
        step_done "Service stopped"
    else
        step_skip "Service not running"
    fi

    step 2 ${total} "Disabling and removing systemd service"
    if [[ -f /etc/systemd/system/timemachine.service ]]; then
        systemctl disable timemachine.service 2>/dev/null || true
        rm -f /etc/systemd/system/timemachine.service
        systemctl daemon-reload
        step_done "Systemd service removed"
    else
        step_skip "Systemd service"
    fi

    step 3 ${total} "Removing cron jobs"
    local removed_cron=0
    if [[ -f /etc/cron.d/timemachine ]]; then
        rm -f /etc/cron.d/timemachine
        removed_cron=1
    fi
    if [[ -f /etc/cron.d/timemachine-dump ]]; then
        rm -f /etc/cron.d/timemachine-dump
        removed_cron=1
    fi
    if [[ ${removed_cron} -eq 1 ]]; then
        step_done "Cron jobs removed"
    else
        step_skip "Cron jobs"
    fi

    step 4 ${total} "Removing sudoers rules"
    if [[ -f /etc/sudoers.d/timemachine ]]; then
        rm -f /etc/sudoers.d/timemachine
        step_done "Sudoers rules removed"
    else
        step_skip "Sudoers rules"
    fi

    step 5 ${total} "Removing symlinks"
    local removed_links=0
    for link in /usr/local/bin/tmctl /usr/local/bin/timemachine /usr/local/bin/tm-restore; do
        if [[ -L "${link}" ]]; then
            rm -f "${link}"
            removed_links=1
        fi
    done
    if [[ ${removed_links} -eq 1 ]]; then
        step_done "Symlinks removed from /usr/local/bin"
    else
        step_skip "Symlinks"
    fi

    step 6 ${total} "Removing nginx configuration"
    local removed_nginx=0
    for f in /etc/nginx/sites-enabled/timemachine /etc/nginx/sites-available/timemachine; do
        if [[ -f "${f}" ]] || [[ -L "${f}" ]]; then
            rm -f "${f}"
            removed_nginx=1
        fi
    done
    if [[ ${removed_nginx} -eq 1 ]]; then
        nginx -t &>/dev/null && systemctl reload nginx 2>/dev/null || true
        step_done "Nginx configuration removed"
    else
        step_skip "Nginx configuration"
    fi

    step 7 ${total} "Removing timemachine user and directories"
    if id "${TM_USER}" &>/dev/null; then
        userdel -r "${TM_USER}" 2>/dev/null || true
        step_done "User '${TM_USER}' removed (with home directory)"
    else
        step_skip "User '${TM_USER}'"
    fi
    rm -rf "${TM_RUN_DIR}" 2>/dev/null || true

    step 8 ${total} "Removing installation directory"
    if [[ -d "${INSTALL_DIR}" ]]; then
        rm -rf "${INSTALL_DIR}"
        step_done "Installation directory removed: ${INSTALL_DIR}"
    else
        step_skip "Installation directory"
    fi

    if [[ ${REMOVE_BACKUPS} -eq 1 ]]; then
        step 9 ${total} "Removing backup data"
        # Try to find the backup root from .env or use default
        local backup_root="/backups/timemachine"
        if [[ -f "${INSTALL_DIR}/.env" ]]; then
            local env_root
            env_root=$(grep -oP 'TM_BACKUP_ROOT="\K[^"]+' "${INSTALL_DIR}/.env" 2>/dev/null || true)
            [[ -n "${env_root}" ]] && backup_root="${env_root}"
        fi
        if [[ -d "${backup_root}" ]]; then
            rm -rf "${backup_root}"
            step_done "Backup data removed: ${backup_root}"
        else
            step_skip "Backup data at ${backup_root}"
        fi
    fi
}

# ============================================================
# CLIENT UNINSTALL
# ============================================================

uninstall_client() {
    local total=4

    step 1 ${total} "Removing cron jobs"
    if [[ -f /etc/cron.d/timemachine-dump ]]; then
        rm -f /etc/cron.d/timemachine-dump
        step_done "Cron job removed"
    else
        step_skip "Cron jobs"
    fi

    step 2 ${total} "Removing sudoers rules"
    if [[ -f /etc/sudoers.d/timemachine ]]; then
        rm -f /etc/sudoers.d/timemachine
        step_done "Sudoers rules removed"
    else
        step_skip "Sudoers rules"
    fi

    step 3 ${total} "Removing timemachine user"
    if id "${TM_USER}" &>/dev/null; then
        userdel -r "${TM_USER}" 2>/dev/null || true
        step_done "User '${TM_USER}' removed (with home directory)"
    else
        step_skip "User '${TM_USER}'"
    fi

    step 4 ${total} "Removing runtime directory"
    if [[ -d "${TM_RUN_DIR}" ]]; then
        rm -rf "${TM_RUN_DIR}"
        step_done "Runtime directory removed"
    else
        step_skip "Runtime directory"
    fi
}

# ============================================================
# MAIN
# ============================================================

echo -e "  ${RED}${BOLD}Uninstalling TimeMachine (${INSTALL_TYPE})...${NC}"

case "${INSTALL_TYPE}" in
    server) uninstall_server ;;
    client) uninstall_client ;;
esac

echo ""
echo -e "    ${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "    ${GREEN}${BOLD}  ✅  TimeMachine has been uninstalled.${NC}"
echo -e "    ${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if [[ ${REMOVE_BACKUPS} -eq 0 ]]; then
    info "Backup data was preserved. Remove manually if no longer needed."
fi

info "Thank you for using TimeMachine Backup!"
echo ""
