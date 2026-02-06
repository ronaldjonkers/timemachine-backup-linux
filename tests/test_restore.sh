#!/usr/bin/env bash
# ============================================================
# TimeMachine Backup - Tests for bin/restore.sh
# ============================================================
# Run: bash tests/test_restore.sh
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
export TM_ENCRYPT_ENABLED="false"

mkdir -p "${TM_HOME}" "${TM_BACKUP_ROOT}" "${TM_RUN_DIR}" "${TM_LOG_DIR}"
touch "${TM_SSH_KEY}"

# Create fake backup structure
TEST_HOST="test.example.com"
SNAP_DATE="2025-02-04"
SNAP_DIR="${TM_BACKUP_ROOT}/${TEST_HOST}/${SNAP_DATE}"

mkdir -p "${SNAP_DIR}/files/etc/nginx"
mkdir -p "${SNAP_DIR}/files/home/user1"
mkdir -p "${SNAP_DIR}/sql"

echo "server { listen 80; }" > "${SNAP_DIR}/files/etc/nginx/nginx.conf"
echo "export PATH=/usr/bin" > "${SNAP_DIR}/files/home/user1/.bashrc"
echo "CREATE DATABASE testdb;" > "${SNAP_DIR}/sql/testdb.sql"
echo "CREATE DATABASE appdb;" > "${SNAP_DIR}/sql/appdb.sql"

# Create latest symlink
ln -sf "${SNAP_DIR}" "${TM_BACKUP_ROOT}/${TEST_HOST}/latest"

# ============================================================
# TESTS: LIST SNAPSHOTS
# ============================================================

echo ""
echo "=== Testing: List Snapshots ==="

output=$(bash "${PROJECT_ROOT}/bin/restore.sh" "${TEST_HOST}" --list 2>&1)
assert_contains "Lists host name" "${TEST_HOST}" "${output}"
assert_contains "Lists snapshot date" "${SNAP_DATE}" "${output}"

# ============================================================
# TESTS: LIST FILES
# ============================================================

echo ""
echo "=== Testing: List Files ==="

output=$(bash "${PROJECT_ROOT}/bin/restore.sh" "${TEST_HOST}" --list-files 2>&1)
assert_contains "Lists nginx.conf" "nginx.conf" "${output}"
assert_contains "Lists .bashrc" ".bashrc" "${output}"

# ============================================================
# TESTS: LIST DATABASES
# ============================================================

echo ""
echo "=== Testing: List Databases ==="

output=$(bash "${PROJECT_ROOT}/bin/restore.sh" "${TEST_HOST}" --list-dbs 2>&1)
assert_contains "Lists testdb" "testdb" "${output}"
assert_contains "Lists appdb" "appdb" "${output}"

# ============================================================
# TESTS: DRY-RUN RESTORE FILES
# ============================================================

echo ""
echo "=== Testing: Dry-Run Restore ==="

output=$(bash "${PROJECT_ROOT}/bin/restore.sh" "${TEST_HOST}" --files-only --dry-run --no-confirm 2>&1)
assert_contains "Dry-run message shown" "DRY-RUN" "${output}"

# ============================================================
# TESTS: RESTORE FILES TO TARGET
# ============================================================

echo ""
echo "=== Testing: Restore Files to Target ==="

RESTORE_TARGET="${TEST_TMP}/restored_files"
output=$(bash "${PROJECT_ROOT}/bin/restore.sh" "${TEST_HOST}" \
    --files-only --target "${RESTORE_TARGET}" --no-confirm \
    --date "${SNAP_DATE}" 2>&1)

assert_eq "Restored nginx.conf exists" "true" \
    "$([[ -f "${RESTORE_TARGET}/etc/nginx/nginx.conf" ]] && echo true || echo false)"
assert_eq "Restored .bashrc exists" "true" \
    "$([[ -f "${RESTORE_TARGET}/home/user1/.bashrc" ]] && echo true || echo false)"

# Verify content
if [[ -f "${RESTORE_TARGET}/etc/nginx/nginx.conf" ]]; then
    content=$(cat "${RESTORE_TARGET}/etc/nginx/nginx.conf")
    assert_eq "Restored content matches" "server { listen 80; }" "${content}"
fi

# ============================================================
# TESTS: RESTORE SPECIFIC PATH
# ============================================================

echo ""
echo "=== Testing: Restore Specific Path ==="

RESTORE_PATH_TARGET="${TEST_TMP}/restored_path"
output=$(bash "${PROJECT_ROOT}/bin/restore.sh" "${TEST_HOST}" \
    --files-only --path "/etc/nginx" --target "${RESTORE_PATH_TARGET}" \
    --no-confirm --date "${SNAP_DATE}" 2>&1)

assert_eq "Specific path restored" "true" \
    "$([[ -e "${RESTORE_PATH_TARGET}/etc/nginx" ]] && echo true || echo false)"

# ============================================================
# TESTS: RESTORE DATABASES TO TARGET
# ============================================================

echo ""
echo "=== Testing: Restore Databases to Target ==="

DB_TARGET="${TEST_TMP}/restored_dbs"
output=$(bash "${PROJECT_ROOT}/bin/restore.sh" "${TEST_HOST}" \
    --db-only --db "testdb" --target "${DB_TARGET}" \
    --no-confirm --date "${SNAP_DATE}" 2>&1)

assert_eq "testdb.sql copied to target" "true" \
    "$([[ -f "${DB_TARGET}/testdb.sql" ]] && echo true || echo false)"

# ============================================================
# TESTS: NON-EXISTENT HOST
# ============================================================

echo ""
echo "=== Testing: Error Handling ==="

output=$(bash "${PROJECT_ROOT}/bin/restore.sh" "nonexistent.host" --list 2>&1 || true)
assert_contains "Error for non-existent host" "No backups found" "${output}"

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
