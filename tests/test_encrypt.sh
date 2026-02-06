#!/usr/bin/env bash
# ============================================================
# TimeMachine Backup - Tests for lib/encrypt.sh
# ============================================================
# Run: bash tests/test_encrypt.sh
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

mkdir -p "${TM_HOME}" "${TM_BACKUP_ROOT}" "${TM_RUN_DIR}" "${TM_LOG_DIR}"

source "${PROJECT_ROOT}/lib/common.sh"
source "${PROJECT_ROOT}/lib/encrypt.sh"

tm_load_config

# ============================================================
# TESTS: ENCRYPTION AVAILABILITY
# ============================================================

echo ""
echo "=== Testing: Encryption Availability ==="

# Disabled by default
TM_ENCRYPT_ENABLED="false"
if ! tm_encrypt_available 2>/dev/null; then
    echo "  PASS: Encryption not available when disabled"
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo "  FAIL: Should not be available when disabled"
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Missing passphrase
TM_ENCRYPT_ENABLED="true"
TM_ENCRYPT_MODE="symmetric"
TM_ENCRYPT_PASSPHRASE=""
result="false"
tm_encrypt_available >/dev/null 2>&1 && result="true" || result="false"
assert_eq "Not available without passphrase" "false" "${result}"

# Missing key ID
TM_ENCRYPT_MODE="asymmetric"
TM_ENCRYPT_KEY_ID=""
result="false"
tm_encrypt_available >/dev/null 2>&1 && result="true" || result="false"
assert_eq "Not available without key ID" "false" "${result}"

# Invalid mode
TM_ENCRYPT_MODE="invalid"
result="false"
tm_encrypt_available >/dev/null 2>&1 && result="true" || result="false"
assert_eq "Not available with invalid mode" "false" "${result}"

# ============================================================
# TESTS: ENCRYPT/DECRYPT (if GPG available)
# ============================================================

echo ""
echo "=== Testing: Encrypt/Decrypt ==="

if command -v gpg &>/dev/null; then
    TM_ENCRYPT_ENABLED="true"
    TM_ENCRYPT_MODE="symmetric"
    TM_ENCRYPT_PASSPHRASE="test-passphrase-12345"

    # Create test data
    TEST_DATA_DIR="${TEST_TMP}/test_data"
    mkdir -p "${TEST_DATA_DIR}"
    echo "Hello, TimeMachine!" > "${TEST_DATA_DIR}/test.txt"
    echo "Database content" > "${TEST_DATA_DIR}/db.sql"

    # Test encryption
    ENCRYPTED_FILE="${TEST_TMP}/test_data.tar.gpg"
    if tm_encrypt "${TEST_DATA_DIR}" "${ENCRYPTED_FILE}" 2>/dev/null; then
        assert_eq "Encrypted file created" "true" "$([[ -f "${ENCRYPTED_FILE}" ]] && echo true || echo false)"

        # Test decryption
        DECRYPT_DIR="${TEST_TMP}/decrypted"
        if tm_decrypt "${ENCRYPTED_FILE}" "${DECRYPT_DIR}" 2>/dev/null; then
            assert_eq "Decrypted directory created" "true" "$([[ -d "${DECRYPT_DIR}" ]] && echo true || echo false)"

            # Verify content
            if [[ -f "${DECRYPT_DIR}/test_data/test.txt" ]]; then
                local_content=$(cat "${DECRYPT_DIR}/test_data/test.txt")
                assert_eq "Decrypted content matches" "Hello, TimeMachine!" "${local_content}"
            else
                echo "  FAIL: Decrypted file not found"
                TESTS_RUN=$((TESTS_RUN + 1))
                TESTS_FAILED=$((TESTS_FAILED + 1))
            fi
        else
            echo "  FAIL: Decryption failed"
            TESTS_RUN=$((TESTS_RUN + 1))
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    else
        echo "  FAIL: Encryption failed"
        TESTS_RUN=$((TESTS_RUN + 1))
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi

    # Test encrypt_backup with disabled encryption
    TM_ENCRYPT_ENABLED="false"
    output=$(tm_encrypt_backup "${TEST_DATA_DIR}" 2>&1)
    assert_contains "Encrypt backup skipped when disabled" "not enabled" "${output}"

    # Test encrypt non-existent file
    TM_ENCRYPT_ENABLED="true"
    output=$(tm_encrypt "/nonexistent/path" "${TEST_TMP}/out.tar.gpg" 2>&1 || true)
    assert_contains "Error on non-existent source" "does not exist" "${output}"
else
    echo "  SKIP: GPG not installed; skipping encrypt/decrypt tests"
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
fi

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
