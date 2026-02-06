#!/usr/bin/env bash
# ============================================================
# TimeMachine Backup - Run All Tests
# ============================================================
# Usage: bash tests/run_all_tests.sh
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FAILED=0

echo "============================================"
echo "  TimeMachine Backup - Test Suite"
echo "============================================"

for test_file in "${SCRIPT_DIR}"/test_*.sh; do
    [[ -f "${test_file}" ]] || continue
    test_name=$(basename "${test_file}")

    echo ""
    echo "--- Running: ${test_name} ---"

    if bash "${test_file}"; then
        echo "--- ${test_name}: OK ---"
    else
        echo "--- ${test_name}: FAILED ---"
        FAILED=$((FAILED + 1))
    fi
done

echo ""
echo "============================================"
if [[ ${FAILED} -gt 0 ]]; then
    echo "  ${FAILED} test suite(s) FAILED"
    echo "============================================"
    exit 1
else
    echo "  All test suites passed!"
    echo "============================================"
    exit 0
fi
