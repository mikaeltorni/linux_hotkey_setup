#!/usr/bin/env bash
# components.sh - Component manifest for linux_hotkey_setup.
#
# Maps each selectable hotkey component to the function (defined in lib/) that
# applies it. install.sh sources lib/hotkeys_setup.sh first, then this manifest,
# then routes execution through component_main from component_runtime.sh.
#
# Entry format:
# "id|label|default|function|detect|uninstall|section|requires|configurator|status".

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
  "workspace_switch_1|Switch to workspace 1|on|configure_workspace_switch_1|detect_workspace_switch_1|uninstall_workspace_switch_1|Switch to workspace|workspace_behavior|configure_workspace_switch_field_1|workspace_switch_status_1"
  "workspace_switch_2|Switch to workspace 2|on|configure_workspace_switch_2|detect_workspace_switch_2|uninstall_workspace_switch_2|Switch to workspace|workspace_behavior|configure_workspace_switch_field_2|workspace_switch_status_2"
  "workspace_switch_3|Switch to workspace 3|on|configure_workspace_switch_3|detect_workspace_switch_3|uninstall_workspace_switch_3|Switch to workspace|workspace_behavior|configure_workspace_switch_field_3|workspace_switch_status_3"
  "workspace_switch_4|Switch to workspace 4|on|configure_workspace_switch_4|detect_workspace_switch_4|uninstall_workspace_switch_4|Switch to workspace|workspace_behavior|configure_workspace_switch_field_4|workspace_switch_status_4"
  "workspace_switch_5|Switch to workspace 5|on|configure_workspace_switch_5|detect_workspace_switch_5|uninstall_workspace_switch_5|Switch to workspace|workspace_behavior|configure_workspace_switch_field_5|workspace_switch_status_5"
  "workspace_switch_6|Switch to workspace 6|on|configure_workspace_switch_6|detect_workspace_switch_6|uninstall_workspace_switch_6|Switch to workspace|workspace_behavior|configure_workspace_switch_field_6|workspace_switch_status_6"
  "workspace_switch_7|Switch to workspace 7|on|configure_workspace_switch_7|detect_workspace_switch_7|uninstall_workspace_switch_7|Switch to workspace|workspace_behavior|configure_workspace_switch_field_7|workspace_switch_status_7"
  "workspace_switch_8|Switch to workspace 8|on|configure_workspace_switch_8|detect_workspace_switch_8|uninstall_workspace_switch_8|Switch to workspace|workspace_behavior|configure_workspace_switch_field_8|workspace_switch_status_8"
  "workspace_switch_9|Switch to workspace 9|off|configure_workspace_switch_9|detect_workspace_switch_9|uninstall_workspace_switch_9|Switch to workspace|workspace_behavior|configure_workspace_switch_field_9|workspace_switch_status_9"
  "workspace_move_modifier|Move window modifier|on|configure_workspace_move_modifier|detect_workspace_move_modifier|uninstall_workspace_move_modifier|Move window to workspace|workspace_behavior|configure_workspace_move_modifier_field|workspace_move_modifier_status"
  "window_placement_tiling|Window placement tiling (Ctrl + mouse Back)|on|configure_window_placement_tiling_service|detect_window_placement_tiling|uninstall_window_placement_tiling|Window tools"
)

# hotkey_postflight - audit the applied keybindings and report any skipped
# root-only steps. Runs once after the selected components install.
hotkey_postflight() {
  audit_keybindings || true
  report_sudo_required || true
}
