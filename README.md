# Ubuntu Hotkeys Setup

> Part of [installation_scripts](https://github.com/mikaeltorni/installation_scripts) — the master installer that orchestrates a productivity-focused Ubuntu 24.04 desktop setup (workspaces, hotkeys, window tiling, programming tools, and more).

Standalone installer for the Ubuntu GNOME hotkey setup used by the desktop installer.

It owns screenshot shortcuts, numbered workspace switching and moving, Albert launcher shortcuts, the local monitor/window GNOME Shell hotkeys extension, the numbered workspace popup extension, the Ctrl+Back window tiler user service, and the optional primary-paste blocker service. Automatic same-application tiling is delegated to the sibling `linux_automatic_window_tiling` repository.

## Technology Stack

- Bash installer for GNOME GSettings, GNOME Shell extension installation, and systemd user-service setup.
- Python `evdev` helper logic inside the setup module for pointer-device detection.
- A local GNOME Shell extension for monitor/window movement, resizing, pointer drag, and tiling shortcuts.
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
bash -n install.sh lib/hotkeys_setup.sh configs/gnome-shell/extensions/monitor-window-hotkeys@local/apply-system-bindings.sh
```

## Project Structure

- `install.sh` - standalone entrypoint for applying the full hotkey setup.
- `lib/hotkeys_setup.sh` - shared implementation used by standalone installs and delegated desktop installs.
- `configs/gnome-shell/extensions/monitor-window-hotkeys@local/` - local GNOME Shell extension and schema defaults.
- `configs/window-hotkeys/` - Ctrl+Back tiler script and user service template.
- `tests/` - simulation tests.

## Configuration

Important defaults:

- `WORKSPACE_COUNT=8`
- `SCREENSHOT_UI_BINDINGS=('<Shift><Super>s')`
- `SCREENSHOT_QUICK_BINDINGS=('Print')`
- `OVERVIEW_BINDINGS=('<Super>Tab')`
- `MONITOR_WINDOW_HOTKEYS_EXTENSION_ID=monitor-window-hotkeys@local`
- `AUTOMATIC_WINDOW_TILING_DIR=../linux_automatic_window_tiling`
- `AUTOMATIC_WINDOW_TILING_BINDING=<Super>t`

Extension-owned monitor/window keybindings live in the extension schema defaults. System bindings that must be coordinated with those defaults live in `apply-system-bindings.sh`.

Half-screen tiling aliases include `<Super>Up` for the top half, `<Super>Down` for the bottom half, `<Super>Left` for the left half, and `<Super>Right` for the right half. The Ctrl+Back mouse button is handled by a separate D-Bus service (ctrl_back_tile_right.py). `apply-system-bindings.sh` removes GNOME's default Super+Up/Super+Down maximize and unmaximize/minimize bindings, and Tiling Assistant's `tile-maximize` Super+Up binding, so those vertical shortcuts reach the tiling actions.

When `linux_automatic_window_tiling` exists beside this repository, the
installer calls its parameterized installer with `<Super>t`. The standalone
repository owns the extension, tiling behavior, schema, and general-purpose
binding interface.

## Troubleshooting

- If the Ctrl+Back tiler cannot find a pointing device with a browser-back button, it skips the service setup.
- If monitor/window hotkeys do not respond immediately, log out and back in so GNOME Shell loads the updated extension code.
- If GSettings schema writes fail for the local extension, run `glib-compile-schemas` on the extension `schemas/` directory and retry the installer.

## Deployment

Before deploying:

```bash
bash -n install.sh lib/hotkeys_setup.sh configs/gnome-shell/extensions/monitor-window-hotkeys@local/apply-system-bindings.sh
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

## Disclaimer

This software is provided under the MIT License on an **“as is”** basis, without warranties of any kind. To the maximum extent permitted by applicable law, the authors and copyright holders shall not be liable for any claims, damages, losses, or other liability arising from the use of this software.

You are solely responsible for determining whether this software is suitable, safe, lawful, and appropriate for your intended use. Unless explicitly stated otherwise, this project is general-purpose software and is not designed, tested, certified, or approved for safety-critical, medical, automotive, aviation, industrial-control, life-support, cybersecurity-critical, financial-critical, or other high-risk use cases.

The authors and copyright holders make no guarantees regarding security, reliability, availability, correctness, compliance, non-infringement, or fitness for any particular purpose.

This notice is intended to clarify the nature of the project and does not impose additional restrictions beyond the MIT License.
