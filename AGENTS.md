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

## Clean Installation Compatibility

All repository changes must remain compatible with a clean installation run
through `installation_scripts/install.sh` and this repository's `install.sh`.
Do not rely on packages, files, settings, or manual steps that exist only on
the current machine. Add every required dependency, asset, configuration
step, and migration to the installer so a fresh checkout can reproduce the
complete setup.

Keep installation steps idempotent and verify the clean-install path for every
change.

## Reloading GNOME Shell

When a change needs GNOME Shell to reload (extensions, themes, shell-side
configuration), reload it in place — never log the user out or terminate the
session.

- X11 session: run
  `busctl --user call org.gnome.Shell /org/gnome/Shell org.gnome.Shell Eval s 'Meta.restart("Restarting…")'`
  (equivalent to pressing Alt+F2 → `r`). This restarts gnome-shell while
  preserving the user's open windows and applications.
- Wayland session: there is no in-place reload. Ask the user to log out and
  back in themselves. Do NOT initiate it.

Never use any of the following to force changes through, regardless of session
type:

- `gnome-session-quit` / `--logout` / `--force`
- `loginctl terminate-session …` / `loginctl kill-user …`
- `systemctl --user stop gnome-session*` or similar unit stops
- `pkill -HUP gnome-shell`, `killall gnome-shell`, or any signal that ends the
  shell process on Wayland

Losing the user's open work is a worse outcome than waiting for them to reload
manually.
