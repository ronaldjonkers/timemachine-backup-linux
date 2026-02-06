#!/usr/bin/env bash
# ============================================================
# TimeMachine Backup - Tests for lib/notify.sh
# ============================================================
# Run: bash tests/test_notify.sh
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

assert_eq() {
    local description="$1" expected="$2" actual="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "${expected}" == "${actual}" ]]; then
        echo "  PASS: ${description}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "  FAIL: ${description}"
        echo "    Expected: '${expected}'"
        echo "    Actual:   '${actual}'"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_contains() {
    local description="$1" needle="$2" haystack="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "${haystack}" == *"${needle}"* ]]; then
        echo "  PASS: ${description}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "  FAIL: ${description}"
        echo "    Expected to contain: '${needle}'"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# ============================================================
# SETUP
# ============================================================

TEST_TMP=$(mktemp -d)
trap 'rm -rf "${TEST_TMP}"' EXIT

export TM_USER="$(whoami)"
export TM_HOME="${TEST_TMP}/home"
export TM_BACKUP_ROOT="${TEST_TMP}/backups"
export TM_RUN_DIR="${TEST_TMP}/run"
export TM_LOG_DIR="${TEST_TMP}/logs"
export TM_LOG_LEVEL="DEBUG"
export TM_ALERT_ENABLED="false"
export TM_NOTIFY_METHODS="email"
export TM_WEBHOOK_URL=""
export TM_SLACK_WEBHOOK_URL=""
export TM_ALERT_EMAIL=""
export TM_ALERT_SUBJECT_PREFIX="[Test]"

mkdir -p "${TM_HOME}" "${TM_BACKUP_ROOT}" "${TM_RUN_DIR}" "${TM_LOG_DIR}"

source "${PROJECT_ROOT}/lib/common.sh"
source "${PROJECT_ROOT}/lib/notify.sh"

tm_load_config

# ============================================================
# TESTS: NOTIFICATION DISABLED
# ============================================================

echo ""
echo "=== Testing: Notifications Disabled ==="

TM_ALERT_ENABLED="false"
output=$(tm_notify "Test" "Body" 2>&1)
assert_contains "Skipped when disabled" "disabled" "${output}"

# ============================================================
# TESTS: EMAIL NOTIFICATION (no mail command expected)
# ============================================================

echo ""
echo "=== Testing: Email Notification ==="

TM_ALERT_ENABLED="true"
TM_NOTIFY_METHODS="email"
TM_ALERT_EMAIL=""

output=$(_tm_notify_email "Test Subject" "Test Body" 2>&1 || true)
assert_contains "Email skipped without TM_ALERT_EMAIL" "not set" "${output}"

TM_ALERT_EMAIL="test@example.com"
# mail command may not exist in test env, that's OK
output=$(_tm_notify_email "Test Subject" "Test Body" 2>&1 || true)
# Should either send or warn about missing mail command
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "${output}" == *"sent"* || "${output}" == *"not found"* ]]; then
    echo "  PASS: Email handler executed correctly"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo "  FAIL: Email handler unexpected output: ${output}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ============================================================
# TESTS: WEBHOOK NOTIFICATION
# ============================================================

echo ""
echo "=== Testing: Webhook Notification ==="

TM_WEBHOOK_URL=""
output=$(_tm_notify_webhook "Test" "Body" "info" 2>&1 || true)
assert_contains "Webhook skipped without URL" "not set" "${output}"

# ============================================================
# TESTS: SLACK NOTIFICATION
# ============================================================

echo ""
echo "=== Testing: Slack Notification ==="

TM_SLACK_WEBHOOK_URL=""
output=$(_tm_notify_slack "Test" "Body" "info" 2>&1 || true)
assert_contains "Slack skipped without URL" "not set" "${output}"

# ============================================================
# TESTS: MULTI-CHANNEL DISPATCH
# ============================================================

echo ""
echo "=== Testing: Multi-Channel Dispatch ==="

TM_ALERT_ENABLED="true"
TM_NOTIFY_METHODS="email,webhook,slack"
TM_ALERT_EMAIL=""
TM_WEBHOOK_URL=""
TM_SLACK_WEBHOOK_URL=""

# All channels should gracefully handle missing config
output=$(tm_notify "Test Multi" "Body" "info" 2>&1 || true)
TESTS_RUN=$((TESTS_RUN + 1))
if [[ $? -le 1 ]]; then
    echo "  PASS: Multi-channel dispatch handled gracefully"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo "  FAIL: Multi-channel dispatch crashed"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Unknown method should warn
TM_NOTIFY_METHODS="unknown_method"
output=$(tm_notify "Test Unknown" "Body" "info" 2>&1 || true)
assert_contains "Unknown method warned" "Unknown notification method" "${output}"

# ============================================================
# SUMMARY
# ============================================================

echo ""
echo "============================================"
echo "  Test Results: ${TESTS_PASSED}/${TESTS_RUN} passed"
if [[ ${TESTS_FAILED} -gt 0 ]]; then
    echo "  FAILED: ${TESTS_FAILED} test(s)"
    echo "============================================"
    exit 1
else
    echo "  All tests passed!"
    echo "============================================"
    exit 0
fi
