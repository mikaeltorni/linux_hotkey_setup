#!/usr/bin/env bash
# hotkeys_setup.sh — Ubuntu GNOME hotkey setup helpers.
#
# Components:
#   - configure_screenshot_binding(): Bind screenshot and screen recording keys.
#   - configure_workspace_keys(): Bind numbered workspace switching/moving keys.
#   - configure_albert_keybindings(): Bind Albert launcher shortcuts.
#   - configure_monitor_window_hotkeys_extension(): Install monitor/window GNOME Shell hotkeys.
#   - configure_workspace_number_popup_extension(): Install numbered workspace popup extension.
#   - select_input_device(): Select a pointing device for Ctrl+Back tiling.
#   - configure_ctrl_back_window_tiler_service(): Install Ctrl+Back window tiler service.
#   - lock_primary_paste(): Configure xmousepasteblock when available.
#
# Usage:
#   source lib/hotkeys_setup.sh
#   configure_screenshot_binding
#   configure_workspace_keys
#
# The caller must set TARGET_USER, TARGET_HOME, SCRIPT_DIR, CONFIG_DIR,
# RUNTIME_DIR, DISPLAY_VAL, and USER_BUS before sourcing this file.

: "${TARGET_USER:=${SUDO_USER:-$USER}}"
: "${TARGET_HOME:=$(getent passwd "$TARGET_USER" | cut -d: -f6)}"
HOTKEYS_SETUP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOTKEYS_SETUP_DIR="$(cd "$HOTKEYS_SETUP_LIB_DIR/.." && pwd)"
HOTKEYS_SETUP_CONFIG_DIR="$HOTKEYS_SETUP_DIR/configs"
: "${SCRIPT_DIR:=$HOTKEYS_SETUP_DIR}"
: "${CONFIG_DIR:=$HOTKEYS_SETUP_CONFIG_DIR}"
: "${RUNTIME_DIR:=/run/user/$(id -u "$TARGET_USER")}"
: "${DISPLAY_VAL:=${DISPLAY:-:0}}"
: "${USER_BUS:=unix:path=${RUNTIME_DIR}/bus}"
: "${SESSION_TYPE:=${XDG_SESSION_TYPE:-unknown}}"
: "${APT_UPDATED:=0}"
: "${WORKSPACE_COUNT:=8}"
: "${MONITOR_WINDOW_HOTKEYS_EXTENSION_ID:=monitor-window-hotkeys@local}"
: "${MONITOR_WINDOW_HOTKEYS_SOURCE_DIR:=$HOTKEYS_SETUP_CONFIG_DIR/gnome-shell/extensions/$MONITOR_WINDOW_HOTKEYS_EXTENSION_ID}"

SCREENSHOT_UI_BINDINGS=("${SCREENSHOT_UI_BINDINGS[@]:-<Shift><Super>s}")
SCREENSHOT_QUICK_BINDINGS=("${SCREENSHOT_QUICK_BINDINGS[@]:-Print}")
SCREEN_RECORDING_BINDINGS=("${SCREEN_RECORDING_BINDINGS[@]:-<Shift><Super>r}")
OVERVIEW_BINDINGS=("${OVERVIEW_BINDINGS[@]:-<Super>Tab}")
WORKSPACE_SWITCH_BINDINGS=("${WORKSPACE_SWITCH_BINDINGS[@]:-1:<Super>Z}" "${WORKSPACE_SWITCH_BINDINGS[@]:1}")
WORKSPACE_MOVE_BINDINGS=("${WORKSPACE_MOVE_BINDINGS[@]:-1:<Super><Shift>z}" "${WORKSPACE_MOVE_BINDINGS[@]:1}")
SUPER_ARROW_MOVE_BINDINGS=("${SUPER_ARROW_MOVE_BINDINGS[@]:-move-to-workspace-left:<Super><Shift>Left}" "${SUPER_ARROW_MOVE_BINDINGS[@]:1}")

if [ "${#WORKSPACE_SWITCH_BINDINGS[@]}" -eq 1 ]; then
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
fi

if [ "${#WORKSPACE_MOVE_BINDINGS[@]}" -eq 1 ]; then
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
fi

