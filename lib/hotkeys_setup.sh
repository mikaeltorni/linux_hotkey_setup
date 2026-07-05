#!/usr/bin/env bash
# hotkeys_setup.sh — Ubuntu GNOME hotkey setup helpers.
#
# Components:
#   - configure_screenshot_binding(): Capture + bind the screenshot hotkey.
#   - configure_workspace_behavior(): Apply shared static-workspace behavior.
#   - configure_workspace_switch_N(): Apply one typed switch field + derived move.
#   - configure_workspace_move_modifier(): Rebuild moves from one modifier.
#   - select_input_device(): Select a pointing device for window placement tiling.
#   - configure_window_placement_tiling_service(): Install the window placement tiling service.
#
# Hotkey capture and typed fields come from the shared installer framework.
# Automatic window tiling, pointer move/resize, and the workspace popup live in
# their own repositories.
#
# Usage:
#   source lib/hotkeys_setup.sh
#   configure_screenshot_binding
#   configure_workspace_switch_1
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
# Nine numbered workspaces are offered in the capture UI (the 9th ships blank so
# the user can assign it). WORKSPACE_COUNT is the number of static workspaces
# created; WORKSPACE_UI_COUNT is how many rows the hotkey capture walks.
: "${WORKSPACE_COUNT:=9}"
: "${WORKSPACE_UI_COUNT:=9}"

SCREENSHOT_UI_BINDINGS=("${SCREENSHOT_UI_BINDINGS[@]:-<Shift><Super>s}")
SCREENSHOT_QUICK_BINDINGS=("${SCREENSHOT_QUICK_BINDINGS[@]:-Print}")
OVERVIEW_BINDINGS=("${OVERVIEW_BINDINGS[@]:-<Super>Tab}")
WORKSPACE_SWITCH_BINDINGS=("${WORKSPACE_SWITCH_BINDINGS[@]:-1:<Super>Z}" "${WORKSPACE_SWITCH_BINDINGS[@]:1}")
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

if [ "${#SUPER_ARROW_MOVE_BINDINGS[@]}" -eq 1 ]; then
  SUPER_ARROW_MOVE_BINDINGS=(
    "move-to-workspace-left:<Super><Shift>Left"
    "move-to-workspace-right:<Super><Shift>Right"
    "move-to-workspace-down:<Super><Shift>Down"
    "move-to-workspace-up:<Super><Shift>Up"
  )
fi

# The shared install-time helpers (msg, need_cmd, is_root, run_as_target, and the
# sudo-skip reporting) are provided by the framework's installer_helpers.sh,
# loaded by install.sh via isc_load_helpers before this file is sourced. Only the
# repo-specific log() format is kept here.

# log — Print a level-tagged diagnostic line to stderr.
# Args: $1 — log level label (e.g. info, warn); $2 — message text.
log() {
  printf '[%s] %s\n' "$1" "$2" >&2
}

# shellcheck source=gsettings_helpers.sh
source "$HOTKEYS_SETUP_LIB_DIR/gsettings_helpers.sh"
# shellcheck source=ctrl_back_tiler.sh
source "$HOTKEYS_SETUP_LIB_DIR/ctrl_back_tiler.sh"

# The interactive press-to-capture hotkey engine is provided by the shared
# framework (isc_capture_hotkey in hotkey_capture.sh, loaded by isc_load_helpers).
# When it is unavailable (e.g. a unit test that sources this library directly, or
# an older framework checkout), fall back to an environment override or the
# built-in default so nothing ever blocks. This keeps the configurable-hotkey
# feature shared, not hard-coded to this repo.
if ! declare -F isc_capture_hotkey >/dev/null 2>&1; then
  isc_capture_hotkey() {
    local env_var="$1" default_spec="$2"
    if [[ -n "$env_var" && -n "${!env_var:-}" ]]; then
      printf '%s\n' "${!env_var}"
    else
      printf '%s\n' "$default_spec"
    fi
  }
fi

# Typed fields live in the shared framework. Resolve the sibling helper for
# direct library users that did not enter through install.sh/isc_load_helpers.
if ! declare -F isc_hotkey_field_value >/dev/null 2>&1; then
  for _hotkey_field_helper in \
    "$HOTKEYS_SETUP_DIR/../linux_installation_scripts_functions/hotkey_capture.sh" \
    "${ISC_COMPONENT_LIB_DIR:-}/hotkey_capture.sh"; do
    if [[ -f "$_hotkey_field_helper" ]]; then
      # shellcheck source=/dev/null
      source "$_hotkey_field_helper"
      break
    fi
  done
  unset _hotkey_field_helper
fi

# shellcheck source=workspace_hotkey_fields.sh
source "$HOTKEYS_SETUP_LIB_DIR/workspace_hotkey_fields.sh"

