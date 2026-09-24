#!/usr/bin/env bash
# install.sh — standalone Ubuntu GNOME hotkey setup.
#
# Components:
#   - main(): Apply the configurable screenshot, individually selectable
#     numbered-workspace switch/move actions, and window-placement-tiling
#     hotkeys. Monitor/window movement + tiling is a standalone repository
#     (linux_monitor_window_hotkeys) whose D-Bus tiling this service drives.
#
# Usage:
#   bash install.sh        # user-level setup; apt steps are skipped and reported
#   sudo bash install.sh   # full setup including apt package installation

set -euo pipefail

TARGET_USER="${SUDO_USER:-$USER}"
TARGET_UID="$(id -u "$TARGET_USER")"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="/run/user/${TARGET_UID}"
DISPLAY_VAL="${DISPLAY:-:0}"
USER_BUS="unix:path=${RUNTIME_DIR}/bus"
SESSION_TYPE="${XDG_SESSION_TYPE:-unknown}"
APT_UPDATED=0

WORKSPACE_COUNT="${WORKSPACE_COUNT:-8}"

SCREENSHOT_UI_BINDINGS=('<Shift><Super>s')
SCREENSHOT_QUICK_BINDINGS=('Print')
OVERVIEW_BINDINGS=('<Super>Tab')
WORKSPACE_SWITCH_BINDINGS=(
  "1:<Super>Z"
  "2:<Super>X"
  "3:<Super>C"
  "4:<Super>A"
  "5:<Super>Q"
  "6:<Super>W"
  "7:<Super>E"
  "8:<Super>R"
)
SUPER_ARROW_MOVE_BINDINGS=(
  "move-to-workspace-left:<Super><Shift>Left"
  "move-to-workspace-right:<Super><Shift>Right"
  "move-to-workspace-down:<Super><Shift>Down"
  "move-to-workspace-up:<Super><Shift>Up"
)

# Load the shared installer framework + shared install-time helpers (single
# source of truth in linux_installation_scripts_functions) before sourcing the
# hotkey libs, which use run_as_target/msg/need_cmd. No vendored copy: resolve a
# sibling checkout or clone on demand.
for __isc_d in "${ISC_FUNCTIONS_DIR:-}" \
               "$SCRIPT_DIR/../linux_installation_scripts_functions" \
               "$HOME/projects/linux_installation_scripts_functions"; do
  [ -n "$__isc_d" ] && [ -f "$__isc_d/component_loader.sh" ] && { source "$__isc_d/component_loader.sh"; break; }
done
if ! declare -F isc_load_helpers >/dev/null 2>&1; then
  __isc_framework_ref="${ISC_FUNCTIONS_REF:-master}"
  __isc_framework_key="${__isc_framework_ref//\//_}"
  __isc_framework_cache="${XDG_CACHE_HOME:-$HOME/.cache}/installation_scripts/framework-${__isc_framework_key}"
  __isc_framework_loader="$__isc_framework_cache/component_loader.sh"
  if [[ ! -f "$__isc_framework_loader" ]]; then
    command -v git >/dev/null 2>&1 || {
      printf 'ERROR: git is required to clone the shared installer framework.\n' >&2
      exit 1
    }
    mkdir -p "${__isc_framework_cache%/*}"
    __isc_framework_tmp="$(mktemp -d "${__isc_framework_cache%/*}/.framework-${__isc_framework_key}.XXXXXX")"
    printf 'Cloning shared installer framework ref %s for standalone installation.\n' \
      "$__isc_framework_ref" >&2
    if ! GIT_TERMINAL_PROMPT=0 git clone --quiet --depth 1 --single-branch \
      --branch "$__isc_framework_ref" \
      https://github.com/mikaeltorni/linux_installation_scripts_functions.git \
      "$__isc_framework_tmp/repository"; then
      printf 'ERROR: could not clone the shared installer framework; check GitHub access.\n' >&2
      exit 1
    fi
    if [[ ! -e "$__isc_framework_cache" ]] && mv "$__isc_framework_tmp/repository" "$__isc_framework_cache"; then
      rmdir "$__isc_framework_tmp" 2>/dev/null || true
    else
      __isc_framework_loader="$__isc_framework_tmp/repository/component_loader.sh"
    fi
  fi
  ISC_FUNCTIONS_DIR="${__isc_framework_loader%/*}"
  export ISC_FUNCTIONS_DIR
  source "$__isc_framework_loader"
fi
isc_load_helpers

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/hotkeys_setup.sh"
source "$SCRIPT_DIR/lib/lifecycle.sh"

# Component selection runtime and this repository's component manifest. The
# manifest maps each component id to a configure_*/lock_* function from
# lib/hotkeys_setup.sh and its sourced helpers. The framework was already
# resolved above; activate the component runtime from the same checkout.
isc_activate_components
source "$SCRIPT_DIR/installer/components.sh"

main() {
  msg "=== Linux Hotkey Setup ==="

  # Feature-specific installation support (--features=feature1,feature2,...)
  SELECTED_FEATURES="${FEATURES:-}"

  if [ -n "$SELECTED_FEATURES" ]; then
    # The component runtime already splits comma-separated ids, so the whole
    # FEATURES list is forwarded verbatim; passing only the first element would
    # silently drop every other requested feature.
    IFS="," read -ra FEATURE_ARRAY <<< "$SELECTED_FEATURES"
    msg "Feature filter active: ${FEATURE_ARRAY[*]}"
    component_main "--select=$SELECTED_FEATURES"
  else
    # No explicit selection: component_main shows the interactive component menu
    # on a real terminal, otherwise installs the default-on components. Hotkeys
    # apply their shown defaults unless ISC_HOTKEY_INTERACTIVE=1 is set to press
    # custom ones, so automated runs never block.
    component_main "$@"
  fi

  msg "Ubuntu hotkey setup complete. Log out and back in before testing GNOME Shell extension changes."
}

# Listing/help/export must print only their own output (the master installer
# parses --list-components, --list-configurable-components, and
# --list-component-config-values). Route readonly flags even when --config is
# argv[1].
if isc_route_readonly_args "$@"; then exit $?; fi

main "$@"
