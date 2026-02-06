#!/usr/bin/env bash
# ============================================================
# TimeMachine Backup - Tests for bin/tmctl.sh
# ============================================================
# Run: bash tests/test_tmctl.sh
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
export TM_LOG_LEVEL="INFO"
export TM_ALERT_ENABLED="false"
export TM_SSH_KEY="${TEST_TMP}/fake_key"
export TM_API_PORT="7600"

mkdir -p "${TM_HOME}" "${TM_BACKUP_ROOT}" "${TM_RUN_DIR}" "${TM_RUN_DIR}/state" "${TM_LOG_DIR}"
touch "${TM_SSH_KEY}"
echo "ssh-rsa AAAAFAKEKEY test@test" > "${TM_SSH_KEY}.pub"

# Create a test servers.conf
mkdir -p "${PROJECT_ROOT}/config"

# ============================================================
# TESTS: VERSION
# ============================================================

echo ""
echo "=== Testing: tmctl version ==="

output=$(bash "${PROJECT_ROOT}/bin/tmctl.sh" version 2>&1)
assert_contains "Version output" "0.2.0" "${output}"

# ============================================================
# TESTS: SSH KEY
# ============================================================

echo ""
echo "=== Testing: tmctl ssh-key ==="

output=$(bash "${PROJECT_ROOT}/bin/tmctl.sh" ssh-key 2>&1)
assert_contains "Shows SSH key" "AAAAFAKEKEY" "${output}"
assert_contains "Shows install hint" "install.sh client" "${output}"

# ============================================================
# TESTS: STATUS (service not running)
# ============================================================

echo ""
echo "=== Testing: tmctl status (offline) ==="

output=$(bash "${PROJECT_ROOT}/bin/tmctl.sh" status 2>&1)
assert_contains "Shows status header" "TimeMachine Backup Status" "${output}"
assert_contains "Shows stopped status" "stopped" "${output}"

# ============================================================
# TESTS: PS (with state files)
# ============================================================

echo ""
echo "=== Testing: tmctl ps (with state files) ==="

# Create a fake completed process state
echo "12345|test.example.com|full|2025-02-04 10:00:00|completed" > \
    "${TM_RUN_DIR}/state/proc-test.example.com.state"

output=$(bash "${PROJECT_ROOT}/bin/tmctl.sh" ps 2>&1)
assert_contains "Shows process hostname" "test.example.com" "${output}"
assert_contains "Shows completed status" "completed" "${output}"

# ============================================================
# TESTS: HELP
# ============================================================

echo ""
echo "=== Testing: tmctl help ==="

output=$(bash "${PROJECT_ROOT}/bin/tmctl.sh" help 2>&1 || true)
assert_contains "Help shows commands" "Commands:" "${output}"
assert_contains "Help shows backup" "backup" "${output}"
assert_contains "Help shows restore" "restore" "${output}"

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
