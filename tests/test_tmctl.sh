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
export TM_STATE_DIR="${TEST_TMP}/state"
export TM_LOG_DIR="${TEST_TMP}/logs"
export TM_LOG_LEVEL="INFO"
export TM_ALERT_ENABLED="false"
export TM_SSH_KEY="${TEST_TMP}/fake_key"
export TM_API_PORT="7600"

mkdir -p "${TM_HOME}" "${TM_BACKUP_ROOT}" "${TM_RUN_DIR}" "${TM_STATE_DIR}" "${TM_LOG_DIR}"
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
assert_contains "Version output" "3.4.0" "${output}"

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
    "${TM_STATE_DIR}/proc-test.example.com.state"

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

# Add with priority
output=$(bash "${PROJECT_ROOT}/bin/tmctl.sh" server add testhost3.example.com --priority 1 2>&1)
assert_contains "Server add with priority" "Added" "${output}"
file_content=$(cat "${TEST_SERVERS_CONF}")
assert_contains "Priority in config" "testhost3.example.com --priority 1" "${file_content}"

# Add with db-interval
output=$(bash "${PROJECT_ROOT}/bin/tmctl.sh" server add testhost4.example.com --priority 2 --db-interval 4h 2>&1)
assert_contains "Server add with db-interval" "Added" "${output}"
file_content=$(cat "${TEST_SERVERS_CONF}")
assert_contains "DB interval in config" "--db-interval 4h" "${file_content}"

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
assert_contains "Help shows update" "update" "${output}"
assert_contains "Help shows fix-permissions" "fix-permissions" "${output}"
assert_contains "Help shows uninstall" "uninstall" "${output}"

# ============================================================
# TESTS: PRIORITY SORTING
# ============================================================

echo ""
echo "=== Testing: priority sorting ==="

# Create a test servers.conf with mixed priorities
PRIO_CONF="${TEST_TMP}/prio-servers.conf"
cat > "${PRIO_CONF}" <<'EOF'
low.example.com --priority 20
high.example.com --priority 1
default.example.com
mid.example.com --priority 5
EOF

# Source tmserviced.sh functions for _parse_priority and _get_sorted_servers
source "${PROJECT_ROOT}/lib/common.sh"
tm_load_config

# Inline the functions for testing (they're defined in tmserviced.sh)
_test_parse_priority() {
    local line="$1"
    if echo "${line}" | grep -qo '\-\-priority[[:space:]]\+[0-9]\+'; then
        echo "${line}" | grep -o '\-\-priority[[:space:]]\+[0-9]\+' | awk '{print $2}'
    else
        echo "10"
    fi
}

_test_parse_db_interval() {
    local line="$1"
    if echo "${line}" | grep -qo '\-\-db-interval[[:space:]]\+[0-9]\+h'; then
        echo "${line}" | grep -o '\-\-db-interval[[:space:]]\+[0-9]\+h' | grep -o '[0-9]\+'
    fi
}

# Test priority parsing
prio=$(_test_parse_priority "high.example.com --priority 1")
assert_eq "Parse priority 1" "1" "${prio}"

prio=$(_test_parse_priority "default.example.com")
assert_eq "Parse default priority" "10" "${prio}"

prio=$(_test_parse_priority "low.example.com --priority 20 --files-only")
assert_eq "Parse priority with other opts" "20" "${prio}"

# Test db-interval parsing
db_int=$(_test_parse_db_interval "db.example.com --db-interval 4h")
assert_eq "Parse db-interval 4h" "4" "${db_int}"

db_int=$(_test_parse_db_interval "db.example.com --priority 1 --db-interval 2h --files-only")
assert_eq "Parse db-interval with other opts" "2" "${db_int}"

db_int=$(_test_parse_db_interval "default.example.com")
assert_eq "No db-interval returns empty" "" "${db_int}"

# Test priority sorting
sorted=$(
    grep -E '^\s*[^#\s]' "${PRIO_CONF}" | \
        sed 's/^[[:space:]]*//' | \
        while IFS= read -r line; do
            prio=$(_test_parse_priority "${line}")
            printf '%03d|%s\n' "${prio}" "${line}"
        done | sort -t'|' -k1,1n | cut -d'|' -f2-
)
first_host=$(echo "${sorted}" | head -1 | awk '{print $1}')
assert_eq "Highest priority first" "high.example.com" "${first_host}"

last_host=$(echo "${sorted}" | tail -1 | awk '{print $1}')
assert_eq "Lowest priority last" "low.example.com" "${last_host}"

# ============================================================
# TESTS: TIMEMACHINE.SH ACCEPTS NEW FLAGS
# ============================================================

echo ""
echo "=== Testing: timemachine.sh flag parsing ==="

# Syntax check
syntax_output=$(bash -n "${PROJECT_ROOT}/bin/timemachine.sh" 2>&1)
syntax_rc=$?
assert_eq "timemachine.sh syntax valid" "0" "${syntax_rc}"

# daily-runner.sh syntax check
syntax_output=$(bash -n "${PROJECT_ROOT}/bin/daily-runner.sh" 2>&1)
syntax_rc=$?
assert_eq "daily-runner.sh syntax valid" "0" "${syntax_rc}"

# tmserviced.sh syntax check
syntax_output=$(bash -n "${PROJECT_ROOT}/bin/tmserviced.sh" 2>&1)
syntax_rc=$?
assert_eq "tmserviced.sh syntax valid" "0" "${syntax_rc}"

# tm-api-server.py syntax check
if command -v python3 &>/dev/null; then
    syntax_output=$(python3 -c "import py_compile; py_compile.compile('${PROJECT_ROOT}/bin/tm-api-server.py', doraise=True)" 2>&1)
    syntax_rc=$?
    assert_eq "tm-api-server.py syntax valid" "0" "${syntax_rc}"
fi

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
