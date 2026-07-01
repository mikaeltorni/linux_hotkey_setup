#!/usr/bin/env bash
# hotkeys_setup.sh — Ubuntu GNOME hotkey setup helpers.
#
# Components:
#   - configure_screenshot_binding(): Capture + bind the screenshot hotkey.
#   - configure_workspace_behavior(): Apply shared static-workspace behavior.
#   - configure_workspace_{switch,move}_N(): Configure one numbered action.
#   - configure_monitor_window_hotkeys_extension(): Install monitor/window GNOME Shell hotkeys (4 monitors).
#   - select_input_device(): Select a pointing device for window placement tiling.
#   - configure_window_placement_tiling_service(): Install the window placement tiling service.
#
# Every hotkey above is configurable through the shared press-to-capture engine
# (isc_capture_hotkey). Automatic window tiling, the pointer move/resize hotkeys,
# and the numbered workspace popup moved to their own repositories.
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
: "${MONITOR_WINDOW_HOTKEYS_EXTENSION_ID:=monitor-window-hotkeys@local}"
: "${MONITOR_WINDOW_HOTKEYS_SOURCE_DIR:=$HOTKEYS_SETUP_CONFIG_DIR/gnome-shell/extensions/$MONITOR_WINDOW_HOTKEYS_EXTENSION_ID}"

SCREENSHOT_UI_BINDINGS=("${SCREENSHOT_UI_BINDINGS[@]:-<Shift><Super>s}")
SCREENSHOT_QUICK_BINDINGS=("${SCREENSHOT_QUICK_BINDINGS[@]:-Print}")
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

# capture_workspace_bindings — walk workspaces 1..WORKSPACE_UI_COUNT and let the
# user press a hotkey for the given action, seeding each with its default (the
# 9th is blank on purpose). Rebuilds the caller-named array with the captured
# "index:accelerator" entries (blank captures are dropped so they stay unbound).
# Args: $1 action label ("switch to"/"move window to"); $2 gsettings key prefix
#       used only for the conflict identifier; $3 nameref result array;
#       $4.. default "index:binding" entries.
capture_workspace_bindings() {
  local action="$1" _keyprefix="$2" resultname="$3"; shift 3
  local -a defaults=("$@") captured=()
  local i default accel
  for (( i=1; i<=WORKSPACE_UI_COUNT; i++ )); do
    default="$(hotkey_default_for_index "$i" "${defaults[@]}")"
    ISC_HOTKEY_CONFLICTS_FN=hotkey_wm_conflict_candidates \
      accel="$(isc_capture_hotkey "WORKSPACE_${_keyprefix}_${i}" "$default" "$action workspace $i")"
    [[ -n "$accel" ]] && captured+=("$i:$accel")
  done
  # Assign the rebuilt entries into the caller-named array via a nameref created
  # only now (after the source array has been fully read), avoiding aliasing.
  local -n result="$resultname"
  result=("${captured[@]}")
  return 0
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

# configure_workspace_binding ACTION INDEX — Capture and apply exactly one
# numbered workspace key. ACTION is "switch" or "move" and INDEX is 1..9.
# WORKSPACE_SWITCH_N / WORKSPACE_MOVE_N provide non-interactive overrides.
configure_workspace_binding() {
  local action="$1" index="$2" array_name key_prefix label env_prefix
  case "$action" in
    switch)
      array_name=WORKSPACE_SWITCH_BINDINGS
      key_prefix=switch-to-workspace-
      label="switch to"
      env_prefix=SWITCH
      ;;
    move)
      array_name=WORKSPACE_MOVE_BINDINGS
      key_prefix=move-to-workspace-
      label="move window to"
      env_prefix=MOVE
      ;;
    *)
      msg "ERROR: unsupported workspace binding action: $action"
      return 2
      ;;
  esac
  [[ "$index" =~ ^[1-9]$ ]] || {
    msg "ERROR: workspace binding index must be between 1 and 9: $index"
    return 2
  }

  local -n defaults="$array_name"
  local default accel env_var="WORKSPACE_${env_prefix}_${index}"
  default="$(hotkey_default_for_index "$index" "${defaults[@]}")"
  ISC_HOTKEY_CONFLICTS_FN=hotkey_wm_conflict_candidates \
    accel="$(isc_capture_hotkey "$env_var" "$default" "$label workspace $index")"

  msg "Binding $label workspace $index to ${accel:-unassigned}"
  set_gsettings_strv org.gnome.desktop.wm.keybindings "${key_prefix}${index}" "$accel"

  # GNOME's screen-recording default shadows the default move-to-workspace-8
  # chord. Release it whenever that exact chord is assigned, even when the
  # screenshot component was not selected in the same installer run.
  if [[ "${accel,,}" == "<super><shift>r" || "${accel,,}" == "<shift><super>r" ]]; then
    set_gsettings_strv_if_key_exists org.gnome.shell.keybindings show-screen-recording-ui
  fi
}

