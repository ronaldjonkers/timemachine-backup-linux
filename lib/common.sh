#!/usr/bin/env bash
# ============================================================
# TimeMachine Backup - Shared Library
# ============================================================
# Reusable functions for all TimeMachine scripts.
# Source this file at the top of every script:
#   source "$(dirname "$0")/lib/common.sh"
# ============================================================

set -euo pipefail

# ============================================================
# CONFIGURATION LOADING
# ============================================================

# Resolve the project root (parent of lib/)
TM_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load .env if it exists
tm_load_config() {
    local env_file="${TM_PROJECT_ROOT}/.env"
    if [[ -f "${env_file}" ]]; then
        # Export all non-comment, non-empty lines
        set -a
        # shellcheck disable=SC1090
        source "${env_file}"
        set +a
    else
        tm_log "WARN" "No .env file found at ${env_file}; using defaults"
    fi

    # Apply defaults for any unset variables
    : "${TM_USER:=timemachine}"
    : "${TM_HOME:=/home/timemachine}"
    : "${TM_BACKUP_ROOT:=/backups}"
    : "${TM_RETENTION_DAYS:=7}"
    : "${TM_SSH_KEY:=${TM_HOME}/.ssh/id_rsa}"
    : "${TM_SSH_PORT:=22}"
    : "${TM_SSH_TIMEOUT:=10}"
    : "${TM_RSYNC_EXTRA_OPTS:=}"
    : "${TM_RSYNC_BW_LIMIT:=0}"
    : "${TM_BACKUP_SOURCE:=/}"
    : "${TM_INSTALL_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
    : "${TM_DB_TYPES:=auto}"
    : "${TM_CREDENTIALS_DIR:=${TM_HOME}/.credentials}"
    : "${TM_MYSQL_PW_FILE:=${TM_CREDENTIALS_DIR}/mysql.pw}"
    : "${TM_MYSQL_HOST:=}"
    : "${TM_PG_USER:=postgres}"
    : "${TM_PG_HOST:=}"
    : "${TM_MONGO_HOST:=}"
    : "${TM_MONGO_AUTH_DB:=admin}"
    : "${TM_REDIS_HOST:=}"
    : "${TM_REDIS_PORT:=6379}"
    : "${TM_SQLITE_PATHS:=}"
    : "${TM_DB_DUMP_RETRIES:=3}"
    : "${TM_PARALLEL_JOBS:=5}"
    : "${TM_ALERT_EMAIL:=}"
    : "${TM_ALERT_SUBJECT_PREFIX:=[TimeMachine]}"
    : "${TM_ALERT_ENABLED:=false}"
    : "${TM_NOTIFY_METHODS:=email}"
    : "${TM_NOTIFY_BACKUP_OK:=true}"
    : "${TM_NOTIFY_BACKUP_FAIL:=true}"
    : "${TM_NOTIFY_RESTORE_OK:=true}"
    : "${TM_NOTIFY_RESTORE_FAIL:=true}"
    : "${TM_NOTIFY_DAILY_REPORT:=true}"
    : "${TM_ALERT_EMAIL_BACKUP_OK:=}"
    : "${TM_ALERT_EMAIL_BACKUP_FAIL:=}"
    : "${TM_ALERT_EMAIL_RESTORE_OK:=}"
    : "${TM_ALERT_EMAIL_RESTORE_FAIL:=}"
    : "${TM_WEBHOOK_URL:=}"
    : "${TM_WEBHOOK_HEADERS:=}"
    : "${TM_SLACK_WEBHOOK_URL:=}"
    : "${TM_SMTP_HOST:=}"
    : "${TM_SMTP_PORT:=587}"
    : "${TM_SMTP_USER:=}"
    : "${TM_SMTP_PASS:=}"
    : "${TM_SMTP_FROM:=}"
    : "${TM_SMTP_TLS:=true}"
    : "${TM_LOG_LEVEL:=INFO}"
    : "${TM_LOG_DIR:=${TM_HOME}/logs}"
    : "${TM_STATE_DIR:=${TM_HOME}/state}"
    : "${TM_RUN_DIR:=/var/run/timemachine}"
    : "${TM_ENCRYPT_ENABLED:=false}"
    : "${TM_ENCRYPT_MODE:=symmetric}"
    : "${TM_ENCRYPT_PASSPHRASE:=}"
    : "${TM_ENCRYPT_KEY_ID:=}"
    : "${TM_ENCRYPT_REMOVE_ORIGINAL:=false}"
    : "${TM_API_PORT:=7600}"
    : "${TM_API_BIND:=0.0.0.0}"
    : "${TM_SCHEDULE_HOUR:=11}"
    : "${TM_SCHEDULE_MINUTE:=0}"
}

