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
#   sudo ./install.sh --reconfigure            # Re-apply config (sudoers, perms, service)
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
export DEBIAN_FRONTEND=noninteractive

# ============================================================
# CONSTANTS
# ============================================================

INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"
TM_USER="${TM_USER:-timemachine}"
TM_HOME="/home/${TM_USER}"
TM_RUN_DIR="/var/run/timemachine"
TM_BACKUP_ROOT="${TM_BACKUP_ROOT:-/backups}"

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

# ============================================================
# FANCY DISPLAY HELPERS
# ============================================================

show_banner() {
    echo ""
    echo -e "${CYAN}"
    echo '    ████████╗██╗███╗   ███╗███████╗'
    echo '    ╚══██╔══╝██║████╗ ████║██╔════╝'
    echo '       ██║   ██║██╔████╔██║█████╗  '
    echo '       ██║   ██║██║╚██╔╝██║██╔══╝  '
    echo '       ██║   ██║██║ ╚═╝ ██║███████╗'
    echo '       ╚═╝   ╚═╝╚═╝     ╚═╝╚══════╝'
    echo -e "${GREEN}"
    echo '    ███╗   ███╗ █████╗  ██████╗██╗  ██╗██╗███╗   ██╗███████╗'
    echo '    ████╗ ████║██╔══██╗██╔════╝██║  ██║██║████╗  ██║██╔════╝'
    echo '    ██╔████╔██║███████║██║     ███████║██║██╔██╗ ██║█████╗  '
    echo '    ██║╚██╔╝██║██╔══██║██║     ██╔══██║██║██║╚██╗██║██╔══╝  '
    echo '    ██║ ╚═╝ ██║██║  ██║╚██████╗██║  ██║██║██║ ╚████║███████╗'
    echo '    ╚═╝     ╚═╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝╚═╝╚═╝  ╚═══╝╚══════╝'
    echo -e "${NC}"
    echo -e "    ${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "    ${BOLD}Backup for Linux${NC}  ${DIM}│${NC}  ${CYAN}rsync + hardlinks${NC}  ${DIM}│${NC}  ${GREEN}github.com/ronaldjonkers${NC}"
    echo -e "    ${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

show_complete() {
    local mode="$1"
    echo ""
    echo -e "    ${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "    ${GREEN}${BOLD}  ✅  ${mode} Installation Complete!${NC}"
    echo -e "    ${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

step() {
    local num="$1" total="$2"
    shift 2
    echo ""
    echo -e "  ${CYAN}▶ [${num}/${total}]${NC} ${BOLD}$*${NC}"
    echo -e "  ${CYAN}─────────────────────────────────────────────────────${NC}"
}

step_done() {
    echo -e "  ${GREEN}✔${NC} $*"
}

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

# Read password input (hidden) — works both interactively and when piped via curl
read_password() {
    local prompt="$1" result
    if [[ -t 0 ]]; then
        read -r -s -p "${prompt}" result
        echo "" >&2
    elif [[ -e /dev/tty ]]; then
        read -r -s -p "${prompt}" result < /dev/tty
        echo "" >&2
    else
        result=""
    fi
    echo "${result}"
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
RECONFIGURE=0

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
            --reconfigure)
                RECONFIGURE=1
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

    info "Detected package manager for: ${os}"

    case "${os}" in
        ubuntu|debian|linuxmint|pop|elementary|zorin)
            info "Using apt-get..."
            apt-get update -qq \
                -o Dpkg::Options::="--force-confdef" \
                -o Dpkg::Options::="--force-confold" 2>/dev/null || true
            apt-get install -y -qq rsync openssh-server socat curl mailutils gnupg2 2>/dev/null || true
            step_done "apt packages installed"
            ;;
        centos|rhel|rocky|almalinux|ol)
            info "Using yum..."
            yum install -y -q rsync openssh-server socat curl s-nail gnupg2 2>/dev/null || {
                yum install -y -q mailx 2>/dev/null || true
            }
            step_done "yum packages installed"
            ;;
        fedora)
            info "Using dnf..."
            dnf install -y -q rsync openssh-server socat curl s-nail gnupg2 2>/dev/null || {
                dnf install -y -q mailx 2>/dev/null || true
            }
            step_done "dnf packages installed"
            ;;
        opensuse*|sles|suse)
            info "Using zypper..."
            zypper --non-interactive install rsync openssh socat curl mailx gpg2 2>/dev/null || true
            step_done "zypper packages installed"
            ;;
        arch|manjaro|endeavouros)
            info "Using pacman..."
            pacman -Sy --noconfirm --needed rsync openssh socat curl gnupg 2>/dev/null || true
            step_done "pacman packages installed"
            ;;
        alpine)
            info "Using apk..."
            apk add --no-cache rsync openssh socat curl gnupg mailx 2>/dev/null || true
            step_done "apk packages installed"
            ;;
        macos)
            warn "macOS detected. This is for development/testing only."
            warn "Ensure rsync, ssh, socat, and curl are available."
            if command -v brew &>/dev/null; then
                brew install socat 2>/dev/null || true
            fi
            step_done "macOS dependencies checked"
            ;;
        *)
            warn "Unknown OS '${os}'. Trying to auto-detect package manager..."
            if command -v apt-get &>/dev/null; then
                apt-get update -qq 2>/dev/null || true
                apt-get install -y -qq rsync openssh-server socat curl mailutils gnupg2 2>/dev/null || true
            elif command -v dnf &>/dev/null; then
                dnf install -y -q rsync openssh-server socat curl s-nail gnupg2 2>/dev/null || true
            elif command -v yum &>/dev/null; then
                yum install -y -q rsync openssh-server socat curl s-nail gnupg2 2>/dev/null || true
            elif command -v zypper &>/dev/null; then
                zypper --non-interactive install rsync openssh socat curl mailx gpg2 2>/dev/null || true
            elif command -v pacman &>/dev/null; then
                pacman -Sy --noconfirm --needed rsync openssh socat curl gnupg 2>/dev/null || true
            elif command -v apk &>/dev/null; then
                apk add --no-cache rsync openssh socat curl gnupg mailx 2>/dev/null || true
            else
                warn "No supported package manager found. Install rsync, openssh, socat, and curl manually."
            fi
            step_done "Dependencies checked (fallback)"
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
        "${TM_HOME}"
        "${TM_HOME}/logs"
        "${TM_HOME}/.ssh"
        "${TM_BACKUP_ROOT}"
        "${TM_RUN_DIR}"
        "${TM_RUN_DIR}/state"
    )

    for dir in "${dirs[@]}"; do
        mkdir -p "${dir}"
        chown "${TM_USER}:${TM_USER}" "${dir}"
        info "  ${dir}"
    done

    # Set restrictive permissions on sensitive dirs
    chmod 750 "${TM_BACKUP_ROOT}"
    chmod 750 "${TM_RUN_DIR}"
    chmod 750 "${TM_RUN_DIR}/state"
    chmod 750 "${TM_HOME}"
    chmod 750 "${TM_HOME}/logs"
    chmod 700 "${TM_HOME}/.ssh"

    # Ensure systemd tmpfiles.d config so /run/timemachine survives reboots
    if [[ -d /etc/tmpfiles.d ]]; then
        echo "d /run/timemachine 0750 ${TM_USER} ${TM_USER} -" > /etc/tmpfiles.d/timemachine.conf
        info "  /etc/tmpfiles.d/timemachine.conf (runtime dir persistence)"
    fi
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
# SERVER: FIX ALL PERMISSIONS (idempotent, safe to re-run)
# ============================================================