if [ "${#SUPER_ARROW_MOVE_BINDINGS[@]}" -eq 1 ]; then
  SUPER_ARROW_MOVE_BINDINGS=(
    "move-to-workspace-left:<Super><Shift>Left"
    "move-to-workspace-right:<Super><Shift>Right"
    "move-to-workspace-down:<Super><Shift>Down"
    "move-to-workspace-up:<Super><Shift>Up"
  )
fi

msg() {
  printf '\n==> %s\n' "$*"
}

log() {
  printf '[%s] %s\n' "$1" "$2" >&2
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

run_as_target() {
  sudo -H -u "$TARGET_USER" env \
    HOME="$TARGET_HOME" \
    USER="$TARGET_USER" \
    LOGNAME="$TARGET_USER" \
    XDG_RUNTIME_DIR="$RUNTIME_DIR" \
    DBUS_SESSION_BUS_ADDRESS="$USER_BUS" \
    DISPLAY="$DISPLAY_VAL" \
    "$@"
}

apt_update_once() {
  if [ "$APT_UPDATED" -eq 0 ]; then
    msg "Updating apt cache"
    apt update -y
    APT_UPDATED=1
  fi
}

apt_install() {
  apt_update_once
  DEBIAN_FRONTEND=noninteractive apt install -y "$@"
}

reload_systemd_daemon() {
  run_as_target systemctl --user daemon-reload || true
}

enable_systemd_service() {
  local service_name="$1"
  run_as_target systemctl --user daemon-reload || true
  run_as_target systemctl --user enable "$service_name" || true
  run_as_target systemctl --user start "$service_name" || true
}

user_gsettings() {
  run_as_target gsettings "$@"
}

gsettings_key_exists() {
  local schema="$1" key="$2"
  run_as_target gsettings list-keys "$schema" 2>/dev/null | grep -qx "$key"
}

join_as_gsettings_array() {
  local out="[" sep="" value escaped
  for value in "$@"; do
    [ -n "$value" ] || continue
    escaped="${value//\\/\\\\}"
    escaped="${escaped//\'/\\\'}"
    out+="${sep}'${escaped}'"
    sep=", "
  done
  out+="]"
  printf '%s\n' "$out"
}

set_gsettings_strv() {
  local schema="$1" key="$2"
  shift 2
  user_gsettings set "$schema" "$key" "$(join_as_gsettings_array "$@")"
}

set_gsettings_strv_if_key_exists() {
  local schema="$1" key="$2"
  shift 2
  if gsettings_key_exists "$schema" "$key"; then
    set_gsettings_strv "$schema" "$key" "$@"
  fi
}

append_gsettings_list() {
  local schema="$1" key="$2" value="$3"
  run_as_target env SCHEMA="$schema" KEY="$key" VALUE="$value" python3 - <<'PY'
import ast
import os
import subprocess
import sys

schema = os.environ["SCHEMA"]
key = os.environ["KEY"]
value = os.environ["VALUE"]
current = subprocess.run(
    ["gsettings", "get", schema, key],
    text=True,
    capture_output=True,
    check=False,
).stdout.strip()
if current.startswith("@as "):
    current = current[4:].strip()
try:
    values = ast.literal_eval(current) if current else []
except Exception:
    values = []
if value not in values:
    values.append(value)
new_value = "[" + ", ".join(repr(v) for v in values) + "]"
result = subprocess.run(["gsettings", "set", schema, key, new_value], check=False)
sys.exit(result.returncode)
PY
}

remove_gsettings_list() {
  local schema="$1" key="$2" value="$3"
  run_as_target env SCHEMA="$schema" KEY="$key" VALUE="$value" python3 - <<'PY'
import ast
import os
import subprocess
import sys

schema = os.environ["SCHEMA"]
key = os.environ["KEY"]
value = os.environ["VALUE"]
current = subprocess.run(
    ["gsettings", "get", schema, key],
    text=True,
    capture_output=True,
    check=False,
).stdout.strip()
if current.startswith("@as "):
    current = current[4:].strip()
try:
    values = ast.literal_eval(current) if current else []
except Exception:
    values = []
values = [item for item in values if item != value]
new_value = "[" + ", ".join(repr(v) for v in values) + "]"
result = subprocess.run(["gsettings", "set", schema, key, new_value], check=False)
sys.exit(result.returncode)
PY
}

set_indexed_keybinding_map() {
  local schema="$1" key_prefix="$2"
  shift 2
  local entry idx binding
  for entry in "$@"; do
    idx="${entry%%:*}"
    binding="${entry##*:}"
    set_gsettings_strv "$schema" "${key_prefix}${idx}" "$binding"
  done
}

enable_shell_extension() {
  local ext_id="$1"
  append_gsettings_list org.gnome.shell enabled-extensions "$ext_id"
}

update_custom_keybindings() {
  local path="$1"
  append_gsettings_list org.gnome.settings-daemon.plugins.media-keys custom-keybindings "$path"
}

configure_screenshot_binding() {
  msg "Binding Shift+Super+S to screenshot UI and Print to quick screenshot"
  local old_custom_screenshot_path="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom-screenshot/"

  set_gsettings_strv_if_key_exists org.gnome.shell.keybindings show-screenshot-ui "${SCREENSHOT_UI_BINDINGS[@]}"
  set_gsettings_strv_if_key_exists org.gnome.shell.keybindings screenshot "${SCREENSHOT_QUICK_BINDINGS[@]}"
  set_gsettings_strv_if_key_exists org.gnome.shell.keybindings show-screen-recording-ui "${SCREEN_RECORDING_BINDINGS[@]}"
  set_gsettings_strv_if_key_exists org.gnome.settings-daemon.plugins.media-keys screenshot "${SCREENSHOT_QUICK_BINDINGS[@]}"
  set_gsettings_strv_if_key_exists org.gnome.settings-daemon.plugins.media-keys screenshot-clip "${SCREENSHOT_QUICK_BINDINGS[@]}"

  remove_gsettings_list org.gnome.settings-daemon.plugins.media-keys custom-keybindings "$old_custom_screenshot_path"
  user_gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:"$old_custom_screenshot_path" binding "''" || true
}

configure_workspace_keys() {
  msg "Applying workspace and UI keybindings"
  user_gsettings set org.gnome.mutter dynamic-workspaces false
  user_gsettings set org.gnome.desktop.wm.preferences num-workspaces "$WORKSPACE_COUNT"
  set_indexed_keybinding_map org.gnome.desktop.wm.keybindings switch-to-workspace- "${WORKSPACE_SWITCH_BINDINGS[@]}"
  set_indexed_keybinding_map org.gnome.desktop.wm.keybindings move-to-workspace- "${WORKSPACE_MOVE_BINDINGS[@]}"

  local entry key binding
  for entry in "${SUPER_ARROW_MOVE_BINDINGS[@]}"; do
    key="${entry%%:*}"
    binding="${entry##*:}"
    set_gsettings_strv org.gnome.desktop.wm.keybindings "$key" "$binding"
  done

  set_gsettings_strv org.gnome.shell.keybindings toggle-overview "${OVERVIEW_BINDINGS[@]}"
  set_gsettings_strv org.gnome.shell.keybindings toggle-application-view
  set_gsettings_strv org.gnome.shell.keybindings toggle-quick-settings
  user_gsettings set org.gnome.mutter overlay-key ''
  user_gsettings set org.gnome.desktop.interface enable-animations false
  user_gsettings set org.gnome.mutter workspaces-only-on-primary false
  user_gsettings set org.gnome.shell.app-switcher current-workspace-only true
  user_gsettings set org.gnome.shell.window-switcher current-workspace-only true
}

configure_albert_keybindings() {
  msg "Configuring Albert launcher keybindings"
  local path_aring="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/albert-aring/"
  update_custom_keybindings "$path_aring"
  user_gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:"$path_aring" name "'Albert Toggle (Å)'"
  user_gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:"$path_aring" command "'albert toggle'"
  user_gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:"$path_aring" binding "'aring'"
}

audit_keybindings() {
  msg "Audit: grep selected keybindings"
  run_as_target bash -lc "gsettings list-recursively | grep -E '<Super>Tab|switch-group|switch-applications' || true"
  run_as_target bash -lc "gsettings list-recursively | grep '<Super>s' || true"
}

configure_monitor_window_hotkeys_extension() {
  msg "Installing local GNOME Shell monitor/window hotkeys"

  if [[ "$SESSION_TYPE" =~ ^(x11|xorg)$ ]]; then
    msg "X11 session detected; skipping monitor/window hotkeys extension."
    return 0
  fi

  local ext_id="$MONITOR_WINDOW_HOTKEYS_EXTENSION_ID"
  local source_dir="$MONITOR_WINDOW_HOTKEYS_SOURCE_DIR"
  local ext_dir="$TARGET_HOME/.local/share/gnome-shell/extensions/$ext_id"

  if [ ! -d "$source_dir" ]; then
    msg "Monitor/window hotkeys source not found at $source_dir; skipping."
    return 0
  fi

  install -d -o "$TARGET_USER" -g "$TARGET_USER" "$ext_dir"
  cp -a "$source_dir/." "$ext_dir/"
  chown -R "$TARGET_USER:$TARGET_USER" "$ext_dir"
  run_as_target chmod +x "$ext_dir/apply-system-bindings.sh"

  if ! need_cmd glib-compile-schemas; then
    apt_install libglib2.0-bin
  fi
  glib-compile-schemas "$ext_dir/schemas"

  if ! run_as_target "$ext_dir/apply-system-bindings.sh"; then
    echo "WARNING: monitor-window-hotkeys apply-system-bindings.sh failed; log out and back in, then re-run installer or apply-system-bindings.sh"
    return 0
  fi

  enable_shell_extension "$ext_id"
  msg "Monitor/window hotkeys extension installed. Log out and back in before testing GNOME Shell extension changes."
}

configure_workspace_number_popup_extension() {
  msg "Installing local GNOME Shell numbered workspace popup"

  if [[ "$SESSION_TYPE" =~ ^(x11|xorg)$ ]]; then
    msg "X11 session detected; skipping numbered workspace popup extension."
    return 0
  fi

  local ext_id="workspace-number-indicator@local"
  local ext_dir="$TARGET_HOME/.local/share/gnome-shell/extensions/$ext_id"
  local old_ext_id="workspace-number-popup@local"

  if run_as_target grep -qs '"name": "Numbered Workspace Popup"' "$TARGET_HOME/.local/share/gnome-shell/extensions/$old_ext_id/metadata.json"; then
    remove_gsettings_list org.gnome.shell enabled-extensions "$old_ext_id"
    run_as_target rm -rf "$TARGET_HOME/.local/share/gnome-shell/extensions/$old_ext_id"
  fi

  run_as_target mkdir -p "$ext_dir"
  run_as_target tee "$ext_dir/metadata.json" >/dev/null <<'EOF'
{
  "uuid": "workspace-number-indicator@local",
  "name": "Numbered Workspace Popup",
  "description": "Show workspace numbers in the workspace switcher popup",
  "shell-version": ["45", "46", "47", "48", "49", "50"],
  "version": 5
}
EOF

  run_as_target tee "$ext_dir/extension.js" >/dev/null <<'EOF'
import Clutter from 'gi://Clutter';
import St from 'gi://St';

import { Extension } from 'resource:///org/gnome/shell/extensions/extension.js';
import * as WorkspaceSwitcherPopup from 'resource:///org/gnome/shell/ui/workspaceSwitcherPopup.js';

export default class NumberedWorkspacePopupExtension extends Extension {
  enable() {
    const popupProto = WorkspaceSwitcherPopup.MonitorWorkspaceSwitcherPopup?.prototype
      ?? WorkspaceSwitcherPopup.WorkspaceSwitcherPopup?.prototype;
    const redisplayMethodName = popupProto?.redisplay
      ? 'redisplay'
      : popupProto?._redisplay
        ? '_redisplay'
        : null;

    if (!popupProto || !redisplayMethodName) {
      console.warn('Numbered Workspace Popup: unsupported GNOME Shell workspace switcher API');
      return;
    }

    this._popupProto = popupProto;
    this._redisplayMethodName = redisplayMethodName;
    this._originalRedisplay = popupProto[redisplayMethodName];

    popupProto[redisplayMethodName] = function(activeWorkspaceIndex = null) {
      const workspaceManager = global.workspace_manager;
      const activeIndex = Number.isInteger(activeWorkspaceIndex)
        ? activeWorkspaceIndex
        : this._activeWorkspaceIndex;
      this._list.destroy_all_children();

      for (let i = 0; i < workspaceManager.n_workspaces; i++) {
        const label = new St.Label({
          style_class: 'workspace-number-popup-label',
          text: `${i + 1}`,
        });

        const indicator = new St.Bin({
          style_class: 'ws-switcher-indicator workspace-number-popup-indicator',
          child: label,
          x_align: Clutter.ActorAlign.CENTER,
          y_align: Clutter.ActorAlign.CENTER,
        });

        if (i === activeIndex) {
          indicator.add_style_pseudo_class('active');
        }

        this._list.add_child(indicator);
      }
    };
  }

  disable() {
    if (this._originalRedisplay && this._popupProto && this._redisplayMethodName) {
      this._popupProto[this._redisplayMethodName] = this._originalRedisplay;
      this._originalRedisplay = null;
      this._redisplayMethodName = null;
      this._popupProto = null;
    }
  }
}
EOF

  run_as_target tee "$ext_dir/stylesheet.css" >/dev/null <<'EOF'
.workspace-switcher {
  spacing: 3px;
}

.workspace-number-popup-indicator {
  min-width: 44px;
  min-height: 32px;
  margin: 2px 0;
  padding: 0;
  border-radius: 5px;
  border: 1px solid rgba(238, 238, 236, 0.22);
  background-color: rgba(238, 238, 236, 0.16);
}

.workspace-number-popup-indicator:active {
  margin: 2px 0;
  padding: 0;
  border-color: rgba(238, 238, 236, 0.95);
  background-color: #eeeeec;
}

.workspace-number-popup-label {
  font-size: 14px;
  font-weight: 700;
  text-align: center;
  color: rgba(255, 255, 255, 0.82);
}

.workspace-number-popup-indicator:active .workspace-number-popup-label {
  color: #2e3436;
}
EOF

  enable_shell_extension "$ext_id"
}

select_input_device() {
  msg "Detecting pointing devices with back buttons"
  local device_list
  device_list="$(python3 -c '
from evdev import InputDevice, ecodes, list_devices
BACK_CODES = {ecodes.KEY_BACK, ecodes.BTN_SIDE, ecodes.BTN_EXTRA}
POINTER_RELS = {ecodes.REL_X, ecodes.REL_Y}
devices = []
for path in sorted(list_devices()):
    try:
        dev = InputDevice(path)
    except OSError:
        continue
    caps = dev.capabilities(absinfo=False)
    keys = set(caps.get(ecodes.EV_KEY, []))
    rels = set(caps.get(ecodes.EV_REL, []))
    if not (rels & POINTER_RELS) or not (keys & BACK_CODES):
        dev.close()
        continue
    if "Keychron" in dev.name or "ctrl-back-window-tiler" in dev.name:
        dev.close()
        continue
    devices.append((dev.path, dev.name))
    dev.close()
for path, name in devices:
    print(f"{path}|{name}")
' 2>/dev/null)"
  if [ -z "$device_list" ]; then
    msg "No pointing devices with back buttons detected; tiler service will be skipped."
    return 1
  fi
  if [ ! -t 0 ]; then
    local default_selected
    default_selected="$(echo "$device_list" | head -1)"
    SELECTED_INPUT_DEVICE="${default_selected%%|*}"
    SELECTED_INPUT_DEVICE_NAME="${default_selected##*|}"
    msg "Non-interactive mode detected; auto-selecting: $SELECTED_INPUT_DEVICE_NAME ($SELECTED_INPUT_DEVICE)"
    return 0
  fi

  local idx=0
  while IFS='|' read -r path name; do
    printf '  [%d] %s (%s)\n' "$idx" "$name" "$path"
    idx=$((idx + 1))
  done <<< "$device_list"
  printf '\nSelect your primary pointing device (0-%d):\n' "$((idx - 1))"
  read -r -p "> " selection
  if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -lt "$idx" ]; then
    local selected
    selected="$(echo "$device_list" | sed -n "$((selection + 1))p")"
    SELECTED_INPUT_DEVICE="${selected%%|*}"
    SELECTED_INPUT_DEVICE_NAME="${selected##*|}"
    msg "Selected: $SELECTED_INPUT_DEVICE_NAME ($SELECTED_INPUT_DEVICE)"
    return 0
  fi
  local fallback_selected
  fallback_selected="$(echo "$device_list" | head -1)"
  SELECTED_INPUT_DEVICE="${fallback_selected%%|*}"
  SELECTED_INPUT_DEVICE_NAME="${fallback_selected##*|}"
  msg "No valid selection; using first detected: $SELECTED_INPUT_DEVICE_NAME"
}

