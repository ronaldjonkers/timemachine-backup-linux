#!/usr/bin/env bash
# ============================================================
# TimeMachine Backup - Client Installation Script
# ============================================================
# Run this script on each server you want to back up.
# It creates the timemachine user, configures SSH access,
# sets up sudoers, and optionally deploys the database dump
# script.
#
# Usage:
#   sudo ./install-client.sh [OPTIONS]
#
# Options:
#   --server <host>     Backup server hostname/IP (auto-downloads SSH key)
#   --server-port <p>   Backup server API port (default: 7600)
#   --ssh-key <key>     SSH public key string (manual alternative)
#   --with-db           Deploy database dump script
#   --db-cronjob        Also install a cron job for DB dumps
#   --uninstall         Remove timemachine user and config
#
# The --server option connects to the backup server's API to
# automatically download the correct SSH public key. This removes
# the need to manually copy keys.
#
# Supports: Debian/Ubuntu, RHEL/CentOS/Fedora
# ============================================================

set -euo pipefail

# ============================================================
# CONSTANTS
# ============================================================

TM_USER="${TM_USER:-timemachine}"
TM_HOME="/home/${TM_USER}"
TM_RUN_DIR="/var/run/timemachine"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ============================================================
# HELPERS
# ============================================================

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        error "This script must be run as root (use sudo)"
    fi
}

# ============================================================
# ARGUMENT PARSING
# ============================================================

SSH_PUBLIC_KEY="${TM_SSH_PUBLIC_KEY:-}"
BACKUP_SERVER=""
BACKUP_SERVER_PORT="7600"
WITH_DB=0
DB_CRONJOB=0
UNINSTALL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --server)
            BACKUP_SERVER="$2"
            shift 2
            ;;
        --server-port)
            BACKUP_SERVER_PORT="$2"
            shift 2
            ;;
        --ssh-key)
            SSH_PUBLIC_KEY="$2"
            shift 2
            ;;
        --with-db)
            WITH_DB=1
            shift
            ;;
        --db-cronjob)
            DB_CRONJOB=1
            WITH_DB=1
            shift
            ;;
        --uninstall)
            UNINSTALL=1
            shift
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

# ============================================================
# UNINSTALL
# ============================================================

do_uninstall() {
    info "Uninstalling TimeMachine client..."

    # Remove cron job
    rm -f /etc/cron.d/timemachine-dump

    # Remove sudoers
    rm -f /etc/sudoers.d/timemachine

    # Remove user
    if id "${TM_USER}" &>/dev/null; then
        userdel -r "${TM_USER}" 2>/dev/null || true
        info "Removed user '${TM_USER}'"
    fi

    # Remove run directory
    rm -rf "${TM_RUN_DIR}"

    info "Uninstall complete"
    exit 0
}

# ============================================================
# INSTALL
# ============================================================

setup_user() {
    info "Setting up user '${TM_USER}'..."

    if id "${TM_USER}" &>/dev/null; then
        info "User '${TM_USER}' already exists"
    else
        useradd -m -s /bin/bash "${TM_USER}"
        passwd -d "${TM_USER}" &>/dev/null || true
        info "Created user '${TM_USER}'"
    fi
}

fetch_ssh_key() {
    if [[ -z "${BACKUP_SERVER}" ]]; then
        return 1
    fi

    info "Downloading SSH public key from ${BACKUP_SERVER}:${BACKUP_SERVER_PORT}..."

    if ! command -v curl &>/dev/null; then
        error "curl is required for --server option. Install curl first."
    fi

    local key
    key=$(curl -sf --connect-timeout 10 \
        "http://${BACKUP_SERVER}:${BACKUP_SERVER_PORT}/api/ssh-key/raw" 2>/dev/null)

    if [[ -z "${key}" ]]; then
        error "Failed to download SSH key from ${BACKUP_SERVER}:${BACKUP_SERVER_PORT}. Is the TimeMachine service running?"
    fi

    SSH_PUBLIC_KEY="${key}"
    info "SSH key downloaded successfully from ${BACKUP_SERVER}"
}

setup_ssh() {
    # Auto-download key from server if --server was provided
    if [[ -n "${BACKUP_SERVER}" && -z "${SSH_PUBLIC_KEY}" ]]; then
        fetch_ssh_key
    fi

    if [[ -z "${SSH_PUBLIC_KEY}" ]]; then
        error "SSH public key is required. Use --server <host> or --ssh-key '<key>'"
    fi

    info "Configuring SSH access..."

    local ssh_dir="${TM_HOME}/.ssh"
    mkdir -p "${ssh_dir}"

    # Add key (avoid duplicates)
    local auth_keys="${ssh_dir}/authorized_keys"
    touch "${auth_keys}"

    if grep -qF "${SSH_PUBLIC_KEY}" "${auth_keys}" 2>/dev/null; then
        info "SSH key already present"
    else
        echo "${SSH_PUBLIC_KEY}" >> "${auth_keys}"
        info "SSH key added"
    fi

    chown -R "${TM_USER}:${TM_USER}" "${ssh_dir}"
    chmod 700 "${ssh_dir}"
    chmod 600 "${auth_keys}"
}

