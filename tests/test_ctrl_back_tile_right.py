#!/usr/bin/env python3
"""Focused behavior tests for the Ctrl+Back input interceptor."""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from types import SimpleNamespace

from evdev import ecodes


ROOT_DIR = Path(__file__).resolve().parent.parent
MODULE_PATH = ROOT_DIR / "configs" / "window-hotkeys" / "ctrl_back_tile_right.py"
SPEC = importlib.util.spec_from_file_location("ctrl_back_tile_right", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class FakeUInput:
    def __init__(self) -> None:
        self.events: list[tuple[int, int, int]] = []

    def write(self, event_type: int, code: int, value: int) -> None:
        self.events.append((event_type, code, value))

    def syn(self) -> None:
        pass


def make_tiler():
    tiler = MODULE.CtrlBackWindowTiler.__new__(MODULE.CtrlBackWindowTiler)
    tiler.ctrl_pressed = set()
    tiler.suppressed = set()
    tiler.ui = FakeUInput()
    tiler.forward_capabilities = {
        ecodes.EV_KEY: {
            ecodes.BTN_SIDE,
            ecodes.KEY_LEFTCTRL,
        },
    }
    return tiler


def event(code: int, value: int):
    return SimpleNamespace(type=ecodes.EV_KEY, code=code, value=value)


def test_ctrl_back_is_consumed_and_tiles_once():
    tiler = make_tiler()
    calls = []
    tiler._tile_right = lambda: calls.append("tile")
    keyboard = MODULE.WatchedDevice(
        device=SimpleNamespace(path="/dev/input/keyboard"),
        grabbed=False,
    )
    pointer = MODULE.WatchedDevice(
        device=SimpleNamespace(path="/dev/input/mouse"),
        grabbed=True,
    )

    tiler._handle_event(keyboard, event(ecodes.KEY_LEFTCTRL, 1))
    tiler._handle_event(pointer, event(ecodes.BTN_SIDE, 1))
    tiler._handle_event(pointer, event(ecodes.BTN_SIDE, 0))

    assert calls == ["tile"]
    assert tiler.ui.events == []
    assert tiler.suppressed == set()


def test_plain_back_is_forwarded_to_applications():
    tiler = make_tiler()
    pointer = MODULE.WatchedDevice(
        device=SimpleNamespace(path="/dev/input/mouse"),
        grabbed=True,
    )

    tiler._handle_event(pointer, event(ecodes.BTN_SIDE, 1))
    tiler._handle_event(pointer, event(ecodes.BTN_SIDE, 0))

    assert tiler.ui.events == [
        (ecodes.EV_KEY, ecodes.BTN_SIDE, 1),
        (ecodes.EV_KEY, ecodes.BTN_SIDE, 0),
    ]
