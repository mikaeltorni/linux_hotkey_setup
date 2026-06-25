#!/usr/bin/env bash
# lifecycle.sh - Detection and uninstall functions for linux_hotkey_setup.
#
# detect_* report live state for --detect; uninstall_* reverse each component:
# reset keybindings, disable+remove bundled GNOME extensions, or disable+remove
# the ctrl-back tiler user service. Components that delegate to a sibling repo
# (automatic_window_tiling, hotkey_window_tools) delegate their uninstall too.

hs_ext_dir() { printf '%s\n' "$TARGET_HOME/.local/share/gnome-shell/extensions/$1"; }
hs_remove_extension() {
  local uuid="$1"
  run_as_target gnome-extensions disable "$uuid" 2>/dev/null || true
  run_as_target rm -rf "$(hs_ext_dir "$uuid")"
}
hs_delegate() {  # $1 repo dir name, $2.. = --uninstall ids
  local dir="$TARGET_HOME/projects/$1"
  if [ -f "$dir/install.sh" ]; then
    run_as_target bash "$dir/install.sh" "${@:2}" || true
  fi
}
hs_strv_is_single() {
  local actual="$1" expected="$2"
  [[ "${actual,,}" == "['${expected,,}']" ]]
}
hs_binding_matches() {
  local schema="$1" key="$2" expected="$3" actual
  actual="$(run_as_target gsettings get "$schema" "$key" 2>/dev/null || true)"
  hs_strv_is_single "$actual" "$expected"
}

# --- Detection ---------------------------------------------------------------
detect_screenshot() {
  hs_binding_matches org.gnome.shell.keybindings show-screenshot-ui "${SCREENSHOT_UI_BINDINGS[0]}" &&
    hs_binding_matches org.gnome.shell.keybindings screenshot "${SCREENSHOT_QUICK_BINDINGS[0]}"
}
detect_workspace_keys() {
  local entry idx binding
  for entry in "${WORKSPACE_SWITCH_BINDINGS[@]}"; do
    idx="${entry%%:*}"
    binding="${entry#*:}"
    hs_binding_matches org.gnome.desktop.wm.keybindings "switch-to-workspace-$idx" "$binding" || return 1
  done
  for entry in "${WORKSPACE_MOVE_BINDINGS[@]}"; do
    idx="${entry%%:*}"
    binding="${entry#*:}"
    hs_binding_matches org.gnome.desktop.wm.keybindings "move-to-workspace-$idx" "$binding" || return 1
  done
  return 0
}
detect_monitor_window_hotkeys() { [ -d "$(hs_ext_dir monitor-window-hotkeys@local)" ]; }
detect_automatic_window_tiling() { [ -d "$(hs_ext_dir automatic-window-tiling@local)" ]; }
detect_hotkey_window_tools()     { [ -d "$(hs_ext_dir window-move-resize@local)" ]; }
detect_ctrl_back_tiler() { [ -f "$TARGET_HOME/.config/systemd/user/ctrl-back-window-tiler.service" ]; }
detect_workspace_popup() { [ -d "$(hs_ext_dir workspace-number-indicator@local)" ]; }

# --- Uninstall ---------------------------------------------------------------
uninstall_screenshot() {
  msg "Removing screenshot custom shortcut"
  local path="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom-screenshot/"
  local current filtered
  current="$(run_as_target gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings 2>/dev/null || printf '[]')"
  filtered="$(RMP="$path" python3 - "$current" <<'PY'
import ast,os,sys
raw=sys.argv[1].strip() or "[]"
try:
  items=ast.literal_eval(raw); items=items if isinstance(items,list) else []
except Exception: items=[]
print("["+", ".join("'"+p+"'" for p in items if p!=os.environ["RMP"])+"]")
PY
)"
  run_as_target gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "$filtered" 2>/dev/null || true
  run_as_target gsettings reset org.gnome.settings-daemon.plugins.media-keys screenshot 2>/dev/null || true
  run_as_target gsettings reset org.gnome.settings-daemon.plugins.media-keys screenshot-clip 2>/dev/null || true
}
uninstall_workspace_keys() {
  msg "Resetting numbered workspace switch/move keys"
  local i
  for i in 1 2 3 4 5 6 7 8 9; do
    run_as_target gsettings reset org.gnome.desktop.wm.keybindings "switch-to-workspace-$i" 2>/dev/null || true
    run_as_target gsettings reset org.gnome.desktop.wm.keybindings "move-to-workspace-$i" 2>/dev/null || true
  done
}
uninstall_monitor_window_hotkeys() { msg "Removing monitor/window hotkeys extension"; hs_remove_extension monitor-window-hotkeys@local; }
uninstall_automatic_window_tiling() { msg "Uninstalling automatic window tiling (delegated)"; hs_delegate linux_automatic_window_tiling --uninstall keybinding,per_app_widths,portrait_stacking; }
uninstall_hotkey_window_tools()     { msg "Uninstalling pointer window tools (delegated)"; hs_delegate linux_hotkey_window_tools --uninstall move_hotkey,resize_hotkey; }
uninstall_ctrl_back_tiler() {
  msg "Removing Ctrl+Back window tiler service"
  run_as_target systemctl --user disable --now ctrl-back-window-tiler.service 2>/dev/null || true
  run_as_target rm -f "$TARGET_HOME/.config/systemd/user/ctrl-back-window-tiler.service"
  run_as_target systemctl --user daemon-reload 2>/dev/null || true
}
uninstall_workspace_popup() { msg "Removing numbered workspace popup extension"; hs_remove_extension workspace-number-indicator@local; hs_remove_extension workspace-number-popup@local; }