# ============================================================
# LOGGING
# ============================================================

# Log levels: DEBUG=0, INFO=1, WARN=2, ERROR=3
_tm_log_level_num() {
    local level
    level=$(echo "$1" | tr '[:lower:]' '[:upper:]')
    case "${level}" in
        DEBUG) echo 0 ;;
        INFO)  echo 1 ;;
        WARN)  echo 2 ;;
        ERROR) echo 3 ;;
        *)     echo 1 ;;
    esac
}

tm_log() {
    local level="${1}"
    shift
    local message="$*"
    local current_level_num
    local msg_level_num

    current_level_num=$(_tm_log_level_num "${TM_LOG_LEVEL:-INFO}")
    msg_level_num=$(_tm_log_level_num "${level}")

    if [[ ${msg_level_num} -ge ${current_level_num} ]]; then
        printf "[%s] [%-5s] %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "${level}" "${message}" >&2
    fi
}

# ============================================================
# LOCK / PID FILE MANAGEMENT
# ============================================================

tm_acquire_lock() {
    local lock_name="${1}"
    local pid_dir="${TM_RUN_DIR:-/var/run/timemachine}"
    local pidfile="${pid_dir}/${lock_name}.pid"

    mkdir -p "${pid_dir}"

    if [[ -f "${pidfile}" ]]; then
        local old_pid
        old_pid=$(cat "${pidfile}")
        if kill -0 "${old_pid}" 2>/dev/null; then
            tm_log "ERROR" "Process ${lock_name} already running (PID ${old_pid})"
            return 1
        else
            tm_log "WARN" "Stale PID file found for ${lock_name}; removing"
            rm -f "${pidfile}"
        fi
    fi

    echo $$ > "${pidfile}"
    tm_log "DEBUG" "Lock acquired: ${pidfile} (PID $$)"
}

tm_release_lock() {
    local lock_name="${1}"
    local pid_dir="${TM_RUN_DIR:-/var/run/timemachine}"
    local pidfile="${pid_dir}/${lock_name}.pid"

    rm -f "${pidfile}"
    tm_log "DEBUG" "Lock released: ${pidfile}"
}

# ============================================================
# SELF-RESTART IN TEMP FILE
# ============================================================
# Allows editing the script while it's running.

tm_self_restart() {
    local caller="$1"
    shift

    # Already running from temp copy — just register cleanup
    if [[ -n "${_TM_ORIG_SCRIPT_DIR:-}" ]]; then
        SCRIPT_DIR="${_TM_ORIG_SCRIPT_DIR}"
        # shellcheck disable=SC2064
        trap "rm -f '${caller}'" EXIT
        return
    fi

    # First run: copy script to temp dir and re-exec
    # Use per-user subdir to avoid permission conflicts (e.g. root vs timemachine)
    local tmp_dir="${TMPDIR:-/tmp}/tm-self-restart-$(id -u)"
    mkdir -p "${tmp_dir}"
    chmod 700 "${tmp_dir}" 2>/dev/null || true
    local dist
    dist="${tmp_dir}/$(basename "${caller}").$$"
    install -m 700 "${caller}" "${dist}"
    export _TM_ORIG_SCRIPT_DIR="${SCRIPT_DIR}"
    exec "${dist}" "$@"
    exit
}

# ============================================================
# USER VALIDATION
# ============================================================

tm_require_user() {
    local required_user="${1:-${TM_USER}}"
    if [[ "$(whoami)" != "${required_user}" ]]; then
        tm_log "ERROR" "This script must be run as user '${required_user}'"
        exit 1
    fi
}

# ============================================================
# NOTIFICATION
# ============================================================
# Multi-channel notifications are handled by lib/notify.sh.
# If notify.sh is sourced, tm_notify uses all configured channels.
# Otherwise, fall back to a simple implementation.

