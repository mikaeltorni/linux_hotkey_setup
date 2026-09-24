#!/usr/bin/env python3
"""Tests for the --features/FEATURES selection forwarded to the component runtime.

Components:
  - test_install_forwards_every_requested_feature(): install.sh must hand the
    whole FEATURES list to component_main, not just its first element.
  - test_runtime_splits_comma_separated_selection(): the shared component
    runtime really does accept a comma-separated id list, which is what makes
    forwarding the raw list correct.

Usage:
  python3 tests/test_feature_selection.py
"""

from __future__ import annotations

import re
import subprocess
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent


def _shared_runtime() -> Path:
    """Locate the sibling framework from a live checkout or nested worktree."""
    for parent in ROOT_DIR.parents:
        runtime = parent / "linux_installation_scripts_functions" / "component_runtime.sh"
        if runtime.is_file():
            return runtime
    return ROOT_DIR.parent / "linux_installation_scripts_functions" / "component_runtime.sh"


RUNTIME = _shared_runtime()


def test_install_forwards_every_requested_feature() -> None:
    """install.sh must not truncate a multi-feature FEATURES request."""
    text = (ROOT_DIR / "install.sh").read_text(encoding="utf-8")
    select_calls = re.findall(r'component_main "--select=([^"]*)"', text)
    assert select_calls, "no component_main --select call found in install.sh"
    for call in select_calls:
        assert "FEATURE_ARRAY[0]" not in call, (
            f"install.sh forwards only the first feature ({call!r}); "
            "every id in FEATURES must reach the component runtime"
        )
    assert "$SELECTED_FEATURES" in select_calls, (
        f"expected the full FEATURES list to be forwarded, got {select_calls!r}"
    )


def test_runtime_splits_comma_separated_selection() -> None:
    """The component runtime treats 'a,b' as two ids, so forwarding raw is safe."""
    script = f"""
    set -euo pipefail
    msg() {{ printf '%s\\n' "$*"; }}
    isc_log_info() {{ :; }}; isc_log_debug() {{ :; }}
    isc_log_warn() {{ :; }}; isc_log_error() {{ :; }}
    source {RUNTIME!s}
    ISC_REPO_NAME=test
    ISC_COMPONENTS=(
      "alpha|Alpha|on|install_alpha"
      "beta|Beta|on|install_beta"
    )
    install_alpha() {{ printf 'RAN:alpha\\n'; }}
    install_beta() {{ printf 'RAN:beta\\n'; }}
    _isc_run_selected "alpha,beta"
    """
    proc = subprocess.run(
        ["bash", "-c", script], capture_output=True, text=True, cwd=ROOT_DIR
    )
    assert "RAN:alpha" in proc.stdout, proc.stdout + proc.stderr
    assert "RAN:beta" in proc.stdout, proc.stdout + proc.stderr


if __name__ == "__main__":
    test_install_forwards_every_requested_feature()
    test_runtime_splits_comma_separated_selection()
    print("ok")
