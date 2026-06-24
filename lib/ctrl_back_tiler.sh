#!/usr/bin/env bash
# ctrl_back_tiler.sh - Ctrl+Back device selection and service installation.
#
# The caller must provide TARGET_HOME, TARGET_USER, HOTKEYS_SETUP_CONFIG_DIR,
# and the installer helpers msg(), run_as_target(), is_root(),
# reload_systemd_daemon(), and enable_systemd_service().

# select_input_device — Detect pointing devices that expose a back button and
# choose one for the Ctrl+Back tiler. Prompts interactively; auto-selects the
# first device in non-interactive runs. Exports SELECTED_INPUT_DEVICE and
# SELECTED_INPUT_DEVICE_NAME. Takes no arguments. Returns non-zero when no
# eligible device is found so the caller can skip the tiler service.
select_input_device() {
  msg "Detecting pointing devices with back buttons"
  local device_list
  device_list="$(python3 -c '
from evdev import InputDevice, ecodes, list_devices
from pathlib import Path

BACK_CODES = {ecodes.KEY_BACK, ecodes.BTN_SIDE, ecodes.BTN_EXTRA}
POINTER_RELS = {ecodes.REL_X, ecodes.REL_Y}

def event_sort_key(path):
    suffix = path.rsplit("event", 1)[-1]
    return (0, int(suffix)) if suffix.isdigit() else (1, path)

def stable_device_path(path):
    resolved = Path(path).resolve()
    by_id = Path("/dev/input/by-id")
    if by_id.is_dir():
        aliases = [
            alias
            for alias in by_id.iterdir()
            if "event-mouse" in alias.name and alias.resolve() == resolved
        ]
        if aliases:
            return str(sorted(aliases)[0])
    return path

devices = []
for path in sorted(list_devices(), key=event_sort_key):
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
    devices.append((stable_device_path(dev.path), dev.name))
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

# configure_ctrl_back_window_tiler_service — Install the ctrl_back_tile_right.py
# service script, its centralized Python logger, and its systemd --user unit.
# Pins the unit to the device chosen by select_input_device (via
# CTRL_BACK_TILE_DEVICE), then enables and starts it. Skipped when the source
# files are missing. Takes no arguments; reads SELECTED_INPUT_DEVICE and
# HOTKEYS_SETUP_CONFIG_DIR.
configure_ctrl_back_window_tiler_service() {
  msg "Installing Ctrl + browser-back window tiler service"

  # Device selection belongs to this component alone: only prompt/detect when
  # the tiler is actually being installed, and only when a caller (or test)
  # hasn't already pinned SELECTED_INPUT_DEVICE. A missing device is a clean
  # skip, not an installer failure.
  if [[ -z "${SELECTED_INPUT_DEVICE:-}" ]]; then
    if ! select_input_device; then
      msg "No pointing device with a back button detected; skipping Ctrl+Back tiler service."
      return 0
    fi
  fi

  local script_source="$HOTKEYS_SETUP_CONFIG_DIR/window-hotkeys/ctrl_back_tile_right.py"
  local logging_source="$HOTKEYS_SETUP_CONFIG_DIR/window-hotkeys/hotkey_logging_utils.py"
  local service_source="$HOTKEYS_SETUP_CONFIG_DIR/window-hotkeys/ctrl-back-window-tiler.service"
  local script_target="$TARGET_HOME/.local/bin/ctrl_back_tile_right.py"
  local logging_target="$TARGET_HOME/.local/bin/hotkey_logging_utils.py"
  local service_target="$TARGET_HOME/.config/systemd/user/ctrl-back-window-tiler.service"
  if [ ! -f "$script_source" ] || [ ! -f "$logging_source" ] || [ ! -f "$service_source" ]; then
    msg "Ctrl-back tiler service source files missing; skipping."
    return 0
  fi

  local device_filter="${SELECTED_INPUT_DEVICE:-}"
  run_as_target mkdir -p "$(dirname "$service_target")"
  if is_root; then
    install -D -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$script_source" "$script_target"
    install -D -m 0644 -o "$TARGET_USER" -g "$TARGET_USER" "$logging_source" "$logging_target"
  else
    install -D -m 0755 "$script_source" "$script_target"
    install -D -m 0644 "$logging_source" "$logging_target"
  fi
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
