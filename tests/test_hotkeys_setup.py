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


HELPERS = ROOT_DIR.parent / "linux_installation_scripts_functions" / "installer_helpers.sh"


def run_bash(script: str) -> subprocess.CompletedProcess[str]:
    """Run a bash snippet from the project root.

    The shared install-time helpers (run_as_target, msg, need_cmd, …) now live in
    the framework and are loaded by install.sh before lib/hotkeys_setup.sh, so the
    harness sources them too. Snippets may still override individual helpers.

    Args:
        script: Bash source to execute.

    Returns:
        CompletedProcess with stdout, stderr, and return code.
    """
    full = f'source {str(HELPERS)!r}\n{script}'
    return subprocess.run(
        ["bash", "-c", full],
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
                "declare -F configure_screenshot_binding configure_workspace_keys >/dev/null",
                "declare -F configure_monitor_window_hotkeys_extension configure_automatic_window_tiling configure_workspace_number_popup_extension >/dev/null",
                "declare -F configure_hotkey_window_tools configure_ctrl_back_window_tiler_service >/dev/null",
                "declare -F select_input_device >/dev/null",
            ]
        )
    )

    assert proc.returncode == 0, proc.stderr


def test_gsettings_helpers_preserve_array_values_and_optional_keys():
    """GSettings helpers should format arrays and skip unavailable keys."""
    proc = run_bash(
        "\n".join(
            [
                "set -euo pipefail",
                f"SCRIPT_DIR={str(ROOT_DIR)!r}",
                f"CONFIG_DIR={str(ROOT_DIR / 'configs')!r}",
                "TARGET_USER=$(id -un)",
                "TARGET_HOME=/tmp/ubuntu-hotkeys-test-home",
                "source lib/hotkeys_setup.sh",
                "calls=()",
                "user_gsettings() { calls+=(\"$*\"); }",
                "gsettings_key_exists() { [ \"$2\" = available ]; }",
                "set_gsettings_strv org.example bindings '<Super>A' \"quote'key\"",
                "set_gsettings_strv_if_key_exists org.example missing '<Super>B'",
                "set_gsettings_strv_if_key_exists org.example available '<Super>C'",
                "set_indexed_keybinding_map org.example item- '1:<Super>X' '2:<Super>Y'",
                "printf '%s\\n' \"${calls[@]}\"",
            ]
        )
    )

    assert proc.returncode == 0, proc.stderr
    assert proc.stdout.splitlines() == [
        "set org.example bindings ['<Super>A', 'quote\\'key']",
        "set org.example available ['<Super>C']",
        "set org.example item-1 ['<Super>X']",
        "set org.example item-2 ['<Super>Y']",
    ]


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


def test_detect_workspace_keys_requires_configured_bindings():
    """GNOME default workspace bindings must not count as this component."""
    proc = run_bash(
        "\n".join(
            [
                "set -euo pipefail",
                f"SCRIPT_DIR={str(ROOT_DIR)!r}",
                f"CONFIG_DIR={str(ROOT_DIR / 'configs')!r}",
                "TARGET_USER=$(id -un)",
                "TARGET_HOME=/tmp/ubuntu-hotkeys-test-home",
                "WORKSPACE_SWITCH_BINDINGS=('1:<Super>Z' '2:<Super>X')",
                "WORKSPACE_MOVE_BINDINGS=('1:<Super><Shift>z' '2:<Super><Shift>x')",
                "source lib/hotkeys_setup.sh",
                "source lib/lifecycle.sh",
                "run_as_target() {",
                "  if [ \"$1\" = gsettings ] && [ \"$2\" = get ]; then",
                "    case \"$3 $4\" in",
                "      'org.gnome.desktop.wm.keybindings switch-to-workspace-1') printf \"['<Super>1']\\n\" ;;",
                "      'org.gnome.desktop.wm.keybindings move-to-workspace-1') printf \"[]\\n\" ;;",
                "      'org.gnome.desktop.wm.keybindings switch-to-workspace-2') printf \"[]\\n\" ;;",
                "      'org.gnome.desktop.wm.keybindings move-to-workspace-2') printf \"[]\\n\" ;;",
                "      *) printf \"[]\\n\" ;;",
                "    esac",
                "  fi",
                "}",
                "if detect_workspace_keys; then exit 1; fi",
            ]
        )
    )

    assert proc.returncode == 0, proc.stderr


