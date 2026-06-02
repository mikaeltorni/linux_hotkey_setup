#!/usr/bin/env python3
"""Turn Ctrl + browser-back mouse button into the right-half tiling shortcut.

This script monitors input devices with back buttons and triggers GNOME's
window tiling when Ctrl+Back is detected.

On GNOME Wayland, synthetic UInput keyboard events do not reliably trigger
GNOME Shell keybindings. Therefore this script uses a hybrid approach:
- For grabbed (keyboard-like) devices: emit synthetic <Control>XF86Back via
  UInput to attempt triggering the tiling-assistant extension's binding.
- For ungrabbed (mouse-only) devices: detect Ctrl+Back and emit synthetic
  events without grabbing, allowing GNOME Shell to potentially respond.

The script also suppresses browser back navigation when Ctrl is held by
consuming the back button event on grabbed devices.

Components:
  - CtrlBackWindowTiler: Main class that watches devices and handles events.
  - WatchedDevice: Dataclass wrapping an InputDevice with grab state.

Usage:
  python3 ctrl_back_tile_right.py
  # or via systemd user service (see ctrl-back-window-tiler.service)
"""

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
    ecodes.BTN_FORWARD,
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

# The tiling-assistant extension binds <Control>XF86Back to tile-right-half.
# In evdev, XF86Back is KEY_BACK (code 158). We emit Ctrl+KEY_BACK so that
# Mutter's input subsystem can match it against the tiling-assistant binding.
TILE_RIGHT_SHORTCUT_MODIFIERS = (ecodes.KEY_LEFTCTRL,)
TILE_RIGHT_SHORTCUT_KEY = ecodes.KEY_BACK

VIRTUAL_DEVICE_NAME = "ctrl-back-window-tiler"


@dataclass
class WatchedDevice:
    """Wrapper around an InputDevice with grab state tracking.

    Attributes:
        device: The evdev InputDevice being watched.
        grabbed: Whether this device is currently grabbed (events intercepted).
    """
    device: InputDevice
    grabbed: bool


