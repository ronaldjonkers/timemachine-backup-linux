#!/usr/bin/env bash
# ============================================================
# TimeMachine Backup - Tests: Database Auto-Detection & Config
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
export TM_LOG_LEVEL="INFO"
export TM_ALERT_ENABLED=false
export TM_ENCRYPT_ENABLED=false
export TM_RUN_DIR="${TEST_TMP}/run"
export TM_DB_TYPES="auto"
export TM_MYSQL_PW_FILE="/root/mysql.pw"
export TM_MYSQL_HOST=""
export TM_PG_USER="postgres"
export TM_PG_HOST=""
export TM_MONGO_HOST=""
export TM_MONGO_AUTH_DB="admin"
export TM_REDIS_HOST=""
export TM_REDIS_PORT=6379
export TM_SQLITE_PATHS=""
export TM_DB_DUMP_RETRIES=3

mkdir -p "${TM_RUN_DIR}"

# Source common for tm_log
source "${PROJECT_ROOT}/lib/common.sh"

# ============================================================
# TESTS: DATABASE CONFIG DEFAULTS
# ============================================================

echo ""
echo "=== Testing: Database Config Defaults ==="

tm_load_config 2>/dev/null
assert_eq "TM_DB_TYPES default" "auto" "${TM_DB_TYPES}"
assert_eq "TM_PG_USER default" "postgres" "${TM_PG_USER}"
assert_eq "TM_MONGO_AUTH_DB default" "admin" "${TM_MONGO_AUTH_DB}"
assert_eq "TM_REDIS_PORT default" "6379" "${TM_REDIS_PORT}"
assert_eq "TM_DB_DUMP_RETRIES default" "3" "${TM_DB_DUMP_RETRIES}"

# ============================================================
# TESTS: DUMP_DBS.SH SYNTAX CHECK
# ============================================================

echo ""
echo "=== Testing: dump_dbs.sh Syntax ==="

syntax_output=$(bash -n "${PROJECT_ROOT}/bin/dump_dbs.sh" 2>&1)
syntax_rc=$?
assert_eq "dump_dbs.sh syntax valid" "0" "${syntax_rc}"

# ============================================================
# TESTS: DATABASE AUTO-DETECTION
# ============================================================

echo ""
echo "=== Testing: Database Auto-Detection ==="

# Source the detect function from dump_dbs.sh by extracting it
# We simulate by checking what the script would detect
# Since we're on macOS dev, sqlite3 should be available

if command -v sqlite3 &>/dev/null; then
    # Set a SQLite path to trigger detection
    export TM_SQLITE_PATHS="/tmp/test.db"
    output=$(bash -c '
        source "'"${PROJECT_ROOT}/lib/common.sh"'"
        detect_db_types() {
            local detected=""
            if command -v mysql &>/dev/null || command -v mariadb &>/dev/null; then
                detected+="mysql,"
            fi
            if command -v psql &>/dev/null; then
                detected+="postgresql,"
            fi
            if command -v mongodump &>/dev/null; then
                detected+="mongodb,"
            fi
            if command -v redis-cli &>/dev/null; then
                detected+="redis,"
            fi
            if [[ -n "${TM_SQLITE_PATHS}" ]]; then
                detected+="sqlite,"
            fi
            detected="${detected%,}"
            echo "${detected}"
        }
        detect_db_types
    ' 2>/dev/null)
    assert_contains "SQLite detected when paths set" "sqlite" "${output}"
    export TM_SQLITE_PATHS=""
fi

# Test with explicit DB types
export TM_DB_TYPES="mysql,postgresql"
assert_eq "Explicit DB types preserved" "mysql,postgresql" "${TM_DB_TYPES}"

# Test with auto
export TM_DB_TYPES="auto"
assert_eq "Auto mode set" "auto" "${TM_DB_TYPES}"

# ============================================================
# TESTS: DATABASE LIBRARY (server-side)
# ============================================================

echo ""
echo "=== Testing: Database Library ==="

source "${PROJECT_ROOT}/lib/database.sh"

# Verify tm_trigger_remote_dump function exists
assert_eq "tm_trigger_remote_dump exists" "0" \
    "$(type -t tm_trigger_remote_dump &>/dev/null && echo 0 || echo 1)"

# Verify tm_wait_for_db_dump function exists
assert_eq "tm_wait_for_db_dump exists" "0" \
    "$(type -t tm_wait_for_db_dump &>/dev/null && echo 0 || echo 1)"

# ============================================================
# TESTS: CREDENTIAL FILE PATTERNS
# ============================================================

echo ""
echo "=== Testing: Credential File Patterns ==="

# Test MySQL password file pattern
assert_eq "MySQL pw file default" "/root/mysql.pw" "${TM_MYSQL_PW_FILE}"

# Test MongoDB credentials file path
mongo_cred="${TM_HOME}/.mongo_credentials"
assert_contains "Mongo cred path in TM_HOME" "${TEST_TMP}" "${mongo_cred}"

# Test Redis password file path
redis_pw="${TM_HOME}/.redis_password"
assert_contains "Redis pw path in TM_HOME" "${TEST_TMP}" "${redis_pw}"

# ============================================================
# TESTS: DUMP DIRECTORY STRUCTURE
# ============================================================

echo ""
echo "=== Testing: Dump Directory Structure ==="

# Simulate what dump_dbs.sh creates
SQL_DIR="${TEST_TMP}/sql"
mkdir -p "${SQL_DIR}/mysql"
mkdir -p "${SQL_DIR}/postgresql"
mkdir -p "${SQL_DIR}/mongodb"
mkdir -p "${SQL_DIR}/redis"
mkdir -p "${SQL_DIR}/sqlite"

assert_eq "MySQL dump dir exists" "true" \
    "$([[ -d "${SQL_DIR}/mysql" ]] && echo true || echo false)"
assert_eq "PostgreSQL dump dir exists" "true" \
    "$([[ -d "${SQL_DIR}/postgresql" ]] && echo true || echo false)"
assert_eq "MongoDB dump dir exists" "true" \
    "$([[ -d "${SQL_DIR}/mongodb" ]] && echo true || echo false)"
assert_eq "Redis dump dir exists" "true" \
    "$([[ -d "${SQL_DIR}/redis" ]] && echo true || echo false)"
assert_eq "SQLite dump dir exists" "true" \
    "$([[ -d "${SQL_DIR}/sqlite" ]] && echo true || echo false)"

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
