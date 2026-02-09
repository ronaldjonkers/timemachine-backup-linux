#!/usr/bin/env bash
# ============================================================
# TimeMachine Backup - Notification Library
# ============================================================
# Multi-channel notification system.
# Supported methods: email, HTTP POST (webhook), Slack, log-only.
#
# Configure via .env:
#   TM_NOTIFY_METHODS="email,webhook,slack"
#   TM_ALERT_EMAIL="admin@example.com"
#   TM_WEBHOOK_URL="https://example.com/hook"
#   TM_SLACK_WEBHOOK_URL="https://hooks.slack.com/..."
# ============================================================

# Send notification through all configured channels
# Usage: tm_notify <subject> <body> [level]
# Level: info, warn, error (default: info)
tm_notify() {
    local subject="$1"
    local body="$2"
    local level="${3:-info}"

    if [[ "${TM_ALERT_ENABLED:-false}" != "true" ]]; then
        tm_log "DEBUG" "Notifications disabled; skipping: ${subject}"
        return 0
    fi

    local methods="${TM_NOTIFY_METHODS:-email}"
    local full_subject="${TM_ALERT_SUBJECT_PREFIX:-[TimeMachine]} ${subject}"
    local failed=0

    # Split methods by comma and dispatch
    local IFS=','
    for method in ${methods}; do
        method=$(echo "${method}" | tr -d ' ')
        case "${method}" in
            email)    _tm_notify_email "${full_subject}" "${body}" || failed=1 ;;
            webhook)  _tm_notify_webhook "${full_subject}" "${body}" "${level}" || failed=1 ;;
            slack)    _tm_notify_slack "${full_subject}" "${body}" "${level}" || failed=1 ;;
            *)        tm_log "WARN" "Unknown notification method: ${method}" ;;
        esac
    done

    return ${failed}
}

# ============================================================
# EMAIL
# ============================================================

_tm_notify_email() {
    local subject="$1"
    local body="$2"

    if [[ -z "${TM_ALERT_EMAIL:-}" ]]; then
        tm_log "WARN" "TM_ALERT_EMAIL not set; skipping email"
        return 1
    fi

    # Try multiple mail tools in order of preference
    if command -v mail &>/dev/null; then
        echo "${body}" | mail -s "${subject}" "${TM_ALERT_EMAIL}"
    elif command -v mailx &>/dev/null; then
        echo "${body}" | mailx -s "${subject}" "${TM_ALERT_EMAIL}"
    elif command -v msmtp &>/dev/null; then
        printf "To: %s\nSubject: %s\n\n%s\n" "${TM_ALERT_EMAIL}" "${subject}" "${body}" | msmtp "${TM_ALERT_EMAIL}"
    elif command -v sendmail &>/dev/null; then
        printf "To: %s\nSubject: %s\n\n%s\n" "${TM_ALERT_EMAIL}" "${subject}" "${body}" | sendmail "${TM_ALERT_EMAIL}"
    else
        tm_log "WARN" "No mail tool found (tried: mail, mailx, msmtp, sendmail); cannot send email"
        return 1
    fi

    tm_log "INFO" "Email sent to ${TM_ALERT_EMAIL}: ${subject}"
    return 0
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
