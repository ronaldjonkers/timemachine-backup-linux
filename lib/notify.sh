#!/usr/bin/env bash
# ============================================================
# TimeMachine Backup - Notification Library
# ============================================================
# Multi-channel notification system with per-event and per-server routing.
# Supported methods: email, HTTP POST (webhook), Slack, log-only.
#
# Configure via .env:
#   TM_ALERT_ENABLED="true"
#   TM_NOTIFY_METHODS="email,webhook,slack"
#   TM_ALERT_EMAIL="admin@example.com"
#
#   Per-event email overrides (optional, falls back to TM_ALERT_EMAIL):
#   TM_ALERT_EMAIL_BACKUP_OK="ops@example.com"
#   TM_ALERT_EMAIL_BACKUP_FAIL="oncall@example.com"
#   TM_ALERT_EMAIL_RESTORE_OK="ops@example.com"
#   TM_ALERT_EMAIL_RESTORE_FAIL="oncall@example.com"
#
#   Per-event enable/disable (all enabled by default when alerts are on):
#   TM_NOTIFY_BACKUP_OK="true"
#   TM_NOTIFY_BACKUP_FAIL="true"
#   TM_NOTIFY_DAILY_REPORT="true"
#   TM_NOTIFY_RESTORE_OK="true"
#   TM_NOTIFY_RESTORE_FAIL="true"
#
#   Webhook / Slack:
#   TM_WEBHOOK_URL="https://example.com/hook"
#   TM_SLACK_WEBHOOK_URL="https://hooks.slack.com/..."
#
#   Per-server email (in servers.conf):
#   web1.example.com --notify admin@example.com
#   web1.example.com --notify admin@example.com --notify-ok
# ============================================================

# Send notification through all configured channels
# Usage: tm_notify <subject> <body> [level] [event_type] [server_hostname]
# Level: info, warn, error (default: info)
# Event types: backup_ok, backup_fail, restore_ok, restore_fail
tm_notify() {
    local subject="$1"
    local body="$2"
    local level="${3:-info}"
    local event_type="${4:-}"
    local server_host="${5:-}"

    if [[ "${TM_ALERT_ENABLED:-false}" != "true" ]]; then
        tm_log "DEBUG" "Notifications disabled; skipping: ${subject}"
        return 0
    fi

    # Check per-event enable/disable
    if [[ -n "${event_type}" ]]; then
        local event_upper
        event_upper=$(echo "${event_type}" | tr '[:lower:]' '[:upper:]')
        local enable_var="TM_NOTIFY_${event_upper}"
        if [[ "${!enable_var:-true}" == "false" ]]; then
            # Per-server override: if the server has --notify-ok in servers.conf,
            # send success emails for that server even when globally disabled.
            if [[ "${event_type}" == "backup_ok" && -n "${server_host}" ]] && \
               _tm_server_has_notify_ok "${server_host}"; then
                tm_log "DEBUG" "Global ${event_type} disabled but ${server_host} has --notify-ok override"
            else
                tm_log "DEBUG" "Notification disabled for event ${event_type}; skipping: ${subject}"
                return 0
            fi
        fi
    fi

    local methods="${TM_NOTIFY_METHODS:-email}"
    local full_subject="${TM_ALERT_SUBJECT_PREFIX:-[TimeMachine]} ${subject}"
    local failed=0

    # Split methods by comma and dispatch
    local IFS=','
    for method in ${methods}; do
        method=$(echo "${method}" | tr -d ' ')
        case "${method}" in
            email)    _tm_notify_email "${full_subject}" "${body}" "${event_type}" "${server_host}" || failed=1 ;;
            webhook)  _tm_notify_webhook "${full_subject}" "${body}" "${level}" || failed=1 ;;
            slack)    _tm_notify_slack "${full_subject}" "${body}" "${level}" || failed=1 ;;
            *)        tm_log "WARN" "Unknown notification method: ${method}" ;;
        esac
    done

    return ${failed}
}

# ============================================================
# EMAIL (with per-event and per-server routing)
# ============================================================

