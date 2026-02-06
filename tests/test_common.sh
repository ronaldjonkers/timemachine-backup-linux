#!/usr/bin/env bash
# ============================================================
# TimeMachine Backup - Tests for lib/common.sh
# ============================================================
# Run: bash tests/test_common.sh
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# ============================================================
# TEST FRAMEWORK
# ============================================================

assert_eq() {
    local description="$1"
    local expected="$2"
    local actual="$3"
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

assert_success() {
    local description="$1"
    shift
    TESTS_RUN=$((TESTS_RUN + 1))

    if "$@" >/dev/null 2>&1; then
        echo "  PASS: ${description}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "  FAIL: ${description} (exit code $?)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_fail() {
    local description="$1"
    shift
    TESTS_RUN=$((TESTS_RUN + 1))

    if "$@" >/dev/null 2>&1; then
        echo "  FAIL: ${description} (expected failure, got success)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    else
        echo "  PASS: ${description}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    fi
}

assert_contains() {
    local description="$1"
    local needle="$2"
    local haystack="$3"
    TESTS_RUN=$((TESTS_RUN + 1))

    if [[ "${haystack}" == *"${needle}"* ]]; then
        echo "  PASS: ${description}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "  FAIL: ${description}"
        echo "    Expected to contain: '${needle}'"
        echo "    Actual: '${haystack}'"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# ============================================================
# SETUP
# ============================================================

# Create temp directory for test artifacts
TEST_TMP=$(mktemp -d)
trap 'rm -rf "${TEST_TMP}"' EXIT

# Override config for testing
export TM_USER="$(whoami)"
export TM_HOME="${TEST_TMP}/home"
export TM_BACKUP_ROOT="${TEST_TMP}/backups"
export TM_RUN_DIR="${TEST_TMP}/run"
export TM_LOG_DIR="${TEST_TMP}/logs"
export TM_LOG_LEVEL="DEBUG"
export TM_ALERT_ENABLED="false"

mkdir -p "${TM_HOME}" "${TM_BACKUP_ROOT}" "${TM_RUN_DIR}" "${TM_LOG_DIR}"

# Source the library
source "${PROJECT_ROOT}/lib/common.sh"

# ============================================================
# TESTS: CONFIGURATION
# ============================================================

echo ""
echo "=== Testing: Configuration Loading ==="

tm_load_config

assert_eq "TM_USER is set" "$(whoami)" "${TM_USER}"
assert_eq "TM_RETENTION_DAYS default" "7" "${TM_RETENTION_DAYS}"
assert_eq "TM_SSH_PORT default" "22" "${TM_SSH_PORT}"
assert_eq "TM_PARALLEL_JOBS default" "5" "${TM_PARALLEL_JOBS}"
assert_eq "TM_DB_DUMP_RETRIES default" "3" "${TM_DB_DUMP_RETRIES}"

# ============================================================
# TESTS: LOGGING
# ============================================================

echo ""
echo "=== Testing: Logging ==="

# Test log level filtering
TM_LOG_LEVEL="INFO"
output=$(tm_log "DEBUG" "debug message" 2>&1)
assert_eq "DEBUG suppressed at INFO level" "" "${output}"

output=$(tm_log "INFO" "info message" 2>&1)
assert_contains "INFO shown at INFO level" "info message" "${output}"

output=$(tm_log "ERROR" "error message" 2>&1)
assert_contains "ERROR shown at INFO level" "error message" "${output}"

TM_LOG_LEVEL="DEBUG"
output=$(tm_log "DEBUG" "debug message" 2>&1)
assert_contains "DEBUG shown at DEBUG level" "debug message" "${output}"

# ============================================================
# TESTS: LOCK MANAGEMENT
# ============================================================

echo ""
echo "=== Testing: Lock Management ==="

# Acquire lock
assert_success "Acquire lock" tm_acquire_lock "test-lock"
assert_eq "PID file created" "true" "$([[ -f "${TM_RUN_DIR}/test-lock.pid" ]] && echo true || echo false)"

pid_content=$(cat "${TM_RUN_DIR}/test-lock.pid")
assert_eq "PID file contains current PID" "$$" "${pid_content}"

# Acquire same lock should fail (same PID, but kill -0 $$ succeeds)
output=$(tm_acquire_lock "test-lock" 2>&1 || true)
# Note: this will fail because our own PID is running

# Release lock
tm_release_lock "test-lock"
assert_eq "PID file removed after release" "false" "$([[ -f "${TM_RUN_DIR}/test-lock.pid" ]] && echo true || echo false)"

# Stale PID file cleanup
echo "99999" > "${TM_RUN_DIR}/stale-lock.pid"
# PID 99999 is very unlikely to be running
if ! kill -0 99999 2>/dev/null; then
    assert_success "Acquire lock with stale PID" tm_acquire_lock "stale-lock"
    tm_release_lock "stale-lock"
fi

# ============================================================
# TESTS: USER VALIDATION
# ============================================================

echo ""
echo "=== Testing: User Validation ==="

assert_success "Require current user" tm_require_user "$(whoami)"

# ============================================================
# TESTS: UTILITY FUNCTIONS
# ============================================================

echo ""
echo "=== Testing: Utility Functions ==="

# tm_ensure_dir
NEW_DIR="${TEST_TMP}/new_test_dir"
tm_ensure_dir "${NEW_DIR}"
assert_eq "Directory created" "true" "$([[ -d "${NEW_DIR}" ]] && echo true || echo false)"

# tm_timestamp
ts=$(tm_timestamp)
assert_eq "Timestamp format (length)" "true" "$([[ ${#ts} -ge 15 ]] && echo true || echo false)"

# tm_date_today
today=$(tm_date_today)
assert_eq "Date format matches YYYY-MM-DD" "true" "$([[ "${today}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && echo true || echo false)"

# ============================================================
# TESTS: NOTIFICATION (disabled)
# ============================================================

echo ""
echo "=== Testing: Notification ==="

TM_ALERT_ENABLED="false"
output=$(tm_notify "Test Subject" "Test Body" 2>&1)
assert_contains "Notification skipped when disabled" "disabled" "${output}"

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
