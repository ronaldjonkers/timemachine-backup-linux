#!/usr/bin/env bash
# ============================================================
# TimeMachine Backup - Service Watchdog
# ============================================================
# Cron-based fallback watchdog that ensures the timemachine
# service is always running. Runs every 5 minutes via cron.
#
# If systemd is available, checks and restarts the service.
# If not, checks for the PID file and restarts manually.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load config for TM_HOME, TM_LOG_DIR
if [[ -f "${PROJECT_ROOT}/.env" ]]; then
    set -a
    source "${PROJECT_ROOT}/.env"
    set +a
fi

: "${TM_HOME:=/home/timemachine}"
: "${TM_LOG_DIR:=${TM_HOME}/logs}"
: "${TM_RUN_DIR:=/var/run/timemachine}"

LOG="${TM_LOG_DIR}/watchdog.log"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >> "${LOG}" 2>/dev/null
}

# Systemd-based check
if command -v systemctl &>/dev/null; then
    if ! systemctl is-active timemachine.service &>/dev/null; then
        log "Service not running — attempting restart"

        # Reset failed state if needed (allows restart after StartLimitBurst)
        systemctl reset-failed timemachine.service 2>/dev/null || true
        systemctl start timemachine.service 2>/dev/null

        sleep 3
        if systemctl is-active timemachine.service &>/dev/null; then
            log "Service restarted successfully"
        else
            log "ERROR: Failed to restart service"
        fi
    fi
else
    # Non-systemd fallback: check PID file
    local pidfile="${TM_RUN_DIR}/tmserviced.pid"
    if [[ -f "${pidfile}" ]]; then
        local pid
        pid=$(cat "${pidfile}")
        if ! kill -0 "${pid}" 2>/dev/null; then
            log "PID ${pid} not running — restarting service"
            nohup "${SCRIPT_DIR}/tmserviced.sh" --foreground >> "${TM_LOG_DIR}/service.log" 2>&1 &
            log "Service restarted (PID $!)"
        fi
    else
        log "No PID file found — starting service"
        nohup "${SCRIPT_DIR}/tmserviced.sh" --foreground >> "${TM_LOG_DIR}/service.log" 2>&1 &
        log "Service started (PID $!)"
    fi
fi
