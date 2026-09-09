#!/usr/bin/env python3
"""Tests for the standalone Ubuntu hotkeys setup helpers.

Components:
  - run_bash(): Execute bash snippets from the project root.
  - test_exports_expected_hotkey_functions(): Verifies the public helper API.
  - test_workspace_and_screenshot_bindings_are_applied(): Simulates GSettings
    calls without modifying the host system.
  - test_ctrl_back_assets_exist(): Verifies the Rust tiler sources remain
    here after the monitor/window extension moved to its own repository.

Usage:
  python3 tests/test_hotkeys_setup.py
"""

from __future__ import annotations

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
                "declare -F configure_workspace_behavior configure_workspace_switch_1 configure_workspace_move_modifier >/dev/null",
                "declare -F configure_workspace_switch_field_1 configure_workspace_move_modifier_field >/dev/null",
                "declare -F configure_window_placement_tiling_service >/dev/null",
                "declare -F select_input_device isc_capture_hotkey >/dev/null",
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


def test_workspace_behavior_keeps_eight_static_workspaces_and_unbinds_add_keys():
    """The real workspace-behavior helper must pin 8 workspaces and unbind add keys.

    WORKSPACE_COUNT is left unset so the library default is the value under
    test. user_gsettings is stubbed; the real set_gsettings_strv writes empty
    arrays through that stub so the log is the actual apply path.
    """
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
                    "unset WORKSPACE_COUNT WORKSPACE_UI_COUNT",
                    "source lib/hotkeys_setup.sh",
                    "calls=$TARGET_HOME/gsettings.log",
                    "run_as_target() { \"$@\"; }",
                    "user_gsettings() { printf '%s\\n' \"$*\" >> \"$calls\"; }",
                    "configure_workspace_behavior",
                    "cat \"$calls\"",
                ]
            )
        )

    assert proc.returncode == 0, proc.stderr
    log = proc.stdout
    assert "set org.gnome.mutter dynamic-workspaces false" in log
    assert "set org.gnome.desktop.wm.preferences num-workspaces 8" in log
    assert "num-workspaces 9" not in log
    assert "num-workspaces 10" not in log
    for key in (
        "switch-to-workspace-last",
        "move-to-workspace-last",
        "switch-to-workspace-left",
        "switch-to-workspace-right",
        "switch-to-workspace-up",
        "switch-to-workspace-down",
    ):
        assert f"set org.gnome.desktop.wm.keybindings {key} []" in log
    for index in range(9, 13):
        assert f"set org.gnome.desktop.wm.keybindings switch-to-workspace-{index} []" in log
        assert f"set org.gnome.desktop.wm.keybindings move-to-workspace-{index} []" in log
    # Super+Shift+Arrow window-move bindings stay assigned, not cleared.
    assert "set org.gnome.desktop.wm.keybindings move-to-workspace-left []" not in log
    assert "set org.gnome.desktop.wm.keybindings move-to-workspace-right []" not in log


def test_workspace_hotkeys_expose_typed_fields_and_one_move_modifier():
    """Switch fields are individually editable while move uses one modifier."""
    configurable = subprocess.run(
        ["bash", "install.sh", "--list-configurable-components"],
        cwd=ROOT_DIR, text=True, capture_output=True, check=False,
    )
    values = subprocess.run(
        ["bash", "install.sh", "--list-component-config-values"],
        cwd=ROOT_DIR, text=True, capture_output=True, check=False,
    )
    assert configurable.returncode == values.returncode == 0
    assert configurable.stdout.splitlines() == [
        *(f"workspace_switch_{index}" for index in range(1, 9)),
        "workspace_move_modifier",
    ]
    assert "workspace_switch_6\tSuper+W" in values.stdout
    assert "workspace_switch_9" not in configurable.stdout
    assert "workspace_move_modifier\tShift" in values.stdout


def test_numbered_workspace_hotkeys_use_switch_rows_and_one_move_modifier():
    """Discovery exposes eight switch fields without duplicated move rows."""
    proc = subprocess.run(
        ["bash", "install.sh", "--list-components"],
        cwd=ROOT_DIR,
        text=True,
        capture_output=True,
        check=False,
    )

    assert proc.returncode == 0, proc.stderr
    rows = [line.split("\t") for line in proc.stdout.splitlines()]
    ids = [row[0] for row in rows]
    assert "workspace_keys" not in ids
    assert "workspace_behavior" in ids
    assert [item for item in ids if item.startswith("workspace_switch_")] == [
        f"workspace_switch_{index}" for index in range(1, 9)
    ]
    assert "workspace_switch_9" not in ids
    assert [item for item in ids if item.startswith("workspace_move_")] == [
        "workspace_move_modifier"
    ]
    assert all(len(row) >= 4 for row in rows if row[0].startswith("workspace_"))


