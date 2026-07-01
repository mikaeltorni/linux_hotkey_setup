#!/usr/bin/env bash
# components.sh - Component manifest for linux_hotkey_setup.
#
# Maps each selectable hotkey component to the function (defined in lib/) that
# applies it. install.sh sources lib/hotkeys_setup.sh first, then this manifest,
# then routes execution through component_main from component_runtime.sh.
#
# Entry format:
# "id|label|default(on/off)|function|detect|uninstall|section".

ISC_REPO_NAME="linux_hotkey_setup"
ISC_REPO_LABEL="GNOME hotkeys and window tools"

# Device selection for the window-placement tiling service now lives inside that
# component (configure_window_placement_tiling_service) so it only runs when the
# service is selected and never prompts a user who deselected it. The
# post-install audit + sudo summary still run once after the selected components.
ISC_POSTFLIGHT="hotkey_postflight"

# Automatic same-application window tiling (linux_automatic_window_tiling) and
# the pointer-driven window move/resize hotkeys (linux_hotkey_window_tools) used
# to be delegated from here. They are standalone, directly-installed repositories
# now — each configures its own hotkeys through the shared interactive
# hotkey-capture engine (isc_capture_hotkey) — so they are no longer components
# of this repo. The numbered workspace popup extension moved to
# linux_workspaces_setup. Each numbered switch/move action is its own component
# row so both the standalone and aggregate installer menus expose it directly.
# Hotkeys resolve through the shared press-to-capture engine; environment
# overrides remain available for scripted master runs.
ISC_COMPONENTS=(
  "screenshot|Screenshot shortcut|on|configure_screenshot_binding|detect_screenshot|uninstall_screenshot|General"
  "workspace_behavior|Static workspace behavior and navigation|on|configure_workspace_behavior|detect_workspace_behavior|uninstall_workspace_behavior|Workspace behavior"
  "workspace_switch_1|Switch to workspace 1 — Super+Z|on|configure_workspace_switch_1|detect_workspace_switch_1|uninstall_workspace_switch_1|Switch to workspace"
  "workspace_switch_2|Switch to workspace 2 — Super+X|on|configure_workspace_switch_2|detect_workspace_switch_2|uninstall_workspace_switch_2|Switch to workspace"
  "workspace_switch_3|Switch to workspace 3 — Super+C|on|configure_workspace_switch_3|detect_workspace_switch_3|uninstall_workspace_switch_3|Switch to workspace"
  "workspace_switch_4|Switch to workspace 4 — Super+A|on|configure_workspace_switch_4|detect_workspace_switch_4|uninstall_workspace_switch_4|Switch to workspace"
  "workspace_switch_5|Switch to workspace 5 — Super+Q|on|configure_workspace_switch_5|detect_workspace_switch_5|uninstall_workspace_switch_5|Switch to workspace"
  "workspace_switch_6|Switch to workspace 6 — Super+W|on|configure_workspace_switch_6|detect_workspace_switch_6|uninstall_workspace_switch_6|Switch to workspace"
  "workspace_switch_7|Switch to workspace 7 — Super+E|on|configure_workspace_switch_7|detect_workspace_switch_7|uninstall_workspace_switch_7|Switch to workspace"
  "workspace_switch_8|Switch to workspace 8 — Super+R|on|configure_workspace_switch_8|detect_workspace_switch_8|uninstall_workspace_switch_8|Switch to workspace"
  "workspace_switch_9|Switch to workspace 9 — unassigned|off|configure_workspace_switch_9|detect_workspace_switch_9|uninstall_workspace_switch_9|Switch to workspace"
  "workspace_move_1|Move window to workspace 1 — Super+Shift+Z|on|configure_workspace_move_1|detect_workspace_move_1|uninstall_workspace_move_1|Move window to workspace"
  "workspace_move_2|Move window to workspace 2 — Super+Shift+X|on|configure_workspace_move_2|detect_workspace_move_2|uninstall_workspace_move_2|Move window to workspace"
  "workspace_move_3|Move window to workspace 3 — Super+Shift+C|on|configure_workspace_move_3|detect_workspace_move_3|uninstall_workspace_move_3|Move window to workspace"
  "workspace_move_4|Move window to workspace 4 — Super+Shift+A|on|configure_workspace_move_4|detect_workspace_move_4|uninstall_workspace_move_4|Move window to workspace"
  "workspace_move_5|Move window to workspace 5 — Super+Shift+Q|on|configure_workspace_move_5|detect_workspace_move_5|uninstall_workspace_move_5|Move window to workspace"
  "workspace_move_6|Move window to workspace 6 — Super+Shift+W|on|configure_workspace_move_6|detect_workspace_move_6|uninstall_workspace_move_6|Move window to workspace"
  "workspace_move_7|Move window to workspace 7 — Super+Shift+E|on|configure_workspace_move_7|detect_workspace_move_7|uninstall_workspace_move_7|Move window to workspace"
  "workspace_move_8|Move window to workspace 8 — Super+Shift+R|on|configure_workspace_move_8|detect_workspace_move_8|uninstall_workspace_move_8|Move window to workspace"
  "workspace_move_9|Move window to workspace 9 — unassigned|off|configure_workspace_move_9|detect_workspace_move_9|uninstall_workspace_move_9|Move window to workspace"
  "monitor_window_hotkeys|Monitor/window movement hotkeys extension|on|configure_monitor_window_hotkeys_extension|detect_monitor_window_hotkeys|uninstall_monitor_window_hotkeys|Window tools"
  "window_placement_tiling|Window placement tiling (Ctrl + mouse Back)|on|configure_window_placement_tiling_service|detect_window_placement_tiling|uninstall_window_placement_tiling|Window tools"
)

# hotkey_postflight - audit the applied keybindings and report any skipped
# root-only steps. Runs once after the selected components install.
hotkey_postflight() {
  audit_keybindings || true
  report_sudo_required || true
}
