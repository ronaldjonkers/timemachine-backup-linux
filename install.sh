#!/usr/bin/env bash
# ============================================================
# TimeMachine Backup - Unified Installer
# ============================================================
# Installs TimeMachine as either a backup SERVER or CLIENT.
# Safe to run multiple times (idempotent).
#
# Usage:
#   sudo ./install.sh                          # Interactive mode selection
#   sudo ./install.sh server                   # Install backup server
#   sudo ./install.sh client [OPTIONS]         # Install client
#
# Client options:
#   --server <host>     Backup server hostname/IP (auto-downloads SSH key)
#   --server-port <p>   Backup server API port (default: 7600)
#   --ssh-key <key>     SSH public key string (manual alternative)
#   --with-db           Deploy database dump script (auto-detect DB engines)
#   --db-type <types>   Comma-separated DB types: mysql,postgresql,mongodb,redis,sqlite
#   --db-cronjob        Also install a cron job for DB dumps
#   --uninstall         Remove timemachine user and config
#
# Single-line install:
#   curl -sSL https://raw.githubusercontent.com/ronaldjonkers/timemachine-backup-linux/main/get.sh | sudo bash
#
# Supports: Debian/Ubuntu, RHEL/CentOS/Fedora, macOS (dev only)
# ============================================================

set -euo pipefail

# ============================================================
# CONSTANTS
# ============================================================

INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"
TM_USER="${TM_USER:-timemachine}"
TM_HOME="/home/${TM_USER}"
TM_RUN_DIR="/var/run/timemachine"
TM_BACKUP_ROOT="${TM_BACKUP_ROOT:-/backups}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ============================================================
# HELPERS
# ============================================================

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

detect_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        echo "${ID}"
    elif [[ "$(uname)" == "Darwin" ]]; then
        echo "macos"
    else
        echo "unknown"
    fi
}

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        error "This script must be run as root (use sudo)"
    fi
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
# MODE SELECTION
# ============================================================

INSTALL_MODE=""
SSH_PUBLIC_KEY="${TM_SSH_PUBLIC_KEY:-}"
BACKUP_SERVER=""
BACKUP_SERVER_PORT="7600"
WITH_DB=0
DB_TYPE="auto"
DB_CRONJOB=0
UNINSTALL=0

parse_args() {
    # First positional argument is the mode
    if [[ $# -gt 0 && "$1" != --* ]]; then
        INSTALL_MODE="$1"
        shift
    fi

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
            --db-type)
                WITH_DB=1
                DB_TYPE="$2"
                shift 2
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
}

select_mode() {
    if [[ -n "${INSTALL_MODE}" ]]; then
        case "${INSTALL_MODE}" in
            server|client) return ;;
            *) error "Invalid mode '${INSTALL_MODE}'. Use 'server' or 'client'." ;;
        esac
    fi

    echo ""
    echo -e "${BOLD}What would you like to install?${NC}"
    echo ""
    echo "  1) ${CYAN}Server${NC}  — The backup server that stores all backups"
    echo "  2) ${CYAN}Client${NC}  — A remote server that will be backed up"
    echo ""

    local choice
    choice=$(read_input "  Choose [1/2]: " "")

    case "${choice}" in
        1|server|s)  INSTALL_MODE="server" ;;
        2|client|c)  INSTALL_MODE="client" ;;
        *)           error "Invalid choice '${choice}'. Please enter 1 or 2." ;;
    esac
}

# ############################################################
#
#  SERVER INSTALLATION
#
# ############################################################

# ============================================================
# SERVER: DEPENDENCY INSTALLATION
# ============================================================

server_install_dependencies() {
    local os="$1"
    local packages=(rsync openssh-server socat curl)

    info "Installing dependencies for ${os}..."

    case "${os}" in
        ubuntu|debian)
            apt-get update -qq
            apt-get install -y -qq "${packages[@]}" mailutils gnupg2 2>/dev/null || true
            ;;
        centos|rhel|fedora|rocky|almalinux)
            yum install -y -q "${packages[@]}" mailx gnupg2 2>/dev/null || \
            dnf install -y -q "${packages[@]}" mailx gnupg2 2>/dev/null || true
            ;;
        macos)
            warn "macOS detected. This is for development/testing only."
            warn "Ensure rsync, ssh, socat, and curl are available."
            if command -v brew &>/dev/null; then
                brew install socat 2>/dev/null || true
            fi
            ;;
        *)
            warn "Unknown OS '${os}'. Please install rsync, openssh, socat, and curl manually."
            ;;
    esac
}

