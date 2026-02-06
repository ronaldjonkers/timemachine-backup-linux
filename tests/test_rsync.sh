#!/usr/bin/env bash
# ============================================================
# TimeMachine Backup - Tests for lib/rsync.sh
# ============================================================
# Run: bash tests/test_rsync.sh
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
export TM_SSH_KEY="${TEST_TMP}/fake_key"
export TM_SSH_PORT="22"
export TM_SSH_TIMEOUT="10"
export TM_RSYNC_BW_LIMIT="0"
export TM_RSYNC_EXTRA_OPTS=""
export TM_RETENTION_DAYS="3"

mkdir -p "${TM_HOME}" "${TM_BACKUP_ROOT}" "${TM_RUN_DIR}" "${TM_LOG_DIR}"
touch "${TM_SSH_KEY}"

source "${PROJECT_ROOT}/lib/common.sh"
source "${PROJECT_ROOT}/lib/rsync.sh"

tm_load_config

# ============================================================
# TESTS: RSYNC COMMAND BUILDING
# ============================================================

echo ""
echo "=== Testing: Rsync Command Building ==="

cmd=$(_tm_rsync_base_cmd)
assert_contains "Base cmd includes rsync" "rsync" "${cmd}"
assert_contains "Base cmd includes archive mode" "-aH" "${cmd}"
assert_contains "Base cmd includes delete" "--delete" "${cmd}"
assert_contains "Base cmd includes SSH" "ssh -p ${TM_SSH_PORT}" "${cmd}"

# Test bandwidth limit
TM_RSYNC_BW_LIMIT=1000
cmd=$(_tm_rsync_base_cmd)
assert_contains "BW limit included when > 0" "--bwlimit=1000" "${cmd}"

TM_RSYNC_BW_LIMIT=0
cmd=$(_tm_rsync_base_cmd)
# Should NOT contain bwlimit when 0
if [[ "${cmd}" != *"--bwlimit"* ]]; then
    echo "  PASS: No bwlimit when set to 0"
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo "  FAIL: bwlimit should not be present when 0"
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Test extra options
TM_RSYNC_EXTRA_OPTS="--compress --progress"
cmd=$(_tm_rsync_base_cmd)
assert_contains "Extra opts included" "--compress --progress" "${cmd}"
TM_RSYNC_EXTRA_OPTS=""

# ============================================================
# TESTS: BACKUP ROTATION
# ============================================================

echo ""
echo "=== Testing: Backup Rotation ==="

# Create fake backup directories
ROTATION_DIR="${TEST_TMP}/rotation_test"
mkdir -p "${ROTATION_DIR}"

# Create directories with dates
# "Old" backups (should be removed with 3-day retention)
mkdir -p "${ROTATION_DIR}/2020-01-01"
mkdir -p "${ROTATION_DIR}/2020-01-02"
mkdir -p "${ROTATION_DIR}/2020-06-15"

# "Recent" backup (today - should be kept)
TODAY=$(date +'%Y-%m-%d')
mkdir -p "${ROTATION_DIR}/${TODAY}"

# Also create a "latest" symlink (should not be touched by rotation)
ln -sf "${ROTATION_DIR}/${TODAY}" "${ROTATION_DIR}/latest"

TM_RETENTION_DAYS=3
tm_rotate_backups "${ROTATION_DIR}"

assert_eq "Old backup 2020-01-01 removed" "false" "$([[ -d "${ROTATION_DIR}/2020-01-01" ]] && echo true || echo false)"
assert_eq "Old backup 2020-01-02 removed" "false" "$([[ -d "${ROTATION_DIR}/2020-01-02" ]] && echo true || echo false)"
assert_eq "Old backup 2020-06-15 removed" "false" "$([[ -d "${ROTATION_DIR}/2020-06-15" ]] && echo true || echo false)"
assert_eq "Today's backup kept" "true" "$([[ -d "${ROTATION_DIR}/${TODAY}" ]] && echo true || echo false)"

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
