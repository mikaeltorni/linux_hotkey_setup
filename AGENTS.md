# Agent Command Center — AGENTS.md

## Configurable hotkeys (press-to-capture)

Every hotkey this repo installs can be chosen through the shared interactive
press-to-capture engine (`isc_capture_hotkey` from
`linux_installation_scripts_functions/hotkey_capture.sh`, loaded via
`isc_load_helpers`). The capture logic is **not** vendored here — do not fork it;
extend the shared engine instead.

**Interactive capture is opt-in** via `ISC_HOTKEY_INTERACTIVE=1`. A plain install
(`bash install.sh`, `sudo bash install.sh`, the master run, `--default`,
`--select`, …) applies each hotkey's shown **default** non-interactively and
never opens an evdev grab, so it can never appear to hang. This is deliberate:
the batch install would otherwise prompt for ~24 hotkeys and grab the keyboard
each time. To press your own hotkeys, run with the env set, e.g.
`ISC_HOTKEY_INTERACTIVE=1 bash install.sh` (or reconfigure a single component:
`ISC_HOTKEY_INTERACTIVE=1 bash install.sh --reconfigure screenshot`). In that
mode the installer shows each default and lets the user press modifiers + one key
(Backspace removes the last input, Enter confirms, Esc keeps the default),
warning in real time which GNOME default a chosen accelerator would unbind; the
read loop times out to the default after prolonged idle so it never blocks.

Every hotkey also has an environment override for fully scripted runs
(`SCREENSHOT_HOTKEY`, `WORKSPACE_SWITCH_<n>` / `WORKSPACE_MOVE_MODIFIER`,
`WINDOW_PLACEMENT_TILING_TRIGGER`).

Every numbered switch appears as its own editable component row
(`workspace_switch_1` … `workspace_switch_8`) in both the master and standalone
menus. RIGHT opens the framework-owned typed field; the current `Super+W` style
value appears in the row with an explicit rebind action. Window movement uses
one `workspace_move_modifier` field (Shift by default), which is added to each
switch chord and must never duplicate a modifier already present in a switch.

Favourite (`f`) and Startup (`s`) are the app-selection menu's own toggles
(owned by the shared `component_menu.sh` and applied while installing programs in
`linux_configuration_setup`); they are intentionally **not** part of this hotkey
capture. In the window-placement-tiling mouse capture, keyboard `F`/`B` instead
stand in for the mouse Forward/Back buttons.

## Restarting the window placement tiling service after code changes

If you modify `src/tiler.rs` (the `lhs-tools tiler` service), restart the
service so changes take effect:

```bash
systemctl --user restart window-placement-tiling.service
```

This is required for the modifier + mouse-button half-tiling (default Ctrl +
mouse Back) to pick up your edits. The installer migrates the legacy
`ctrl-back-window-tiler.service` unit to this name automatically.

## GNOME Shell reload requirements

This repository no longer ships a GNOME Shell extension. A Shell reload is
**not** needed for its changes:

- `lhs-tools tiler` / `src/tiler.rs` runs as a systemd user service — restart
  `window-placement-tiling.service` instead.
- Installer-side `gsettings` keybinding changes apply live.

Monitor-move + half-tiling + Super+U send-mode extension code lives in
`linux_monitor_window_hotkeys`. When that sibling's extension JS changes,
follow the `linux-configuration` skill there.

## Shift+Super+R must stay free of screen recording

`<Super><Shift>r` is intentionally bound to **move-to-workspace-8**. GNOME's
default `org.gnome.shell.keybindings show-screen-recording-ui` also uses
`Shift+Super+R`, so the installer (`configure_screenshot_binding` in
`lib/hotkeys_setup.sh`) clears it to `[]`. If screen recording still fires on
that chord, the installer hasn't been applied: re-run `bash install.sh`. This
is a `gsettings` keybinding change, so GNOME Shell picks it up live — no Shell
reload is needed. Confirm with
`gsettings get org.gnome.shell.keybindings show-screen-recording-ui` → `@as []`.