# hotkey_wm_conflict_candidates — print "identifier<TAB>accelerator" lines for
# every GNOME keybinding currently set, so the capture UI can warn in real time
# which system default a chosen hotkey would unbind. Best-effort: prints nothing
# when gsettings is unavailable. Set as ISC_HOTKEY_CONFLICTS_FN before a capture.
hotkey_wm_conflict_candidates() {
  local schema
  for schema in org.gnome.desktop.wm.keybindings org.gnome.shell.keybindings \
                org.gnome.mutter.keybindings org.gnome.settings-daemon.plugins.media-keys; do
    run_as_target gsettings list-recursively "$schema" 2>/dev/null
  done | python3 - <<'PY' 2>/dev/null || true
import ast, sys
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line.strip():
        continue
    # "schema key ['<Accel>', ...]"
    try:
        schema, key, raw = line.split(" ", 2)
    except ValueError:
        continue
    try:
        values = ast.literal_eval(raw)
    except Exception:
        continue
    if not isinstance(values, list):
        continue
    for accel in values:
        if accel:
            print(f"{schema} {key}\t{accel}")
PY
}

# apt_update_once — Refresh the apt cache the first time only (idempotent across
# multiple apt_install calls in one run via the APT_UPDATED guard).
apt_update_once() {
  if [ "$APT_UPDATED" -eq 0 ]; then
    msg "Updating apt cache"
    apt update -y
    APT_UPDATED=1
  fi
}

# apt_install — Install any of the named packages that are not already present.
# Skips and records a sudo-required note when run without root.
# Args: $@ — apt package names to ensure are installed.
apt_install() {
  local missing=() pkg
  for pkg in "$@"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
  done
  [ "${#missing[@]}" -eq 0 ] && return 0
  if ! is_root; then
    note_sudo_required "apt install ${missing[*]}"
    return 0
  fi
  apt_update_once
  DEBIAN_FRONTEND=noninteractive apt install -y "${missing[@]}"
}

# reload_systemd_daemon — Reload the target user's systemd manager so newly
# written unit files are picked up. Failures are tolerated (|| true).
reload_systemd_daemon() {
  run_as_target systemctl --user daemon-reload || true
}

# enable_systemd_service — Reload, enable, and start a systemd --user unit for
# the target user. Each step tolerates failure so a missing session does not
# abort the installer.
# Args: $1 — service unit name (e.g. ctrl-back-window-tiler.service).
enable_systemd_service() {
  local service_name="$1"
  run_as_target systemctl --user daemon-reload || true
  run_as_target systemctl --user enable "$service_name" || true
  run_as_target systemctl --user start "$service_name" || true
}

# configure_screenshot_binding — Bind Shift+Super+S to the screenshot UI and
# Print to a quick screenshot, leave screen recording (Shift+Super+R) unbound so
# it cannot shadow move-to-workspace-8, and clear the legacy custom screenshot
# keybinding. Takes no arguments; reads the SCREENSHOT_*_BINDINGS arrays.
configure_screenshot_binding() {
  local old_custom_screenshot_path="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom-screenshot/"

  # The screenshot is a single hotkey. Show the default (Super+Shift+S) and let
  # the user press their own via the shared capture UI (Backspace removes the
  # last input). SCREENSHOT_HOTKEY overrides it non-interactively.
  local screenshot_accel
  ISC_HOTKEY_CONFLICTS_FN=hotkey_wm_conflict_candidates \
    screenshot_accel="$(isc_capture_hotkey SCREENSHOT_HOTKEY "${SCREENSHOT_UI_BINDINGS[0]:-<Shift><Super>s}" "screenshot")"
  SCREENSHOT_UI_BINDINGS=("$screenshot_accel")
  msg "Binding screenshot UI to $screenshot_accel and Print to quick screenshot"

  set_gsettings_strv_if_key_exists org.gnome.shell.keybindings show-screenshot-ui "${SCREENSHOT_UI_BINDINGS[@]}"
  set_gsettings_strv_if_key_exists org.gnome.shell.keybindings screenshot "${SCREENSHOT_QUICK_BINDINGS[@]}"
  # Leave screen recording (Shift+Super+R) unbound so it cannot shadow our
  # move-to-workspace-8 hotkey.
  set_gsettings_strv_if_key_exists org.gnome.shell.keybindings show-screen-recording-ui
  set_gsettings_strv_if_key_exists org.gnome.settings-daemon.plugins.media-keys screenshot "${SCREENSHOT_QUICK_BINDINGS[@]}"
  set_gsettings_strv_if_key_exists org.gnome.settings-daemon.plugins.media-keys screenshot-clip "${SCREENSHOT_QUICK_BINDINGS[@]}"

  remove_gsettings_list org.gnome.settings-daemon.plugins.media-keys custom-keybindings "$old_custom_screenshot_path"
  user_gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:"$old_custom_screenshot_path" binding "''" || true
}

# hotkey_default_for_index — look up the "index:binding" default for a workspace
# index in a bindings array, printing the binding (empty when none is defined,
# e.g. the intentionally-blank 9th workspace). Args: $1 index; $2.. entries.
hotkey_default_for_index() {
  local want="$1"; shift
  local entry
  for entry in "$@"; do
    [[ "${entry%%:*}" == "$want" ]] && { printf '%s' "${entry#*:}"; return 0; }
  done
  printf ''
}

