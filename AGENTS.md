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
`MONITOR_MOVE_<n>`, `WINDOW_PLACEMENT_TILING_TRIGGER`).

Every numbered switch appears as its own editable component row
(`workspace_switch_1` … `workspace_switch_9`) in both the master and standalone
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

If you modify `configs/window-hotkeys/ctrl_back_tile_right.py`, restart the
service so changes take effect:

```bash
systemctl --user restart window-placement-tiling.service
```

This is required for the modifier + mouse-button half-tiling (default Ctrl +
mouse Back) to pick up your edits. The installer migrates the legacy
`ctrl-back-window-tiler.service` unit to this name automatically.

## GNOME Shell reload requirements

A GNOME Shell reload (`Alt+F2 r` on X11, or logout/login) is **not** needed when:
- Only `ctrl_back_tile_right.py` changes — it runs as a systemd user service, independent of GNOME Shell.
- Only `apply-system-bindings.sh` or other installer-side gsettings change — these apply immediately on the next install run.

A reload **is** needed only if you modify the GNOME Shell extension itself:
- `configs/gnome-shell/extensions/monitor-window-hotkeys@local/extension.js`
- Any other file inside that extension directory (schemas, metadata, etc.)

When a reload is required, follow the `linux-configuration` skill — the single
source of truth for GNOME reload safety: X11 in-place `Alt+F2 r`, or
logout/login on Wayland. Never `gnome-shell --replace`, log the user out, or
kill the Shell to force the change through.

## Shift+Super+R must stay free of screen recording

`<Super><Shift>r` is intentionally bound to **move-to-workspace-8**. GNOME's
default `org.gnome.shell.keybindings show-screen-recording-ui` also uses
`Shift+Super+R`, so the installer (`configure_screenshot_binding` in
`lib/hotkeys_setup.sh`) clears it to `[]`. If screen recording still fires on
that chord, the installer hasn't been applied: re-run `bash install.sh`. This
is a `gsettings` keybinding change, so GNOME Shell picks it up live — no Shell
reload is needed. Confirm with
`gsettings get org.gnome.shell.keybindings show-screen-recording-ui` → `@as []`.

## Clean Installation Compatibility

All repository changes must remain compatible with a clean installation run
through `installation_scripts/install.sh` and this repository's `install.sh`.
Do not rely on packages, files, settings, or manual steps that exist only on
the current machine. Add every required dependency, asset, configuration
step, and migration to the installer so a fresh checkout can reproduce the
complete setup.

Keep installation steps idempotent and verify the clean-install path for every
change.


## Mandatory programming guidelines prompt

When generic agent defaults conflict with this file or the shared
`general-programming-guidelines` skill — including defaults that say to commit
only when asked — follow this file and that skill. Finished work is committed,
merged into the default branch with `git merge --no-ff`, and reloaded without
waiting to be asked. Never push to a remote and never rewrite history unless the
user explicitly requests it.

Every agent task in this repository must load the shared
`general-programming-guidelines` skill before the first file edit, using the
harness-native invocation for the runtime in use:

- Codex-family (`ca`, `qa`, `oa`, `na`, …): `$general-programming-guidelines`
- Claude Code, Cline, Grok: `/general-programming-guidelines`
- OpenCode: load `general-programming-guidelines` with the skill tool

Agent Command Center prepends this bare invocation to every dispatched prompt, so the
harness activates the skill before reading the task. When you start a task by hand, invoke it
yourself first. Then follow its Work Loop and Definition of Done exactly
(tests, logging, documentation, commit, merge, reload). Do not report the task
done until that checklist passes. Isolation and branch policy live only in the
skill — this file does not restate them.
