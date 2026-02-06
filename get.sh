#!/usr/bin/env bash
# ============================================================
# TimeMachine Backup - Quick Installer
# ============================================================
# Single-line install:
#   curl -sSL https://raw.githubusercontent.com/ronaldjonkers/timemachine-backup-linux/main/get.sh | sudo bash
#
# Or with a preset backup directory:
#   curl -sSL ... | sudo TM_BACKUP_DIR=/mnt/storage bash
#
# This script:
#   1. Clones the repository
#   2. Asks for the backup storage directory
#   3. Runs install.sh with the chosen directory
# ============================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ============================================================
# PRE-FLIGHT CHECKS
# ============================================================

if [[ "$(id -u)" -ne 0 ]]; then
    error "This installer must be run as root (use sudo)"
fi

if ! command -v git &>/dev/null; then
    info "Installing git..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq git
    elif command -v yum &>/dev/null; then
        yum install -y -q git
    elif command -v dnf &>/dev/null; then
        dnf install -y -q git
    else
        error "git is required but could not be installed automatically. Install git first."
    fi
fi

# ============================================================
# BANNER
# ============================================================

echo ""
echo -e "${CYAN}${BOLD}"
echo "  ╔══════════════════════════════════════════╗"
echo "  ║     TimeMachine Backup for Linux         ║"
echo "  ║     Quick Installer                      ║"
echo "  ╚══════════════════════════════════════════╝"
echo -e "${NC}"
echo ""

# ============================================================
# ASK FOR BACKUP DIRECTORY
# ============================================================

INSTALL_DIR="${TM_INSTALL_DIR:-/opt/timemachine-backup-linux}"
BACKUP_DIR="${TM_BACKUP_DIR:-}"

if [[ -z "${BACKUP_DIR}" ]]; then
    echo -e "${BOLD}Where should backups be stored?${NC}"
    echo ""
    echo "  This should be a mount point or directory with enough disk space"
    echo "  to hold all your server backups. A 'timemachine' subdirectory"
    echo "  will be created automatically with the correct permissions."
    echo ""
    echo "  Examples:"
    echo "    /mnt/backups"
    echo "    /srv/backups"
    echo "    /data/backups"
    echo ""

    # Check if stdin is a terminal (interactive)
    if [[ -t 0 ]]; then
        read -r -p "  Backup directory [/backups]: " BACKUP_DIR
        BACKUP_DIR="${BACKUP_DIR:-/backups}"
    else
        # Non-interactive (piped) — try to read from /dev/tty
        if [[ -e /dev/tty ]]; then
            read -r -p "  Backup directory [/backups]: " BACKUP_DIR < /dev/tty
            BACKUP_DIR="${BACKUP_DIR:-/backups}"
        else
            BACKUP_DIR="/backups"
            warn "Non-interactive mode; using default backup directory: ${BACKUP_DIR}"
            warn "Set TM_BACKUP_DIR to override: curl ... | sudo TM_BACKUP_DIR=/mnt/data bash"
        fi
    fi
fi

# Validate the backup directory path
if [[ "${BACKUP_DIR}" != /* ]]; then
    error "Backup directory must be an absolute path (starting with /)"
fi

echo ""
info "Backup directory: ${BACKUP_DIR}"
info "Backups will be stored in: ${BACKUP_DIR}/timemachine/"

# ============================================================
# CLONE REPOSITORY
# ============================================================

REPO_URL="https://github.com/ronaldjonkers/timemachine-backup-linux.git"

if [[ -d "${INSTALL_DIR}" ]]; then
    info "Installation directory already exists: ${INSTALL_DIR}"
    info "Updating..."
    cd "${INSTALL_DIR}"
    git pull --quiet 2>/dev/null || warn "Could not update repository (offline?)"
else
    info "Cloning TimeMachine Backup..."
    git clone --quiet "${REPO_URL}" "${INSTALL_DIR}"
    cd "${INSTALL_DIR}"
fi

# ============================================================
# RUN INSTALL
# ============================================================

# The actual backup root is <backup_dir>/timemachine
export TM_BACKUP_ROOT="${BACKUP_DIR}/timemachine"

info "Running installer..."
echo ""
bash "${INSTALL_DIR}/install.sh"

echo ""
echo -e "${CYAN}${BOLD}  Installation complete!${NC}"
echo ""
echo "  Backups stored in:  ${TM_BACKUP_ROOT}/"
echo "  Config file:        ${INSTALL_DIR}/.env"
echo "  Dashboard:          http://$(hostname):7600"
echo ""
echo "  Quick start:"
echo "    1. Edit servers:  vi ${INSTALL_DIR}/config/servers.conf"
echo "    2. Start service: systemctl start timemachine"
echo "    3. Add clients:   sudo ./install-client.sh --server $(hostname)"
echo ""
