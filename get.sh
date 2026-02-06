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
#   1. Installs git if needed
#   2. Clones or updates the repository
#   3. Runs install.sh (interactive server/client selection)
# ============================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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
