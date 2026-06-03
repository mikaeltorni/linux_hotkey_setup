#!/usr/bin/env bash
set -euo pipefail

# Tests for xmousepasteblock functions in hotkeys_setup.sh
# Run with: sudo bash tests/test_xmousepasteblock.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6 2>/dev/null || echo "/home/$TARGET_USER")"
RUNTIME_DIR="/run/user/$(id -u "$TARGET_USER")"
DISPLAY_VAL="${DISPLAY:-:0}"
USER_BUS="unix:path=${RUNTIME_DIR}/bus"

# Source hotkeys_setup.sh (it defines its own msg, log, need_cmd, run_as_target)
source "$SCRIPT_DIR/lib/hotkeys_setup.sh"

PASS=0
FAIL=0

assert_eq() {
  local expected="$1" actual="$2" msg="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $msg"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $msg (expected '$expected', got '$actual')"
    FAIL=$((FAIL + 1))
  fi
}

echo "=========================================="
echo "  xmousepasteblock Module Tests"
echo "=========================================="

# Test build_xmousepasteblock function exists and is callable
echo ""
echo "--- build_xmousepasteblock ---"
if declare -f build_xmousepasteblock >/dev/null 2>&1; then
  echo "  PASS: build_xmousepasteblock function exists"
  PASS=$((PASS + 1))
else
  echo "  FAIL: build_xmousepasteblock function not found"
  FAIL=$((FAIL + 1))
fi

# Test configure_xmousepasteblock_service function exists and is callable
echo ""
echo "--- configure_xmousepasteblock_service ---"
if declare -f configure_xmousepasteblock_service >/dev/null 2>&1; then
  echo "  PASS: configure_xmousepasteblock_service function exists"
  PASS=$((PASS + 1))
else
  echo "  FAIL: configure_xmousepasteblock_service function not found"
  FAIL=$((FAIL + 1))
fi

# Test lock_primary_paste function exists and is callable
echo ""
echo "--- lock_primary_paste ---"
if declare -f lock_primary_paste >/dev/null 2>&1; then
  echo "  PASS: lock_primary_paste function exists"
  PASS=$((PASS + 1))
else
  echo "  FAIL: lock_primary_paste function not found"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
