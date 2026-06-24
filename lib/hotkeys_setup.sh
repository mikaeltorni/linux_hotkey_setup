#!/usr/bin/env bash
# hotkeys_setup.sh — Ubuntu GNOME hotkey setup helpers.
#
# Components:
#   - configure_screenshot_binding(): Bind screenshot keys; unbind screen recording.
#   - configure_workspace_keys(): Bind numbered workspace switching/moving keys.
#   - configure_monitor_window_hotkeys_extension(): Install monitor/window GNOME Shell hotkeys.
#   - configure_automatic_window_tiling(): Delegate automatic tiling installation.
#   - configure_hotkey_window_tools(): Delegate window move/resize hotkey install.
#   - configure_workspace_number_popup_extension(): Install numbered workspace popup extension.
#   - select_input_device(): Select a pointing device for Ctrl+Back tiling.
#   - configure_ctrl_back_window_tiler_service(): Install Ctrl+Back window tiler service.
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
: "${AUTOMATIC_WINDOW_TILING_DIR:=$HOTKEYS_SETUP_DIR/../linux_automatic_window_tiling}"
: "${AUTOMATIC_WINDOW_TILING_BINDING:=<Super>t}"
: "${HOTKEY_WINDOW_TOOLS_DIR:=$HOTKEYS_SETUP_DIR/../linux_hotkey_window_tools}"

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
# shellcheck source=workspace_popup.sh
source "$HOTKEYS_SETUP_LIB_DIR/workspace_popup.sh"

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
  msg "Binding Shift+Super+S to screenshot UI and Print to quick screenshot"
  local old_custom_screenshot_path="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom-screenshot/"

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

# configure_workspace_keys — Switch to a fixed WORKSPACE_COUNT of static
# workspaces and bind the numbered switch/move keys, Super+Shift arrow moves, and
# overview toggle. Takes no arguments; reads WORKSPACE_COUNT and the
# WORKSPACE_SWITCH/MOVE, SUPER_ARROW_MOVE, and OVERVIEW binding arrays.
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

  enable_shell_extension "$ext_id"
  msg "Monitor/window hotkeys extension installed. Log out and back in before testing GNOME Shell extension changes."
}

# configure_automatic_window_tiling — Delegate to the sibling
# linux_automatic_window_tiling repository's installer, passing the configured
# tiling binding. Skipped when that repository is absent. Takes no arguments;
# reads AUTOMATIC_WINDOW_TILING_DIR and AUTOMATIC_WINDOW_TILING_BINDING.
configure_automatic_window_tiling() {
  msg "Configuring automatic window tiling"
  local installer="$AUTOMATIC_WINDOW_TILING_DIR/install.sh"

  if [[ ! -f "$installer" ]]; then
    msg "Automatic window tiling repository not found at $AUTOMATIC_WINDOW_TILING_DIR; skipping."
    return 0
  fi

  TARGET_USER="$TARGET_USER" bash "$installer" "$AUTOMATIC_WINDOW_TILING_BINDING"
}

# configure_hotkey_window_tools — Install the pointer-driven window move/resize
# hotkeys by delegating to the sibling linux_hotkey_window_tools repository. The
# <Alt><Super>W move and <Alt><Super>E resize features used to live in the local
# monitor-window-hotkeys extension and now ship from that standalone repo, which
# can also be installed on its own. Skipped on X11 (like the local extension)
# and when the repository is absent.
configure_hotkey_window_tools() {
  msg "Configuring pointer-driven window move/resize hotkeys"

  if [[ "$SESSION_TYPE" =~ ^(x11|xorg)$ ]]; then
    msg "X11 session detected; skipping window move/resize hotkeys extension."
    return 0
  fi

  local installer="$HOTKEY_WINDOW_TOOLS_DIR/install.sh"
  if [[ ! -f "$installer" ]]; then
    msg "Window move/resize tools repository not found at $HOTKEY_WINDOW_TOOLS_DIR; skipping."
    return 0
  fi

  # Pass --default so the component-aware tools installer runs non-interactively.
  # Without a selection flag it would open its interactive submenu on the parent
  # installer's inherited TTY and block forever, hanging the whole master run.
  TARGET_USER="$TARGET_USER" bash "$installer" --default
}
