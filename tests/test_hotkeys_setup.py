#!/usr/bin/env python3
"""Tests for the standalone Ubuntu hotkeys setup helpers.

Components:
  - run_bash(): Execute bash snippets from the project root.
  - test_exports_expected_hotkey_functions(): Verifies the public helper API.
  - test_workspace_and_screenshot_bindings_are_applied(): Simulates GSettings
    calls without modifying the host system.
  - test_monitor_window_hotkey_assets_exist(): Verifies transferred extension assets.
  - test_apply_system_bindings_reassigns_super_vertical_arrows_to_half_tiling():
    Verifies Super+Up/Down are released from GNOME defaults for tiling.

Usage:
  python3 tests/test_hotkeys_setup.py
"""

from __future__ import annotations

import ast
import json
import os
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
                "declare -F configure_monitor_window_hotkeys_extension configure_automatic_window_tiling configure_workspace_number_popup_extension >/dev/null",
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


def test_automatic_window_tiling_is_delegated_to_sibling_repository():
    """Hotkey setup should call the standalone tiler with the configured binding."""
    setup = (ROOT_DIR / "lib" / "hotkeys_setup.sh").read_text(encoding="utf-8")
    extension = (
        ROOT_DIR
        / "configs"
        / "gnome-shell"
        / "extensions"
        / "monitor-window-hotkeys@local"
        / "extension.js"
    ).read_text(encoding="utf-8")

    assert "configure_automatic_window_tiling()" in setup
    assert 'bash "$installer" "$AUTOMATIC_WINDOW_TILING_BINDING"' in setup
    assert "AUTOMATIC_WINDOW_TILING_BINDING:=<Super>t" in setup
    assert "tileFocusedApplicationWindows" not in extension