setup_sudoers() {
    info "Configuring sudoers..."

    local sudoers_file="/etc/sudoers.d/timemachine"

    # Determine correct paths for this system
    local rsync_path cat_path
    rsync_path=$(command -v rsync 2>/dev/null || echo "/usr/bin/rsync")
    cat_path=$(command -v cat 2>/dev/null || echo "/bin/cat")

    local sudoers_content="# TimeMachine Backup - client sudoers rules
Defaults:${TM_USER} !tty_tickets
Defaults:${TM_USER} !requiretty
${TM_USER} ALL=NOPASSWD:${rsync_path}, ${cat_path}"

    # Add MySQL commands if database support is requested
    if [[ ${WITH_DB} -eq 1 ]]; then
        local mysql_path mysqldump_path
        mysql_path=$(command -v mysql 2>/dev/null || echo "/usr/bin/mysql")
        mysqldump_path=$(command -v mysqldump 2>/dev/null || echo "/usr/bin/mysqldump")
        sudoers_content+=", ${mysql_path}, ${mysqldump_path}"
    fi

    echo "${sudoers_content}" > "${sudoers_file}"
    chmod 440 "${sudoers_file}"

    if visudo -cf "${sudoers_file}" &>/dev/null; then
        info "Sudoers configured"
    else
        error "Invalid sudoers syntax! Removing ${sudoers_file}"
        rm -f "${sudoers_file}"
    fi
}

setup_directories() {
    info "Setting up directories..."

    mkdir -p "${TM_RUN_DIR}"
    chown "${TM_USER}:${TM_USER}" "${TM_RUN_DIR}"

    mkdir -p "${TM_HOME}/sql"
    chown "${TM_USER}:${TM_USER}" "${TM_HOME}/sql"
}

deploy_db_scripts() {
    if [[ ${WITH_DB} -eq 0 ]]; then
        return
    fi

    info "Deploying database dump scripts..."

    # Copy dump_dbs.sh to client
    if [[ -f "${SCRIPT_DIR}/bin/dump_dbs.sh" ]]; then
        install -m 700 -o "${TM_USER}" -g "${TM_USER}" \
            "${SCRIPT_DIR}/bin/dump_dbs.sh" "${TM_HOME}/dump_dbs.sh"
        info "Deployed dump_dbs.sh"
    else
        warn "dump_dbs.sh not found in ${SCRIPT_DIR}/bin/"
    fi

    # Copy dump_dbs_wait.sh to client
    if [[ -f "${SCRIPT_DIR}/bin/dump_dbs_wait.sh" ]]; then
        install -m 700 -o "${TM_USER}" -g "${TM_USER}" \
            "${SCRIPT_DIR}/bin/dump_dbs_wait.sh" "${TM_HOME}/dump_dbs_wait.sh"
        info "Deployed dump_dbs_wait.sh"
    else
        warn "dump_dbs_wait.sh not found in ${SCRIPT_DIR}/bin/"
    fi

    # Install cron job for autonomous DB dumps
    if [[ ${DB_CRONJOB} -eq 1 ]]; then
        local cron_file="/etc/cron.d/timemachine-dump"
        echo "# TimeMachine - Autonomous database dump
0 1 * * * ${TM_USER} /bin/bash ${TM_HOME}/dump_dbs.sh --db-cronjob >> ${TM_HOME}/dump_dbs.log 2>&1" > "${cron_file}"
        chmod 644 "${cron_file}"
        info "Database dump cron job installed"
    fi
}

# ============================================================
# MAIN
# ============================================================

main() {
    echo "============================================"
    echo "  TimeMachine Backup - Client Installation"
    echo "============================================"
    echo ""

    require_root

    if [[ ${UNINSTALL} -eq 1 ]]; then
        do_uninstall
    fi

    setup_user
    setup_ssh
    setup_sudoers
    setup_directories
    deploy_db_scripts

    echo ""
    echo "============================================"
    echo "  Client Installation Complete!"
    echo "============================================"
    echo ""
    info "This server is now ready to be backed up by TimeMachine."
    if [[ -n "${BACKUP_SERVER}" ]]; then
        info "Backup server: ${BACKUP_SERVER}"
    fi
    info "Test connectivity from the backup server:"
    echo "  ssh -i ~/.ssh/id_rsa ${TM_USER}@$(hostname -f) 'echo OK'"
    echo ""
}

main "$@"