# ============================================================
# SERVER: USER SETUP
# ============================================================

server_setup_user() {
    info "Setting up user '${TM_USER}'..."

    if id "${TM_USER}" &>/dev/null; then
        info "User '${TM_USER}' already exists"
    else
        useradd -m -s /bin/bash "${TM_USER}"
        info "Created user '${TM_USER}'"
    fi

    # Generate SSH key pair if not exists
    local ssh_dir="${TM_HOME}/.ssh"
    mkdir -p "${ssh_dir}"

    if [[ ! -f "${ssh_dir}/id_rsa" ]]; then
        ssh-keygen -t rsa -b 4096 -f "${ssh_dir}/id_rsa" -N "" \
            -C "${TM_USER}@$(hostname)"
        info "Generated SSH key pair"
    else
        info "SSH key pair already exists"
    fi

    chown -R "${TM_USER}:${TM_USER}" "${ssh_dir}"
    chmod 700 "${ssh_dir}"
    chmod 600 "${ssh_dir}"/*
    chmod 644 "${ssh_dir}/id_rsa.pub" 2>/dev/null || true

    info "SSH key (add this to client servers):"
    echo "  $(cat "${ssh_dir}/id_rsa.pub")"
}

# ============================================================
# SERVER: DIRECTORY SETUP
# ============================================================

server_setup_directories() {
    info "Setting up directories..."

    # If TM_BACKUP_ROOT doesn't end with /timemachine, create the subdir
    # This ensures proper ownership isolation
    if [[ "${TM_BACKUP_ROOT}" != */timemachine ]]; then
        local parent_dir="${TM_BACKUP_ROOT}"
        TM_BACKUP_ROOT="${TM_BACKUP_ROOT}/timemachine"
        mkdir -p "${parent_dir}"
        info "  ${parent_dir} (parent mount point)"
    fi

    local dirs=(
        "${TM_BACKUP_ROOT}"
        "${TM_RUN_DIR}"
        "${TM_RUN_DIR}/state"
        "${TM_HOME}/logs"
    )

    for dir in "${dirs[@]}"; do
        mkdir -p "${dir}"
        chown "${TM_USER}:${TM_USER}" "${dir}"
        chmod 750 "${dir}"
        info "  ${dir}"
    done
}

# ============================================================
# SERVER: CONFIGURATION
# ============================================================

server_setup_config() {
    info "Setting up configuration..."

    # Copy .env.example if .env doesn't exist
    if [[ ! -f "${INSTALL_DIR}/.env" ]]; then
        cp "${INSTALL_DIR}/.env.example" "${INSTALL_DIR}/.env"
        # Update TM_HOME in .env
        sed -i.bak "s|TM_HOME=.*|TM_HOME=\"${TM_HOME}\"|" "${INSTALL_DIR}/.env" 2>/dev/null || \
        sed -i '' "s|TM_HOME=.*|TM_HOME=\"${TM_HOME}\"|" "${INSTALL_DIR}/.env"
        rm -f "${INSTALL_DIR}/.env.bak"
        # Update TM_BACKUP_ROOT in .env
        sed -i.bak "s|TM_BACKUP_ROOT=.*|TM_BACKUP_ROOT=\"${TM_BACKUP_ROOT}\"|" "${INSTALL_DIR}/.env" 2>/dev/null || \
        sed -i '' "s|TM_BACKUP_ROOT=.*|TM_BACKUP_ROOT=\"${TM_BACKUP_ROOT}\"|" "${INSTALL_DIR}/.env"
        rm -f "${INSTALL_DIR}/.env.bak"
        # Configure email notifications if provided
        if [[ -n "${TM_REPORT_EMAIL:-}" ]]; then
            sed -i.bak "s|TM_ALERT_ENABLED=.*|TM_ALERT_ENABLED=true|" "${INSTALL_DIR}/.env" 2>/dev/null || \
            sed -i '' "s|TM_ALERT_ENABLED=.*|TM_ALERT_ENABLED=true|" "${INSTALL_DIR}/.env"
            rm -f "${INSTALL_DIR}/.env.bak"
            sed -i.bak "s|TM_ALERT_EMAIL=.*|TM_ALERT_EMAIL=\"${TM_REPORT_EMAIL}\"|" "${INSTALL_DIR}/.env" 2>/dev/null || \
            sed -i '' "s|TM_ALERT_EMAIL=.*|TM_ALERT_EMAIL=\"${TM_REPORT_EMAIL}\"|" "${INSTALL_DIR}/.env"
            rm -f "${INSTALL_DIR}/.env.bak"
            info "Email reports enabled: ${TM_REPORT_EMAIL}"
        fi
        info "Created .env from template (edit as needed)"
    else
        info ".env already exists; skipping"
    fi

    # Copy servers.conf.example if servers.conf doesn't exist
    if [[ ! -f "${INSTALL_DIR}/config/servers.conf" ]]; then
        cp "${INSTALL_DIR}/config/servers.conf.example" "${INSTALL_DIR}/config/servers.conf"
        info "Created config/servers.conf from template (add your servers)"
    else
        info "config/servers.conf already exists; skipping"
    fi

    # Set ownership of project directory
    chown -R "${TM_USER}:${TM_USER}" "${INSTALL_DIR}"
}

