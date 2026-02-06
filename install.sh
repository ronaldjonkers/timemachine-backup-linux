#!/usr/bin/env bash
# ============================================================
# TimeMachine Backup - Server Installation Script
# ============================================================
# Installs and configures the TimeMachine backup server.
# Safe to run multiple times (idempotent).
#
# Usage:
#   sudo ./install.sh
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
NC='\033[0m' # No Color

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

# ============================================================
# DEPENDENCY INSTALLATION
# ============================================================

install_dependencies() {
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
# USER SETUP
# ============================================================

setup_user() {
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
# DIRECTORY SETUP
# ============================================================

setup_directories() {
    info "Setting up directories..."

    local dirs=(
        "${TM_BACKUP_ROOT}"
        "${TM_RUN_DIR}"
        "${TM_RUN_DIR}/state"
        "${TM_HOME}/logs"
    )

    for dir in "${dirs[@]}"; do
        mkdir -p "${dir}"
        chown "${TM_USER}:${TM_USER}" "${dir}"
        info "  ${dir}"
    done
}

# ============================================================
# CONFIGURATION
# ============================================================

setup_config() {
    info "Setting up configuration..."

    # Copy .env.example if .env doesn't exist
    if [[ ! -f "${INSTALL_DIR}/.env" ]]; then
        cp "${INSTALL_DIR}/.env.example" "${INSTALL_DIR}/.env"
        # Update TM_HOME in .env
        sed -i.bak "s|TM_HOME=.*|TM_HOME=\"${TM_HOME}\"|" "${INSTALL_DIR}/.env" 2>/dev/null || \
        sed -i '' "s|TM_HOME=.*|TM_HOME=\"${TM_HOME}\"|" "${INSTALL_DIR}/.env"
        rm -f "${INSTALL_DIR}/.env.bak"
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
# SUDOERS SETUP
# ============================================================

setup_sudoers() {
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
# SYSTEMD SERVICE SETUP
# ============================================================

setup_service() {
    info "Setting up systemd service..."

    if ! command -v systemctl &>/dev/null; then
        warn "systemd not found; falling back to cron-based scheduling"
        setup_cron
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
        setup_cron
    fi
}

setup_cron() {
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
# MAKE SCRIPTS EXECUTABLE
# ============================================================

setup_permissions() {
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
# MAIN
# ============================================================

main() {
    echo "============================================"
    echo "  TimeMachine Backup - Server Installation"
    echo "============================================"
    echo ""

    require_root

    local os
    os=$(detect_os)
    info "Detected OS: ${os}"

    install_dependencies "${os}"
    setup_user
    setup_directories
    setup_permissions
    setup_config
    setup_sudoers
    setup_service

    echo ""
    echo "============================================"
    echo "  Installation Complete!"
    echo "============================================"
    echo ""
    info "Next steps:"
    echo "  1. Edit .env to configure your backup settings"
    echo "  2. Edit config/servers.conf to add your servers"
    echo "  3. Start the service:"
    echo "     systemctl start timemachine"
    echo "  4. On each client server, install with:"
    echo "     sudo ./install-client.sh --server <this-hostname>"
    echo "     (auto-downloads SSH key from the API)"
    echo "  5. Or manually provide the SSH key:"
    echo "     sudo ./install-client.sh --ssh-key '$(cat ${TM_HOME}/.ssh/id_rsa.pub 2>/dev/null || echo "<key>")'"
    echo "  6. Test with: tmctl backup <hostname> --dry-run"
    echo "  7. Dashboard: http://$(hostname):7600"
    echo ""
}

main "$@"
