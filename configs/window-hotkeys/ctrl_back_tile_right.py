#!/usr/bin/env python3
"""Turn Ctrl + browser-back mouse button into direct right-half tiling.

The selected pointing device is grabbed so Ctrl+Back can be consumed before it
reaches applications. All other mouse events, including plain Back, are
forwarded through a virtual input device. Ctrl state is observed from keyboard
event nodes without grabbing them.
"""

from __future__ import annotations

import atexit
import os
import select
import signal
import time
from dataclasses import dataclass

import gi
from evdev import InputDevice, UInput, ecodes, list_devices
from hotkey_logging_utils import LOGGER, log_call

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib


FORWARD_EVENT_TYPES = {
    ecodes.EV_KEY,
    ecodes.EV_REL,
}

# Modifier keys the window-placement-tiling trigger can require. Configurable via
# WINDOW_PLACEMENT_TILE_MODIFIER (default Control); multiple names may be joined
# with "+" and any of their codes counts as "held".
_MODIFIER_CODES = {
    "Control": {ecodes.KEY_LEFTCTRL, ecodes.KEY_RIGHTCTRL},
    "Alt": {ecodes.KEY_LEFTALT, ecodes.KEY_RIGHTALT},
    "Super": {ecodes.KEY_LEFTMETA, ecodes.KEY_RIGHTMETA},
    "Shift": {ecodes.KEY_LEFTSHIFT, ecodes.KEY_RIGHTSHIFT},
}
# Mouse button codes for the trigger, configurable via
# WINDOW_PLACEMENT_TILE_BUTTON (BTN_BACK, the default, or BTN_FORWARD).
_BUTTON_CODES = {
    "BTN_BACK": {ecodes.KEY_BACK, ecodes.BTN_SIDE, ecodes.BTN_EXTRA},
    "BTN_FORWARD": {ecodes.BTN_FORWARD, ecodes.BTN_EXTRA},
}


def _configured_modifier_codes() -> set[int]:
    """Return the evdev codes for the configured trigger modifier(s)."""
    names = os.environ.get("WINDOW_PLACEMENT_TILE_MODIFIER", "Control")
    codes: set[int] = set()
    for name in names.replace("|", "+").split("+"):
        codes |= _MODIFIER_CODES.get(name.strip(), set())
    return codes or _MODIFIER_CODES["Control"]


def _configured_button_codes() -> set[int]:
    """Return the evdev codes for the configured trigger mouse button."""
    name = os.environ.get("WINDOW_PLACEMENT_TILE_BUTTON", "BTN_BACK").strip()
    return _BUTTON_CODES.get(name, _BUTTON_CODES["BTN_BACK"])


BACK_CODES = _configured_button_codes()
CTRL_CODES = _configured_modifier_codes()
POINTER_REL_CODES = {
    ecodes.REL_X,
    ecodes.REL_Y,
}
RESCAN_INTERVAL_SECONDS = 2.0
VIRTUAL_DEVICE_NAME = "ctrl-back-window-tiler"

DBUS_BUS_NAME = "org.gnome.shell.extensions.MonitorWindowHotkeys"
DBUS_OBJECT_PATH = "/org/gnome/shell/extensions/monitor_window_hotkeys"
DBUS_INTERFACE = "org.gnome.shell.extensions.MonitorWindowHotkeys"


def input_device_sort_key(path: str) -> tuple[int, int | str]:
    """Sort event device paths by their numeric suffix when available."""
    prefix, separator, suffix = path.rpartition("event")
    if separator and prefix.endswith("/dev/input/") and suffix.isdigit():
        return (0, int(suffix))
    return (1, path)


@dataclass
class WatchedDevice:
    """An input device and whether its events are intercepted."""

    device: InputDevice
    grabbed: bool