# ============================================================
# SERVER: SUDOERS SETUP
# ============================================================

server_setup_sudoers() {
    info "Setting up sudoers for '${TM_USER}'..."

    local sudoers_file="/etc/sudoers.d/timemachine"
    local sudoers_content="# TimeMachine Backup - sudoers rules
Defaults:${TM_USER} !tty_tickets
Defaults:${TM_USER} !requiretty
${TM_USER} ALL=NOPASSWD:/usr/bin/rsync, /bin/cat, /bin/chown, /usr/bin/mysql, /usr/bin/mv, /usr/bin/ln, /usr/bin/rm"

    echo "${sudoers_content}" > "${sudoers_file}"
    chmod 440 "${sudoers_file}"

    # Validate sudoers syntax
    if visudo -cf "${sudoers_file}" &>/dev/null; then
        info "Sudoers configured successfully"
    else
        error "Invalid sudoers syntax! Removing ${sudoers_file}"
        rm -f "${sudoers_file}"
    fi
}

# ============================================================
# SERVER: SYSTEMD SERVICE SETUP
# ============================================================

server_setup_service() {
    info "Setting up systemd service..."

    if ! command -v systemctl &>/dev/null; then
        warn "systemd not found; falling back to cron-based scheduling"
        server_setup_cron
        return
    fi

    local service_file="/etc/systemd/system/timemachine.service"
    local source_file="${INSTALL_DIR}/config/timemachine.service"

    if [[ -f "${source_file}" ]]; then
        # Update paths in service file
        sed "s|/opt/timemachine-backup-linux|${INSTALL_DIR}|g" \
            "${source_file}" > "${service_file}"
        chmod 644 "${service_file}"

        systemctl daemon-reload
        systemctl enable timemachine.service
        info "Systemd service installed and enabled"
        info "Start with: systemctl start timemachine"
    else
        warn "Service file not found at ${source_file}; skipping"
        server_setup_cron
    fi
}

server_setup_cron() {
    info "Setting up cron job (fallback)..."

    local cron_file="/etc/cron.d/timemachine"
    local cron_content="# TimeMachine Backup - Daily backup schedule
MAILTO=\"\"
30 11 * * * ${TM_USER} /bin/bash ${INSTALL_DIR}/bin/daily-runner.sh >> ${TM_HOME}/logs/cron.log 2>&1"

    echo "${cron_content}" > "${cron_file}"
    chmod 644 "${cron_file}"
    info "Cron job installed at ${cron_file}"
}

# ============================================================
# SERVER: PERMISSIONS & SYMLINKS
# ============================================================

server_setup_permissions() {
    info "Setting script permissions..."

    find "${INSTALL_DIR}/bin" -name "*.sh" -exec chmod +x {} \;
    # Create convenience symlinks
    local bin_dir="/usr/local/bin"
    if [[ -d "${bin_dir}" ]]; then
        ln -sf "${INSTALL_DIR}/bin/tmctl.sh" "${bin_dir}/tmctl" 2>/dev/null || true
        ln -sf "${INSTALL_DIR}/bin/timemachine.sh" "${bin_dir}/timemachine" 2>/dev/null || true
        ln -sf "${INSTALL_DIR}/bin/restore.sh" "${bin_dir}/tm-restore" 2>/dev/null || true
        info "Symlinks created in ${bin_dir}: tmctl, timemachine, tm-restore"
    fi
    info "All scripts in bin/ are now executable"
}

# ============================================================
# SERVER: ASK BACKUP DIRECTORY
# ============================================================