class CtrlBackWindowTiler:
    """Monitors mouse/keyboard devices for Ctrl+Back and triggers window tiling.

    This class watches input devices that have back buttons, detects when
    Ctrl is held and the back button is pressed, suppresses browser navigation
    on grabbed devices, and emits a synthetic <Control>XF86Back to trigger
    GNOME's window tiling action.
    """

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
        """Main event loop: scan devices, handle input events."""
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
        """Release grabs and close all devices."""
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
        """Signal handler to gracefully stop the event loop."""
        self.running = False

    def _open_devices(self) -> None:
        """Scan for devices with back buttons and set up capabilities."""
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
        """Rescan devices if enough time has passed since last scan."""
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
        """Scan for input devices with back-button capability.

        Returns:
            Number of new devices opened during this scan.
        """
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
                # Mouse-only node: do NOT grab to allow GNOME Shell to see
                # physical keypresses. We still detect Ctrl+Back and emit
                # synthetic events for tiling.
                grabbed = False
            elif has_keyboard_keys:
                # Keyboard-heavy node: grab to suppress back button navigation.
                grabbed = self._maybe_grab_back_device(device, caps, keys)

            if grabbed:
                self._add_forward_capabilities(caps)
            self.devices.append(WatchedDevice(device=device, grabbed=grabbed))
            opened += 1
            print(
                f"watching {device.path}: {device.name}"
                + (" [grabbed]" if grabbed else " [ungrabbed]"),
                flush=True,
            )
        return opened

    def _open_uinput(self) -> None:
        """Create or recreate the virtual input device for emitting events."""
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
        """Close all devices and reopen them."""
        self.close()
        self._open_devices()
        self._open_uinput()

    def _maybe_grab_back_device(
        self,
        device: InputDevice,
        caps: dict[int, list[int]],
        keys: set[int],
    ) -> bool:
        """Try to grab a keyboard-like or multi-function device with back-button.

        This is the fallback path for combined mouse+keyboard event nodes.
        It applies stricter filtering to avoid grabbing full keyboards.

        Args:
            device: The InputDevice to attempt grabbing.
            caps: Device capabilities dictionary.
            keys: Set of key codes supported by the device.

        Returns:
            True if the device was successfully grabbed.
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
        non_pointer_keys = keys - BACK_CODES - CTRL_CODES - FORWARD_CODES - POINTER_BUTTON_CODES
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
        """Add device capabilities to the forward-capabilities set.

        Args:
            caps: Device capabilities dictionary from evdev.
        """
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

        Args:
            device_path: Path to the device's event node.
            caps: Device capabilities dictionary.
            keys: Set of key codes supported by the device.

        Returns:
            True if this is a mouse-only interface.
        """
        rels = set(caps.get(ecodes.EV_REL, []))
        has_pointer_motion = bool(rels & {ecodes.REL_X, ecodes.REL_Y})
        if not has_pointer_motion:
            return False

        # A mouse-only node should have no non-pointer keys.
        non_pointer_keys = keys - BACK_CODES - CTRL_CODES - FORWARD_CODES - POINTER_BUTTON_CODES
        return len(non_pointer_keys) == 0

    def _handle_event(self, entry: WatchedDevice, event) -> None:
        """Handle an input event from a watched device.

        Args:
            entry: The WatchedDevice that generated the event.
            event: An evdev input event.
        """
        if event.type != ecodes.EV_KEY:
            if entry.grabbed:
                self._forward_event(event.type, event.code, event.value)
            return

        if event.code in CTRL_CODES:
            self.ctrl_down = event.value != 0
            if entry.grabbed:
                self._forward_key(event.code, event.value)
            elif not entry.grabbed and event.value == 1:
                # On ungrabbed devices, forward Ctrl so GNOME Shell sees it.
                self._emit_modifier(ecodes.EV_KEY, event.code, 1)
            return

        if event.code in BACK_CODES:
            self._handle_back_event(entry, event)
            return

        if entry.grabbed:
            self._forward_event(event.type, event.code, event.value)

    def _handle_back_event(self, entry: WatchedDevice, event) -> None:
        """Handle a back-button press/release event.

        On grabbed devices: suppress the back button when Ctrl is held and
        emit synthetic <Control>XF86Back to trigger GNOME's window tiling.

        On ungrabbed devices: detect Ctrl+Back and emit synthetic events
        for tiling, while letting other applications see the raw event too.

        Args:
            entry: The WatchedDevice that generated the event.
            event: An evdev input event for the back button.
        """
        key = (entry.device.path, event.code)

        if event.value == 1 and self.ctrl_down:
            # Ctrl + Back pressed: suppress navigation on grabbed devices,
            # trigger tiling via synthetic events.
            if entry.grabbed:
                self.suppressed.add(key)
            self._emit_ctrl_back()
            return

        if key in self.suppressed:
            if event.value == 0:
                self.suppressed.discard(key)
            return

        # Non-Ctrl back press or release on grabbed device: forward normally.
        if entry.grabbed:
            self._forward_event(ecodes.EV_KEY, event.code, event.value)

    def _forward_key(self, code: int, value: int) -> None:
        """Forward a key event to the virtual device.

        Args:
            code: The evdev key code.
            value: The event value (0 = release, 1 = press).
        """
        self._forward_event(ecodes.EV_KEY, code, value)

    def _forward_event(self, event_type: int, code: int, value: int) -> None:
        """Forward an event to the virtual device if it's in capabilities.

        Args:
            event_type: The evdev event type (e.g., EV_KEY).
            code: The event code.
            value: The event value.
        """
        if code in self.forward_capabilities.get(event_type, set()):
            self._write(event_type, code, value)

    def _emit_modifier(self, event_type: int, code: int, value: int) -> None:
        """Event to the virtual device without capability checking.

        Used for forwarding modifier keys on ungrabbed devices where we
        want GNOME Shell to see the physical keypress state.

        Args:
            event_type: The evdev event type.
            code: The event code.
            value: The event value.
        """
        self._write(event_type, code, value)

    def _emit_ctrl_back(self) -> None:
        """Emit a synthetic <Control>XF86Back (KEY_BACK) via UInput.

        This triggers GNOME's tiling-assistant extension's tile-right-half
        action by emitting the same key codes that would be generated by
        pressing Ctrl + XF86Back on a physical keyboard. The modifier is
        held while KEY_BACK is pressed and released, then the modifier
        is released.

        Note: On GNOME Wayland, synthetic UInput events may not reliably
        trigger GSettings-based keybindings. This is a known limitation.
        """
        if not self.ui:
            return
        for code in TILE_RIGHT_SHORTCUT_MODIFIERS:
            self.ui.write(ecodes.EV_KEY, code, 1)
        self.ui.syn()

        # Emit KEY_BACK (XF86Back / browser-back media key).
        self.ui.write(ecodes.EV_KEY, TILE_RIGHT_SHORTCUT_KEY, 1)
        self.ui.syn()
        self.ui.write(ecodes.EV_KEY, TILE_RIGHT_SHORTCUT_KEY, 0)
        self.ui.syn()

        for code in reversed(TILE_RIGHT_SHORTCUT_MODIFIERS):
            self.ui.write(ecodes.EV_KEY, code, 0)
        self.ui.syn()
        print("sent Ctrl+XF86Back (KEY_BACK) via held Ctrl + browser-back", flush=True)

    def _write(self, event_type: int, code: int, value: int) -> None:
        """Write an event to the virtual input device.

        Args:
            event_type: The evdev event type.
            code: The event code.
            value: The event value.
        """
        if not self.ui:
            return
        self.ui.write(event_type, code, value)
        self.ui.syn()


if __name__ == "__main__":
    CtrlBackWindowTiler().run()
