#!/usr/bin/env bash
# ============================================================
# TimeMachine Backup - Report Generator
# ============================================================
# Generates and sends backup reports after daily runs.
# Tracks per-server success/failure and builds a summary.
#
# Usage:
#   source lib/report.sh
#   tm_report_init
#   tm_report_add "hostname" "success" "45s" "files+db"
#   tm_report_add "hostname2" "failed" "12s" "files"
#   tm_report_send "daily"
# ============================================================

# State file for current report
_TM_REPORT_FILE=""

# Initialize a new report
# Usage: tm_report_init [report_type]
tm_report_init() {
    local report_type="${1:-daily}"
    _TM_REPORT_FILE="${TM_RUN_DIR:-/var/run/timemachine}/report-${report_type}-$(date +%s).tmp"
    : > "${_TM_REPORT_FILE}"
    tm_log "DEBUG" "Report initialized: ${_TM_REPORT_FILE}"
}

# Add a result line to the report
# Usage: tm_report_add <hostname> <status> <duration> <mode> [details] [logfile]
#   status: success | failed | skipped
#   duration: e.g. "45s" or "2m 30s"
#   mode: files+db | files | db-only | db-interval
tm_report_add() {
    local hostname="$1"
    local status="$2"
    local duration="$3"
    local mode="${4:-full}"
    local details="${5:-}"
    local logfile="${6:-}"

    [[ -z "${_TM_REPORT_FILE}" ]] && return

    echo "${hostname}|${status}|${duration}|${mode}|${details}|${logfile}" >> "${_TM_REPORT_FILE}"
}

# Format duration from seconds to human-readable
_tm_format_duration() {
    local secs="$1"
    if [[ ${secs} -ge 3600 ]]; then
        printf '%dh %dm %ds' $((secs/3600)) $((secs%3600/60)) $((secs%60))
    elif [[ ${secs} -ge 60 ]]; then
        printf '%dm %ds' $((secs/60)) $((secs%60))
    else
        printf '%ds' "${secs}"
    fi
}

# Build and send the report
# Usage: tm_report_send <report_type>
#   report_type: daily | db-interval
tm_report_send() {
    local report_type="${1:-daily}"

    [[ -z "${_TM_REPORT_FILE}" || ! -f "${_TM_REPORT_FILE}" ]] && return

    local total=0 succeeded=0 failed=0 skipped=0
    local success_lines="" fail_lines="" skip_lines=""
    local -a server_logfiles=()

    while IFS='|' read -r hostname status duration mode details logfile; do
        total=$((total + 1))
        [[ -n "${logfile}" ]] && server_logfiles+=("${hostname}|${logfile}")
        case "${status}" in
            success)
                succeeded=$((succeeded + 1))
                success_lines+="  OK   ${hostname} (${mode}, ${duration})"
                [[ -n "${details}" ]] && success_lines+=" - ${details}"
                success_lines+=$'\n'
                ;;
            failed)
                failed=$((failed + 1))
                fail_lines+="  FAIL ${hostname} (${mode}, ${duration})"
                [[ -n "${details}" ]] && fail_lines+=" - ${details}"
                fail_lines+=$'\n'
                ;;
            skipped)
                skipped=$((skipped + 1))
                skip_lines+="  SKIP ${hostname} (${mode})"
                [[ -n "${details}" ]] && skip_lines+=" - ${details}"
                skip_lines+=$'\n'
                ;;
        esac
    done < "${_TM_REPORT_FILE}"

    # Build report body
    local server_hostname
    server_hostname=$(hostname -f 2>/dev/null || hostname)
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')

    local subject level
    if [[ ${failed} -gt 0 ]]; then
        subject="Backup Report: ${failed} FAILED, ${succeeded} OK (${report_type})"
        level="error"
    else
        subject="Backup Report: All ${succeeded} OK (${report_type})"
        level="info"
    fi

    local body=""
    body+="TimeMachine Backup Report"$'\n'
    body+="========================"$'\n'
    body+="Server:    ${server_hostname}"$'\n'
    body+="Date:      ${timestamp}"$'\n'
    body+="Type:      ${report_type}"$'\n'
    body+="Summary:   ${succeeded} succeeded, ${failed} failed, ${skipped} skipped (${total} total)"$'\n'
    body+=""$'\n'

    if [[ -n "${fail_lines}" ]]; then
        body+="FAILED:"$'\n'
        body+="${fail_lines}"
        body+=""$'\n'
    fi

    if [[ -n "${success_lines}" ]]; then
        body+="SUCCEEDED:"$'\n'
        body+="${success_lines}"
        body+=""$'\n'
    fi

    if [[ -n "${skip_lines}" ]]; then
        body+="SKIPPED:"$'\n'
        body+="${skip_lines}"
        body+=""$'\n'
    fi

    # Append per-server backup logs (full output including rsync + DB)
    for entry in "${server_logfiles[@]+"${server_logfiles[@]}"}"; do
        local srv_name="${entry%%|*}"
        local srv_log="${entry#*|}"
        if [[ -n "${srv_log}" && -f "${srv_log}" ]]; then
            body+=$'\n'
            body+="============================================================"$'\n'
            body+="BACKUP LOG: ${srv_name}"$'\n'
            body+="============================================================"$'\n'
            body+=$(cat "${srv_log}" 2>/dev/null)$'\n'

            # Also find and append the rsync transfer log for this server
            local rsync_log
            rsync_log=$(ls -t "${TM_LOG_DIR}"/rsync-"${srv_name}"-*.log 2>/dev/null | head -1)
            if [[ -n "${rsync_log}" && -f "${rsync_log}" ]]; then
                body+=$'\n'
                body+="------------------------------------------------------------"$'\n'
                body+="RSYNC TRANSFER LOG: ${srv_name} (${rsync_log##*/})"$'\n'
                body+="------------------------------------------------------------"$'\n'
                body+=$(cat "${rsync_log}" 2>/dev/null)$'\n'
            fi
        fi
    done

    # Log the report
    tm_log "INFO" "Backup report (${report_type}): ${succeeded} OK, ${failed} FAILED, ${skipped} skipped"

    # Send via notification system
    tm_notify "${subject}" "${body}" "${level}"

    # Save report to log directory
    local report_log="${TM_LOG_DIR}/report-${report_type}-$(date +'%Y-%m-%d').log"
    echo "${body}" >> "${report_log}"

    # Cleanup temp file
    rm -f "${_TM_REPORT_FILE}"
    _TM_REPORT_FILE=""
}