server_ask_backup_dir() {
    # Skip if TM_BACKUP_ROOT was already set explicitly (e.g. by get.sh)
    if [[ "${TM_BACKUP_ROOT}" != "/backups" ]]; then
        return
    fi

    echo ""
    echo -e "${BOLD}Where should backups be stored?${NC}"
    echo ""
    echo "  This should be a mount point or directory with enough disk space."
    echo "  A 'timemachine' subdirectory will be created automatically."
    echo ""
    echo "  Examples: /mnt/backups, /srv/backups, /data/backups"
    echo ""

    local backup_dir
    backup_dir=$(read_input "  Backup directory [/backups]: " "/backups")

    if [[ "${backup_dir}" != /* ]]; then
        error "Backup directory must be an absolute path (starting with /)"
    fi

    TM_BACKUP_ROOT="${backup_dir}"
    info "Backups will be stored in: ${TM_BACKUP_ROOT}/timemachine/"
}

# ============================================================
# SERVER: ASK EMAIL FOR REPORTS
# ============================================================

server_ask_email() {
    echo ""
    echo -e "${BOLD}Email address for backup reports?${NC}"
    echo ""
    echo "  You will receive daily reports with per-server backup results"
    echo "  (success/failure) and alerts for failed DB interval backups."
    echo "  Leave empty to skip (can be configured later in .env)."
    echo ""

    TM_REPORT_EMAIL=$(read_input "  Email address []: " "")

    if [[ -n "${TM_REPORT_EMAIL}" ]]; then
        info "Reports will be sent to: ${TM_REPORT_EMAIL}"
    else
        info "Email reports disabled (set TM_ALERT_EMAIL in .env to enable)"
    fi
}

# ============================================================
# SERVER: MAIN
# ============================================================

install_server() {
    echo ""
    echo "============================================"
    echo "  TimeMachine Backup - Server Installation"
    echo "============================================"
    echo ""

    local os
    os=$(detect_os)
    info "Detected OS: ${os}"

    server_ask_backup_dir
    server_ask_email
    server_install_dependencies "${os}"
    server_setup_user
    server_setup_directories
    server_setup_permissions
    server_setup_config
    server_setup_sudoers
    server_setup_service

    echo ""
    echo "============================================"
    echo "  Server Installation Complete!"
    echo "============================================"
    echo ""
    info "Next steps:"
    echo "  1. Edit .env:             vi ${INSTALL_DIR}/.env"
    echo "  2. Add servers:           vi ${INSTALL_DIR}/config/servers.conf"
    echo "  3. Start service:         systemctl start timemachine"
    echo "  4. Install on clients:    sudo ./install.sh client --server $(hostname)"
    echo "  5. Test:                  tmctl backup <hostname> --dry-run"
    echo "  6. Dashboard:             http://$(hostname):7600"
    if [[ -n "${TM_REPORT_EMAIL:-}" ]]; then
    echo "  7. Reports:               ${TM_REPORT_EMAIL}"
    fi
    echo ""
}

# ############################################################
#
#  CLIENT INSTALLATION
#
# ############################################################

# ============================================================
# CLIENT: UNINSTALL
# ============================================================

client_do_uninstall() {
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
# CLIENT: USER SETUP
# ============================================================

client_setup_user() {
    info "Setting up user '${TM_USER}'..."

    if id "${TM_USER}" &>/dev/null; then
        info "User '${TM_USER}' already exists"
    else
        useradd -m -s /bin/bash "${TM_USER}"
        passwd -d "${TM_USER}" &>/dev/null || true
        info "Created user '${TM_USER}'"
    fi
}

# ============================================================
# CLIENT: SSH KEY
# ============================================================

client_fetch_ssh_key() {
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

client_setup_ssh() {
    # Auto-download key from server if --server was provided
    if [[ -n "${BACKUP_SERVER}" && -z "${SSH_PUBLIC_KEY}" ]]; then
        client_fetch_ssh_key
    fi

    # If still no key, ask interactively
    if [[ -z "${SSH_PUBLIC_KEY}" ]]; then
        echo ""
        echo -e "${BOLD}How do you want to configure the SSH key?${NC}"
        echo ""
        echo "  1) Enter the backup server hostname (auto-download key)"
        echo "  2) Paste the SSH public key manually"
        echo ""

        local choice
        choice=$(read_input "  Choose [1/2]: " "")

        case "${choice}" in
            1)
                BACKUP_SERVER=$(read_input "  Backup server hostname/IP: " "")
                [[ -z "${BACKUP_SERVER}" ]] && error "Server hostname is required"
                client_fetch_ssh_key
                ;;
            2)
                SSH_PUBLIC_KEY=$(read_input "  SSH public key: " "")
                [[ -z "${SSH_PUBLIC_KEY}" ]] && error "SSH key is required"
                ;;
            *)
                error "Invalid choice"
                ;;
        esac
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

# ============================================================
# CLIENT: SUDOERS
# ============================================================

client_setup_sudoers() {
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

    # Add database commands if database support is requested
    if [[ ${WITH_DB} -eq 1 ]]; then
        # MySQL/MariaDB
        if command -v mysql &>/dev/null; then
            sudoers_content+=", $(command -v mysql)"
        fi
        if command -v mysqldump &>/dev/null; then
            sudoers_content+=", $(command -v mysqldump)"
        fi
        if command -v mariadb &>/dev/null; then
            sudoers_content+=", $(command -v mariadb)"
        fi
        if command -v mariadb-dump &>/dev/null; then
            sudoers_content+=", $(command -v mariadb-dump)"
        fi
        # PostgreSQL
        if command -v psql &>/dev/null; then
            sudoers_content+=", $(command -v psql), $(command -v pg_dump), $(command -v pg_dumpall)"
        fi
        # MongoDB
        if command -v mongodump &>/dev/null; then
            sudoers_content+=", $(command -v mongodump)"
        fi
        # Redis
        if command -v redis-cli &>/dev/null; then
            sudoers_content+=", $(command -v redis-cli)"
        fi
        # SQLite
        if command -v sqlite3 &>/dev/null; then
            sudoers_content+=", $(command -v sqlite3)"
        fi
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

# ============================================================
# CLIENT: DIRECTORIES
# ============================================================

client_setup_directories() {
    info "Setting up directories..."

    mkdir -p "${TM_RUN_DIR}"
    chown "${TM_USER}:${TM_USER}" "${TM_RUN_DIR}"

    mkdir -p "${TM_HOME}/sql"
    chown "${TM_USER}:${TM_USER}" "${TM_HOME}/sql"

    # Credential storage directory (all DB passwords in one place)
    local cred_dir="${TM_HOME}/.credentials"
    mkdir -p "${cred_dir}"
    chown "${TM_USER}:${TM_USER}" "${cred_dir}"
    chmod 700 "${cred_dir}"
    info "  Credentials dir: ${cred_dir}"
}

# ============================================================
# CLIENT: DATABASE SCRIPTS
# ============================================================

client_deploy_db_scripts() {
    if [[ ${WITH_DB} -eq 0 ]]; then
        return
    fi

    info "Deploying database dump scripts..."

    # Copy dump_dbs.sh to client
    if [[ -f "${INSTALL_DIR}/bin/dump_dbs.sh" ]]; then
        install -m 700 -o "${TM_USER}" -g "${TM_USER}" \
            "${INSTALL_DIR}/bin/dump_dbs.sh" "${TM_HOME}/dump_dbs.sh"
        info "Deployed dump_dbs.sh"
    else
        warn "dump_dbs.sh not found in ${INSTALL_DIR}/bin/"
    fi

    # Copy dump_dbs_wait.sh to client
    if [[ -f "${INSTALL_DIR}/bin/dump_dbs_wait.sh" ]]; then
        install -m 700 -o "${TM_USER}" -g "${TM_USER}" \
            "${INSTALL_DIR}/bin/dump_dbs_wait.sh" "${TM_HOME}/dump_dbs_wait.sh"
        info "Deployed dump_dbs_wait.sh"
    else
        warn "dump_dbs_wait.sh not found in ${INSTALL_DIR}/bin/"
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
# CLIENT: MAIN
# ============================================================

install_client() {
    echo ""
    echo "============================================"
    echo "  TimeMachine Backup - Client Installation"
    echo "============================================"
    echo ""

    if [[ ${UNINSTALL} -eq 1 ]]; then
        client_do_uninstall
    fi

    client_setup_user
    client_setup_ssh
    client_setup_sudoers
    client_setup_directories
    client_deploy_db_scripts

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
    echo "  ssh -i ~/.ssh/id_rsa ${TM_USER}@$(hostname -f 2>/dev/null || hostname) 'echo OK'"
    echo ""
}

# ############################################################
#
#  MAIN ENTRY POINT
#
# ############################################################

main() {
    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║     TimeMachine Backup for Linux         ║"
    echo "  ║     Installer                            ║"
    echo "  ╚══════════════════════════════════════════╝"
    echo -e "${NC}"

    require_root
    parse_args "$@"
    select_mode

    case "${INSTALL_MODE}" in
        server) install_server ;;
        client) install_client ;;
    esac
}

main "$@"