server_fix_permissions() {
    info "Fixing all permissions for '${TM_USER}'..."

    # 1. Install directory — owned by timemachine, scripts executable
    chown -R "${TM_USER}:${TM_USER}" "${INSTALL_DIR}"
    find "${INSTALL_DIR}/bin" -name "*.sh" -exec chmod +x {} \;
    chmod 600 "${INSTALL_DIR}/.env" 2>/dev/null || true

    # 2. Home directory
    if [[ -d "${TM_HOME}" ]]; then
        chown -R "${TM_USER}:${TM_USER}" "${TM_HOME}"
        chmod 750 "${TM_HOME}"
    fi

    # 3. SSH directory
    if [[ -d "${TM_HOME}/.ssh" ]]; then
        chmod 700 "${TM_HOME}/.ssh"
        chmod 600 "${TM_HOME}/.ssh"/* 2>/dev/null || true
        chmod 644 "${TM_HOME}/.ssh/id_rsa.pub" 2>/dev/null || true
        chmod 644 "${TM_HOME}/.ssh/authorized_keys" 2>/dev/null || true
    fi

    # 4. Logs directory
    if [[ -d "${TM_HOME}/logs" ]]; then
        chown -R "${TM_USER}:${TM_USER}" "${TM_HOME}/logs"
        chmod 750 "${TM_HOME}/logs"
    fi

    # 5. Credentials directory
    if [[ -d "${TM_HOME}/.credentials" ]]; then
        chown -R "${TM_USER}:${TM_USER}" "${TM_HOME}/.credentials"
        chmod 700 "${TM_HOME}/.credentials"
        find "${TM_HOME}/.credentials" -type f -exec chmod 600 {} \;
    fi

    # 6. Backup root
    if [[ -d "${TM_BACKUP_ROOT}" ]]; then
        chown "${TM_USER}:${TM_USER}" "${TM_BACKUP_ROOT}"
        chmod 750 "${TM_BACKUP_ROOT}"
        # Also fix ownership of per-host backup dirs (non-recursive for speed)
        find "${TM_BACKUP_ROOT}" -maxdepth 1 -type d -exec chown "${TM_USER}:${TM_USER}" {} \;
    fi

    # 7. Runtime directory
    local run_dir="${TM_RUN_DIR:-/var/run/timemachine}"
    mkdir -p "${run_dir}" "${run_dir}/state"
    chown -R "${TM_USER}:${TM_USER}" "${run_dir}"
    chmod 750 "${run_dir}"

    # 8. tmpfiles.d for runtime dir persistence across reboots
    if [[ -d /etc/tmpfiles.d ]]; then
        echo "d /run/timemachine 0750 ${TM_USER} ${TM_USER} -" > /etc/tmpfiles.d/timemachine.conf
    fi

    # 9. Clean up stale self-restart temp dirs that may be owned by wrong user
    rm -rf /tmp/tm-self-restart 2>/dev/null || true

    info "All permissions fixed"
}

# ============================================================
# SERVER: SUDOERS SETUP
# ============================================================

server_setup_sudoers() {
    info "Setting up sudoers for '${TM_USER}'..."

    local sudoers_file="/etc/sudoers.d/timemachine"

    # Resolve actual binary paths for this system
    local rsync_path cat_path chown_path mv_path ln_path rm_path tar_path
    rsync_path=$(command -v rsync 2>/dev/null || echo "/usr/bin/rsync")
    cat_path=$(command -v cat 2>/dev/null || echo "/bin/cat")
    chown_path=$(command -v chown 2>/dev/null || echo "/bin/chown")
    mv_path=$(command -v mv 2>/dev/null || echo "/usr/bin/mv")
    ln_path=$(command -v ln 2>/dev/null || echo "/usr/bin/ln")
    rm_path=$(command -v rm 2>/dev/null || echo "/usr/bin/rm")
    tar_path=$(command -v tar 2>/dev/null || echo "/bin/tar")

    local sudoers_content="# TimeMachine Backup - server sudoers rules
Defaults:${TM_USER} !tty_tickets
Defaults:${TM_USER} !requiretty
${TM_USER} ALL=NOPASSWD:${rsync_path}, ${cat_path}, ${chown_path}, ${mv_path}, ${ln_path}, ${rm_path}, ${tar_path}"

    # Add zip if available (used for restore archive creation)
    if command -v zip &>/dev/null; then
        sudoers_content+=", $(command -v zip)"
    fi

    # Add database commands if available
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
    if command -v psql &>/dev/null; then
        sudoers_content+=", $(command -v psql), $(command -v pg_dump), $(command -v pg_dumpall)"
    fi

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

        # Ensure runtime directories exist before first start
        local run_dir="/var/run/timemachine"
        local log_dir="${TM_HOME:-/home/timemachine}/logs"
        mkdir -p "${run_dir}" "${log_dir}" 2>/dev/null || true
        chown "${TM_USER}:${TM_USER}" "${run_dir}" "${log_dir}" 2>/dev/null || true

        systemctl daemon-reload
        systemctl enable timemachine.service

        # Start and verify
        systemctl start timemachine.service 2>/dev/null || true
        sleep 1

        if systemctl is-active timemachine.service &>/dev/null; then
            step_done "Systemd service installed, enabled, and started"
        else
            warn "Service installed but failed to start. Checking logs..."
            journalctl -u timemachine --no-pager -n 5 2>/dev/null || true
            warn "Try: sudo systemctl restart timemachine"
        fi
        info "Service will auto-start on reboot"
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
    # Install to /usr/bin (guaranteed in sudo's secure_path on all distros)
    local bin_dir="/usr/bin"
    ln -sf "${INSTALL_DIR}/bin/tmctl.sh" "${bin_dir}/tmctl" 2>/dev/null || true
    ln -sf "${INSTALL_DIR}/bin/timemachine.sh" "${bin_dir}/timemachine" 2>/dev/null || true
    ln -sf "${INSTALL_DIR}/bin/restore.sh" "${bin_dir}/tm-restore" 2>/dev/null || true
    # Clean up old symlinks from previous installs
    rm -f /usr/local/bin/tmctl /usr/local/bin/timemachine /usr/local/bin/tm-restore 2>/dev/null || true
    info "Symlinks created in ${bin_dir}: tmctl, timemachine, tm-restore"
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
# SERVER: FIREWALL
# ============================================================

server_configure_firewall() {
    local api_port="${TM_API_PORT:-7600}"

    # SELinux: allow nginx to proxy to backend ports (RHEL/CentOS/Rocky/Alma)
    if command -v setsebool &>/dev/null; then
        if ! getsebool httpd_can_network_connect 2>/dev/null | grep -q "on$"; then
            info "Enabling SELinux httpd_can_network_connect..."
            setsebool -P httpd_can_network_connect 1 2>/dev/null || true
            info "SELinux: nginx can now proxy to backend services"
        fi
    fi

    # 1) binadit-firewall (auto-configure)
    #    Binary may be at /usr/local/sbin which is not always in PATH
    local bf_cmd=""
    if command -v binadit-firewall &>/dev/null; then
        bf_cmd="binadit-firewall"
    elif [[ -x /usr/local/sbin/binadit-firewall ]]; then
        bf_cmd="/usr/local/sbin/binadit-firewall"
    fi

    if [[ -n "${bf_cmd}" ]]; then
        info "binadit-firewall detected (${bf_cmd})"
        local current_ports
        current_ports=$(${bf_cmd} config get TCP_PORTS 2>/dev/null || true)
        if echo "${current_ports}" | grep -qw "${api_port}" 2>/dev/null; then
            step_done "Port ${api_port} already open in binadit-firewall"
        else
            ${bf_cmd} config add TCP_PORTS "${api_port}" 2>/dev/null || true
            ${bf_cmd} restart 2>/dev/null || true
            step_done "Port ${api_port} opened in binadit-firewall automatically"
        fi
        return
    fi

    # 2) ufw
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -qi "active"; then
        info "ufw firewall detected (active)"
        if ufw status | grep -qw "${api_port}" 2>/dev/null; then
            step_done "Port ${api_port} already open in ufw"
        else
            ufw allow "${api_port}/tcp" comment "TimeMachine dashboard" 2>/dev/null || true
            step_done "Port ${api_port} opened in ufw"
        fi
        return
    fi

    # 3) firewalld
    if command -v firewall-cmd &>/dev/null && firewall-cmd --state 2>/dev/null | grep -qi "running"; then
        info "firewalld detected (running)"
        if firewall-cmd --list-ports 2>/dev/null | grep -qw "${api_port}/tcp"; then
            step_done "Port ${api_port} already open in firewalld"
        else
            firewall-cmd --permanent --add-port="${api_port}/tcp" 2>/dev/null || true
            firewall-cmd --reload 2>/dev/null || true
            step_done "Port ${api_port} opened in firewalld"
        fi
        return
    fi

    # 4) iptables (check only, don't modify)
    if command -v iptables &>/dev/null; then
        if iptables -L INPUT -n 2>/dev/null | grep -qw "${api_port}"; then
            step_done "Port ${api_port} appears open in iptables"
        else
            info "No managed firewall detected (ufw/firewalld/binadit-firewall)"
            warn "Ensure TCP port ${api_port} is open in your firewall for the dashboard"
        fi
        return
    fi

    info "No firewall detected; port ${api_port} should be accessible"
}

# ============================================================
# SERVER: DASHBOARD SECURITY
# ============================================================

DASHBOARD_DOMAIN=""
DASHBOARD_USER=""
DASHBOARD_PASS=""
DASHBOARD_SECURED=0

server_ask_dashboard_security() {
    echo ""
    echo -e "  ${BOLD}Dashboard Security${NC}"
    echo ""
    echo "  The dashboard runs on port ${TM_API_PORT:-7600}."
    echo "  You can secure it with an Nginx reverse proxy + Let's Encrypt SSL"
    echo "  + password protection (accessible via HTTPS on port 443)."
    echo ""

    local choice
    choice=$(read_input "  Set up SSL + password-protected dashboard now? [y/N]: " "n")

    case "${choice}" in
        y|Y|yes|YES)
            ;;
        *)
            info "Skipped. You can set this up later with: sudo tmctl setup-web"
            return
            ;;
    esac

    # --- Domain ---
    echo ""
    DASHBOARD_DOMAIN=$(read_input "  Domain name for the dashboard (e.g. tm.example.com): " "")
    if [[ -z "${DASHBOARD_DOMAIN}" ]]; then
        warn "Domain name is required for Let's Encrypt SSL. Skipping."
        return
    fi
    info "Domain: ${DASHBOARD_DOMAIN}"

    # --- Username ---
    DASHBOARD_USER=$(read_input "  Dashboard username [admin]: " "admin")
    info "Username: ${DASHBOARD_USER}"

    # --- Password (ask twice) ---
    local pass1 pass2
    while true; do
        pass1=$(read_password "  Dashboard password: ")
        if [[ -z "${pass1}" ]]; then
            warn "Password cannot be empty. Try again."
            continue
        fi
        pass2=$(read_password "  Confirm password: ")
        if [[ "${pass1}" != "${pass2}" ]]; then
            warn "Passwords do not match. Try again."
            continue
        fi
        break
    done
    DASHBOARD_PASS="${pass1}"
    info "Password: ********"

    # --- Email (reuse report email or ask) ---
    local le_email="${TM_REPORT_EMAIL:-}"
    if [[ -z "${le_email}" ]]; then
        le_email=$(read_input "  Email for Let's Encrypt []: " "")
        if [[ -z "${le_email}" ]]; then
            warn "Email is required for Let's Encrypt. Skipping dashboard security."
            return
        fi
    else
        info "Using report email for Let's Encrypt: ${le_email}"
    fi

    # --- Run setup-web.sh ---
    if [[ -f "${INSTALL_DIR}/bin/setup-web.sh" ]]; then
        echo ""
        info "Installing Nginx + Certbot and configuring dashboard..."
        bash "${INSTALL_DIR}/bin/setup-web.sh" \
            --domain "${DASHBOARD_DOMAIN}" \
            --email "${le_email}" \
            --user "${DASHBOARD_USER}" \
            --pass "${DASHBOARD_PASS}" \
            --open-ssh-key

        if [[ $? -eq 0 ]]; then
            DASHBOARD_SECURED=1
            step_done "Dashboard secured with Let's Encrypt SSL + password via Nginx"
        else
            warn "Dashboard security setup had issues. Run 'sudo tmctl setup-web' to retry."
        fi
    else
        warn "setup-web.sh not found. Run 'tmctl setup-web' after installation."
    fi
}

# ============================================================
# SERVER: AUTO-UPDATE
# ============================================================

server_setup_auto_update() {
    local cron_file="/etc/cron.d/timemachine-update"
    local tmctl_path="/usr/bin/tmctl"
    local log_file="${TM_HOME:-/home/timemachine}/logs/auto-update.log"

    echo ""
    echo -e "  ${BOLD}Automatic Updates${NC}"
    echo ""
    echo "  TimeMachine can check for updates weekly and install them"
    echo "  automatically (runs 'tmctl update' via cron every Sunday at 04:00)."
    echo ""

    local choice
    choice=$(read_input "  Enable weekly auto-update? [y/N]: " "n")

    case "${choice}" in
        y|Y|yes|YES)
            # Resolve tmctl path
            if [[ ! -x "${tmctl_path}" ]]; then
                tmctl_path="${INSTALL_DIR}/bin/tmctl.sh"
            fi

            cat > "${cron_file}" <<CRON_EOF
# TimeMachine Backup — Weekly auto-update (Sunday 04:00)
MAILTO=""
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 4 * * 0 root ${tmctl_path} update >> ${log_file} 2>&1
CRON_EOF
            chmod 644 "${cron_file}"
            step_done "Weekly auto-update enabled (Sunday 04:00)"
            info "Update log: ${log_file}"
            ;;
        *)
            info "Skipped. You can enable it later by running:"
            echo "     sudo tmctl auto-update on"
            ;;
    esac
}

# ============================================================
# SERVER: RECONFIGURE (non-interactive, called by tmctl update)
# ============================================================

reconfigure_server() {
    echo ""
    echo -e "  ${MAGENTA}${BOLD}Reconfiguring Server${NC}"
    echo ""

    local total=5

    step 1 ${total} "Setting file permissions & symlinks"
    server_setup_permissions
    step_done "Permissions and symlinks configured"

    step 2 ${total} "Setting up sudoers"
    server_setup_sudoers
    step_done "Sudoers configured"

    step 3 ${total} "Updating systemd service"
    server_setup_service

    step 4 ${total} "Fixing all permissions"
    server_fix_permissions
    step_done "All permissions verified"

    step 5 ${total} "Restarting service"
    if command -v systemctl &>/dev/null; then
        systemctl daemon-reload 2>/dev/null || true
        systemctl restart timemachine 2>/dev/null || true
        sleep 1
        if systemctl is-active timemachine &>/dev/null; then
            step_done "TimeMachine service restarted"
        else
            warn "Service may not have started. Check: journalctl -u timemachine -n 20"
        fi
    else
        step_done "No systemd — skipped"
    fi

    echo ""
    echo -e "  ${GREEN}${BOLD}Reconfiguration complete${NC}"
    echo ""
}

# ============================================================
# SERVER: MAIN
# ============================================================

install_server() {
    echo ""
    echo -e "  ${MAGENTA}${BOLD}Server Installation${NC}"
    echo ""

    local os
    os=$(detect_os)
    local total=13

    server_ask_backup_dir
    server_ask_email

    step 1 ${total} "Detecting operating system"
    info "Detected OS: ${BOLD}${os}${NC}"
    step_done "OS detected: ${os}"

    step 2 ${total} "Installing system dependencies"
    server_install_dependencies "${os}"

    step 3 ${total} "Setting up timemachine user & SSH keys"
    server_setup_user
    step_done "User and SSH keys configured"

    step 4 ${total} "Creating backup directories"
    server_setup_directories
    step_done "Directories created"

    step 5 ${total} "Setting file permissions & symlinks"
    server_setup_permissions
    step_done "Permissions and symlinks configured"

    step 6 ${total} "Configuring environment"
    server_setup_config
    step_done "Environment configured"

    step 7 ${total} "Setting up sudoers"
    server_setup_sudoers
    step_done "Sudoers configured"

    step 8 ${total} "Configuring systemd service"
    server_setup_service

    step 9 ${total} "Starting TimeMachine service"
    if command -v systemctl &>/dev/null && systemctl is-active timemachine.service &>/dev/null; then
        step_done "Service is running and enabled on boot"
    else
        warn "Service could not be started (check logs with: journalctl -u timemachine)"
    fi

    step 10 ${total} "Configuring firewall"
    server_configure_firewall

    step 11 ${total} "Dashboard security"
    server_ask_dashboard_security

    step 12 ${total} "Automatic updates"
    server_setup_auto_update

    step 13 ${total} "Final permission check"
    server_fix_permissions
    step_done "All permissions verified"

    show_complete "Server"

    # Final service restart to ensure everything is running with latest config
    if command -v systemctl &>/dev/null; then
        info "Restarting TimeMachine service..."
        systemctl restart timemachine 2>/dev/null || true
        sleep 2
        if systemctl is-active timemachine &>/dev/null; then
            step_done "TimeMachine service is running"
        else
            warn "Service may not have started. Check: journalctl -u timemachine -n 20"
        fi
    fi

    local my_hostname
    my_hostname=$(hostname -f 2>/dev/null || hostname)

    echo ""
    echo "  ─────────────────────────────────────────────────────"
    echo -e "  ${BOLD}GETTING STARTED${NC}"
    echo "  ─────────────────────────────────────────────────────"
    echo ""
    echo -e "  ${BOLD}1. Add servers to back up:${NC}"
    echo "     tmctl server add web1.example.com"
    echo "     tmctl server add db1.example.com --priority 1 --db-interval 4h"
    echo ""
    echo -e "  ${BOLD}2. Install TimeMachine on each client server:${NC}"
    echo "     (run this command on the client machine)"
    echo ""
    echo "     curl -sSL https://raw.githubusercontent.com/ronaldjonkers/timemachine-backup-linux/main/get.sh | sudo bash -s -- client --server ${my_hostname}"
    echo ""
    echo -e "  ${BOLD}3. Test a backup (dry-run):${NC}"
    echo "     tmctl backup web1.example.com --dry-run"
    echo ""
    echo -e "  ${BOLD}4. Start a real backup:${NC}"
    echo "     tmctl backup web1.example.com"
    echo ""
    echo "  ─────────────────────────────────────────────────────"
    echo -e "  ${BOLD}WEB DASHBOARD${NC}"
    echo "  ─────────────────────────────────────────────────────"
    echo ""
    if [[ ${DASHBOARD_SECURED} -eq 1 ]]; then
    echo -e "  URL:      ${CYAN}https://${DASHBOARD_DOMAIN}/${NC}"
    echo -e "  Username: ${BOLD}${DASHBOARD_USER}${NC}"
    echo -e "  Password: ${BOLD}${DASHBOARD_PASS}${NC}"
    echo ""
    echo -e "  SSH key endpoint (no auth): ${CYAN}https://${DASHBOARD_DOMAIN}/api/ssh-key/raw${NC}"
    else
    echo -e "  URL: ${CYAN}http://${my_hostname}:${TM_API_PORT:-7600}${NC}"
    echo ""
    echo "  Tip: Secure the dashboard with SSL + password:"
    echo "     sudo tmctl setup-web"
    fi
    echo ""
    if [[ -n "${TM_REPORT_EMAIL:-}" ]]; then
    echo "  ─────────────────────────────────────────────────────"
    echo -e "  ${BOLD}EMAIL REPORTS${NC}"
    echo "  ─────────────────────────────────────────────────────"
    echo ""
    echo "  Reports will be sent to: ${TM_REPORT_EMAIL}"
    echo ""
    fi
    echo "  ─────────────────────────────────────────────────────"
    echo -e "  ${BOLD}ALL COMMANDS (tmctl)${NC}"
    echo "  ─────────────────────────────────────────────────────"
    echo ""
    echo "  tmctl status                Show service status and running processes"
    echo "  tmctl ps                    List running backup processes"
    echo "  tmctl backup <host>         Start a backup for a host"
    echo "  tmctl kill <host>           Kill a running backup"
    echo "  tmctl restore <host>        Restore from backup (interactive)"
    echo "  tmctl logs [host]           View backup logs"
    echo "  tmctl servers               List all configured servers"
    echo "  tmctl server add <host>     Add a server to back up"
    echo "  tmctl server remove <host>  Remove a server"
    echo "  tmctl snapshots <host>      List available snapshots for a host"
    echo "  tmctl ssh-key               Show the SSH public key"
    echo "  tmctl setup-web             Setup Nginx + SSL + Auth for the dashboard"
    echo "  tmctl update                Update to the latest version"
    echo "  tmctl auto-update on|off    Enable/disable weekly auto-updates"
    echo "  tmctl uninstall             Remove TimeMachine completely"
    echo "  tmctl version               Show installed version"
    echo ""
    echo "  ─────────────────────────────────────────────────────"
    echo -e "  ${BOLD}IMPORTANT${NC}"
    echo "  ─────────────────────────────────────────────────────"
    echo ""
    if [[ ${DASHBOARD_SECURED} -eq 1 ]]; then
    echo -e "  ${YELLOW}Firewall:${NC} Ensure TCP ports 80 and 443 are open for HTTPS access."
    else
    echo -e "  ${YELLOW}Firewall:${NC} Ensure TCP port ${TM_API_PORT:-7600} is open for the dashboard."
    fi
    echo ""
    echo "  Uninstall:"
    echo "     curl -sSL https://raw.githubusercontent.com/ronaldjonkers/timemachine-backup-linux/main/uninstall.sh | sudo bash"
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

    if ! command -v curl &>/dev/null; then
        error "curl is required for --server option. Install curl first."
    fi

    local key=""

    # Try 1: HTTPS via nginx gateway (port 443)
    info "Trying HTTPS (port 443) on ${BACKUP_SERVER}..."
    key=$(curl -sf --connect-timeout 5 -k \
        "https://${BACKUP_SERVER}/api/ssh-key/raw" 2>/dev/null) || true

    if [[ -n "${key}" ]]; then
        SSH_PUBLIC_KEY="${key}"
        info "SSH key downloaded via HTTPS (nginx gateway) from ${BACKUP_SERVER}"
        return 0
    fi

    # Try 2: HTTP direct (port 7600 or custom)
    info "Trying HTTP (port ${BACKUP_SERVER_PORT}) on ${BACKUP_SERVER}..."
    key=$(curl -sf --connect-timeout 5 \
        "http://${BACKUP_SERVER}:${BACKUP_SERVER_PORT}/api/ssh-key/raw" 2>/dev/null) || true

    if [[ -n "${key}" ]]; then
        SSH_PUBLIC_KEY="${key}"
        info "SSH key downloaded via HTTP from ${BACKUP_SERVER}:${BACKUP_SERVER_PORT}"
        return 0
    fi

    # Both failed — show helpful diagnostics
    echo ""
    warn "Could not download SSH key from ${BACKUP_SERVER}"
    echo ""
    echo -e "  ${BOLD}Possible causes:${NC}"
    echo "    1) TimeMachine service is not running on ${BACKUP_SERVER}"
    echo "       Fix: ssh ${BACKUP_SERVER} 'sudo systemctl start timemachine'"
    echo ""
    echo "    2) Port ${BACKUP_SERVER_PORT} is blocked by a firewall"
    echo "       Fix: open TCP port ${BACKUP_SERVER_PORT} on the backup server's firewall"
    echo ""
    echo "    3) Nginx gateway is not set up for HTTPS access"
    echo "       Fix: run 'sudo tmctl setup-web' on the backup server"
    echo ""
    echo -e "  ${BOLD}You can still continue by pasting the SSH key manually.${NC}"
    echo ""

    return 1
}

client_setup_ssh() {
    # Auto-download key from server if --server was provided
    if [[ -n "${BACKUP_SERVER}" && -z "${SSH_PUBLIC_KEY}" ]]; then
        client_fetch_ssh_key || true
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
                if [[ -z "${BACKUP_SERVER}" ]]; then
                    BACKUP_SERVER=$(read_input "  Backup server hostname/IP: " "")
                    [[ -z "${BACKUP_SERVER}" ]] && error "Server hostname is required"
                fi
                if ! client_fetch_ssh_key; then
                    # Fallback: ask for manual paste
                    SSH_PUBLIC_KEY=$(read_input "  SSH public key (paste here): " "")
                    [[ -z "${SSH_PUBLIC_KEY}" ]] && error "SSH key is required"
                fi
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
# CLIENT: DATABASE DETECTION & CREDENTIALS
# ============================================================

DETECTED_DBS=""

client_detect_databases() {
    info "Scanning for installed database engines..."

    DETECTED_DBS=""

    if command -v mysql &>/dev/null || command -v mariadb &>/dev/null; then
        DETECTED_DBS+="mysql,"
        step_done "MySQL / MariaDB detected"
    fi
    if command -v psql &>/dev/null; then
        DETECTED_DBS+="postgresql,"
        step_done "PostgreSQL detected"
    fi
    if command -v mongodump &>/dev/null; then
        DETECTED_DBS+="mongodb,"
        step_done "MongoDB detected"
    fi
    if command -v redis-cli &>/dev/null; then
        DETECTED_DBS+="redis,"
        step_done "Redis detected"
    fi
    if command -v sqlite3 &>/dev/null; then
        DETECTED_DBS+="sqlite,"
        step_done "SQLite detected"
    fi

    DETECTED_DBS="${DETECTED_DBS%,}"

    if [[ -z "${DETECTED_DBS}" ]]; then
        info "No database engines detected on this system"
        return
    fi

    info "Detected: ${BOLD}${DETECTED_DBS}${NC}"

    # Auto-enable database support
    if [[ ${WITH_DB} -eq 0 ]]; then
        WITH_DB=1
        DB_TYPE="${DETECTED_DBS}"
        info "Database support auto-enabled"
    fi
}

client_setup_db_credentials() {
    if [[ -z "${DETECTED_DBS}" ]]; then
        return
    fi

    local cred_dir="${TM_HOME}/.credentials"
    mkdir -p "${cred_dir}"
    chown "${TM_USER}:${TM_USER}" "${cred_dir}"
    chmod 700 "${cred_dir}"

    echo ""
    echo -e "  ${BOLD}Database Credential Setup${NC}"
    echo -e "  ${DIM}Credentials are stored securely in ${cred_dir} (mode 700)${NC}"
    echo ""

    IFS=',' read -ra db_array <<< "${DETECTED_DBS}"
    for db in "${db_array[@]}"; do
        case "${db}" in
            mysql)  _setup_cred_mysql "${cred_dir}" ;;
            postgresql) _setup_cred_postgresql ;;
            mongodb) _setup_cred_mongodb "${cred_dir}" ;;
            redis)  _setup_cred_redis "${cred_dir}" ;;
            sqlite) info "SQLite: no credentials needed (file-based)" ;;
        esac
    done
}

_setup_cred_mysql() {
    local cred_dir="$1"
    local pw_file="${cred_dir}/mysql.pw"

    echo ""
    echo -e "  ${CYAN}━ MySQL / MariaDB ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # Check if credentials already exist
    if [[ -f "${pw_file}" ]]; then
        info "MySQL credentials already configured at ${pw_file}"
        return
    fi

    # Check for existing /root/mysql.pw (common convention)
    if [[ -f /root/mysql.pw ]]; then
        local existing_pw
        existing_pw=$(cat /root/mysql.pw 2>/dev/null)
        if [[ -n "${existing_pw}" ]]; then
            info "Found existing MySQL password in /root/mysql.pw"
            echo "${existing_pw}" > "${pw_file}"
            chown "${TM_USER}:${TM_USER}" "${pw_file}"
            chmod 600 "${pw_file}"
            step_done "MySQL credentials imported from /root/mysql.pw (user: root)"
            return
        fi
    fi

    # Also check /root/.my.cnf
    if [[ -f /root/.my.cnf ]]; then
        local mycnf_pw
        mycnf_pw=$(grep -oP '^\s*password\s*=\s*\K.*' /root/.my.cnf 2>/dev/null | head -1 | tr -d '"'"'" || true)
        if [[ -n "${mycnf_pw}" ]]; then
            info "Found existing MySQL password in /root/.my.cnf"
            echo "${mycnf_pw}" > "${pw_file}"
            chown "${TM_USER}:${TM_USER}" "${pw_file}"
            chmod 600 "${pw_file}"
            step_done "MySQL credentials imported from /root/.my.cnf (user: root)"
            return
        fi
    fi

    echo "  TimeMachine connects to MySQL as ${BOLD}root${NC}."
    echo "  Enter the MySQL root password (or leave empty to skip):"
    echo ""
    local mysql_pw
    mysql_pw=$(read_input "  MySQL root password: " "")

    if [[ -n "${mysql_pw}" ]]; then
        echo "${mysql_pw}" > "${pw_file}"
        chown "${TM_USER}:${TM_USER}" "${pw_file}"
        chmod 600 "${pw_file}"
        step_done "MySQL credentials saved to ${pw_file}"
    else
        warn "MySQL password not set. Configure later:"
        echo "    echo 'yourpassword' | sudo tee ${pw_file} && sudo chmod 600 ${pw_file}"
    fi
}

_setup_cred_postgresql() {
    echo ""
    echo -e "  ${CYAN}━ PostgreSQL ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    info "PostgreSQL uses peer authentication (no password needed)"
    step_done "PostgreSQL: no credentials required"
}

_setup_cred_mongodb() {
    local cred_dir="$1"
    local cred_file="${cred_dir}/mongodb.conf"

    echo ""
    echo -e "  ${CYAN}━ MongoDB ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    if [[ -f "${cred_file}" ]]; then
        info "MongoDB credentials already configured at ${cred_file}"
        return
    fi

    echo "  If MongoDB has authentication enabled, enter credentials."
    echo "  Leave empty if MongoDB has no auth (open access)."
    echo ""
    local mongo_user
    mongo_user=$(read_input "  MongoDB admin username: " "")

    if [[ -n "${mongo_user}" ]]; then
        local mongo_pw
        mongo_pw=$(read_input "  MongoDB admin password: " "")
        if [[ -n "${mongo_pw}" ]]; then
            echo "${mongo_user}:${mongo_pw}" > "${cred_file}"
            chown "${TM_USER}:${TM_USER}" "${cred_file}"
            chmod 600 "${cred_file}"
            step_done "MongoDB credentials saved to ${cred_file}"
        else
            warn "MongoDB password empty, skipping credential setup"
        fi
    else
        info "MongoDB: no auth configured (assumes open access)"
    fi
}

_setup_cred_redis() {
    local cred_dir="$1"
    local pw_file="${cred_dir}/redis.pw"

    echo ""
    echo -e "  ${CYAN}━ Redis ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    if [[ -f "${pw_file}" ]]; then
        info "Redis credentials already configured at ${pw_file}"
        return
    fi

    # Try to detect if Redis has a password set
    local redis_needs_auth=0
    if redis-cli ping 2>/dev/null | grep -q "NOAUTH" 2>/dev/null; then
        redis_needs_auth=1
    fi

    if [[ ${redis_needs_auth} -eq 1 ]]; then
        echo "  Redis requires authentication (NOAUTH detected)."
    else
        echo "  Enter Redis password if requirepass is set (leave empty to skip):"
    fi
    echo ""
    local redis_pw
    redis_pw=$(read_input "  Redis password: " "")

    if [[ -n "${redis_pw}" ]]; then
        echo "${redis_pw}" > "${pw_file}"
        chown "${TM_USER}:${TM_USER}" "${pw_file}"
        chmod 600 "${pw_file}"
        step_done "Redis credentials saved to ${pw_file}"
    else
        info "Redis: no password configured (assumes no requirepass)"
    fi
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
    echo -e "  ${MAGENTA}${BOLD}Client Installation${NC}"
    echo ""

    if [[ ${UNINSTALL} -eq 1 ]]; then
        client_do_uninstall
    fi

    step 1 7 "Setting up timemachine user"
    client_setup_user
    step_done "User configured"

    step 2 7 "Configuring SSH access"
    client_setup_ssh
    step_done "SSH access configured"

    step 3 7 "Setting up sudoers"
    client_setup_sudoers
    step_done "Sudoers configured"

    step 4 7 "Creating directories"
    client_setup_directories
    step_done "Directories created"

    step 5 7 "Detecting installed databases"
    client_detect_databases

    step 6 7 "Configuring database credentials"
    client_setup_db_credentials

    step 7 7 "Deploying database scripts"
    if [[ ${WITH_DB} -eq 1 ]]; then
        client_deploy_db_scripts
        step_done "Database scripts deployed"
    else
        info "No databases detected; skipping DB script deployment"
    fi

    show_complete "Client"

    info "This server is now ready to be backed up by TimeMachine."
    echo ""
    if [[ -n "${BACKUP_SERVER}" ]]; then
    echo "  ${BOLD}Backup server:${NC} ${BACKUP_SERVER}"
    echo ""
    fi
    echo "  ${BOLD}Next: add this server on the backup server:${NC}"
    echo "     tmctl server add $(hostname -f 2>/dev/null || hostname)"
    echo ""
    echo "  ${BOLD}Test connectivity from the backup server:${NC}"
    echo "     ssh -i ~/.ssh/id_rsa ${TM_USER}@$(hostname -f 2>/dev/null || hostname) 'echo OK'"
    echo ""
    echo "  ${BOLD}Uninstall:${NC}"
    echo "     curl -sSL https://raw.githubusercontent.com/ronaldjonkers/timemachine-backup-linux/main/uninstall.sh | sudo bash"
    echo ""
    echo "  ${CYAN}Run 'tmctl help' on the backup server for all available commands.${NC}"
    echo ""
}

# ############################################################
#
#  MAIN ENTRY POINT
#
# ############################################################

main() {
    show_banner
    require_root
    parse_args "$@"
    select_mode

    if [[ ${RECONFIGURE} -eq 1 ]]; then
        reconfigure_server
        return
    fi

    case "${INSTALL_MODE}" in
        server) install_server ;;
        client) install_client ;;
    esac
}

main "$@"
