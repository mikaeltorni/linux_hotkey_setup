#!/usr/bin/env python3
"""Tests for the standalone Ubuntu hotkeys setup helpers.

Components:
  - run_bash(): Execute bash snippets from the project root.
  - test_exports_expected_hotkey_functions(): Verifies the public helper API.
  - test_workspace_and_screenshot_bindings_are_applied(): Simulates GSettings
    calls without modifying the host system.
  - test_monitor_window_hotkey_assets_exist(): Verifies transferred extension assets.

Usage:
  python3 tests/test_hotkeys_setup.py
"""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parent.parent


def run_bash(script: str) -> subprocess.CompletedProcess[str]:
    """Run a bash snippet from the project root.

    Args:
        script: Bash source to execute.

    Returns:
        CompletedProcess with stdout, stderr, and return code.
    """
    return subprocess.run(
        ["bash", "-c", script],
        cwd=ROOT_DIR,
        text=True,
        capture_output=True,
        check=False,
    )


def test_exports_expected_hotkey_functions():
    """The setup library should export the installer-facing function names."""
    proc = run_bash(
        "\n".join(
            [
                "set -euo pipefail",
                f"SCRIPT_DIR={str(ROOT_DIR)!r}",
                f"CONFIG_DIR={str(ROOT_DIR / 'configs')!r}",
                "TARGET_USER=$(id -un)",
                "TARGET_HOME=/tmp/ubuntu-hotkeys-test-home",
                "source lib/hotkeys_setup.sh",
                "declare -F configure_screenshot_binding configure_workspace_keys configure_albert_keybindings >/dev/null",
                "declare -F configure_monitor_window_hotkeys_extension configure_workspace_number_popup_extension >/dev/null",
                "declare -F select_input_device configure_ctrl_back_window_tiler_service lock_primary_paste configure_ubuntu_hotkeys >/dev/null",
            ]
        )
    )

    assert proc.returncode == 0, proc.stderr


def test_workspace_and_screenshot_bindings_are_applied():
    """Workspace and screenshot helpers should emit the expected GSettings calls."""
    with tempfile.TemporaryDirectory() as td:
        home = Path(td) / "home"
        home.mkdir()
        proc = run_bash(
            "\n".join(
                [
                    "set -euo pipefail",
                    f"SCRIPT_DIR={str(ROOT_DIR)!r}",
                    f"CONFIG_DIR={str(ROOT_DIR / 'configs')!r}",
                    f"TARGET_HOME={str(home)!r}",
                    "TARGET_USER=$(id -un)",
                    "SESSION_TYPE=wayland",
                    "WORKSPACE_COUNT=8",
                    "SCREENSHOT_UI_BINDINGS=('<Shift><Super>s')",
                    "SCREENSHOT_QUICK_BINDINGS=('Print')",
                    "SCREEN_RECORDING_BINDINGS=('<Shift><Super>r')",
                    "OVERVIEW_BINDINGS=('<Super>Tab')",
                    "WORKSPACE_SWITCH_BINDINGS=('1:<Super>Z' '2:<Super>X')",
                    "WORKSPACE_MOVE_BINDINGS=('1:<Super><Shift>z' '2:<Super><Shift>x')",
                    "SUPER_ARROW_MOVE_BINDINGS=('move-to-workspace-left:<Super><Shift>Left')",
                    "source lib/hotkeys_setup.sh",
                    "calls=$TARGET_HOME/gsettings.log",
                    "run_as_target() { \"$@\"; }",
                    "gsettings_key_exists() { return 0; }",
                    "user_gsettings() { printf '%s\\n' \"$*\" >> \"$calls\"; }",
                    "append_gsettings_list() { printf 'append %s %s %s\\n' \"$1\" \"$2\" \"$3\" >> \"$calls\"; }",
                    "remove_gsettings_list() { printf 'remove %s %s %s\\n' \"$1\" \"$2\" \"$3\" >> \"$calls\"; }",
                    "configure_screenshot_binding",
                    "configure_workspace_keys",
                    "grep -F \"set org.gnome.shell.keybindings show-screenshot-ui ['<Shift><Super>s']\" \"$calls\"",
                    "grep -F \"set org.gnome.desktop.wm.keybindings switch-to-workspace-1 ['<Super>Z']\" \"$calls\"",
                    "grep -F \"set org.gnome.desktop.wm.keybindings move-to-workspace-2 ['<Super><Shift>x']\" \"$calls\"",
                    "grep -F \"set org.gnome.mutter dynamic-workspaces false\" \"$calls\"",
                ]
            )
        )

    assert proc.returncode == 0, proc.stderr


def test_monitor_window_hotkey_assets_exist():
    """Transferred monitor/window hotkey extension and Ctrl+Back assets should exist."""
    extension_dir = ROOT_DIR / "configs" / "gnome-shell" / "extensions" / "monitor-window-hotkeys@local"
    assert (extension_dir / "extension.js").is_file()
    assert (extension_dir / "apply-system-bindings.sh").is_file()
    assert (extension_dir / "schemas" / "org.gnome.shell.extensions.monitor-window-hotkeys.gschema.xml").is_file()
    assert (ROOT_DIR / "configs" / "window-hotkeys" / "ctrl_back_tile_right.py").is_file()
    assert (ROOT_DIR / "configs" / "window-hotkeys" / "ctrl-back-window-tiler.service").is_file()


if __name__ == "__main__":
    tests = [t for name, t in sorted(globals().items()) if name.startswith("test_") and callable(t)]
    failed = 0
    for test_fn in tests:
        try:
            test_fn()
            print(f"  PASS: {test_fn.__doc__}")
        except Exception as exc:
            failed += 1
            print(f"  FAIL: {test_fn.__doc__} - {exc}")
    raise SystemExit(failed)
