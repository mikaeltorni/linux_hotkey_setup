#!/usr/bin/env python3
"""Tests for the centralized Python logging utility."""

from __future__ import annotations

import importlib.util
import logging
import sys
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parent.parent
MODULE_PATH = ROOT_DIR / "configs" / "window-hotkeys" / "hotkey_logging_utils.py"
SPEC = importlib.util.spec_from_file_location("hotkey_logging_utils", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def test_get_logger_is_idempotent() -> None:
    """Repeated logger setup does not duplicate handlers."""
    logger = MODULE.get_logger("hotkey-test-idempotent")
    handler_count = len(logger.handlers)

    assert MODULE.get_logger("hotkey-test-idempotent") is logger
    assert len(logger.handlers) == handler_count


def test_log_call_records_arguments_and_return(caplog) -> None:
    """The standard decorator logs bound arguments and the return value."""
    logger = logging.getLogger("hotkey-test-trace")
    logger.handlers.clear()
    logger.propagate = True

    @MODULE.log_call(logger)
    def add(left: int, right: int = 1) -> int:
        return left + right

    with caplog.at_level(logging.DEBUG, logger="hotkey-test-trace"):
        assert add(2, right=3) == 5

    messages = [record.getMessage() for record in caplog.records]
    assert (
        "ENTER test_logging_utils.py:test_log_call_records_arguments_and_return."
        "<locals>.add(left=2, right=3)"
    ) in messages
    assert (
        "EXIT test_logging_utils.py:test_log_call_records_arguments_and_return."
        "<locals>.add -> 5"
    ) in messages