# Resolve the email address for a given event type and server
_tm_resolve_email() {
    local event_type="$1"
    local server_host="$2"
    local recipients=""

    # 1. Per-event email override
    if [[ -n "${event_type}" ]]; then
        local event_upper
        event_upper=$(echo "${event_type}" | tr '[:lower:]' '[:upper:]')
        local event_email_var="TM_ALERT_EMAIL_${event_upper}"
        [[ -n "${!event_email_var:-}" ]] && recipients="${!event_email_var}"
    fi

    # 2. Fall back to global email
    [[ -z "${recipients}" ]] && recipients="${TM_ALERT_EMAIL:-}"

    # 3. Add per-server email (CC) if configured
    if [[ -n "${server_host}" ]]; then
        local server_email
        server_email=$(_tm_get_server_notify_email "${server_host}")
        if [[ -n "${server_email}" && "${server_email}" != "${recipients}" ]]; then
            [[ -n "${recipients}" ]] && recipients="${recipients},${server_email}" || recipients="${server_email}"
        fi
    fi

    echo "${recipients}"
}

# Check if a server has --notify-ok flag in servers.conf
_tm_server_has_notify_ok() {
    local hostname="$1"
    local servers_conf="${TM_PROJECT_ROOT:-}/config/servers.conf"
    [[ ! -f "${servers_conf}" ]] && return 1

    local line
    line=$(grep -E "^\s*${hostname}(\s|$)" "${servers_conf}" 2>/dev/null | head -1)
    [[ -z "${line}" ]] && return 1

    echo "${line}" | grep -q '\-\-notify-ok' 2>/dev/null
}

# Get the --notify email for a specific server from servers.conf
_tm_get_server_notify_email() {
    local hostname="$1"
    local servers_conf="${TM_PROJECT_ROOT:-}/config/servers.conf"
    [[ ! -f "${servers_conf}" ]] && return

    local line
    line=$(grep -E "^\s*${hostname}(\s|$)" "${servers_conf}" 2>/dev/null | head -1)
    [[ -z "${line}" ]] && return

    # Extract --notify value
    echo "${line}" | grep -oP '(?<=--notify\s)\S+' 2>/dev/null || \
    echo "${line}" | sed -n 's/.*--notify[[:space:]]\+\([^[:space:]]*\).*/\1/p'
}

_tm_notify_email() {
    local subject="$1"
    local body="$2"
    local event_type="${3:-}"
    local server_host="${4:-}"

    local recipients
    recipients=$(_tm_resolve_email "${event_type}" "${server_host}")

    if [[ -z "${recipients}" ]]; then
        tm_log "WARN" "No email recipients for event=${event_type:-any} host=${server_host:-global}; skipping"
        return 1
    fi

    _tm_send_email "${subject}" "${body}" "${recipients}"
}

_tm_send_email() {
    local subject="$1"
    local body="$2"
    local recipients="$3"

    # 1. SMTP relay via Python (preferred — always works, no local MTA needed)
    if [[ -n "${TM_SMTP_HOST:-}" ]] && _tm_send_email_smtp "${subject}" "${body}" "${recipients}"; then
        tm_log "INFO" "Email sent to ${recipients}: ${subject}"
        return 0
    fi

    # 2. Fallback to local mail tools (only works if local MTA is configured)
    if command -v mail &>/dev/null; then
        echo "${body}" | mail -s "${subject}" "${recipients}" 2>/dev/null
    elif command -v mailx &>/dev/null; then
        echo "${body}" | mailx -s "${subject}" "${recipients}" 2>/dev/null
    elif command -v msmtp &>/dev/null; then
        printf "To: %s\nSubject: %s\n\n%s\n" "${recipients}" "${subject}" "${body}" | msmtp "${recipients}" 2>/dev/null
    elif command -v sendmail &>/dev/null; then
        printf "To: %s\nSubject: %s\n\n%s\n" "${recipients}" "${subject}" "${body}" | sendmail "${recipients}" 2>/dev/null
    else
        tm_log "WARN" "No mail method available. Set TM_SMTP_HOST in .env for SMTP relay, or install a local MTA"
        return 1
    fi

    tm_log "INFO" "Email sent to ${recipients}: ${subject}"
    return 0
}

