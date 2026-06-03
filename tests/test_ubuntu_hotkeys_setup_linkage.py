#!/usr/bin/env python3
"""Regression tests for installation_scripts to linux_hotkey_setup linkage.

Components:
  - test_install_sh_sources_hotkeys_from_submodule(): Verifies the installer
    sources hotkeys_setup.sh directly from the git submodule path.
  - test_install_sh_uses_git_submodule(): Verifies install.sh initializes the
    linux_hotkey_setup git submodule instead of cloning it as a regular repo.
  - test_install_sh_has_no_delegation_wrapper(): Verifies the old delegation
    wrapper (lib/linux_hotkey_setup.sh) has been removed.
  - test_install_sh_does_not_clone_linux_hotkey_setup(): Verifies install.sh
    no longer lists linux_hotkey_setup in CLONE_REPOS.
  - test_hotkey_assets_are_in_submodule(): Verifies hotkey extension and
    Ctrl+Back assets live inside the linux_hotkey_setup submodule.

Usage:
  python3 tests/test_ubuntu_hotkeys_setup_linkage.py
"""

from __future__ import annotations

from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parent.parent


def test_install_sh_sources_hotkeys_from_submodule():
    """install.sh should source hotkeys_setup.sh directly from the submodule."""
    source = (ROOT_DIR / "install.sh").read_text(encoding="utf-8")

    assert 'source "$SCRIPT_DIR/linux_hotkey_setup/lib/hotkeys_setup.sh"' in source
    assert 'git -c protocol.file.allow=always submodule update --init linux_hotkey_setup' in source


def test_install_sh_uses_git_submodule():
    """install.sh should initialize the git submodule, not clone via CLONE_REPOS."""
    source = (ROOT_DIR / "install.sh").read_text(encoding="utf-8")

    assert '["mikaeltorni/linux_hotkey_setup"]' not in source
    # Verify .gitmodules exists and references linux_hotkey_setup
    gitmodules = (ROOT_DIR / ".gitmodules").read_text(encoding="utf-8")
    assert "linux_hotkey_setup" in gitmodules


def test_install_sh_has_no_delegation_wrapper():
    """The old delegation wrapper lib/linux_hotkey_setup.sh should not exist."""
    assert not (ROOT_DIR / "lib" / "linux_hotkey_setup.sh").exists()


def test_install_sh_does_not_clone_linux_hotkey_setup():
    """install.sh should no longer list linux_hotkey_setup in CLONE_REPOS."""
    source = (ROOT_DIR / "install.sh").read_text(encoding="utf-8")

    assert 'UBUNTU_HOTKEYS_SETUP_DIR' not in source


def test_hotkey_assets_are_in_submodule():
    """Hotkey extension and Ctrl+Back assets should live inside the submodule."""
    submodule_dir = ROOT_DIR / "linux_hotkey_setup"
    assert (submodule_dir / "lib" / "hotkeys_setup.sh").is_file()
    assert (submodule_dir / "configs" / "gnome-shell" / "extensions" / "monitor-window-hotkeys@local" / "extension.js").is_file()
    assert (submodule_dir / "configs" / "window-hotkeys" / "ctrl_back_tile_right.py").is_file()


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