def test_individual_workspace_component_changes_only_its_binding():
    """A numbered component must not reconfigure any sibling workspace key."""
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
                "set_gsettings_strv() { calls+=(\"$*\"); }",
                "configure_workspace_switch_2",
                "printf '%s\\n' \"${calls[@]}\"",
            ]
        )
    )

    assert proc.returncode == 0, proc.stderr
    calls = [line for line in proc.stdout.splitlines() if line.startswith("org.gnome.")]
    assert calls == [
        "org.gnome.desktop.wm.keybindings switch-to-workspace-2 <Super>X",
        "org.gnome.desktop.wm.keybindings move-to-workspace-2 <Super><Shift>x",
    ]


def test_selected_workspace_component_installs_with_detached_stdin(tmp_path):
    """Master-style --select must apply one row without reading from stdin."""
    bin_dir = tmp_path / "bin"
    state_dir = tmp_path / "state"
    calls = tmp_path / "gsettings.log"
    bin_dir.mkdir()
    fake_gsettings = bin_dir / "gsettings"
    fake_gsettings.write_text(
        "#!/usr/bin/env bash\n"
        f"printf '%s\\n' \"$*\" >> {str(calls)!r}\n"
        "case \"$1\" in get) printf '%s\\n' '@as []';; esac\n",
        encoding="utf-8",
    )
    fake_gsettings.chmod(0o755)
    env = os.environ.copy()
    env.update(
        {
            "PATH": f"{bin_dir}:{env['PATH']}",
            "XDG_STATE_HOME": str(state_dir),
            "WORKSPACE_SWITCH_2": "<Alt><Super>2",
        }
    )
    proc = subprocess.run(
        ["bash", "install.sh", "--select", "workspace_behavior,workspace_switch_2"],
        cwd=ROOT_DIR,
        text=True,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        check=False,
        env=env,
    )

    assert proc.returncode == 0, proc.stderr
    mutations = calls.read_text(encoding="utf-8").splitlines()
    assert any(
        "set org.gnome.desktop.wm.keybindings switch-to-workspace-2 "
        "['<Alt><Super>2']" in line
        for line in mutations
    )
    assert not any("switch-to-workspace-1 " in line for line in mutations)
    assert any(
        "set org.gnome.desktop.wm.keybindings move-to-workspace-2 "
        "['<Alt><Super><Shift>2']" in line
        for line in mutations
    )
    assert not any("move-to-workspace-1 " in line for line in mutations)
    assert (state_dir / "isc/receipts/linux_hotkey_setup/workspace_switch_2").is_file()


def test_move_modifier_derives_moves_without_overriding_switches():
    """One Ctrl modifier derives moves and Super is rejected for Super switches."""
    proc = run_bash(
        "\n".join(
            [
                "set -euo pipefail",
                f"SCRIPT_DIR={str(ROOT_DIR)!r}",
                f"CONFIG_DIR={str(ROOT_DIR / 'configs')!r}",
                "TARGET_USER=$(id -un)",
                "TARGET_HOME=/tmp/ubuntu-hotkeys-test-home",
                "WORKSPACE_UI_COUNT=2",
                "WORKSPACE_MOVE_MODIFIER=Control",
                "source lib/hotkeys_setup.sh",
                "calls=()",
                "set_gsettings_strv() { calls+=(\"$*\"); }",
                "configure_workspace_move_modifier",
                "printf '%s\\n' \"${calls[@]}\"",
                "if workspace_validate_move_modifier Super; then exit 9; fi",
            ]
        )
    )
    assert proc.returncode == 0, proc.stderr
    assert "org.gnome.desktop.wm.keybindings move-to-workspace-1 <Control><Super>z" in proc.stdout
    assert "org.gnome.desktop.wm.keybindings move-to-workspace-2 <Control><Super>x" in proc.stdout
    assert "already used" in proc.stderr


