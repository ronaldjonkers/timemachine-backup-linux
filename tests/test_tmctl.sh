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
assert_contains "Version output" "0.3.1" "${output}"

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
# TESTS: SERVER ADD / REMOVE
# ============================================================

echo ""
echo "=== Testing: tmctl server add/remove ==="

# Create a clean servers.conf for testing
TEST_SERVERS_CONF="${PROJECT_ROOT}/config/servers.conf"
ORIG_SERVERS_CONF=""
if [[ -f "${TEST_SERVERS_CONF}" ]]; then
    ORIG_SERVERS_CONF=$(cat "${TEST_SERVERS_CONF}")
fi
echo "# test" > "${TEST_SERVERS_CONF}"

# Add a server
output=$(bash "${PROJECT_ROOT}/bin/tmctl.sh" server add testhost1.example.com 2>&1)
assert_contains "Server add output" "Added" "${output}"

# Verify it's in the file
file_content=$(cat "${TEST_SERVERS_CONF}")
assert_contains "Server in config" "testhost1.example.com" "${file_content}"

# Add with options
output=$(bash "${PROJECT_ROOT}/bin/tmctl.sh" server add testhost2.example.com --files-only 2>&1)
assert_contains "Server add with opts" "Added" "${output}"
file_content=$(cat "${TEST_SERVERS_CONF}")
assert_contains "Server with opts in config" "testhost2.example.com --files-only" "${file_content}"

# Duplicate should fail
output=$(bash "${PROJECT_ROOT}/bin/tmctl.sh" server add testhost1.example.com 2>&1 || true)
assert_contains "Duplicate rejected" "already exists" "${output}"

# Remove a server
output=$(bash "${PROJECT_ROOT}/bin/tmctl.sh" server remove testhost1.example.com 2>&1)
assert_contains "Server remove output" "Removed" "${output}"

# Verify it's gone
file_content=$(cat "${TEST_SERVERS_CONF}")
if [[ "${file_content}" != *"testhost1.example.com"* ]]; then
    echo "  PASS: Server removed from config"
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo "  FAIL: Server still in config after remove"
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Remove non-existent should fail
output=$(bash "${PROJECT_ROOT}/bin/tmctl.sh" server remove nonexistent.example.com 2>&1 || true)
assert_contains "Remove non-existent fails" "not found" "${output}"

# Restore original servers.conf
if [[ -n "${ORIG_SERVERS_CONF}" ]]; then
    echo "${ORIG_SERVERS_CONF}" > "${TEST_SERVERS_CONF}"
else
    rm -f "${TEST_SERVERS_CONF}"
fi

# ============================================================
# TESTS: HELP
# ============================================================

echo ""
echo "=== Testing: tmctl help ==="

output=$(bash "${PROJECT_ROOT}/bin/tmctl.sh" help 2>&1 || true)
assert_contains "Help shows commands" "Commands:" "${output}"
assert_contains "Help shows backup" "backup" "${output}"
assert_contains "Help shows restore" "restore" "${output}"
assert_contains "Help shows server add" "server add" "${output}"
assert_contains "Help shows server remove" "server remove" "${output}"
assert_contains "Help shows setup-web" "setup-web" "${output}"

# ============================================================
# TESTS: SETUP-WEB SCRIPT
# ============================================================

echo ""
echo "=== Testing: setup-web.sh ==="

# Syntax check
syntax_output=$(bash -n "${PROJECT_ROOT}/bin/setup-web.sh" 2>&1)
syntax_rc=$?
assert_eq "setup-web.sh syntax valid" "0" "${syntax_rc}"

# Script is executable or at least parseable
assert_contains "setup-web.sh has shebang" "#!/usr/bin/env bash" "$(head -1 "${PROJECT_ROOT}/bin/setup-web.sh")"

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
