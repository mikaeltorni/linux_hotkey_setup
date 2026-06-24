#!/usr/bin/env bash
# components.sh - Component manifest for linux_hotkey_setup.
#
# Maps each selectable hotkey component to the function (defined in lib/) that
# applies it. install.sh sources lib/hotkeys_setup.sh first, then this manifest,
# then routes execution through component_main from component_runtime.sh.
#
# Entry format: "id|label|default(on/off)|function".

ISC_REPO_NAME="linux_hotkey_setup"
ISC_REPO_LABEL="GNOME hotkeys and window tools"

# Device selection for the Ctrl+Back tiler now lives inside that component
# (configure_ctrl_back_window_tiler_service) so it only runs when the tiler is
# selected and never prompts a user who deselected it. The post-install audit +
# sudo summary still run once after the selected components.
ISC_POSTFLIGHT="hotkey_postflight"

ISC_COMPONENTS=(
  "screenshot|Screenshot shortcuts|on|configure_screenshot_binding"
  "workspace_keys|Numbered workspace switch/move keys|on|configure_workspace_keys"
  "albert|Albert launcher bindings|on|configure_albert_keybindings"
  "monitor_window_hotkeys|Monitor/window movement hotkeys extension|on|configure_monitor_window_hotkeys_extension"
  "automatic_window_tiling|Automatic same-app window tiling (<Super>t)|on|configure_automatic_window_tiling"
  "hotkey_window_tools|Pointer-driven window move/resize hotkeys|on|configure_hotkey_window_tools"
  "ctrl_back_tiler|Ctrl+Back window tiler service|on|configure_ctrl_back_window_tiler_service"
  "workspace_popup|Numbered workspace popup extension|on|configure_workspace_number_popup_extension"
  "primary_paste_block|Block middle-click primary paste|on|lock_primary_paste"
)

# hotkey_postflight - audit the applied keybindings and report any skipped
# root-only steps. Runs once after the selected components install.
hotkey_postflight() {
  audit_keybindings || true
  report_sudo_required || true
}