def test_detect_workspace_keys_accepts_configured_bindings():
    """The workspace component is installed only when configured bindings match."""
    proc = run_bash(
        "\n".join(
            [
                "set -euo pipefail",
                f"SCRIPT_DIR={str(ROOT_DIR)!r}",
                f"CONFIG_DIR={str(ROOT_DIR / 'configs')!r}",
                "TARGET_USER=$(id -un)",
                "TARGET_HOME=/tmp/ubuntu-hotkeys-test-home",
                "WORKSPACE_SWITCH_BINDINGS=('1:<Super>Z' '2:<Super>X')",
                "WORKSPACE_MOVE_BINDINGS=('1:<Super><Shift>z' '2:<Super><Shift>x')",
                "source lib/hotkeys_setup.sh",
                "source lib/lifecycle.sh",
                "run_as_target() {",
                "  if [ \"$1\" = gsettings ] && [ \"$2\" = get ]; then",
                "    case \"$3 $4\" in",
                "      'org.gnome.desktop.wm.keybindings switch-to-workspace-1') printf \"['<Super>Z']\\n\" ;;",
                "      'org.gnome.desktop.wm.keybindings move-to-workspace-1') printf \"['<Super><Shift>z']\\n\" ;;",
                "      'org.gnome.desktop.wm.keybindings switch-to-workspace-2') printf \"['<Super>X']\\n\" ;;",
                "      'org.gnome.desktop.wm.keybindings move-to-workspace-2') printf \"['<Super><Shift>x']\\n\" ;;",
                "      *) printf \"[]\\n\" ;;",
                "    esac",
                "  fi",
                "}",
                "detect_workspace_keys",
            ]
        )
    )

    assert proc.returncode == 0, proc.stderr


def test_monitor_window_hotkey_assets_exist():
    """Transferred monitor/window hotkey extension and Ctrl+Back assets should exist."""
    extension_dir = ROOT_DIR / "configs" / "gnome-shell" / "extensions" / "monitor-window-hotkeys@local"
    assert (extension_dir / "extension.js").is_file()
    assert (extension_dir / "apply-system-bindings.sh").is_file()
    assert (extension_dir / "gsettings-strv.py").is_file()
    assert (extension_dir / "schemas" / "org.gnome.shell.extensions.monitor-window-hotkeys.gschema.xml").is_file()
    assert (ROOT_DIR / "configs" / "window-hotkeys" / "ctrl_back_tile_right.py").is_file()
    assert (ROOT_DIR / "configs" / "window-hotkeys" / "hotkey_logging_utils.py").is_file()
    assert (ROOT_DIR / "configs" / "window-hotkeys" / "ctrl-back-window-tiler.service").is_file()


def test_gsettings_list_mutation_uses_extracted_helper():
    helpers = (ROOT_DIR / "lib/gsettings_helpers.sh").read_text(encoding="utf-8")
    apply_bindings = (
        ROOT_DIR
        / "configs"
        / "gnome-shell"
        / "extensions"
        / "monitor-window-hotkeys@local"
        / "apply-system-bindings.sh"
    ).read_text(encoding="utf-8")

    assert "gsettings_strv.py" in helpers
    assert "python3 - <<'PY'" not in helpers
    assert "gsettings-strv.py" in apply_bindings
    assert "python3 - <<'PY'" not in apply_bindings


