#!/usr/bin/env python3
"""Turn Ctrl + browser-back mouse button into the right-half tiling shortcut."""

from __future__ import annotations

import atexit
import os
import select
import signal
import sys
import time
from dataclasses import dataclass

from evdev import InputDevice, UInput, ecodes, list_devices


FORWARD_EVENT_TYPES = {
    ecodes.EV_KEY,
    ecodes.EV_REL,
}
BACK_CODES = {
    ecodes.KEY_BACK,
    ecodes.BTN_SIDE,
    ecodes.BTN_EXTRA,
}
POINTER_BUTTON_CODES = {
    ecodes.BTN_LEFT,
    ecodes.BTN_RIGHT,
    ecodes.BTN_MIDDLE,
    ecodes.BTN_SIDE,
    ecodes.BTN_EXTRA,
}
CTRL_CODES = {
    ecodes.KEY_LEFTCTRL,
    ecodes.KEY_RIGHTCTRL,
}
FORWARD_CODES = {
    ecodes.KEY_BACK,
    ecodes.KEY_FORWARD,
}
RESCAN_INTERVAL_SECONDS = 2.0
TILE_RIGHT_SHORTCUT_MODIFIERS = (ecodes.KEY_LEFTCTRL,)
TILE_RIGHT_SHORTCUT_KEY = ecodes.KEY_RIGHT
VIRTUAL_DEVICE_NAME = "ctrl-back-window-tiler"


@dataclass
class WatchedDevice:
    device: InputDevice
    grabbed: bool


