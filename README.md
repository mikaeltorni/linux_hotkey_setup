# Ubuntu Hotkeys Setup

> Part of [installation_scripts](https://github.com/mikaeltorni/installation_scripts) — the master installer that orchestrates a productivity-focused Ubuntu 24.04 desktop setup (workspaces, hotkeys, window tiling, programming tools, and more). Tested on Ubuntu 24.04.4 LTS.

Standalone installer for the Ubuntu GNOME hotkey setup used by the desktop installer.

It owns the configurable screenshot shortcut, numbered workspace switching and moving (up to 9 workspaces), the local monitor/window GNOME Shell hotkeys extension (4 monitors), and the window placement tiling user service (formerly the "Ctrl+Back window tiler"). Every hotkey can be chosen interactively through the shared press-to-capture engine. Automatic same-application tiling now installs from the sibling `linux_automatic_window_tiling` repository, pointer-driven window move/resize hotkeys from `linux_hotkey_window_tools`, and the numbered workspace popup extension from `linux_workspaces_setup` — each a standalone, directly-installed repository that configures its hotkeys the same interactive way. The Albert launcher toggle binding and the xmousepasteblock primary-paste blocker service also live in `linux_workspaces_setup`.

## Repository dependencies

This repository installs and runs **standalone**; sibling repositories only
enhance it and never block installation when absent.

- **Build-time (soft):** the shared installer component framework
  [`linux_installation_scripts_functions`](https://github.com/mikaeltorni/linux_installation_scripts_functions) —
  loaded from a sibling checkout when present, otherwise downloaded on demand.
  It also provides the shared interactive hotkey-capture engine every hotkey
  here is configured with.

See the full cross-repository map in
[installation_scripts/DEPENDENCIES.md](https://github.com/mikaeltorni/installation_scripts/blob/master/DEPENDENCIES.md).

## Technology Stack

- Bash installer for GNOME GSettings, GNOME Shell extension installation, and systemd user-service setup.
- Python `evdev` helper logic inside the setup module for pointer-device detection.
- A local GNOME Shell extension for monitor/window movement and tiling shortcuts.
- Pytest-compatible Python tests that simulate shell behavior without modifying host settings.

## Installation

```bash
sudo bash install.sh
```

The installer must run with `sudo` because it installs files into the target user's GNOME Shell extension directory, writes user systemd services, and fixes ownership. GSettings and user-service operations run as the target desktop user.

After installation, log out and back in before testing GNOME Shell extension changes. Do not reload GNOME Shell extensions from an active Wayland session.

## Development Workflow

Run tests:

```bash
python3 -m pytest tests -q
```

Run shell syntax validation:

```bash
bash -n install.sh lib/hotkeys_setup.sh lib/ctrl_back_tiler.sh lib/gsettings_helpers.sh lib/lifecycle.sh configs/gnome-shell/extensions/monitor-window-hotkeys@local/apply-system-bindings.sh
```

## Project Structure

- `install.sh` - standalone entrypoint for applying the full hotkey setup.
- `lib/hotkeys_setup.sh` - shared implementation; each hotkey is captured via the shared `isc_capture_hotkey` engine.
- `lib/ctrl_back_tiler.sh` - pointing-device selection and window-placement-tiling user-service installation (configurable modifier + mouse-button trigger).
- `lib/gsettings_helpers.sh` - reusable GSettings list and keybinding helpers sourced by the setup library.
- `lib/lifecycle.sh` - per-component detect/uninstall functions.
- `configs/gnome-shell/extensions/monitor-window-hotkeys@local/` - local GNOME Shell extension and schema defaults.
- `configs/window-hotkeys/` - window-placement-tiling service script and centralized logger.
- `tests/` - simulation tests.

## Configuration

Important defaults:

Interactive capture is used on a terminal; these are the shown defaults and the
environment overrides for automated runs:

- `WORKSPACE_COUNT=9` (numbered workspaces created; capture walks up to 9)
- `SCREENSHOT_HOTKEY` overrides the screenshot default `<Shift><Super>s`
- `WORKSPACE_SWITCH_<n>` overrides one switch field; `WORKSPACE_MOVE_MODIFIER`
  controls every derived move binding (default `Shift`)
- `MONITOR_MOVE_<n>` overrides "move to monitor N" (defaults `<Alt><Super>x/z/c`, the 4th blank)
- `WINDOW_PLACEMENT_TILING_TRIGGER` overrides the tiling trigger (default `Control|BTN_BACK`)
- `MONITOR_WINDOW_HOTKEYS_EXTENSION_ID=monitor-window-hotkeys@local`

Extension-owned monitor/window keybindings live in the extension schema defaults. System bindings that must be coordinated with those defaults live in `apply-system-bindings.sh`.

Pointer-driven window move (`<Alt><Super>W` drag) and resize (`<Alt><Super>E`
center scaling) now live in the standalone `linux_hotkey_window_tools`
repository, installed directly by the master installer.

Half-screen tiling defaults: among arrow keys only `<Super>Up` tiles (top half, in
`linux_monitor_window_hotkeys`); bottom/left/right halves use `Ctrl+Super` letter
bindings (`W`/`C`/`Right`). The window-placement-tiling trigger (default Ctrl +
mouse Back) is handled by a separate D-Bus service (ctrl_back_tile_right.py);
its modifier and mouse button are configurable via the capture UI.
`apply-system-bindings.sh` in `linux_monitor_window_hotkeys` removes only the
`<Super>Up` conflicts (GNOME maximize and Tiling Assistant `tile-maximize`) so
that shortcut reaches top-half tiling.

Automatic same-application tiling (`linux_automatic_window_tiling`) and
pointer-driven move/resize (`linux_hotkey_window_tools`) are standalone,
directly-installed repositories that own their own extensions, schemas, and
configurable hotkeys (chosen through the same shared capture engine).

## Troubleshooting

- If the window-placement-tiling service cannot find a pointing device with a browser-back button, it skips the service setup.
- If monitor/window hotkeys do not respond immediately, log out and back in so GNOME Shell loads the updated extension code.
- If `Shift+Super+R` triggers GNOME's screen recording instead of move-to-workspace-8, the installer's unbinding of `org.gnome.shell.keybindings show-screen-recording-ui` has not taken effect yet. Re-run `bash install.sh`. This is a `gsettings` keybinding change, which GNOME Shell applies live, so no Shell reload is needed. Verify with `gsettings get org.gnome.shell.keybindings show-screen-recording-ui` returning `@as []`.
- If GSettings schema writes fail for the local extension, run `glib-compile-schemas` on the extension `schemas/` directory and retry the installer.

## Deployment

Before deploying:

```bash
bash -n install.sh lib/hotkeys_setup.sh lib/ctrl_back_tiler.sh lib/gsettings_helpers.sh lib/lifecycle.sh configs/gnome-shell/extensions/monitor-window-hotkeys@local/apply-system-bindings.sh
python3 -m pytest tests -q
```

Then run:

```bash
sudo bash install.sh
```

## Contributing

Keep hotkey values single-sourced. Extension-owned monitor/window bindings belong in the extension schema defaults; installer-owned GNOME system bindings belong in named arrays or `apply-system-bindings.sh`. Avoid hard-coded checkout paths; resolve assets through `SCRIPT_DIR` or `CONFIG_DIR`.

## Part of 8-Repo Desktop Setup Chain

This repository is **Phase 3** in the desktop setup chain:

1. `linux_installations_setup` — Base packages, hardware, apps
2. `linux_configuration_setup` — GNOME desktop, autostart, GSettings
3. `linux_automatic_window_tiling` — Parameterized automatic window tiling
4. **`linux_hotkey_setup` (this repo)** — GNOME hotkeys and workspace bindings
5. `agent_command_center` — Agent command center components
6. `linux_programming_setup` — Cursor IDE, VS Code extensions
7. `ubuntu_2404_taskbar_system_status_monitor` — Taskbar system monitor extension
8. `phrase_automation` — Phrase automation tmux service

It is automatically cloned and run by the main installer (`installation_scripts/install.sh`).

## Component selection

This repository's `install.sh` participates in the shared installer
component menu (see the [`installation_scripts`](https://github.com/mikaeltorni/installation_scripts)
master installer). Run standalone, it offers an interactive submenu on a
terminal; the master installer drives it non-interactively.

```bash
bash install.sh                 # interactive component selection (TTY), else defaults
bash install.sh --default       # install all default-on components, no prompts
bash install.sh --all           # install every component, no prompts
bash install.sh --select a,b    # install exactly these component ids
bash install.sh --list-components  # print: id<TAB>label<TAB>default
```

In the interactive menu, **space** toggles a component, `a`/`n` select all
or none, and **Enter** installs the selection. Components:

A plain install applies each shown default. On a workspace switch or move
modifier row, press RIGHT to open its typed rebind field. Switch fields accept
multiple modifiers plus exactly one key and display values such as `Super+W`;
the move field accepts one modifier (`Shift`, `Ctrl`, `Alt`, or `Super`) and is
rejected if it would duplicate a switch chord. Values persist under
`~/.config/linux-hotkey-setup/workspace-hotkeys.conf` for both standalone and
master installations.

| Component id | Description | Default |
|---|---|---|
| `screenshot` | Screenshot shortcut (default `<Shift><Super>s`) | on |
| `workspace_behavior` | Static workspace count and shared navigation behavior | on |
| `workspace_switch_1` … `workspace_switch_8` | Editable switch field per workspace | on |
| `workspace_switch_9` | Optional switch-to-workspace-9 action (unassigned by default) | off |
| `workspace_move_modifier` | One modifier added to every switch chord for moving windows | on |
| `monitor_window_hotkeys` | Monitor/window movement hotkeys extension (4 monitors) | on |
| `window_placement_tiling` | Window placement tiling service (Ctrl + mouse Back) | on |

Automatic same-application window tiling, the pointer-driven window move/resize
hotkeys, and the numbered workspace popup extension are now their own
directly-installed repositories (`linux_automatic_window_tiling`,
`linux_hotkey_window_tools`, and `linux_workspaces_setup`), each configuring its
hotkeys through the same shared press-to-capture engine.

The standalone and master installers both discover these rows from
`bash install.sh --list-components`. For example, reconfigure only
`workspace_switch_2` with RIGHT in either menu, or script that row with
`WORKSPACE_SWITCH_2='<Alt><Super>2'`.


## Detect, reconfigure, and uninstall

This installer tracks what it has installed and can re-apply or remove it, so you
can refresh configuration after a repo update or cleanly back a feature out.

```bash
bash install.sh --detect            # show each component as installed|absent
bash install.sh --reconfigure a,b   # re-apply (idempotent) these component ids
bash install.sh --uninstall a,b     # uninstall these component ids
```

In the interactive menu (run `bash install.sh` on a terminal, or via the master
installer), already-installed components show a green `✓`. Select one with
**space** to **reconfigure** it (`~`), press **`u`** to mark it for **uninstall**
(`✗`), or press **`r`** to reconfigure every installed component at once. Detection
uses a live check where deterministic and otherwise an install receipt under
`${XDG_STATE_HOME:-~/.local/state}/isc/receipts/`; a component without a reversal
step simply clears that receipt on uninstall.

## Disclaimer

This software is provided under the MIT License on an **“as is”** basis, without warranties of any kind. To the maximum extent permitted by applicable law, the authors and copyright holders shall not be liable for any claims, damages, losses, or other liability arising from the use of this software.

You are solely responsible for determining whether this software is suitable, safe, lawful, and appropriate for your intended use. Unless explicitly stated otherwise, this project is general-purpose software and is not designed, tested, certified, or approved for safety-critical, medical, automotive, aviation, industrial-control, life-support, cybersecurity-critical, financial-critical, or other high-risk use cases.

The authors and copyright holders make no guarantees regarding security, reliability, availability, correctness, compliance, non-infringement, or fitness for any particular purpose.

This notice is intended to clarify the nature of the project and does not impose additional restrictions beyond the MIT License.