# Send email via SMTP relay using Python's smtplib (always available with Python 3)
_tm_send_email_smtp() {
    local subject="$1"
    local body="$2"
    local recipients="$3"

    local smtp_host="${TM_SMTP_HOST:-}"
    local smtp_port="${TM_SMTP_PORT:-587}"
    local smtp_user="${TM_SMTP_USER:-}"
    local smtp_pass="${TM_SMTP_PASS:-}"
    local smtp_from="${TM_SMTP_FROM:-${smtp_user}}"
    local smtp_tls="${TM_SMTP_TLS:-true}"

    if [[ -z "${smtp_host}" ]]; then
        return 1
    fi

    local python_bin=""
    for p in python3 python; do
        if command -v "${p}" &>/dev/null && "${p}" -c 'import sys; sys.exit(0 if sys.version_info[0]>=3 else 1)' 2>/dev/null; then
            python_bin="${p}"
            break
        fi
    done
    if [[ -z "${python_bin}" ]]; then
        tm_log "WARN" "Python 3 not found; cannot use SMTP relay"
        return 1
    fi

    # Pass all values via environment variables to avoid shell quoting issues
    _SMTP_HOST="${smtp_host}" \
    _SMTP_PORT="${smtp_port}" \
    _SMTP_USER="${smtp_user}" \
    _SMTP_PASS="${smtp_pass}" \
    _SMTP_FROM="${smtp_from}" \
    _SMTP_TLS="${smtp_tls}" \
    _SMTP_TO="${recipients}" \
    _SMTP_SUBJECT="${subject}" \
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
' <<< "${body}" 2>&1 | while IFS= read -r line; do
        tm_log "WARN" "SMTP: ${line}"
    done

    # Check pipeline exit status
    return "${PIPESTATUS[0]}"
}

# ============================================================
# HTTP POST (WEBHOOK)
# ============================================================

_tm_notify_webhook() {
    local subject="$1"
    local body="$2"
    local level="$3"

    if [[ -z "${TM_WEBHOOK_URL:-}" ]]; then
        tm_log "WARN" "TM_WEBHOOK_URL not set; skipping webhook"
        return 1
    fi

    if ! command -v curl &>/dev/null; then
        tm_log "WARN" "curl not found; skipping webhook"
        return 1
    fi

    # Build JSON payload
    local hostname
    hostname=$(hostname -f 2>/dev/null || hostname)
    local timestamp
    timestamp=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

    local json
    json=$(printf '{"subject":"%s","body":"%s","level":"%s","hostname":"%s","timestamp":"%s","source":"timemachine"}' \
        "$(echo "${subject}" | sed 's/"/\\"/g')" \
        "$(echo "${body}" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')" \
        "${level}" \
        "${hostname}" \
        "${timestamp}")

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST \
        -H "Content-Type: application/json" \
        ${TM_WEBHOOK_HEADERS:+-H "${TM_WEBHOOK_HEADERS}"} \
        -d "${json}" \
        --connect-timeout 10 \
        --max-time 30 \
        "${TM_WEBHOOK_URL}")

    if [[ "${http_code}" =~ ^2 ]]; then
        tm_log "INFO" "Webhook sent (HTTP ${http_code}): ${subject}"
        return 0
    else
        tm_log "ERROR" "Webhook failed (HTTP ${http_code}): ${subject}"
        return 1
    fi
}

# ============================================================
# SLACK
# ============================================================

_tm_notify_slack() {
    local subject="$1"
    local body="$2"
    local level="$3"

    if [[ -z "${TM_SLACK_WEBHOOK_URL:-}" ]]; then
        tm_log "WARN" "TM_SLACK_WEBHOOK_URL not set; skipping Slack"
        return 1
    fi

    if ! command -v curl &>/dev/null; then
        tm_log "WARN" "curl not found; skipping Slack"
        return 1
    fi

    # Color based on level
    local color
    case "${level}" in
        error) color="#dc3545" ;;
        warn)  color="#ffc107" ;;
        *)     color="#28a745" ;;
    esac

    local hostname
    hostname=$(hostname -f 2>/dev/null || hostname)

    local json
    json=$(printf '{
        "attachments": [{
            "color": "%s",
            "title": "%s",
            "text": "%s",
            "footer": "TimeMachine on %s",
            "ts": %s
        }]
    }' \
        "${color}" \
        "$(echo "${subject}" | sed 's/"/\\"/g')" \
        "$(echo "${body}" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')" \
        "${hostname}" \
        "$(date +%s)")

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST \
        -H "Content-Type: application/json" \
        -d "${json}" \
        --connect-timeout 10 \
        --max-time 30 \
        "${TM_SLACK_WEBHOOK_URL}")

    if [[ "${http_code}" =~ ^2 ]]; then
        tm_log "INFO" "Slack notification sent: ${subject}"
        return 0
    else
        tm_log "ERROR" "Slack notification failed (HTTP ${http_code}): ${subject}"
        return 1
    fi
}
