# Ubuntu Hotkeys Setup

Standalone installer for the Ubuntu GNOME hotkey setup used by the desktop installer.

It owns screenshot shortcuts, numbered workspace switching and moving, Albert launcher shortcuts, the local monitor/window GNOME Shell hotkeys extension, the numbered workspace popup extension, the Ctrl+Back window tiler user service, and the optional primary-paste blocker service.

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
- `SCREEN_RECORDING_BINDINGS=('<Shift><Super>r')`
- `OVERVIEW_BINDINGS=('<Super>Tab')`
- `MONITOR_WINDOW_HOTKEYS_EXTENSION_ID=monitor-window-hotkeys@local`

Extension-owned monitor/window keybindings live in the extension schema defaults. System bindings that must be coordinated with those defaults live in `apply-system-bindings.sh`.

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
