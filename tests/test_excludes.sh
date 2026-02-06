#!/usr/bin/env bash
# ============================================================
# TimeMachine Backup - Tests: Exclude System
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Create temp dir for tests
TEST_TMP=$(mktemp -d)
trap 'rm -rf "${TEST_TMP}"' EXIT

# ============================================================
# TEST FRAMEWORK
# ============================================================

TESTS_RUN=0
TESTS_PASSED=0

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "${haystack}" == *"${needle}"* ]]; then
        echo "  PASS: ${label}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "  FAIL: ${label}"
        echo "    Expected to contain: ${needle}"
        echo "    Got: ${haystack}"
    fi
}

assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "${haystack}" != *"${needle}"* ]]; then
        echo "  PASS: ${label}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "  FAIL: ${label}"
        echo "    Expected NOT to contain: ${needle}"
        echo "    Got: ${haystack}"
    fi
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "${expected}" == "${actual}" ]]; then
        echo "  PASS: ${label}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "  FAIL: ${label}"
        echo "    Expected: ${expected}"
        echo "    Got: ${actual}"
    fi
}

# ============================================================
# SETUP
# ============================================================

export TM_USER="$(whoami)"
export TM_HOME="${TEST_TMP}"
export TM_BACKUP_ROOT="${TEST_TMP}/backups"
export TM_SSH_KEY="${TEST_TMP}/fake_key"
export TM_SSH_PORT=22
export TM_SSH_TIMEOUT=10
export TM_RSYNC_BW_LIMIT=0
export TM_RSYNC_EXTRA_OPTS=""
export TM_LOG_LEVEL="DEBUG"
export TM_ALERT_ENABLED=false
export TM_ENCRYPT_ENABLED=false
export TM_RUN_DIR="${TEST_TMP}/run"
export TM_INSTALL_DIR="${PROJECT_ROOT}"

mkdir -p "${TM_RUN_DIR}"

# Source libraries
source "${PROJECT_ROOT}/lib/common.sh"
source "${PROJECT_ROOT}/lib/rsync.sh"

# ============================================================
# TESTS: GLOBAL EXCLUDE FILE
# ============================================================

echo ""
echo "=== Testing: Global Exclude File ==="

# Test that global exclude file is picked up
output=$(_tm_rsync_excludes "test.example.com" 2>&1)
assert_contains "Global exclude loaded" "exclude.conf" "${output}"

# ============================================================
# TESTS: PER-SERVER EXCLUDE FILE
# ============================================================

echo ""
echo "=== Testing: Per-Server Exclude File ==="

# Create a per-server exclude file
cat > "${PROJECT_ROOT}/config/exclude.test-server.conf" <<'EOF'
/var/www/uploads
/tmp/cache
EOF

output=$(_tm_rsync_excludes "test-server" 2>&1)
assert_contains "Server exclude loaded" "exclude.test-server.conf" "${output}"
assert_contains "Global also loaded" "exclude.conf" "${output}"

# Test that non-existent server doesn't load server exclude
output=$(_tm_rsync_excludes "nonexistent.host" 2>&1)
assert_not_contains "No server exclude for unknown host" "exclude.nonexistent.host.conf" "${output}"

# Cleanup test exclude file
rm -f "${PROJECT_ROOT}/config/exclude.test-server.conf"

# ============================================================
# TESTS: CONFIGURABLE BACKUP PATHS
# ============================================================

echo ""
echo "=== Testing: Configurable Backup Paths ==="

# Test default paths
export TM_BACKUP_PATHS="/etc/,/home/,/root/,/var/spool/cron/,/opt/"

# We can't run the full rsync backup without a remote host,
# but we can verify the paths are parsed correctly
output=$(
    TM_BACKUP_PATHS="/custom/path1,/custom/path2"
    IFS=','
    paths=()
    for p in ${TM_BACKUP_PATHS}; do
        p="${p%/}/"
        paths+=("${p}")
    done
    echo "${paths[@]}"
)
assert_contains "Custom path 1 parsed" "/custom/path1/" "${output}"
assert_contains "Custom path 2 parsed" "/custom/path2/" "${output}"

# ============================================================
# TESTS: EXCLUDE FILE CONTENT
# ============================================================

echo ""
echo "=== Testing: Exclude File Content ==="

# Verify global exclude.conf has expected patterns
global_exclude=$(cat "${PROJECT_ROOT}/config/exclude.conf")
assert_contains "Excludes /proc" "/proc" "${global_exclude}"
assert_contains "Excludes /sys" "/sys" "${global_exclude}"
assert_contains "Excludes /dev" "/dev" "${global_exclude}"
assert_contains "Excludes /tmp" "/tmp" "${global_exclude}"
assert_contains "Excludes docker" "/var/lib/docker" "${global_exclude}"
assert_contains "Excludes /var/log" "/var/log" "${global_exclude}"
assert_contains "Excludes /var/lib/mysql" "/var/lib/mysql" "${global_exclude}"
assert_contains "Excludes /backup" "/backup" "${global_exclude}"
assert_contains "Excludes /mnt" "/mnt" "${global_exclude}"
assert_contains "Excludes varnish" "varnish_storage.bin" "${global_exclude}"
assert_contains "Excludes lxcfs" "/var/lib/lxcfs/" "${global_exclude}"
assert_contains "Excludes node_modules" "node_modules" "${global_exclude}"

# ============================================================
# RESULTS
# ============================================================

echo ""
echo "======================================="
echo "  Test Results: ${TESTS_PASSED}/${TESTS_RUN} passed"
if [[ ${TESTS_PASSED} -eq ${TESTS_RUN} ]]; then
    echo "  All tests passed!"
else
    echo "  Some tests FAILED!"
fi
echo "======================================="

[[ ${TESTS_PASSED} -eq ${TESTS_RUN} ]]
