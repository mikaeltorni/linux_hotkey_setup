#!/usr/bin/env bash
# lifecycle.sh - Detection and uninstall functions for linux_hotkey_setup.
#
# detect_* report live state for --detect; uninstall_* reverse each component:
# reset keybindings, or disable+remove the window-placement-tiling user service
# (migrating away the legacy ctrl-back-window-tiler unit). The monitor/window
# movement + tiling extension now lives in the standalone
# linux_monitor_window_hotkeys repository.

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
# detect_workspace_behavior — Return success when the shared static workspace
# settings are active. Numbered accelerators are detected by their own rows.
detect_workspace_behavior() {
  [[ "$(run_as_target gsettings get org.gnome.mutter dynamic-workspaces 2>/dev/null)" == "false" ]] &&
    [[ "$(run_as_target gsettings get org.gnome.desktop.wm.preferences num-workspaces 2>/dev/null)" == "$WORKSPACE_COUNT" ]]
}
detect_workspace_keys() {
  local index binding
  for ((index = 1; index <= WORKSPACE_UI_COUNT; index++)); do
    binding="$(workspace_switch_accelerator "$index")"
    [[ -z "$binding" ]] && continue
    hs_binding_matches org.gnome.desktop.wm.keybindings "switch-to-workspace-$index" "$binding" || return 1
  done
  detect_workspace_move_modifier
}
detect_workspace_switch_binding() {
  local index="$1" expected
  expected="$(workspace_switch_accelerator "$index")"
  [[ -n "$expected" ]] || return 1
  hs_binding_matches org.gnome.desktop.wm.keybindings "switch-to-workspace-$index" "$expected"
}
detect_workspace_switch_1() { detect_workspace_switch_binding 1; }
detect_workspace_switch_2() { detect_workspace_switch_binding 2; }
detect_workspace_switch_3() { detect_workspace_switch_binding 3; }
detect_workspace_switch_4() { detect_workspace_switch_binding 4; }
detect_workspace_switch_5() { detect_workspace_switch_binding 5; }
detect_workspace_switch_6() { detect_workspace_switch_binding 6; }
detect_workspace_switch_7() { detect_workspace_switch_binding 7; }
detect_workspace_switch_8() { detect_workspace_switch_binding 8; }
detect_workspace_switch_9() { detect_workspace_switch_binding 9; }
detect_workspace_move_modifier() {
  local index expected
  for ((index = 1; index <= WORKSPACE_UI_COUNT; index++)); do
    expected="$(workspace_move_accelerator "$index")"
    [[ -z "$expected" ]] && continue
    hs_binding_matches org.gnome.desktop.wm.keybindings "move-to-workspace-$index" "$expected" || return 1
  done
  return 0
}
detect_window_placement_tiling() {
  [ -f "$TARGET_HOME/.config/systemd/user/window-placement-tiling.service" ] ||
    [ -f "$TARGET_HOME/.config/systemd/user/ctrl-back-window-tiler.service" ]
}

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
uninstall_workspace_behavior() {
  msg "Resetting static workspace behavior"
  run_as_target gsettings reset org.gnome.mutter dynamic-workspaces 2>/dev/null || true
  run_as_target gsettings reset org.gnome.desktop.wm.preferences num-workspaces 2>/dev/null || true
  local entry key
  for entry in "${SUPER_ARROW_MOVE_BINDINGS[@]}"; do
    key="${entry%%:*}"
    run_as_target gsettings reset org.gnome.desktop.wm.keybindings "$key" 2>/dev/null || true
  done
  run_as_target gsettings reset org.gnome.shell.keybindings toggle-overview 2>/dev/null || true
  run_as_target gsettings reset org.gnome.shell.keybindings toggle-application-view 2>/dev/null || true
  run_as_target gsettings reset org.gnome.shell.keybindings toggle-quick-settings 2>/dev/null || true
  run_as_target gsettings reset org.gnome.mutter overlay-key 2>/dev/null || true
  run_as_target gsettings reset org.gnome.desktop.interface enable-animations 2>/dev/null || true
  run_as_target gsettings reset org.gnome.mutter workspaces-only-on-primary 2>/dev/null || true
  run_as_target gsettings reset org.gnome.shell.app-switcher current-workspace-only 2>/dev/null || true
  run_as_target gsettings reset org.gnome.shell.window-switcher current-workspace-only 2>/dev/null || true
}
# uninstall_workspace_switch_binding INDEX — Reset one switch and its derived
# move binding without changing any sibling workspace accelerator.
uninstall_workspace_switch_binding() {
  local index="$1"
  msg "Resetting workspace switch/move binding $index"
  run_as_target gsettings reset org.gnome.desktop.wm.keybindings "switch-to-workspace-${index}" 2>/dev/null || true
  run_as_target gsettings reset org.gnome.desktop.wm.keybindings "move-to-workspace-${index}" 2>/dev/null || true
}
uninstall_workspace_switch_1() { uninstall_workspace_switch_binding 1; }
uninstall_workspace_switch_2() { uninstall_workspace_switch_binding 2; }
uninstall_workspace_switch_3() { uninstall_workspace_switch_binding 3; }
uninstall_workspace_switch_4() { uninstall_workspace_switch_binding 4; }
uninstall_workspace_switch_5() { uninstall_workspace_switch_binding 5; }
uninstall_workspace_switch_6() { uninstall_workspace_switch_binding 6; }
uninstall_workspace_switch_7() { uninstall_workspace_switch_binding 7; }
uninstall_workspace_switch_8() { uninstall_workspace_switch_binding 8; }
uninstall_workspace_switch_9() { uninstall_workspace_switch_binding 9; }
uninstall_workspace_move_modifier() {
  msg "Resetting all derived workspace move bindings"
  local index
  for ((index = 1; index <= WORKSPACE_UI_COUNT; index++)); do
    run_as_target gsettings reset org.gnome.desktop.wm.keybindings "move-to-workspace-${index}" 2>/dev/null || true
  done
}
uninstall_window_placement_tiling() {
  msg "Removing window placement tiling service"
  local unit
  for unit in window-placement-tiling.service ctrl-back-window-tiler.service; do
    run_as_target systemctl --user disable --now "$unit" 2>/dev/null || true
    run_as_target rm -f "$TARGET_HOME/.config/systemd/user/$unit"
  done
  run_as_target systemctl --user daemon-reload 2>/dev/null || true
  run_as_target rm -f \
    "$TARGET_HOME/.local/bin/lhs-tools" \
    "$TARGET_HOME/.local/bin/ctrl_back_tile_right.py" \
    "$TARGET_HOME/.local/bin/hotkey_logging_utils.py"
}
