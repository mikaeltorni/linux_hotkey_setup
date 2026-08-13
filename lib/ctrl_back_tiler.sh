#!/usr/bin/env bash
# ctrl_back_tiler.sh - Window placement tiling: pointer device selection and
# service installation (formerly the "Ctrl+Back window tiler").
#
# The caller must provide TARGET_HOME, TARGET_USER, HOTKEYS_SETUP_CONFIG_DIR,
# the installer helpers msg(), run_as_target(), is_root(),
# reload_systemd_daemon(), and enable_systemd_service(), and the shared
# isc_capture_hotkey engine for the configurable trigger.

# select_input_device — Detect pointing devices that expose a back button and
# choose one for the Ctrl+Back tiler. Uses `lhs-tools list-pointers`. Prompts
# interactively; auto-selects the first device in non-interactive runs. Exports
# SELECTED_INPUT_DEVICE and SELECTED_INPUT_DEVICE_NAME. Takes no arguments.
# Returns non-zero when no eligible device is found so the caller can skip the
# tiler service.
select_input_device() {
  msg "Detecting pointing devices with back buttons"
  local device_list
  device_list="$(lhs_bin list-pointers 2>/dev/null || true)"
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

# Default modifier + mouse button that trigger window placement tiling.
WINDOW_PLACEMENT_TILING_MODIFIER_DEFAULT="Control"
WINDOW_PLACEMENT_TILING_BUTTON_DEFAULT="BTN_BACK"
WINDOW_PLACEMENT_TILING_SERVICE="window-placement-tiling.service"
WINDOW_PLACEMENT_TILING_LEGACY_SERVICE="ctrl-back-window-tiler.service"

# configure_window_placement_tiling_service — Install the window-placement
# tiling service (formerly the "Ctrl+Back window tiler"): a pointer-driven
# service that half-tiles the focused window when a configurable modifier is held
# and a configurable mouse button (Back/Forward) is pressed. The trigger is
# captured through the shared hotkey engine in mouse mode — press the modifier
# then the mouse Back/Forward button, or (when the mouse has no side buttons)
# the keyboard B/F stand-ins. Pins the unit to the device chosen by
# select_input_device and migrates any legacy ctrl-back-window-tiler unit.
# Deploys `lhs-tools` and starts `lhs-tools tiler`. Takes no arguments; reads
# SELECTED_INPUT_DEVICE.
configure_window_placement_tiling_service() {
  msg "Installing window placement tiling service"

  # Device selection belongs to this component alone: only prompt/detect when
  # the service is actually being installed, and only when a caller (or test)
  # hasn't already pinned SELECTED_INPUT_DEVICE. A missing device is a clean
  # skip, not an installer failure.
  if [[ -z "${SELECTED_INPUT_DEVICE:-}" ]]; then
    if ! select_input_device; then
      msg "No pointing device with a back button detected; skipping window placement tiling service."
      return 0
    fi
  fi

  # Capture the trigger (modifier + mouse Back/Forward) in mouse mode. The shared
  # engine returns "MOD[+MOD]|EVENT"; fall back to the Ctrl+Back default.
  local trigger modifier button
  trigger="$(isc_capture_hotkey WINDOW_PLACEMENT_TILING_TRIGGER \
    "${WINDOW_PLACEMENT_TILING_MODIFIER_DEFAULT}|${WINDOW_PLACEMENT_TILING_BUTTON_DEFAULT}" \
    "window placement tiling trigger" --mouse)"
  modifier="${trigger%%|*}"
  button="${trigger##*|}"
  [[ -z "$modifier" ]] && modifier="$WINDOW_PLACEMENT_TILING_MODIFIER_DEFAULT"
  [[ -z "$button" || "$button" == "$modifier" ]] && button="$WINDOW_PLACEMENT_TILING_BUTTON_DEFAULT"
  msg "Window placement tiling trigger: ${modifier} + ${button}"

  if ! ensure_lhs_bin; then
    msg "lhs-tools binary missing; skipping window placement tiling service."
    return 0
  fi
  local bin_source="$LHS_BIN"
  local bin_target="$TARGET_HOME/.local/bin/lhs-tools"
  local service_target="$TARGET_HOME/.config/systemd/user/$WINDOW_PLACEMENT_TILING_SERVICE"

  # Migrate any legacy ctrl-back-window-tiler unit to the renamed service.
  local legacy_target="$TARGET_HOME/.config/systemd/user/$WINDOW_PLACEMENT_TILING_LEGACY_SERVICE"
  if [ -f "$legacy_target" ]; then
    run_as_target systemctl --user disable --now "$WINDOW_PLACEMENT_TILING_LEGACY_SERVICE" 2>/dev/null || true
    run_as_target rm -f "$legacy_target"
  fi

  local device_filter="${SELECTED_INPUT_DEVICE:-}"
  run_as_target mkdir -p "$(dirname "$service_target")" "$(dirname "$bin_target")"
  if is_root; then
    install -D -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$bin_source" "$bin_target"
  else
    install -D -m 0755 "$bin_source" "$bin_target"
  fi
  run_as_target rm -f \
    "$TARGET_HOME/.local/bin/ctrl_back_tile_right.py" \
    "$TARGET_HOME/.local/bin/hotkey_logging_utils.py"
  run_as_target tee "$service_target" >/dev/null <<EOF
[Unit]
Description=Window placement tiling (modifier + mouse button half-tiler)
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=simple
ExecStart=$bin_target tiler
Restart=on-failure
RestartSec=2
Environment=CTRL_BACK_TILE_DEVICE=${device_filter:-}
Environment=WINDOW_PLACEMENT_TILE_MODIFIER=${modifier}
Environment=WINDOW_PLACEMENT_TILE_BUTTON=${button}

[Install]
WantedBy=default.target
EOF
  reload_systemd_daemon
  enable_systemd_service "$WINDOW_PLACEMENT_TILING_SERVICE"
}
