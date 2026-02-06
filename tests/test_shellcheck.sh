#!/usr/bin/env bash
# ============================================================
# TimeMachine Backup - ShellCheck Linting Tests
# ============================================================
# Runs shellcheck on all shell scripts in the project.
# Requires: shellcheck (https://www.shellcheck.net/)
#
# Run: bash tests/test_shellcheck.sh
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Check if shellcheck is available
if ! command -v shellcheck &>/dev/null; then
    echo "WARNING: shellcheck not installed. Skipping lint tests."
    echo "Install with: brew install shellcheck (macOS) or apt install shellcheck (Debian)"
    exit 0
fi

echo "=== Running ShellCheck on all scripts ==="
echo ""

FAILED=0
CHECKED=0

# Find all .sh files
while IFS= read -r -d '' script; do
    CHECKED=$((CHECKED + 1))
    rel_path="${script#${PROJECT_ROOT}/}"

    if shellcheck -x -S warning "${script}" 2>&1; then
        echo "  PASS: ${rel_path}"
    else
        echo "  FAIL: ${rel_path}"
        FAILED=$((FAILED + 1))
    fi
done < <(find "${PROJECT_ROOT}" -name "*.sh" -not -path "*/.sh-tmp/*" -not -path "*/.git/*" -print0)

echo ""
echo "============================================"
echo "  ShellCheck: ${CHECKED} files checked"
if [[ ${FAILED} -gt 0 ]]; then
    echo "  FAILED: ${FAILED} file(s) have warnings"
    echo "============================================"
    exit 1
else
    echo "  All files passed!"
    echo "============================================"
    exit 0
fi