def test_workspace_number_popup_extension_writes_expected_assets():
    """Workspace popup setup should install assets and remove its legacy extension."""
    with tempfile.TemporaryDirectory() as td:
        home = Path(td) / "home"
        old_extension_dir = (
            home
            / ".local"
            / "share"
            / "gnome-shell"
            / "extensions"
            / "workspace-number-popup@local"
        )
        old_extension_dir.mkdir(parents=True)
        (old_extension_dir / "metadata.json").write_text(
            '{"name": "Numbered Workspace Popup"}\n',
            encoding="utf-8",
        )

        proc = run_bash(
            "\n".join(
                [
                    "set -euo pipefail",
                    f"SCRIPT_DIR={str(ROOT_DIR)!r}",
                    f"CONFIG_DIR={str(ROOT_DIR / 'configs')!r}",
                    f"TARGET_HOME={str(home)!r}",
                    "TARGET_USER=$(id -un)",
                    "SESSION_TYPE=wayland",
                    "source lib/hotkeys_setup.sh",
                    "calls=$TARGET_HOME/workspace-popup.log",
                    "run_as_target() { \"$@\"; }",
                    "remove_gsettings_list() { printf 'remove %s %s %s\\n' \"$1\" \"$2\" \"$3\" >> \"$calls\"; }",
                    "enable_shell_extension() { printf 'enable %s\\n' \"$1\" >> \"$calls\"; }",
                    "configure_workspace_number_popup_extension",
                ]
            )
        )

        assert proc.returncode == 0, proc.stderr
        extension_dir = (
            home
            / ".local"
            / "share"
            / "gnome-shell"
            / "extensions"
            / "workspace-number-indicator@local"
        )
        metadata = json.loads(
            (extension_dir / "metadata.json").read_text(encoding="utf-8")
        )
        extension = (extension_dir / "extension.js").read_text(encoding="utf-8")
        stylesheet = (extension_dir / "stylesheet.css").read_text(encoding="utf-8")
        calls = (home / "workspace-popup.log").read_text(encoding="utf-8")

        assert metadata["uuid"] == "workspace-number-indicator@local"
        assert metadata["shell-version"] == ["45", "46", "47", "48", "49", "50"]
        assert "NumberedWorkspacePopupExtension" in extension
        assert "workspace-number-popup-indicator" in stylesheet
        assert (
            "remove org.gnome.shell enabled-extensions "
            "workspace-number-popup@local"
        ) in calls
        assert "enable workspace-number-indicator@local" in calls
        assert not old_extension_dir.exists()


def test_ctrl_back_device_selection_uses_first_device_non_interactively():
    """Ctrl+Back setup should auto-select the first detected device without a TTY."""
    proc = run_bash(
        "\n".join(
            [
                "set -euo pipefail",
                f"SCRIPT_DIR={str(ROOT_DIR)!r}",
                f"CONFIG_DIR={str(ROOT_DIR / 'configs')!r}",
                "TARGET_USER=$(id -un)",
                "TARGET_HOME=/tmp/ubuntu-hotkeys-test-home",
                "source lib/hotkeys_setup.sh",
                "python3() {",
                "  printf '%s\\n' '/dev/input/by-id/first-event-mouse|First Mouse' '/dev/input/by-id/second-event-mouse|Second Mouse'",
                "}",
                "select_input_device",
                "printf '%s|%s\\n' \"$SELECTED_INPUT_DEVICE\" \"$SELECTED_INPUT_DEVICE_NAME\"",
            ]
        )
    )

    assert proc.returncode == 0, proc.stderr
    assert proc.stdout.splitlines()[-1] == (
        "/dev/input/by-id/first-event-mouse|First Mouse"
    )


def test_ctrl_back_device_selection_fails_when_no_device_is_detected():
    """Ctrl+Back setup should report failure when no suitable pointer exists."""
    proc = run_bash(
        "\n".join(
            [
                "set -euo pipefail",
                f"SCRIPT_DIR={str(ROOT_DIR)!r}",
                f"CONFIG_DIR={str(ROOT_DIR / 'configs')!r}",
                "TARGET_USER=$(id -un)",
                "TARGET_HOME=/tmp/ubuntu-hotkeys-test-home",
                "source lib/hotkeys_setup.sh",
                "python3() { return 0; }",
                "if select_input_device; then",
                "  exit 1",
                "fi",
            ]
        )
    )

    assert proc.returncode == 0, proc.stderr
    assert "tiler service will be skipped" in proc.stdout


