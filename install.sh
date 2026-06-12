#!/usr/bin/env bash
# install.sh — standalone Ubuntu GNOME hotkey setup.
#
# Components:
#   - main(): Apply screenshot, workspace, Albert, monitor/window, Ctrl+Back,
#     numbered workspace popup, and primary-paste-blocker hotkey setup.
#
# Usage:
#   bash install.sh        # user-level setup; apt steps are skipped and reported
#   sudo bash install.sh   # full setup including apt package installation

set -euo pipefail

TARGET_USER="${SUDO_USER:-$USER}"
TARGET_UID="$(id -u "$TARGET_USER")"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR/configs"
RUNTIME_DIR="/run/user/${TARGET_UID}"
DISPLAY_VAL="${DISPLAY:-:0}"
USER_BUS="unix:path=${RUNTIME_DIR}/bus"
SESSION_TYPE="${XDG_SESSION_TYPE:-unknown}"
APT_UPDATED=0

WORKSPACE_COUNT="${WORKSPACE_COUNT:-8}"
MONITOR_WINDOW_HOTKEYS_EXTENSION_ID="monitor-window-hotkeys@local"
MONITOR_WINDOW_HOTKEYS_SOURCE_DIR="$CONFIG_DIR/gnome-shell/extensions/$MONITOR_WINDOW_HOTKEYS_EXTENSION_ID"
AUTOMATIC_WINDOW_TILING_DIR="${AUTOMATIC_WINDOW_TILING_DIR:-$SCRIPT_DIR/../linux_automatic_window_tiling}"
AUTOMATIC_WINDOW_TILING_BINDING="${AUTOMATIC_WINDOW_TILING_BINDING:-<Super>t}"

SCREENSHOT_UI_BINDINGS=('<Shift><Super>s')
SCREENSHOT_QUICK_BINDINGS=('Print')
SCREEN_RECORDING_BINDINGS=('<Shift><Super>r')
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
WORKSPACE_MOVE_BINDINGS=(
  "1:<Super><Shift>z"
  "2:<Super><Shift>x"
  "3:<Super><Shift>c"
  "4:<Super><Shift>a"
  "5:<Super><Shift>q"
  "6:<Super><Shift>w"
  "7:<Super><Shift>e"
  "8:<Super><Shift>r"
)
SUPER_ARROW_MOVE_BINDINGS=(
  "move-to-workspace-left:<Super><Shift>Left"
  "move-to-workspace-right:<Super><Shift>Right"
  "move-to-workspace-down:<Super><Shift>Down"
  "move-to-workspace-up:<Super><Shift>Up"
)

main() {
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/hotkeys_setup.sh"
  configure_ubuntu_hotkeys
  report_sudo_required
  msg "Ubuntu hotkey setup complete. Log out and back in before testing GNOME Shell extension changes."
}

main "$@"
