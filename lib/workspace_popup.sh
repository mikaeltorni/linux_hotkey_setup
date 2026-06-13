#!/usr/bin/env bash
# workspace_popup.sh - numbered workspace popup extension installer.
#
# The caller must provide SESSION_TYPE, TARGET_HOME, and the installer helpers
# msg(), run_as_target(), remove_gsettings_list(), and enable_shell_extension().

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
