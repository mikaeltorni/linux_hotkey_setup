#!/usr/bin/env bash
# lhs_bin.sh — Resolve and invoke the lhs-tools Rust helper.
#
# Sourced by install.sh after SCRIPT_DIR is set. Builds the binary on demand
# via scripts/build_lhs_tools.sh.
#
# Public functions:
#   ensure_lhs_bin  — build/locate dist/lhs-tools; sets LHS_BIN
#   lhs_bin         — ensure_lhs_bin then run it with "$@"

# ensure_lhs_bin — Locate or build dist/lhs-tools; export LHS_BIN.
ensure_lhs_bin() {
  local build_script bin
  build_script="${SCRIPT_DIR:-${HOTKEYS_SETUP_DIR:?SCRIPT_DIR unset}}/scripts/build_lhs_tools.sh"
  if [ -n "${LHS_BIN:-}" ] && [ -x "$LHS_BIN" ]; then
    return 0
  fi
  if [ ! -x "$build_script" ]; then
    if declare -F msg >/dev/null 2>&1; then
      msg "Missing build helper: $build_script"
    else
      printf 'Missing build helper: %s\n' "$build_script" >&2
    fi
    return 1
  fi
  bin="$(bash "$build_script" --print)" || return 1
  LHS_BIN="$bin"
  export LHS_BIN
}

# lhs_bin — Run the helper CLI.
lhs_bin() {
  ensure_lhs_bin || return 1
  "$LHS_BIN" "$@"
}
