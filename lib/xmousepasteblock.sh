#!/usr/bin/env bash
# xmousepasteblock.sh - primary clipboard lock service installation.
#
# Locks the X11 PRIMARY selection so a middle-click does not paste, by running
# the xmousepasteblock daemon as a systemd user service.
#
# The caller must provide TARGET_HOME and the installer helpers msg(), log(),
# run_as_target(), reload_systemd_daemon(), and enable_systemd_service().

# build_xmousepasteblock - Return success when the xmousepasteblock binary is installed.
build_xmousepasteblock() {
  local bin_path="$TARGET_HOME/.local/bin/xmousepasteblock"
  [ -x "$bin_path" ]
}

# configure_xmousepasteblock_service - Install and start the xmousepasteblock user service.
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

# lock_primary_paste - Configure the primary clipboard lock when xmousepasteblock is available.
lock_primary_paste() {
  msg "Configuring primary clipboard lock (xmousepasteblock)"
  if build_xmousepasteblock; then
    configure_xmousepasteblock_service || true
  else
    log "info" "xmousepasteblock is unavailable; primary clipboard lock service skipped."
  fi
}
