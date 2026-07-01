#!/usr/bin/env bash
# lifecycle.sh - Detection and uninstall functions for linux_hotkey_setup.
#
# detect_* report live state for --detect; uninstall_* reverse each component:
# reset keybindings, disable+remove the bundled monitor/window GNOME extension,
# or disable+remove the window-placement-tiling user service (migrating away the
# legacy ctrl-back-window-tiler unit).

hs_ext_dir() { printf '%s\n' "$TARGET_HOME/.local/share/gnome-shell/extensions/$1"; }
hs_remove_extension() {
  local uuid="$1"
  run_as_target gnome-extensions disable "$uuid" 2>/dev/null || true
  run_as_target rm -rf "$(hs_ext_dir "$uuid")"
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
# detect_workspace_behavior — Return success when the shared static workspace
# settings are active. Numbered accelerators are detected by their own rows.
detect_workspace_behavior() {
  [[ "$(run_as_target gsettings get org.gnome.mutter dynamic-workspaces 2>/dev/null)" == "false" ]] &&
    [[ "$(run_as_target gsettings get org.gnome.desktop.wm.preferences num-workspaces 2>/dev/null)" == "$WORKSPACE_COUNT" ]]
}
# detect_workspace_binding ACTION INDEX — Return success when the requested
# numbered switch/move key has any assigned accelerator, including a custom one.
detect_workspace_binding() {
  local action="$1" index="$2" key_prefix actual
  case "$action" in
    switch) key_prefix=switch-to-workspace- ;;
    move) key_prefix=move-to-workspace- ;;
    *) return 2 ;;
  esac
  actual="$(run_as_target gsettings get org.gnome.desktop.wm.keybindings "${key_prefix}${index}" 2>/dev/null || true)"
  [[ "$actual" != "[]" && "$actual" != "@as []" && -n "$actual" ]]
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
detect_workspace_switch_1() { detect_workspace_binding switch 1; }
detect_workspace_switch_2() { detect_workspace_binding switch 2; }
detect_workspace_switch_3() { detect_workspace_binding switch 3; }
detect_workspace_switch_4() { detect_workspace_binding switch 4; }
detect_workspace_switch_5() { detect_workspace_binding switch 5; }
detect_workspace_switch_6() { detect_workspace_binding switch 6; }
detect_workspace_switch_7() { detect_workspace_binding switch 7; }
detect_workspace_switch_8() { detect_workspace_binding switch 8; }
detect_workspace_switch_9() { detect_workspace_binding switch 9; }
detect_workspace_move_1() { detect_workspace_binding move 1; }
detect_workspace_move_2() { detect_workspace_binding move 2; }
detect_workspace_move_3() { detect_workspace_binding move 3; }
detect_workspace_move_4() { detect_workspace_binding move 4; }
detect_workspace_move_5() { detect_workspace_binding move 5; }
detect_workspace_move_6() { detect_workspace_binding move 6; }
detect_workspace_move_7() { detect_workspace_binding move 7; }
detect_workspace_move_8() { detect_workspace_binding move 8; }
detect_workspace_move_9() { detect_workspace_binding move 9; }
detect_monitor_window_hotkeys() { [ -d "$(hs_ext_dir monitor-window-hotkeys@local)" ]; }
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
# uninstall_workspace_binding ACTION INDEX — Reset exactly one numbered
# switch/move binding without changing any sibling workspace accelerator.
uninstall_workspace_binding() {
  local action="$1" index="$2" key_prefix
  case "$action" in
    switch) key_prefix=switch-to-workspace- ;;
    move) key_prefix=move-to-workspace- ;;
    *) return 2 ;;
  esac
  msg "Resetting ${action} workspace binding $index"
  run_as_target gsettings reset org.gnome.desktop.wm.keybindings "${key_prefix}${index}" 2>/dev/null || true
}
uninstall_workspace_switch_1() { uninstall_workspace_binding switch 1; }
uninstall_workspace_switch_2() { uninstall_workspace_binding switch 2; }
uninstall_workspace_switch_3() { uninstall_workspace_binding switch 3; }
uninstall_workspace_switch_4() { uninstall_workspace_binding switch 4; }
uninstall_workspace_switch_5() { uninstall_workspace_binding switch 5; }
uninstall_workspace_switch_6() { uninstall_workspace_binding switch 6; }
uninstall_workspace_switch_7() { uninstall_workspace_binding switch 7; }
uninstall_workspace_switch_8() { uninstall_workspace_binding switch 8; }
uninstall_workspace_switch_9() { uninstall_workspace_binding switch 9; }
uninstall_workspace_move_1() { uninstall_workspace_binding move 1; }
uninstall_workspace_move_2() { uninstall_workspace_binding move 2; }
uninstall_workspace_move_3() { uninstall_workspace_binding move 3; }
uninstall_workspace_move_4() { uninstall_workspace_binding move 4; }
uninstall_workspace_move_5() { uninstall_workspace_binding move 5; }
uninstall_workspace_move_6() { uninstall_workspace_binding move 6; }
uninstall_workspace_move_7() { uninstall_workspace_binding move 7; }
uninstall_workspace_move_8() { uninstall_workspace_binding move 8; }
uninstall_workspace_move_9() { uninstall_workspace_binding move 9; }
uninstall_monitor_window_hotkeys() { msg "Removing monitor/window hotkeys extension"; hs_remove_extension monitor-window-hotkeys@local; }
uninstall_window_placement_tiling() {
  msg "Removing window placement tiling service"
  local unit
  for unit in window-placement-tiling.service ctrl-back-window-tiler.service; do
    run_as_target systemctl --user disable --now "$unit" 2>/dev/null || true
    run_as_target rm -f "$TARGET_HOME/.config/systemd/user/$unit"
  done
  run_as_target systemctl --user daemon-reload 2>/dev/null || true
}