if [[ -z "$(type -t tm_notify 2>/dev/null)" ]]; then
    # Fallback SMTP sender (used when lib/notify.sh is not sourced)
    _tm_fallback_smtp() {
        local subject="$1" body="$2" recipients="$3"
        local smtp_host="${TM_SMTP_HOST:-}" smtp_port="${TM_SMTP_PORT:-587}"
        local smtp_user="${TM_SMTP_USER:-}" smtp_pass="${TM_SMTP_PASS:-}"
        local smtp_from="${TM_SMTP_FROM:-${smtp_user}}" smtp_tls="${TM_SMTP_TLS:-true}"
        [[ -z "${smtp_host}" ]] && return 1
        local python_bin=""
        for p in python3 python; do
            command -v "${p}" &>/dev/null && "${p}" -c 'import sys; sys.exit(0 if sys.version_info[0]>=3 else 1)' 2>/dev/null && { python_bin="${p}"; break; }
        done
        [[ -z "${python_bin}" ]] && return 1
        _SMTP_HOST="${smtp_host}" _SMTP_PORT="${smtp_port}" _SMTP_USER="${smtp_user}" \
        _SMTP_PASS="${smtp_pass}" _SMTP_FROM="${smtp_from}" _SMTP_TLS="${smtp_tls}" \
        _SMTP_TO="${recipients}" _SMTP_SUBJECT="${subject}" \
        "${python_bin}" -c '
import smtplib, os, sys
from email.mime.text import MIMEText
body = sys.stdin.read()
msg = MIMEText(body)
msg["Subject"] = os.environ["_SMTP_SUBJECT"]
msg["From"] = os.environ["_SMTP_FROM"]
msg["To"] = os.environ["_SMTP_TO"]
try:
    port = int(os.environ["_SMTP_PORT"])
    if port == 465:
        s = smtplib.SMTP_SSL(os.environ["_SMTP_HOST"], port, timeout=30)
    else:
        s = smtplib.SMTP(os.environ["_SMTP_HOST"], port, timeout=30)
        if os.environ.get("_SMTP_TLS", "true") == "true":
            s.starttls()
    user = os.environ.get("_SMTP_USER", "")
    pw = os.environ.get("_SMTP_PASS", "")
    if user and pw:
        s.login(user, pw)
    rcpts = [r.strip() for r in os.environ["_SMTP_TO"].split(",")]
    s.sendmail(os.environ["_SMTP_FROM"], rcpts, msg.as_string())
    s.quit()
except Exception as e:
    print(f"SMTP error: {e}", file=sys.stderr)
    sys.exit(1)
' <<< "${body}" 2>/dev/null
    }

    tm_notify() {
        local subject="$1"
        local body="$2"

        if [[ "${TM_ALERT_ENABLED:-false}" != "true" ]]; then
            tm_log "DEBUG" "Notifications disabled; skipping alert: ${subject}"
            return 0
        fi

        local full_subject="${TM_ALERT_SUBJECT_PREFIX:-[TimeMachine]} ${subject}"

        if [[ -z "${TM_ALERT_EMAIL:-}" ]]; then
            tm_log "WARN" "TM_ALERT_EMAIL not set; cannot send notification"
            return 1
        fi

        # 1. SMTP relay via Python (preferred — no local MTA needed)
        if [[ -n "${TM_SMTP_HOST:-}" ]] && _tm_fallback_smtp "${full_subject}" "${body}" "${TM_ALERT_EMAIL}"; then
            tm_log "INFO" "Alert sent to ${TM_ALERT_EMAIL}: ${full_subject}"
            return 0
        fi

        # 2. Fallback to local mail tools
        if command -v mail &>/dev/null; then
            echo "${body}" | mail -s "${full_subject}" "${TM_ALERT_EMAIL}" 2>/dev/null
        elif command -v mailx &>/dev/null; then
            echo "${body}" | mailx -s "${full_subject}" "${TM_ALERT_EMAIL}" 2>/dev/null
        elif command -v msmtp &>/dev/null; then
            printf "To: %s\nSubject: %s\n\n%s\n" "${TM_ALERT_EMAIL}" "${full_subject}" "${body}" | msmtp "${TM_ALERT_EMAIL}" 2>/dev/null
        elif command -v sendmail &>/dev/null; then
            printf "To: %s\nSubject: %s\n\n%s\n" "${TM_ALERT_EMAIL}" "${full_subject}" "${body}" | sendmail "${TM_ALERT_EMAIL}" 2>/dev/null
        else
            tm_log "WARN" "No mail method available. Set TM_SMTP_HOST in .env for SMTP relay, or install a local MTA"
            return 1
        fi
        tm_log "INFO" "Alert sent to ${TM_ALERT_EMAIL}: ${full_subject}"
    }
fi

# ============================================================
# UTILITY
# ============================================================

# Detect OS-appropriate rsync flags
# macOS rsync doesn't support -A (ACLs) or -X (xattrs) the same way
# Sets TM_RSYNC_FLAGS as a global array for correct word splitting
if [[ "$(uname)" == "Darwin" ]]; then
    TM_RSYNC_FLAGS=(-aHx --numeric-ids)
else
    TM_RSYNC_FLAGS=(-aHAXx --numeric-ids)
fi

tm_ensure_dir() {
    local dir="$1"
    if [[ ! -d "${dir}" ]]; then
        mkdir -p "${dir}"
        tm_log "DEBUG" "Created directory: ${dir}"
    fi
}

tm_timestamp() {
    date +'%Y-%m-%d_%H%M%S'
}

tm_date_today() {
    date +'%Y-%m-%d'
}

tm_snapshot_id() {
    date +'%Y-%m-%d_%H%M%S'
}