configure_ctrl_back_window_tiler_service() {
  msg "Installing Ctrl + browser-back window tiler service"
  local script_source="$HOTKEYS_SETUP_CONFIG_DIR/window-hotkeys/ctrl_back_tile_right.py"
  local service_source="$HOTKEYS_SETUP_CONFIG_DIR/window-hotkeys/ctrl-back-window-tiler.service"
  local script_target="$TARGET_HOME/.local/bin/ctrl_back_tile_right.py"
  local service_target="$TARGET_HOME/.config/systemd/user/ctrl-back-window-tiler.service"
  if [ ! -f "$script_source" ] || [ ! -f "$service_source" ]; then
    msg "Ctrl-back tiler service source files missing; skipping."
    return 0
  fi

  local device_filter="${SELECTED_INPUT_DEVICE:-}"
  run_as_target mkdir -p "$(dirname "$service_target")"
  install -D -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$script_source" "$script_target"
  run_as_target tee "$service_target" >/dev/null <<EOF
[Unit]
Description=Ctrl + browser-back window right-half tiler
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=simple
ExecStart=$script_target
Restart=on-failure
RestartSec=2
Environment=CTRL_BACK_TILE_DEVICE=${device_filter:-}

[Install]
WantedBy=default.target
EOF
  reload_systemd_daemon
  enable_systemd_service ctrl-back-window-tiler.service
}