def test_apply_system_bindings_reassigns_super_vertical_arrows_to_half_tiling():
    """System binding application should free Super+Up/Down for top/bottom tiling."""
    extension_dir = ROOT_DIR / "configs" / "gnome-shell" / "extensions" / "monitor-window-hotkeys@local"
    script_path = extension_dir / "apply-system-bindings.sh"

    with tempfile.TemporaryDirectory() as td:
        temp_dir = Path(td)
        bin_dir = temp_dir / "bin"
        bin_dir.mkdir()
        log_path = temp_dir / "gsettings.jsonl"
        state_path = temp_dir / "gsettings-state.json"

        fake_gsettings = bin_dir / "gsettings"
        fake_gsettings.write_text(
            """#!/usr/bin/env python3
import json
import os
import sys

STATE_PATH = os.environ["FAKE_GSETTINGS_STATE"]
LOG_PATH = os.environ["FAKE_GSETTINGS_LOG"]

DEFAULTS = {
    ("org.gnome.desktop.wm.keybindings", "maximize"): "['<Super>Up', '<Alt>F10']",
    ("org.gnome.desktop.wm.keybindings", "unmaximize"): "['<Super>Down', '<Alt>F5']",
    ("org.gnome.desktop.wm.keybindings", "minimize"): "['<Super>Down', '<Alt><Super>R']",
    ("org.gnome.shell", "enabled-extensions"): "[]",
    ("org.gnome.shell.extensions.tiling-assistant", "tile-maximize"): "['<Super>Up', '<Super>KP_5']",
    ("org.gnome.shell.extensions.tiling-assistant", "tile-top-half"): "[]",
    ("org.gnome.shell.extensions.tiling-assistant", "tile-bottom-half"): "[]",
    ("org.gnome.shell.extensions.tiling-assistant", "tile-left-half"): "[]",
    ("org.gnome.shell.extensions.tiling-assistant", "tile-right-half"): "[]",
}


def load_state():
    if not os.path.exists(STATE_PATH):
        return {}
    with open(STATE_PATH, "r", encoding="utf-8") as handle:
        return json.load(handle)


def save_state(state):
    with open(STATE_PATH, "w", encoding="utf-8") as handle:
        json.dump(state, handle)


def state_key(schema, key):
    return f"{schema}::{key}"


args = sys.argv[1:]
if args[:1] == ["--schemadir"]:
    args = args[2:]

if args == ["list-schemas"]:
    print("org.gnome.desktop.wm.keybindings")
    print("org.gnome.shell")
    print("org.gnome.shell.extensions.monitor-window-hotkeys")
    print("org.gnome.shell.extensions.tiling-assistant")
    raise SystemExit(0)

if args[:1] == ["reset-recursively"]:
    with open(LOG_PATH, "a", encoding="utf-8") as handle:
        handle.write(json.dumps({"cmd": "reset-recursively", "schema": args[1]}) + "\\n")
    raise SystemExit(0)

if args[:1] == ["get"]:
    schema, key = args[1], args[2]
    state = load_state()
    print(state.get(state_key(schema, key), DEFAULTS.get((schema, key), "[]")))
    raise SystemExit(0)

if args[:1] == ["set"]:
    schema, key, value = args[1], args[2], args[3]
    state = load_state()
    state[state_key(schema, key)] = value
    save_state(state)
    with open(LOG_PATH, "a", encoding="utf-8") as handle:
        handle.write(json.dumps({"cmd": "set", "schema": schema, "key": key, "value": value}) + "\\n")
    raise SystemExit(0)

raise SystemExit(f"unsupported fake gsettings args: {args}")
""",
            encoding="utf-8",
        )
        fake_gsettings.chmod(0o755)

        fake_compile_schemas = bin_dir / "glib-compile-schemas"
        fake_compile_schemas.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
        fake_compile_schemas.chmod(0o755)

        env = os.environ.copy()
        env["PATH"] = f"{bin_dir}:{env['PATH']}"
        env["FAKE_GSETTINGS_LOG"] = str(log_path)
        env["FAKE_GSETTINGS_STATE"] = str(state_path)
        proc = subprocess.run(
            ["bash", str(script_path)],
            cwd=ROOT_DIR,
            text=True,
            capture_output=True,
            check=False,
            env=env,
        )

        assert proc.returncode == 0, proc.stderr

        entries = [
            json.loads(line)
            for line in log_path.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]

    def latest_value(schema: str, key: str) -> str:
        """Return the last fake GSettings value written for a schema/key pair."""
        matches = [
            entry["value"]
            for entry in entries
            if entry.get("cmd") == "set" and entry.get("schema") == schema and entry.get("key") == key
        ]
        assert matches, f"No GSettings set recorded for {schema} {key}"
        return matches[-1]

    assert "<Super>Up" not in ast.literal_eval(
        latest_value("org.gnome.desktop.wm.keybindings", "maximize")
    )
    assert "<Super>Down" not in ast.literal_eval(
        latest_value("org.gnome.desktop.wm.keybindings", "unmaximize")
    )
    assert "<Super>Down" not in ast.literal_eval(
        latest_value("org.gnome.desktop.wm.keybindings", "minimize")
    )
    assert "<Super>Up" not in ast.literal_eval(
        latest_value("org.gnome.shell.extensions.tiling-assistant", "tile-top-half")
    )
    maximize_bindings = ast.literal_eval(
        latest_value("org.gnome.shell.extensions.tiling-assistant", "tile-maximize")
    )
    assert "<Super>Up" not in maximize_bindings
    assert "<Super>KP_5" in maximize_bindings
    schema = (
        extension_dir
        / "schemas"
        / "org.gnome.shell.extensions.monitor-window-hotkeys.gschema.xml"
    ).read_text(encoding="utf-8")
    assert "&lt;Super&gt;Up', '&lt;Control&gt;&lt;Super&gt;X" in schema
    assert "<Super>Down" not in ast.literal_eval(
        latest_value("org.gnome.shell.extensions.tiling-assistant", "tile-bottom-half")
    )
    right_bindings = ast.literal_eval(
        latest_value("org.gnome.shell.extensions.tiling-assistant", "tile-right-half")
    )
    assert "<Super>Right" not in right_bindings
    assert "<Control>XF86Back" not in right_bindings


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
