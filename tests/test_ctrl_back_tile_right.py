#!/usr/bin/env python3
"""Focused behavior tests for the Ctrl+Back input interceptor."""

from __future__ import annotations

import importlib.util
import io
import logging
import sys
from pathlib import Path
from types import SimpleNamespace

from evdev import ecodes


ROOT_DIR = Path(__file__).resolve().parent.parent
MODULE_PATH = ROOT_DIR / "configs" / "window-hotkeys" / "ctrl_back_tile_right.py"
sys.path.insert(0, str(MODULE_PATH.parent))
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

    def close(self) -> None:
        pass


class FailingUInput(FakeUInput):
    def write(self, event_type: int, code: int, value: int) -> None:
        raise OSError("uinput disconnected")


class LogCapture:
    def __init__(self) -> None:
        self.stream = io.StringIO()
        self.handler = logging.StreamHandler(self.stream)

    def __enter__(self) -> "LogCapture":
        MODULE.LOGGER.addHandler(self.handler)
        return self

    def __exit__(self, *_args: object) -> None:
        MODULE.LOGGER.removeHandler(self.handler)

    def text(self) -> str:
        return self.stream.getvalue()


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


def test_input_devices_are_sorted_by_numeric_event_suffix():
    paths = [
        "/dev/input/event13",
        "/dev/input/event4",
        "/dev/input/event6",
    ]

    assert sorted(paths, key=MODULE.input_device_sort_key) == [
        "/dev/input/event4",
        "/dev/input/event6",
        "/dev/input/event13",
    ]


def test_configured_stable_pointer_path_is_resolved(monkeypatch):
    tiler = MODULE.CtrlBackWindowTiler.__new__(MODULE.CtrlBackWindowTiler)
    tiler.target_device = "/dev/input/by-id/razer-event-mouse"
    tiler.pointer_path = ""
    monkeypatch.setattr(
        MODULE.os.path,
        "realpath",
        lambda path: "/dev/input/event4",
    )

    assert tiler._select_pointer_path(
        ["/dev/input/event4", "/dev/input/event13"]
    ) == "/dev/input/event4"


def test_missing_configured_pointer_does_not_fall_back(monkeypatch):
    tiler = MODULE.CtrlBackWindowTiler.__new__(MODULE.CtrlBackWindowTiler)
    tiler.target_device = "/dev/input/by-id/razer-event-mouse"
    tiler.pointer_path = "/dev/input/event4"
    monkeypatch.setattr(
        MODULE.os.path,
        "realpath",
        lambda path: "/dev/input/event99",
    )
    tiler._find_pointer_path = lambda paths: (_ for _ in ()).throw(
        AssertionError("must not select another mouse")
    )

    assert tiler._select_pointer_path(["/dev/input/event13"]) == ""


def test_missing_configured_pointer_is_logged_once(monkeypatch):
    tiler = MODULE.CtrlBackWindowTiler.__new__(MODULE.CtrlBackWindowTiler)
    tiler.target_device = "/dev/input/by-id/razer-event-mouse"
    tiler.pointer_path = "/dev/input/event4"
    tiler.reported_missing_target = False
    monkeypatch.setattr(
        MODULE.os.path,
        "realpath",
        lambda path: "/dev/input/event99",
    )

    with LogCapture() as logs:
        assert tiler._select_pointer_path(["/dev/input/event13"]) == ""
        assert tiler._select_pointer_path(["/dev/input/event13"]) == ""

    assert logs.text().count("configured pointer device is unavailable") == 1


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


def test_forwarding_failure_is_logged_and_disables_uinput():
    tiler = make_tiler()
    tiler.ui = FailingUInput()

    with LogCapture() as logs:
        tiler._forward_event(ecodes.EV_KEY, ecodes.BTN_SIDE, 1)

    assert "could not forward input event" in logs.text()
    assert tiler.ui is None