build_xmousepasteblock() {
  local bin_path="$TARGET_HOME/.local/bin/xmousepasteblock"
  [ -x "$bin_path" ]
}

configure_xmousepasteblock_service() {
  msg "Configuring xmousepasteblock systemd user service"
  local bin_path="$TARGET_HOME/.local/bin/xmousepasteblock"
  local service_file="$TARGET_HOME/.config/systemd/user/xmousepasteblock.service"

  if [ ! -f "$bin_path" ]; then
    log "info" "xmousepasteblock binary not found at $bin_path; skipping service setup."
    return 0
  fi

  run_as_target mkdir -p "$(dirname "$service_file")"
  run_as_target tee "$service_file" >/dev/null <<EOF
[Unit]
Description=xmousepasteblock - lock primary clipboard selection
After=graphical-session.target

[Service]
Type=simple
ExecStart=$bin_path
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
  reload_systemd_daemon
  enable_systemd_service xmousepasteblock.service
  run_as_target systemctl --user start xmousepasteblock.service || true
}

lock_primary_paste() {
  msg "Configuring primary clipboard lock (xmousepasteblock)"
  if build_xmousepasteblock; then
    configure_xmousepasteblock_service || true
  else
    log "info" "xmousepasteblock is unavailable; primary clipboard lock service skipped."
  fi
}

configure_ubuntu_hotkeys() {
  msg "Applying Ubuntu hotkey setup"
  select_input_device || true
  configure_screenshot_binding
  configure_workspace_keys
  configure_albert_keybindings
  audit_keybindings
  configure_monitor_window_hotkeys_extension
  configure_ctrl_back_window_tiler_service
  configure_workspace_number_popup_extension
  lock_primary_paste
}