def test_workspace_behavior_migrates_combined_component_receipt():
    """Applying the split behavior component removes legacy workspace_keys state."""
    proc = run_bash(
        "\n".join(
            [
                "set -euo pipefail",
                f"SCRIPT_DIR={str(ROOT_DIR)!r}",
                f"CONFIG_DIR={str(ROOT_DIR / 'configs')!r}",
                "TARGET_USER=$(id -un)",
                "TARGET_HOME=/tmp/ubuntu-hotkeys-test-home",
                "source lib/hotkeys_setup.sh",
                "cleared=()",
                "_isc_clear_receipt() { cleared+=(\"$1\"); }",
                "user_gsettings() { :; }",
                "set_gsettings_strv() { :; }",
                "configure_workspace_behavior",
                "printf '%s\\n' \"${cleared[@]}\"",
            ]
        )
    )

    assert proc.returncode == 0, proc.stderr
    assert proc.stdout.splitlines()[-10:] == [
        "workspace_keys",
        *(f"workspace_move_{index}" for index in range(1, 10)),
    ]


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


def test_ctrl_back_assets_exist():
    """The Ctrl+Back window placement tiling assets remain in this repo.

    The monitor/window hotkeys extension itself now lives in the standalone
    linux_monitor_window_hotkeys repository; only the Ctrl+Back tiler service
    (which drives that extension's D-Bus tiling) stays here.
    """
    assert (ROOT_DIR / "src" / "tiler.rs").is_file()
    assert (ROOT_DIR / "src" / "main.rs").is_file()
    assert not (ROOT_DIR / "configs" / "window-hotkeys" / "ctrl_back_tile_right.py").exists()
    assert not (ROOT_DIR / "configs" / "window-hotkeys" / "hotkey_logging_utils.py").exists()


def test_monitor_window_extension_no_longer_bundled_here():
    """The monitor/window hotkeys extension was extracted to its own repository."""
    assert not (
        ROOT_DIR / "configs" / "gnome-shell" / "extensions" / "monitor-window-hotkeys@local"
    ).exists()
    manifest = (ROOT_DIR / "installer" / "components.sh").read_text(encoding="utf-8")
    setup = (ROOT_DIR / "lib" / "hotkeys_setup.sh").read_text(encoding="utf-8")
    assert "monitor_window_hotkeys|" not in manifest
    assert "configure_monitor_window_hotkeys_extension" not in setup
    readme = (ROOT_DIR / "README.md").read_text(encoding="utf-8")
    agents = (ROOT_DIR / "AGENTS.md").read_text(encoding="utf-8")
    assert "monitor-window-hotkeys@local" not in readme
    assert "monitor-window-hotkeys@local" not in agents
    assert "| `monitor_window_hotkeys`" not in readme
    assert "MONITOR_MOVE_" not in readme
    assert "MONITOR_MOVE_" not in agents
    assert "apply-system-bindings.sh" not in readme
    assert "apply-system-bindings.sh" not in agents
    assert "CONFIG_DIR=" not in (ROOT_DIR / "install.sh").read_text(encoding="utf-8")
    assert "HOTKEYS_SETUP_CONFIG_DIR=" not in setup


def test_gsettings_list_mutation_uses_extracted_helper():
    helpers = (ROOT_DIR / "lib/gsettings_helpers.sh").read_text(encoding="utf-8")
    assert "lhs_bin" in helpers
    assert "gsettings_strv.py" not in helpers
    assert "python3" not in helpers


def test_numbered_workspace_popup_moved_to_workspaces_repo():
    """The numbered workspace popup is owned by linux_workspaces_setup now."""
    setup = (ROOT_DIR / "lib" / "hotkeys_setup.sh").read_text(encoding="utf-8")
    manifest = (ROOT_DIR / "installer" / "components.sh").read_text(encoding="utf-8")
    assert "configure_workspace_number_popup_extension" not in setup
    assert "workspace_popup|" not in manifest
    assert not (ROOT_DIR / "lib" / "workspace_popup.sh").exists()


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
                "lhs_bin() {",
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
                "lhs_bin() { return 0; }",
                "if select_input_device; then",
                "  exit 1",
                "fi",
            ]
        )
    )

    assert proc.returncode == 0, proc.stderr
    assert "tiler service will be skipped" in proc.stdout