# configure_workspace_behavior — Apply settings shared by all numbered
# workspace bindings without changing any numbered switch/move key. This is a
# separate component so each numbered key can be selected independently.
configure_workspace_behavior() {
  msg "Applying static workspace behavior and navigation keybindings"
  # Migrate the receipt from the former all-in-one component. The live
  # per-action detectors preserve installed state while removing stale metadata.
  if declare -F _isc_clear_receipt >/dev/null 2>&1; then
    _isc_clear_receipt workspace_keys
    local legacy_index
    for ((legacy_index = 1; legacy_index <= 9; legacy_index++)); do
      _isc_clear_receipt "workspace_move_${legacy_index}"
    done
  fi
  user_gsettings set org.gnome.mutter dynamic-workspaces false
  user_gsettings set org.gnome.desktop.wm.preferences num-workspaces "$WORKSPACE_COUNT"

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

# configure_workspace_switch_binding INDEX — Apply one typed switch field and
# its derived move binding (the shared move modifier plus the same base chord).
configure_workspace_switch_binding() {
  local index="$1" switch_accel move_accel
  [[ "$index" =~ ^[1-9]$ ]] || {
    msg "ERROR: workspace binding index must be between 1 and 9: $index"
    return 2
  }

  switch_accel="$(workspace_switch_accelerator "$index")" || return 1
  move_accel="$(workspace_move_accelerator "$index")" || return 1
  msg "Binding workspace $index switch=${switch_accel:-unassigned} move=${move_accel:-unassigned}"
  set_gsettings_strv org.gnome.desktop.wm.keybindings "switch-to-workspace-${index}" "$switch_accel"
  set_gsettings_strv org.gnome.desktop.wm.keybindings "move-to-workspace-${index}" "$move_accel"

  # GNOME's screen-recording default shadows the default move-to-workspace-8
  # chord. Release it whenever that exact chord is assigned, even when the
  # screenshot component was not selected in the same installer run.
  if [[ "${move_accel,,}" == "<super><shift>r" || "${move_accel,,}" == "<shift><super>r" ]]; then
    set_gsettings_strv_if_key_exists org.gnome.shell.keybindings show-screen-recording-ui
  fi
}

configure_workspace_switch_1() { configure_workspace_switch_binding 1; }
configure_workspace_switch_2() { configure_workspace_switch_binding 2; }
configure_workspace_switch_3() { configure_workspace_switch_binding 3; }
configure_workspace_switch_4() { configure_workspace_switch_binding 4; }
configure_workspace_switch_5() { configure_workspace_switch_binding 5; }
configure_workspace_switch_6() { configure_workspace_switch_binding 6; }
configure_workspace_switch_7() { configure_workspace_switch_binding 7; }
configure_workspace_switch_8() { configure_workspace_switch_binding 8; }
configure_workspace_switch_9() { configure_workspace_switch_binding 9; }

# configure_workspace_move_modifier — Rebuild all move bindings after the one
# shared move modifier field changes.
configure_workspace_move_modifier() {
  local index move_accel
  msg "Applying workspace move modifier: $(workspace_move_modifier)"
  for ((index = 1; index <= WORKSPACE_UI_COUNT; index++)); do
    move_accel="$(workspace_move_accelerator "$index")" || return 1
    set_gsettings_strv org.gnome.desktop.wm.keybindings "move-to-workspace-${index}" "$move_accel"
  done
}

# configure_workspace_keys — compatibility helper for callers that still want
# to apply the complete workspace set in one call. New component manifests use
# the individual functions above so standalone and aggregate menus show each row.
configure_workspace_keys() {
  local index
  configure_workspace_behavior
  for ((index = 1; index <= WORKSPACE_UI_COUNT; index++)); do
    configure_workspace_switch_binding "$index"
  done
}

# audit_keybindings — Print the currently applied overview/switch/screenshot
# keybindings for visual verification after configuration. Takes no arguments.
audit_keybindings() {
  msg "Audit: grep selected keybindings"
  run_as_target bash -lc "gsettings list-recursively | grep -E '<Super>Tab|switch-group|switch-applications' || true"
  run_as_target bash -lc "gsettings list-recursively | grep '<Super>s' || true"
}

# Automatic same-application window tiling, the pointer-driven window move/resize
# hotkeys, and the monitor/window movement + tiling extension are no longer
# delegated from here: they are standalone, directly-installed repositories
# (linux_automatic_window_tiling, linux_hotkey_window_tools, and
# linux_monitor_window_hotkeys) that each configure their hotkeys through the same
# shared isc_capture_hotkey engine. Their former configure_* delegators and the
# bundled monitor-window-hotkeys@local extension were removed with the
# corresponding components. The window placement tiling service (below) still
# drives linux_monitor_window_hotkeys' D-Bus tiling methods at runtime.