configure_workspace_switch_1() { configure_workspace_binding switch 1; }
configure_workspace_switch_2() { configure_workspace_binding switch 2; }
configure_workspace_switch_3() { configure_workspace_binding switch 3; }
configure_workspace_switch_4() { configure_workspace_binding switch 4; }
configure_workspace_switch_5() { configure_workspace_binding switch 5; }
configure_workspace_switch_6() { configure_workspace_binding switch 6; }
configure_workspace_switch_7() { configure_workspace_binding switch 7; }
configure_workspace_switch_8() { configure_workspace_binding switch 8; }
configure_workspace_switch_9() { configure_workspace_binding switch 9; }
configure_workspace_move_1() { configure_workspace_binding move 1; }
configure_workspace_move_2() { configure_workspace_binding move 2; }
configure_workspace_move_3() { configure_workspace_binding move 3; }
configure_workspace_move_4() { configure_workspace_binding move 4; }
configure_workspace_move_5() { configure_workspace_binding move 5; }
configure_workspace_move_6() { configure_workspace_binding move 6; }
configure_workspace_move_7() { configure_workspace_binding move 7; }
configure_workspace_move_8() { configure_workspace_binding move 8; }
configure_workspace_move_9() { configure_workspace_binding move 9; }

# configure_workspace_keys — compatibility helper for callers that still want
# to apply the complete workspace set in one call. New component manifests use
# the individual functions above so standalone and aggregate menus show each row.
configure_workspace_keys() {
  local index
  configure_workspace_behavior
  for ((index = 1; index <= WORKSPACE_UI_COUNT; index++)); do
    configure_workspace_binding switch "$index"
  done
  for ((index = 1; index <= WORKSPACE_UI_COUNT; index++)); do
    configure_workspace_binding move "$index"
  done
}

# audit_keybindings — Print the currently applied overview/switch/screenshot
# keybindings for visual verification after configuration. Takes no arguments.
audit_keybindings() {
  msg "Audit: grep selected keybindings"
  run_as_target bash -lc "gsettings list-recursively | grep -E '<Super>Tab|switch-group|switch-applications' || true"
  run_as_target bash -lc "gsettings list-recursively | grep '<Super>s' || true"
}

# configure_monitor_window_hotkeys_extension — Install the local monitor/window
# GNOME Shell extension into the target user's extensions directory, compile its
# schema, apply its system bindings, and enable it. Skipped on X11 and when the
# source directory is absent. Takes no arguments; reads
# MONITOR_WINDOW_HOTKEYS_EXTENSION_ID and MONITOR_WINDOW_HOTKEYS_SOURCE_DIR.
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

  if is_root; then
    install -d -o "$TARGET_USER" -g "$TARGET_USER" "$ext_dir"
  else
    install -d "$ext_dir"
  fi
  cp -a "$source_dir/." "$ext_dir/"
  if is_root; then
    chown -R "$TARGET_USER:$TARGET_USER" "$ext_dir"
  fi
  run_as_target chmod +x "$ext_dir/apply-system-bindings.sh"

  if ! need_cmd glib-compile-schemas; then
    apt_install libglib2.0-bin
  fi
  glib-compile-schemas "$ext_dir/schemas"

  if ! run_as_target "$ext_dir/apply-system-bindings.sh"; then
    echo "WARNING: monitor-window-hotkeys apply-system-bindings.sh failed; log out and back in, then re-run installer or apply-system-bindings.sh"
    return 0
  fi

  configure_monitor_move_hotkeys "$ext_dir"

  enable_shell_extension "$ext_id"
  msg "Monitor/window hotkeys extension installed. Log out and back in before testing GNOME Shell extension changes."
}

# Default "move focused window to monitor N" accelerators. Monitors 1–3 ship a
# default; the 4th is intentionally blank so the user assigns it. Matches the
# extension's own schema defaults.
MONITOR_MOVE_DEFAULTS=(
  "1:<Alt><Super>x"
  "2:<Alt><Super>z"
  "3:<Alt><Super>c"
  "4:"
)
: "${MONITOR_MOVE_COUNT:=4}"

# configure_monitor_move_hotkeys — let the user press a hotkey for each of the
# four "move window to monitor N" actions (defaults shown; 4th blank), then write
# the captured accelerators onto the extension's own schema keys. Runs after
# apply-system-bindings.sh has reset those keys to their defaults.
# Args: $1 — installed extension directory (its schemas/ dir is used).
configure_monitor_move_hotkeys() {
  local ext_dir="$1" schema="org.gnome.shell.extensions.monitor-window-hotkeys"
  local schemadir="$ext_dir/schemas" i default accel
  for (( i=1; i<=MONITOR_MOVE_COUNT; i++ )); do
    default="$(hotkey_default_for_index "$i" "${MONITOR_MOVE_DEFAULTS[@]}")"
    ISC_HOTKEY_CONFLICTS_FN=hotkey_wm_conflict_candidates \
      accel="$(isc_capture_hotkey "MONITOR_MOVE_${i}" "$default" "move window to monitor $i")"
    if [[ -n "$accel" ]]; then
      run_as_target gsettings --schemadir "$schemadir" set "$schema" \
        "move-active-window-to-monitor-$i" "['${accel//\'/\\\'}']" 2>/dev/null || true
    else
      run_as_target gsettings --schemadir "$schemadir" set "$schema" \
        "move-active-window-to-monitor-$i" "[]" 2>/dev/null || true
    fi
  done
}

# Automatic same-application window tiling and the pointer-driven window
# move/resize hotkeys are no longer delegated from here: they are standalone,
# directly-installed repositories (linux_automatic_window_tiling and
# linux_hotkey_window_tools) that each configure their hotkeys through the same
# shared isc_capture_hotkey engine. Their former configure_* delegators were
# removed with the corresponding components.
