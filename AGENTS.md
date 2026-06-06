# Agent Command Center — AGENTS.md

## Restarting the ctrl-back-window-tiler after code changes

If you modify `configs/window-hotkeys/ctrl_back_tile_right.py`, restart the tiler so changes take effect:

```bash
systemctl --user restart ctrl-back-window-tiler.service
```

This is required for the Ctrl+Back mouse button right-half tiling to pick up your edits.

## GNOME Shell reload requirements

A GNOME Shell reload (`Alt+F2 r` or logout/login) is **not** needed when:
- Only `ctrl_back_tile_right.py` changes — it runs as a systemd user service, independent of GNOME Shell.
- Only `apply-system-bindings.sh` changes — these are installer-side gsettings that apply on next install run.

A reload **is** needed only if you modify the GNOME Shell extension itself:
- `configs/gnome-shell/extensions/monitor-window-hotkeys@local/extension.js`
- Any other file inside that extension directory (schemas, metadata, etc.)

In that case, either press `Alt+F2`, type `r`, and press Enter (Wayland), or log out and back in.