class CtrlBackWindowTiler:
    def __init__(self) -> None:
        self.ctrl_down: bool = False
        self.suppressed: set[tuple[str, int]] = set()
        self.devices: list[WatchedDevice] = []
        self.forward_capabilities: dict[int, set[int]] = {}
        self.running = True
        self.ui: UInput | None = None
        self.last_scan_at = 0.0
        atexit.register(self.close)

    def run(self) -> None:
        signal.signal(signal.SIGTERM, self._stop)
        signal.signal(signal.SIGINT, self._stop)
        self._open_devices()
        self._open_uinput()
        print("ctrl-back-window-tiler running", flush=True)

        while self.running:
            if not self.devices:
                time.sleep(RESCAN_INTERVAL_SECONDS)
                self._open_devices()
                self._open_uinput()
                continue

            fd_map = {entry.device.fd: entry for entry in self.devices}
            try:
                ready, _, _ = select.select(fd_map.keys(), [], [], 2)
            except (OSError, ValueError):
                self._reopen_devices()
                continue

            if not ready:
                self._rescan_devices()
                continue

            for fd in ready:
                entry = fd_map.get(fd)
                if not entry:
                    continue
                try:
                    for event in entry.device.read():
                        self._handle_event(entry, event)
                except OSError:
                    self._reopen_devices()
                    break

    def close(self) -> None:
        for entry in self.devices:
            if entry.grabbed:
                try:
                    entry.device.ungrab()
                except OSError:
                    pass
            try:
                entry.device.close()
            except OSError:
                pass
        self.devices = []
        if self.ui:
            try:
                self.ui.close()
            except OSError:
                pass
            self.ui = None

    def _stop(self, *_args: object) -> None:
        self.running = False

    def _open_devices(self) -> None:
        self.forward_capabilities = {ecodes.EV_KEY: {
            *TILE_RIGHT_SHORTCUT_MODIFIERS,
            TILE_RIGHT_SHORTCUT_KEY,
            ecodes.KEY_LEFTMETA,
            ecodes.KEY_RIGHT,
            ecodes.KEY_BACK,
            ecodes.KEY_FORWARD,
        }}
        self._scan_devices()
        self.last_scan_at = time.monotonic()

    def _rescan_devices(self) -> None:
        now = time.monotonic()
        if now - self.last_scan_at < RESCAN_INTERVAL_SECONDS:
            return

        old_forward_capabilities = {
            event_type: set(codes)
            for event_type, codes in self.forward_capabilities.items()
        }
        added = self._scan_devices()
        self.last_scan_at = now

        if added and self.forward_capabilities != old_forward_capabilities:
            self._open_uinput()

    def _scan_devices(self) -> int:
        opened = 0
        target_device = os.environ.get("CTRL_BACK_TILE_DEVICE", "").strip()
        open_paths = {entry.device.path for entry in self.devices}
        seen: set[str] = set()
        for path in list_devices():
            if path in seen:
                continue
            seen.add(path)
            if path in open_paths:
                continue

            # Skip non-matching devices when CTRL_BACK_TILE_DEVICE is set.
            if target_device and path != target_device:
                continue

            try:
                device = InputDevice(path)
                caps = device.capabilities(absinfo=False)
            except OSError:
                continue

            if device.name == VIRTUAL_DEVICE_NAME:
                device.close()
                continue

            keys = set(caps.get(ecodes.EV_KEY, []))
            if not (keys & (BACK_CODES | CTRL_CODES)):
                device.close()
                continue

            # For multi-function devices, prefer the mouse-only event node.
            is_mouse_only = self._prefer_mouse_only_device(device.path, caps, keys)
            has_keyboard_keys = len(keys - BACK_CODES - CTRL_CODES - FORWARD_CODES - {ecodes.BTN_LEFT, ecodes.BTN_RIGHT, ecodes.BTN_MIDDLE}) > 0

            grabbed = False
            if is_mouse_only:
                # Mouse-only node: always try to grab first.
                grabbed = self._try_grab_back_device(device, caps, keys)
            elif has_keyboard_keys and not is_mouse_only:
                # Keyboard-heavy node: only grab if it also has back-button capability.
                grabbed = self._maybe_grab_back_device(device, caps, keys)

            if grabbed:
                self._add_forward_capabilities(caps)
            self.devices.append(WatchedDevice(device=device, grabbed=grabbed))
            opened += 1
            print(
                f"watching {device.path}: {device.name}"
                + (" [grabbed]" if grabbed else ""),
                flush=True,
            )
        return opened

    def _open_uinput(self) -> None:
        if self.ui:
            try:
                self.ui.close()
            except OSError:
                pass
        self.ui = UInput(
            {
                event_type: sorted(codes)
                for event_type, codes in self.forward_capabilities.items()
                if codes
            },
            name=VIRTUAL_DEVICE_NAME,
        )

    def _reopen_devices(self) -> None:
        self.close()
        self._open_devices()
        self._open_uinput()

    def _try_grab_back_device(
        self,
        device: InputDevice,
        caps: dict[int, list[int]],
        keys: set[int],
    ) -> bool:
        """Try to grab a mouse or pointing-device node.

        This is the primary grab path for mouse-only event nodes (e.g. Razer
        Naga V2 if01-mouse).  It accepts any device with pointer motion and
        standard mouse buttons, regardless of whether KEY_BACK is present.
        """
        rels = set(caps.get(ecodes.EV_REL, []))
        has_pointer_motion = bool(rels & {ecodes.REL_X, ecodes.REL_Y})
        if not has_pointer_motion:
            return False

        # Reject Keychron devices (they are keyboards).
        if "Keychron" in device.name:
            return False

        try:
            device.grab()
            return True
        except OSError as exc:
            print(f"could not grab {device.path}: {exc}", file=sys.stderr, flush=True)
            return False

    def _maybe_grab_back_device(
        self,
        device: InputDevice,
        caps: dict[int, list[int]],
        keys: set[int],
    ) -> bool:
        """Try to grab a keyboard-like or multi-function device with back-button.

        This is the fallback path for combined mouse+keyboard event nodes.
        It applies stricter filtering to avoid grabbing full keyboards.
        """
        # Check for back-button capability: KEY_BACK (keyboard/media) OR
        # BTN_SIDE / BTN_EXTRA (mouse buttons).  Mouse devices use the latter.
        has_back_button = bool(keys & BACK_CODES) or ecodes.KEY_BACK in keys

        rels = set(caps.get(ecodes.EV_REL, []))
        has_pointer_motion = bool(rels & {ecodes.REL_X, ecodes.REL_Y})

        # Must have pointer motion (REL_X/REL_Y) to be a pointing device.
        if not has_pointer_motion:
            return False

        is_simple_mouse_buttons = keys <= POINTER_BUTTON_CODES

        # Reject obvious keyboards that happen to have mouse-like buttons.
        non_pointer_keys = keys - BACK_CODES - CTRL_CODES - FORWARD_CODES - {ecodes.BTN_LEFT, ecodes.BTN_RIGHT, ecodes.BTN_MIDDLE}
        has_many_keyboard_keys = len(non_pointer_keys) > 48

        # If it's a simple mouse (only pointer buttons), grab it.
        if is_simple_mouse_buttons:
            pass  # proceed to grab below
        elif has_back_button and not has_many_keyboard_keys:
            # Multi-function device with back button but not a full keyboard.
            pass  # proceed to grab below
        else:
            return False

        if "Keychron" in device.name:
            return False

        try:
            device.grab()
            return True
        except OSError as exc:
            print(f"could not grab {device.path}: {exc}", file=sys.stderr, flush=True)
            return False

    def _add_forward_capabilities(self, caps: dict[int, list[int]]) -> None:
        for event_type, codes in caps.items():
            if event_type not in FORWARD_EVENT_TYPES:
                continue
            self.forward_capabilities.setdefault(event_type, set()).update(codes)

    def _prefer_mouse_only_device(
        self,
        device_path: str,
        caps: dict[int, list[int]],
        keys: set[int],
    ) -> bool:
        """Return True if this device node is a mouse-only interface.

        Multi-function devices (e.g. Razer Naga V2) expose separate event nodes:
        one with just pointer buttons/axes, and another mixing in keyboard keys.
        We prefer the pure mouse node so we do not block normal keyboard input.
        """
        rels = set(caps.get(ecodes.EV_REL, []))
        has_pointer_motion = bool(rels & {ecodes.REL_X, ecodes.REL_Y})
        if not has_pointer_motion:
            return False

        # A mouse-only node should have no non-pointer keys.
        non_pointer_keys = keys - BACK_CODES - CTRL_CODES - FORWARD_CODES - {ecodes.BTN_LEFT, ecodes.BTN_RIGHT, ecodes.BTN_MIDDLE}
        return len(non_pointer_keys) == 0

    def _handle_event(self, entry: WatchedDevice, event) -> None:
        if event.type != ecodes.EV_KEY:
            if entry.grabbed:
                self._forward_event(event.type, event.code, event.value)
            return

        if event.code in CTRL_CODES:
            self.ctrl_down = event.value != 0
            if entry.grabbed:
                self._forward_key(event.code, event.value)
            return

        if event.code in BACK_CODES:
            self._handle_back_event(entry, event)
            return

        if entry.grabbed:
            self._forward_event(event.type, event.code, event.value)

    def _handle_back_event(self, entry: WatchedDevice, event) -> None:
        key = (entry.device.path, event.code)

        if event.value == 1 and self.ctrl_down:
            self.suppressed.add(key)
            self._emit_ctrl_right()
            return

        if key in self.suppressed:
            if event.value == 0:
                self.suppressed.discard(key)
            return

        if entry.grabbed:
            self._forward_event(ecodes.EV_KEY, event.code, event.value)
        elif event.value == 1 and self.ctrl_down:
            self._emit_ctrl_right()

    def _forward_key(self, code: int, value: int) -> None:
        self._forward_event(ecodes.EV_KEY, code, value)

    def _forward_event(self, event_type: int, code: int, value: int) -> None:
        if code in self.forward_capabilities.get(event_type, set()):
            self._write(event_type, code, value)

    def _emit_ctrl_right(self) -> None:
        if not self.ui:
            return
        for code in TILE_RIGHT_SHORTCUT_MODIFIERS:
            self.ui.write(ecodes.EV_KEY, code, 1)
        self.ui.syn()

        self.ui.write(ecodes.EV_KEY, TILE_RIGHT_SHORTCUT_KEY, 1)
        self.ui.syn()
        self.ui.write(ecodes.EV_KEY, TILE_RIGHT_SHORTCUT_KEY, 0)
        self.ui.syn()

        for code in reversed(TILE_RIGHT_SHORTCUT_MODIFIERS):
            self.ui.write(ecodes.EV_KEY, code, 0)
        self.ui.syn()
        print("sent Ctrl+Right via held Ctrl + browser-back", flush=True)

    def _write(self, event_type: int, code: int, value: int) -> None:
        if not self.ui:
            return
        self.ui.write(event_type, code, value)
        self.ui.syn()


if __name__ == "__main__":
    CtrlBackWindowTiler().run()