class CtrlBackWindowTiler:
    """Consume Ctrl+Back and invoke the GNOME Shell right-half tiler."""

    def __init__(self) -> None:
        self.devices: list[WatchedDevice] = []
        self.ctrl_pressed: set[tuple[str, int]] = set()
        self.suppressed: set[tuple[str, int]] = set()
        self.forward_capabilities: dict[int, set[int]] = {}
        self.ui: UInput | None = None
        self.running = True
        self.last_scan_at = 0.0
        self.target_device = os.environ.get("CTRL_BACK_TILE_DEVICE", "").strip()
        self.pointer_path = self.target_device
        self.reported_missing_target = False
        self.dbus_proxy = self._create_dbus_proxy()
        atexit.register(self.close)

    @log_call(LOGGER)
    def run(self) -> None:
        """Watch input devices until the service is stopped."""
        signal.signal(signal.SIGTERM, self._stop)
        signal.signal(signal.SIGINT, self._stop)
        self._open_devices()
        LOGGER.info("running in direct D-Bus mode")

        try:
            while self.running:
                if not self.devices:
                    time.sleep(RESCAN_INTERVAL_SECONDS)
                    self._open_devices()
                    continue

                fd_map = {entry.device.fd: entry for entry in self.devices}
                try:
                    ready, _, _ = select.select(
                        fd_map.keys(),
                        [],
                        [],
                        RESCAN_INTERVAL_SECONDS,
                    )
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
        finally:
            self.close()

    def close(self) -> None:
        """Release grabbed devices and close input resources."""
        for entry in self.devices:
            path = entry.device.path
            if entry.grabbed:
                try:
                    entry.device.ungrab()
                except OSError:
                    pass
            try:
                entry.device.close()
            except OSError:
                pass
            self._clear_device_state(path)
        self.devices = []

        if self.ui:
            try:
                self.ui.close()
            except OSError:
                pass
            self.ui = None

    def _stop(self, *_args: object) -> None:
        """Signal handler that requests a clean shutdown of the run loop.

        Args:
            *_args: Signal number and frame passed by the signal module; unused.
        """
        self.running = False

    @log_call(LOGGER)
    def _create_dbus_proxy(self) -> Gio.DBusProxy:
        """Create a proxy for the GNOME Shell extension's tiling API."""
        return Gio.DBusProxy.new_for_bus_sync(
            Gio.BusType.SESSION,
            Gio.DBusProxyFlags.DO_NOT_LOAD_PROPERTIES,
            None,
            DBUS_BUS_NAME,
            DBUS_OBJECT_PATH,
            DBUS_INTERFACE,
            None,
        )

    def _tile_right(self) -> None:
        """Tile the focused window directly, bypassing keyboard shortcuts."""
        try:
            self.dbus_proxy.call_sync(
                "TileRightHalf",
                None,
                Gio.DBusCallFlags.NONE,
                1000,
                None,
            )
            LOGGER.info("tiled focused window to the right half")
        except GLib.Error as exc:
            LOGGER.error("D-Bus tiling failed: %s", exc.message)

    @log_call(LOGGER)
    def _open_devices(self) -> None:
        """Open the selected pointer and all Ctrl-capable keyboard nodes."""
        self.forward_capabilities = {}
        self._scan_devices()
        self._open_uinput()
        self.last_scan_at = time.monotonic()

    def _scan_devices(self) -> None:
        """Add newly available pointer and Ctrl-capable input devices."""
        paths = sorted(list_devices(), key=input_device_sort_key)
        self.pointer_path = self._select_pointer_path(paths)

        open_paths = {entry.device.path for entry in self.devices}
        for path in paths:
            if path in open_paths:
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
            watches_ctrl = bool(keys & CTRL_CODES)
            is_pointer = path == self.pointer_path
            if not watches_ctrl and not is_pointer:
                device.close()
                continue

            grabbed = False
            if is_pointer:
                if not self._is_back_pointer(caps):
                    LOGGER.warning("%s is not a back-button pointing device", path)
                    device.close()
                    self.pointer_path = ""
                    continue
                grabbed = self._grab_pointer(device)
                if grabbed:
                    self._add_forward_capabilities(caps)

            self.devices.append(WatchedDevice(device=device, grabbed=grabbed))
            mode = "grabbed pointer" if grabbed else "Ctrl monitor"
            LOGGER.info("watching %s: %s [%s]", path, device.name, mode)

    def _select_pointer_path(self, paths: list[str]) -> str:
        """Resolve a configured stable path or auto-detect an available pointer."""
        if self.target_device:
            resolved_path = os.path.realpath(self.target_device)
            if resolved_path in paths:
                self.reported_missing_target = False
                return resolved_path
            if not getattr(self, "reported_missing_target", False):
                LOGGER.warning(
                    "configured pointer device is unavailable: %s -> %s",
                    self.target_device,
                    resolved_path,
                )
                self.reported_missing_target = True
            return ""

        if self.pointer_path in paths:
            return self.pointer_path
        return self._find_pointer_path(paths)

    def _find_pointer_path(self, paths: list[str]) -> str:
        """Choose the first non-keyboard pointing node with a back button."""
        for path in paths:
            try:
                device = InputDevice(path)
                caps = device.capabilities(absinfo=False)
            except OSError:
                continue

            name = device.name
            device.close()
            if name == VIRTUAL_DEVICE_NAME or "Keychron" in name:
                continue
            if self._is_back_pointer(caps):
                return path

        return ""

    @staticmethod
    def _is_back_pointer(caps: dict[int, list[int]]) -> bool:
        """Return whether a device is a relative pointer with a back button.

        Args:
            caps: Device capabilities keyed by evdev event type.

        Returns:
            True when the device reports both pointer motion (REL_X/REL_Y) and a
            back-button key code, i.e. it is the kind of mouse we can grab.
        """
        keys = set(caps.get(ecodes.EV_KEY, []))
        rels = set(caps.get(ecodes.EV_REL, []))
        return bool(keys & BACK_CODES) and bool(rels & POINTER_REL_CODES)

    @staticmethod
    def _grab_pointer(device: InputDevice) -> bool:
        """Exclusively grab a pointer device so its events can be intercepted.

        Args:
            device: The input device to grab.

        Returns:
            True if the grab succeeded; False if it failed (logged to stderr).
        """
        try:
            device.grab()
            return True
        except OSError as exc:
            LOGGER.error("could not grab %s: %s", device.path, exc)
            return False

    def _add_forward_capabilities(self, caps: dict[int, list[int]]) -> None:
        """Record a grabbed device's forwardable event codes.

        Only forwardable event types (keys and relative axes) are kept so the
        virtual uinput device can replay non-suppressed events.

        Args:
            caps: Capabilities of the grabbed device keyed by evdev event type.
        """
        for event_type, codes in caps.items():
            if event_type in FORWARD_EVENT_TYPES:
                self.forward_capabilities.setdefault(event_type, set()).update(codes)

    def _open_uinput(self) -> None:
        """(Re)create the virtual uinput device used to forward pass-through events.

        Closes any existing device first. Does nothing when no forward
        capabilities have been collected (i.e. no pointer is grabbed).
        """
        if self.ui:
            try:
                self.ui.close()
            except OSError:
                pass
            self.ui = None

        if not self.forward_capabilities:
            return

        try:
            self.ui = UInput(
                {
                    event_type: sorted(codes)
                    for event_type, codes in self.forward_capabilities.items()
                    if codes
                },
                name=VIRTUAL_DEVICE_NAME,
            )
            LOGGER.info("opened virtual forwarding input device")
        except OSError as exc:
            LOGGER.error("could not open virtual forwarding input device: %s", exc)
            self.ui = None

    def _rescan_devices(self) -> None:
        """Periodically pick up hot-plugged devices, rebuilding uinput if needed.

        Throttled to at most once per RESCAN_INTERVAL_SECONDS. The virtual
        device is only reopened when the set of forwardable capabilities changed.
        """
        now = time.monotonic()
        if now - self.last_scan_at < RESCAN_INTERVAL_SECONDS:
            return

        before = {
            event_type: set(codes)
            for event_type, codes in self.forward_capabilities.items()
        }
        self._scan_devices()
        self.last_scan_at = now
        if self.forward_capabilities != before:
            self._open_uinput()

    def _reopen_devices(self) -> None:
        """Recover from a device read/select error by closing and reopening all.

        When no device is explicitly configured, the cached pointer path is
        cleared so auto-detection runs again on reopen.
        """
        self.close()
        if not self.target_device:
            self.pointer_path = ""
        self._open_devices()

    def _clear_device_state(self, path: str) -> None:
        """Drop cached Ctrl/suppression state for a device being closed.

        Args:
            path: Event device path whose pending key state should be forgotten.
        """
        self.ctrl_pressed = {
            key for key in self.ctrl_pressed if key[0] != path
        }
        self.suppressed = {
            key for key in self.suppressed if key[0] != path
        }

    def _handle_event(self, entry: WatchedDevice, event) -> None:
        """Dispatch a single evdev event to the appropriate handler.

        Non-key events from grabbed devices are forwarded verbatim; key events
        are routed to the Ctrl, Back, or generic-forward paths.

        Args:
            entry: The watched device the event came from.
            event: The evdev input event to process.
        """
        if event.type != ecodes.EV_KEY:
            if entry.grabbed:
                self._forward_event(event.type, event.code, event.value)
            return

        if event.code in CTRL_CODES:
            self._handle_ctrl_event(entry, event)
            return

        if event.code in BACK_CODES:
            self._handle_back_event(entry, event)
            return

        if entry.grabbed:
            self._forward_event(event.type, event.code, event.value)

    def _handle_ctrl_event(self, entry: WatchedDevice, event) -> None:
        """Track Ctrl press/release state and forward it if grabbed.

        Args:
            entry: The watched device the Ctrl event came from.
            event: The Ctrl key event (value 0 = release, otherwise pressed).
        """
        key = (entry.device.path, event.code)
        if event.value == 0:
            self.ctrl_pressed.discard(key)
        else:
            self.ctrl_pressed.add(key)

        if entry.grabbed:
            self._forward_event(event.type, event.code, event.value)

    def _handle_back_event(self, entry: WatchedDevice, event) -> None:
        """Handle a Back button event, tiling on Ctrl+Back or forwarding it.

        On a Ctrl+Back press the event is suppressed (when grabbed) and the
        right-half tiler is invoked; the matching release is also swallowed so
        applications never see the click. Plain Back is forwarded unchanged.

        Args:
            entry: The watched device the Back event came from.
            event: The Back key event (value 1 = press, 0 = release).
        """
        key = (entry.device.path, event.code)

        if event.value == 1 and self.ctrl_pressed:
            if entry.grabbed:
                self.suppressed.add(key)
            self._tile_right()
            return

        if key in self.suppressed:
            if event.value == 0:
                self.suppressed.discard(key)
            return

        if entry.grabbed:
            self._forward_event(event.type, event.code, event.value)

    def _forward_event(self, event_type: int, code: int, value: int) -> None:
        """Replay an intercepted event through the virtual uinput device.

        Silently drops the event when no virtual device exists or the code is
        not part of the device's declared capabilities.

        Args:
            event_type: evdev event type (e.g. EV_KEY, EV_REL).
            code: Event code within that type.
            value: Event value (key state or relative delta).
        """
        if not self.ui:
            return
        if code not in self.forward_capabilities.get(event_type, set()):
            return
        try:
            self.ui.write(event_type, code, value)
            self.ui.syn()
        except OSError as exc:
            LOGGER.error(
                "could not forward input event %s/%s: %s",
                event_type,
                code,
                exc,
            )
            try:
                self.ui.close()
            except OSError:
                pass
            self.ui = None


if __name__ == "__main__":
    CtrlBackWindowTiler().run()
