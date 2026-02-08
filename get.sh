#!/usr/bin/env bash
# ============================================================
# TimeMachine Backup - Quick Installer
# ============================================================
# Single-line install (server):
#   curl -sSL https://raw.githubusercontent.com/ronaldjonkers/timemachine-backup-linux/main/get.sh | sudo bash
#
# Single-line install (client):
#   curl -sSL https://raw.githubusercontent.com/ronaldjonkers/timemachine-backup-linux/main/get.sh | sudo bash -s -- client --server backup.example.com
#
# This script:
#   1. Installs git if needed (auto-detects package manager)
#   2. Clones or updates the repository
#   3. Runs install.sh (interactive server/client selection)
#
# Supports: Debian/Ubuntu, RHEL/CentOS/Fedora/Rocky/Alma,
#           openSUSE, Arch, Alpine, macOS
# ============================================================

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
NC=$'\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ============================================================
# PRE-FLIGHT CHECKS
# ============================================================

if [[ "$(id -u)" -ne 0 ]]; then
    error "This installer must be run as root (use sudo)"
fi

# ============================================================
# INSTALL GIT (distro-aware, non-interactive)
# ============================================================

install_git() {
    info "Installing git..."

    if command -v apt-get &>/dev/null; then
        apt-get update -qq \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold" 2>/dev/null || true
        apt-get install -y -qq git 2>/dev/null
    elif command -v dnf &>/dev/null; then
        dnf install -y -q git 2>/dev/null
    elif command -v yum &>/dev/null; then
        yum install -y -q git 2>/dev/null
    elif command -v zypper &>/dev/null; then
        zypper --non-interactive install git 2>/dev/null
    elif command -v pacman &>/dev/null; then
        pacman -Sy --noconfirm git 2>/dev/null
    elif command -v apk &>/dev/null; then
        apk add --no-cache git 2>/dev/null
    elif [[ "$(uname)" == "Darwin" ]] && command -v brew &>/dev/null; then
        brew install git 2>/dev/null
    else
        error "Cannot install git automatically. Please install git manually and re-run."
    fi

    if ! command -v git &>/dev/null; then
        error "Failed to install git. Please install it manually and re-run."
    fi

    info "git installed successfully"
}

if ! command -v git &>/dev/null; then
    install_git
else
    info "git is already installed"
fi

# ============================================================
# CLONE / UPDATE REPOSITORY
# ============================================================

INSTALL_DIR="${TM_INSTALL_DIR:-/opt/timemachine-backup-linux}"
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
# RUN UNIFIED INSTALLER (pass all arguments through)
# ============================================================

exec bash "${INSTALL_DIR}/install.sh" "$@"