def test_ctrl_back_service_installs_script_and_selected_device():
    """Ctrl+Back setup should install its script, logger, and user service."""
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
                    "source lib/hotkeys_setup.sh",
                    "calls=$TARGET_HOME/systemd.log",
                    "SELECTED_INPUT_DEVICE=/dev/input/by-id/primary-event-mouse",
                    "run_as_target() { \"$@\"; }",
                    "is_root() { return 1; }",
                    "reload_systemd_daemon() { printf 'reload\\n' >> \"$calls\"; }",
                    "enable_systemd_service() { printf 'enable %s\\n' \"$1\" >> \"$calls\"; }",
                    "configure_ctrl_back_window_tiler_service",
                ]
            )
        )

        assert proc.returncode == 0, proc.stderr
        script_target = home / ".local" / "bin" / "ctrl_back_tile_right.py"
        service_target = (
            home
            / ".config"
            / "systemd"
            / "user"
            / "ctrl-back-window-tiler.service"
        )
        service = service_target.read_text(encoding="utf-8")
        calls = (home / "systemd.log").read_text(encoding="utf-8").splitlines()

        assert script_target.read_bytes() == (
            ROOT_DIR / "configs" / "window-hotkeys" / "ctrl_back_tile_right.py"
        ).read_bytes()
        logging_target = home / ".local" / "bin" / "hotkey_logging_utils.py"
        assert logging_target.read_bytes() == (
            ROOT_DIR / "configs" / "window-hotkeys" / "hotkey_logging_utils.py"
        ).read_bytes()
        assert not logging_target.stat().st_mode & 0o111
        assert script_target.stat().st_mode & 0o111
        assert f"ExecStart={script_target}" in service
        assert (
            "Environment=CTRL_BACK_TILE_DEVICE="
            "/dev/input/by-id/primary-event-mouse"
        ) in service
        assert calls == ["reload", "enable ctrl-back-window-tiler.service"]


def test_ctrl_back_component_self_selects_device_when_unset():
    """The tiler component should detect a device itself, not via a global preflight."""
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
                    "source lib/hotkeys_setup.sh",
                    "python3() {",
                    "  printf '%s\\n' '/dev/input/by-id/auto-event-mouse|Auto Mouse'",
                    "}",
                    "run_as_target() { \"$@\"; }",
                    "is_root() { return 1; }",
                    "reload_systemd_daemon() { :; }",
                    "enable_systemd_service() { :; }",
                    "configure_ctrl_back_window_tiler_service",
                ]
            )
        )

        assert proc.returncode == 0, proc.stderr
        service = (
            home / ".config" / "systemd" / "user" / "ctrl-back-window-tiler.service"
        ).read_text(encoding="utf-8")
        assert (
            "Environment=CTRL_BACK_TILE_DEVICE=/dev/input/by-id/auto-event-mouse"
        ) in service


def test_ctrl_back_component_skips_cleanly_when_no_device():
    """With no suitable pointer the tiler component is a clean skip, not a failure."""
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
                    "source lib/hotkeys_setup.sh",
                    "python3() { return 0; }",
                    "configure_ctrl_back_window_tiler_service",
                ]
            )
        )

        assert proc.returncode == 0, proc.stderr
        assert not (
            home / ".config" / "systemd" / "user" / "ctrl-back-window-tiler.service"
        ).exists()


def test_components_manifest_has_no_global_device_preflight():
    """Device selection must stay inside the tiler component, not a global preflight."""
    manifest = (ROOT_DIR / "installer" / "components.sh").read_text(encoding="utf-8")
    assert 'ISC_PREFLIGHT="select_input_device"' not in manifest
    assert "ctrl_back_tiler|" in manifest


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


def test_hotkey_window_tools_delegation_runs_non_interactively():
    """The delegated tools installer must run with --default, never the menu.

    linux_hotkey_window_tools is component-aware, so invoking it with no
    selection flag would open its interactive submenu on the parent installer's
    inherited TTY and block the whole master run.
    """
    setup = (ROOT_DIR / "lib" / "hotkeys_setup.sh").read_text(encoding="utf-8")

    assert "configure_hotkey_window_tools()" in setup
    assert 'bash "$installer" --default' in setup


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