def test_window_placement_tiling_installs_script_and_configured_trigger():
    """Tiling setup installs lhs-tools and the service with the captured trigger."""
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
                    "ensure_lhs_bin() {",
                    "  LHS_BIN=$TARGET_HOME/stub-lhs-tools",
                    "  printf '#!/bin/sh\\n' > \"$LHS_BIN\"",
                    "  chmod +x \"$LHS_BIN\"",
                    "}",
                    "run_as_target() { \"$@\"; }",
                    "is_root() { return 1; }",
                    "reload_systemd_daemon() { printf 'reload\\n' >> \"$calls\"; }",
                    "enable_systemd_service() { printf 'enable %s\\n' \"$1\" >> \"$calls\"; }",
                    "configure_window_placement_tiling_service",
                ]
            )
        )

        assert proc.returncode == 0, proc.stderr
        bin_target = home / ".local" / "bin" / "lhs-tools"
        service_target = (
            home
            / ".config"
            / "systemd"
            / "user"
            / "window-placement-tiling.service"
        )
        service = service_target.read_text(encoding="utf-8")
        calls = (home / "systemd.log").read_text(encoding="utf-8").splitlines()

        assert bin_target.is_file()
        assert bin_target.stat().st_mode & 0o111
        assert not (home / ".local" / "bin" / "ctrl_back_tile_right.py").exists()
        assert not (home / ".local" / "bin" / "hotkey_logging_utils.py").exists()
        assert f"ExecStart={bin_target} tiler" in service
        assert (
            "Environment=CTRL_BACK_TILE_DEVICE="
            "/dev/input/by-id/primary-event-mouse"
        ) in service
        # Default captured trigger (non-interactive) is Ctrl + mouse Back.
        assert "Environment=WINDOW_PLACEMENT_TILE_MODIFIER=Control" in service
        assert "Environment=WINDOW_PLACEMENT_TILE_BUTTON=BTN_BACK" in service
        assert "StartLimitIntervalSec=60" in service
        assert "StartLimitBurst=3" in service
        assert "MemoryHigh=32M" in service
        assert "MemoryMax=64M" in service
        assert "MemorySwapMax=0" in service
        assert calls == ["reload", "enable window-placement-tiling.service"]


def test_window_placement_tiling_migrates_legacy_unit():
    """Installing the renamed service removes the legacy ctrl-back unit."""
    with tempfile.TemporaryDirectory() as td:
        home = Path(td) / "home"
        legacy = home / ".config" / "systemd" / "user" / "ctrl-back-window-tiler.service"
        legacy.parent.mkdir(parents=True)
        legacy.write_text("[Service]\n", encoding="utf-8")
        proc = run_bash(
            "\n".join(
                [
                    "set -euo pipefail",
                    f"SCRIPT_DIR={str(ROOT_DIR)!r}",
                    f"CONFIG_DIR={str(ROOT_DIR / 'configs')!r}",
                    f"TARGET_HOME={str(home)!r}",
                    "TARGET_USER=$(id -un)",
                    "SELECTED_INPUT_DEVICE=/dev/input/by-id/primary-event-mouse",
                    "source lib/hotkeys_setup.sh",
                    "ensure_lhs_bin() {",
                    "  LHS_BIN=$TARGET_HOME/stub-lhs-tools",
                    "  printf '#!/bin/sh\\n' > \"$LHS_BIN\"",
                    "  chmod +x \"$LHS_BIN\"",
                    "}",
                    "run_as_target() { \"$@\"; }",
                    "is_root() { return 1; }",
                    "reload_systemd_daemon() { :; }",
                    "enable_systemd_service() { :; }",
                    "configure_window_placement_tiling_service",
                ]
            )
        )

        assert proc.returncode == 0, proc.stderr
        assert not legacy.exists()
        assert (
            home / ".config" / "systemd" / "user" / "window-placement-tiling.service"
        ).exists()


def test_window_placement_tiling_skips_cleanly_when_no_device():
    """With no suitable pointer the tiling component is a clean skip, not a failure."""
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
                    "lhs_bin() { return 0; }",
                    "configure_window_placement_tiling_service",
                ]
            )
        )

        assert proc.returncode == 0, proc.stderr
        assert not (
            home / ".config" / "systemd" / "user" / "window-placement-tiling.service"
        ).exists()


def test_components_manifest_renames_tiler_and_drops_moved_components():
    """The manifest exposes window_placement_tiling and no moved-out components."""
    manifest = (ROOT_DIR / "installer" / "components.sh").read_text(encoding="utf-8")
    assert 'ISC_PREFLIGHT="select_input_device"' not in manifest
    assert "window_placement_tiling|" in manifest
    assert "ctrl_back_tiler|" not in manifest
    # Automatic tiling, pointer move/resize, and the popup are their own repos.
    assert "automatic_window_tiling|" not in manifest
    assert "hotkey_window_tools|" not in manifest
    assert "workspace_popup|" not in manifest


def test_moved_out_features_are_not_configured_here():
    """The delegators for tiling / pointer tools were removed from this repo."""
    setup = (ROOT_DIR / "lib" / "hotkeys_setup.sh").read_text(encoding="utf-8")
    assert "configure_automatic_window_tiling" not in setup
    assert "configure_hotkey_window_tools" not in setup


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
