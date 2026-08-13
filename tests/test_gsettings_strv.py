"""Installer contract: gsettings updates go through the Rust helper."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_installer_uses_rust_helper():
    helpers = (ROOT / "lib" / "gsettings_helpers.sh").read_text(encoding="utf-8")
    assert "lhs_bin" in helpers
    assert "gsettings_strv.py" not in helpers
    assert "python3" not in helpers
    assert (ROOT / "src" / "gsettings_strv.rs").is_file()
    assert (ROOT / "scripts" / "build_lhs_tools.sh").is_file()
