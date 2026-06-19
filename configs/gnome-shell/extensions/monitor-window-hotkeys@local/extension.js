/**
 * extension.js — Monitor & Window Hotkeys GNOME Shell extension.
 *
 * Provides keyboard shortcuts (and a D-Bus API) to move the focused window
 * between monitors, tile it to screen halves, and drag it with the pointer. The
 * D-Bus interface (TileRightHalf, …) lets the companion Ctrl+Back tiler systemd
 * service trigger tiling without keybindings.
 *
 * Pointer-driven scaling about the window center has moved to the standalone
 * linux_hotkey_window_tools repository (window-move-resize@local).
 *
 * Components:
 *   - getFocusWindow(): Resolve the focused, user-manageable window.
 *   - moveFocusedWindowToMonitor(): Move the focused window between monitors.
 *   - tileFocusedWindow{Top,Bottom,Left,Right}Half(): Half-screen tiling.
 *   - startPointerDrag()/stopPointerDrag(): Pointer-driven window dragging.
 *   - MonitorWindowHotkeysExtension: Extension lifecycle (enable/disable).
 */
import Shell from 'gi://Shell';
import Meta from 'gi://Meta';
import GLib from 'gi://GLib';
import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import { Extension } from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

const MONITOR_KEYBINDINGS = [
  { name: 'move-active-window-to-monitor-1', monitor: 0 },
  { name: 'move-active-window-to-monitor-2', monitor: 1 },
  { name: 'move-active-window-to-monitor-3', monitor: 2 },
  { name: 'move-active-window-to-monitor-4', monitor: 3 },
  { name: 'move-active-window-to-monitor-5', monitor: 4 },
  { name: 'move-active-window-to-monitor-6', monitor: 5 },
];

const POINTER_POLL_INTERVAL_MS = 8;

// Modifier bits that mean the Super key is held. X11 reports Super as Mod4;
// some layouts also set the dedicated Super bit, so accept either. The pointer
// drag stays active only while Super is held (the <Super> in <Alt><Super>W).
const SUPER_HELD_MASK = Clutter.ModifierType.MOD4_MASK | Clutter.ModifierType.SUPER_MASK;

const POINTER_DRAG_KEY = 'drag-active-window-with-pointer';
const DBUS_BUS_NAME = 'org.gnome.shell.extensions.MonitorWindowHotkeys';
const DBUS_OBJECT_PATH = '/org/gnome/shell/extensions/monitor_window_hotkeys';

// D-Bus XML interface definition for programmatic window tiling.
const DBUS_INTERFACE_XML = `
<node name="/org/gnome/shell/extensions/monitor_window_hotkeys">
  <interface name="org.gnome.shell.extensions.MonitorWindowHotkeys">
    <method name="TileRightHalf"/>
    <method name="TileLeftHalf"/>
    <method name="TileTopHalf"/>
    <method name="TileBottomHalf"/>
    <method name="MoveToMonitor1"/>
    <method name="MoveToMonitor2"/>
    <method name="MoveToMonitor3"/>
    <method name="MoveToMonitor4"/>
    <method name="MoveToMonitor5"/>
    <method name="MoveToMonitor6"/>
  </interface>
</node>`;

/**
 * Return the currently focused, user-manageable window.
 *
 * Windows that are absent or marked skip-taskbar (panels, docks, OSDs) are
 * ignored so hotkeys only ever act on real application windows.
 *
 * @returns {Meta.Window|null} The focused window, or null when none qualifies.
 */
function getFocusWindow() {
  const win = global.display.focus_window;
  const skipTaskbar = typeof win?.is_skip_taskbar === 'function'
    ? win.is_skip_taskbar()
    : win?.skip_taskbar;

  if (!win || skipTaskbar) {
    return null;
  }

  return win;
}

/**
 * Move the focused window to the given monitor.
 *
 * No-ops when there is no focused window, the window cannot be moved, the
 * monitor index is out of range, or the window already lives on that monitor.
 *
 * @param {number} monitorIndex Zero-based index of the destination monitor.
 * @returns {void}
 */
function moveFocusedWindowToMonitor(monitorIndex) {
  const win = getFocusWindow();
  if (!win || typeof win.move_to_monitor !== 'function') {
    return;
  }

  const monitorCount = global.display.get_n_monitors();
  if (monitorIndex < 0 || monitorIndex >= monitorCount) {
    return;
  }

  if (typeof win.get_monitor === 'function' && win.get_monitor() === monitorIndex) {
    return;
  }

  win.move_to_monitor(monitorIndex);
}

/**
 * Unmaximize a window across the differing GNOME Shell/Mutter APIs.
 *
 * Newer Mutter exposes get_maximized(); older versions expose the
 * maximizedHorizontally/maximizedVertically flags. Both paths are handled.
 *
 * @param {Meta.Window} win Window to unmaximize.
 * @returns {void}
 */
function unmaximizeWindow(win) {
  if (typeof win.get_maximized === 'function') {
    const maximized = win.get_maximized();
    if (maximized) {
      win.unmaximize(maximized);
    }
    return;
  }

  if (win.maximizedHorizontally && typeof win.unmaximize === 'function') {
    win.unmaximize(Meta.MaximizeFlags.HORIZONTAL);
  }
  if (win.maximizedVertically && typeof win.unmaximize === 'function') {
    win.unmaximize(Meta.MaximizeFlags.VERTICAL);
  }
}

/**
 * Report whether a window can be both moved and resized.
 *
 * @param {Meta.Window|null} win Candidate window.
 * @returns {boolean} True when the window supports move_resize_frame and any
 *   available allows_resize()/allows_move() checks pass.
 */
function canMoveResizeWindow(win) {
  if (!win || typeof win.move_resize_frame !== 'function') {
    return false;
  }

  // Check allows_resize/allows_move only when those methods exist.
  if (typeof win.allows_resize === 'function' && !win.allows_resize()) {
    return false;
  }
  if (typeof win.allows_move === 'function' && !win.allows_move()) {
    return false;
  }

  return true;
}

/**
 * Report whether a window can be moved (without requiring resize support).
 *
 * @param {Meta.Window|null} win Candidate window.
 * @returns {boolean} True when the window supports move_frame and any available
 *   allows_move() check passes.
 */
function canMoveWindow(win) {
  if (!win || typeof win.move_frame !== 'function') {
    return false;
  }

  if (typeof win.allows_move === 'function' && !win.allows_move()) {
    return false;
  }

  return true;
}

/**
 * Normalize a window's state so it can be freely positioned/resized.
 *
 * Clears maximized, fullscreen, minimized, and always-on-top states when the
 * corresponding methods are available on this GNOME Shell version.
 *
 * @param {Meta.Window} win Window to prepare.
 * @returns {void}
 */
function prepareWindowForMoveResize(win) {
  unmaximizeWindow(win);
  if (typeof win.unmake_fullscreen === 'function') {
    win.unmake_fullscreen();
  }
  if (typeof win.unminimize === 'function') {
    win.unminimize();
  }
  if (typeof win.unmake_above === 'function') {
    win.unmake_above();
  }
}

/**
 * Raise a window to the top and mark it most-recently-used.
 *
 * Uses the workspace-aware API when present, otherwise falls back to the
 * legacy raise_and_make_recent().
 *
 * @param {Meta.Window} win Window to raise.
 * @returns {void}
 */
function raiseWindow(win) {
  if (typeof win.raise_and_make_recent_on_workspace === 'function') {
    win.raise_and_make_recent_on_workspace(global.workspace_manager.get_active_workspace());
  } else if (typeof win.raise_and_make_recent === 'function') {
    win.raise_and_make_recent();
  }
}

/**
 * Resolve a valid monitor index for a window.
 *
 * Mutter aborts the entire shell (assertion `which_monitor >= 0` in
 * meta_window_get_work_area_for_monitor) when get_work_area_for_monitor() or
 * move_to_monitor() is called with -1. win.get_monitor() returns -1 while a
 * window is transiently off all monitors, e.g. mid workspace-switch animation.
 * Because that abort is at the C level it cannot be caught with try/catch, so
 * every monitor lookup must be clamped to a usable index here. Falls back to
 * the current monitor and finally returns -1 when no monitor is available, so
 * callers can bail out instead of crashing the shell.
 *
 * @param {Meta.Window} win Window whose monitor is requested.
 * @returns {number} A valid zero-based monitor index, or -1 when none exists.
 */
function resolveWindowMonitor(win) {
  const monitorCount = global.display.get_n_monitors();
  if (monitorCount <= 0) {
    return -1;
  }

  let index = typeof win.get_monitor === 'function' ? win.get_monitor() : -1;
  if (index < 0 || index >= monitorCount) {
    index = global.display.get_current_monitor();
  }
  if (index < 0 || index >= monitorCount) {
    return -1;
  }

  return index;
}

/**
 * Get the usable work area (excluding panels) for a window's monitor.
 *
 * @param {Meta.Window} win Window whose monitor work area is requested.
 * @returns {Meta.Rectangle|null} The work area rectangle for that monitor, or
 *   null when the window is not on any valid monitor.
 */
function getWindowWorkArea(win) {
  const monitorIndex = resolveWindowMonitor(win);
  if (monitorIndex < 0) {
    return null;
  }

  return win.get_work_area_for_monitor(monitorIndex);
}

/**
 * Test whether an event signals the end of a pointer drag.
 *
 * @param {Clutter.Event} event Event received from the captured-event signal.
 * @returns {boolean} True for a primary (left) mouse button release.
 */
function pointerDragReleaseEvent(event) {
  if (event.type !== Clutter.EventType.BUTTON_RELEASE) {
    return false;
  }

  const button = event.get_button();
  return button === 1;
}

/**
 * Stop an in-progress pointer drag and settle the window in place.
 *
 * Cancels the drag timeout, clamps the window inside its work area, raises it,
 * and clears the drag state. Safe to call when no drag is active.
 *
 * @param {{timeoutId: ?number, window: ?Meta.Window}} state Pointer drag state.
 * @returns {void}
 */
function stopPointerDrag(state) {
  if (!state) {
    return;
  }

  if (state.timeoutId) {
    GLib.source_remove(state.timeoutId);
    state.timeoutId = null;
  }

  const win = state.window;
  if (!win) {
    return;
  }

  try {
    prepareWindowForMoveResize(win);
    const workArea = getWindowWorkArea(win);
    if (!workArea) {
      return;
    }
    const frame = win.get_frame_rect();

    // Clamp to work area.
    let x = Math.max(workArea.x, Math.min(frame.x, workArea.x + workArea.width - frame.width));
    let y = Math.max(workArea.y, Math.min(frame.y, workArea.y + workArea.height - frame.height));

    win.move_frame(true, x, y);
    raiseWindow(win);
  } catch (error) {
    console.error(`monitor-window-hotkeys: failed to stop pointer drag: ${error}`);
  }

  state.window = null;
}

/**
 * Begin dragging the focused window with the pointer.
 *
 * Records the pointer-to-frame offset and installs a periodic timeout
 * (POINTER_POLL_INTERVAL_MS) that follows the pointer. The drag is held: it
 * ends as soon as Super is released (mirroring center scaling), and also via
 * stopPointerDrag() on a left-button release. No-ops when a drag is already
 * active or the focused window cannot be moved. Errors are logged.
 *
 * @param {{timeoutId: ?number, window: ?Meta.Window, pointerX: number,
 *   pointerY: number, armed: boolean}} state Pointer drag state to populate.
 * @returns {void}
 */
function startPointerDrag(state) {
  if (!state) {
    return;
  }

  // Never stack a second drag on top of a live one. Re-entry (e.g. spamming
  // the chord) would orphan the previous timeout — it keeps running because
  // state.window is still set — and every leaked 8ms source calls move_frame()
  // + raiseWindow(), piling up until the shell is overwhelmed and crashes.
  if (state.timeoutId) {
    return;
  }

  const win = getFocusWindow();
  if (!canMoveWindow(win)) {
    return;
  }

  try {
    prepareWindowForMoveResize(win);
    state.window = win;
    const [pointerX, pointerY] = global.get_pointer();
    const frame = win.get_frame_rect();
    state.pointerX = pointerX - frame.x;
    state.pointerY = pointerY - frame.y;
    // Only auto-stop on Super release once Super has actually been seen held,
    // so the chord settling on the first poll cannot end the drag instantly.
    state.armed = false;

    // Start a timeout to handle the drag.
    state.timeoutId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, POINTER_POLL_INTERVAL_MS, () => {
      if (!state || !state.window) {
        return GLib.SOURCE_REMOVE;
      }

      const win = state.window;
      const [pointerX, pointerY, mods] = global.get_pointer();

      // The drag is "while held": end the moment the Super key is let go (after
      // it has been seen held). Without this the window keeps tracking the
      // pointer forever, since the only other exit is a left-button release.
      const superHeld = (mods & SUPER_HELD_MASK) !== 0;
      if (superHeld) {
        state.armed = true;
      } else if (state.armed) {
        // Clear without source_remove(): returning SOURCE_REMOVE removes this
        // very source, so removing it here too would double-free.
        state.timeoutId = null;
        state.window = null;
        raiseWindow(win);
        return GLib.SOURCE_REMOVE;
      }

      let newX = pointerX - state.pointerX;
      let newY = pointerY - state.pointerY;

      // Clamp to work area.
      const workArea = getWindowWorkArea(win);
      if (!workArea) {
        return GLib.SOURCE_CONTINUE;
      }
      newX = Math.max(workArea.x, Math.min(newX, workArea.x + workArea.width - win.get_frame_rect().width));
      newY = Math.max(workArea.y, Math.min(newY, workArea.y + workArea.height - win.get_frame_rect().height));

      win.move_frame(true, newX, newY);
      raiseWindow(win);

      return GLib.SOURCE_CONTINUE;
    });
  } catch (error) {
    console.error(`monitor-window-hotkeys: failed to start pointer drag: ${error}`);
  }
}

/**
 * Tile the focused window to a sub-rectangle of its monitor's work area.
 *
 * Shared implementation behind the top/bottom/left/right half tilers: it
 * resolves the focused window's monitor, asks computeRect() for the target
 * geometry, and applies it. No-ops when the window cannot be move/resized or
 * the computed rectangle is degenerate. Errors are logged, never thrown.
 *
 * @param {string} label Edge name used in error messages (e.g. 'top').
 * @param {(workArea: Meta.Rectangle) => {x: number, y: number, width: number,
 *   height: number}} computeRect Maps the monitor work area to the target rect.
 * @returns {void}
 */
function tileFocusedWindowToRect(label, computeRect) {
  const win = getFocusWindow();
  if (!canMoveResizeWindow(win)) {
    return;
  }

  try {
    prepareWindowForMoveResize(win);

    const monitorIndex = resolveWindowMonitor(win);
    if (monitorIndex < 0) {
      return;
    }
    const workArea = win.get_work_area_for_monitor(monitorIndex);
    const { x, y, width, height } = computeRect(workArea);

    if (width <= 0 || height <= 0) {
      return;
    }

    if (typeof win.move_to_monitor === 'function') {
      win.move_to_monitor(monitorIndex);
    }
    if (typeof win.move_frame === 'function') {
      win.move_frame(true, x, y);
    }
    win.move_resize_frame(true, x, y, width, height);
    raiseWindow(win);
  } catch (error) {
    console.error(`monitor-window-hotkeys: failed to tile focused window ${label}: ${error}`);
  }
}

/**
 * Tile the focused window to the top half of its monitor's work area.
 *
 * @returns {void}
 */
function tileFocusedWindowTopHalf() {
  tileFocusedWindowToRect('top', (workArea) => ({
    x: workArea.x,
    y: workArea.y,
    width: workArea.width,
    height: Math.floor(workArea.height / 2),
  }));
}

/**
 * Tile the focused window to the bottom half of its monitor's work area.
 *
 * @returns {void}
 */
function tileFocusedWindowBottomHalf() {
  tileFocusedWindowToRect('bottom', (workArea) => {
    const halfHeight = Math.floor(workArea.height / 2);
    return {
      x: workArea.x,
      y: workArea.y + halfHeight,
      width: workArea.width,
      height: halfHeight,
    };
  });
}

/**
 * Tile the focused window to the left half of its monitor's work area.
 *
 * @returns {void}
 */
function tileFocusedWindowLeftHalf() {
  tileFocusedWindowToRect('left', (workArea) => {
    const leftWidth = Math.floor(workArea.width / 2);
    return {
      x: workArea.x,
      y: workArea.y,
      width: workArea.width - leftWidth,
      height: workArea.height,
    };
  });
}

/**
 * Tile the focused window to the right half of its monitor's work area.
 *
 * Also invoked over D-Bus (TileRightHalf) by the Ctrl+Back tiler service.
 *
 * @returns {void}
 */
function tileFocusedWindowRightHalf() {
  tileFocusedWindowToRect('right', (workArea) => {
    const leftWidth = Math.floor(workArea.width / 2);
    return {
      x: workArea.x + leftWidth,
      y: workArea.y,
      width: workArea.width - leftWidth,
      height: workArea.height,
    };
  });
}

/**
 * GNOME Shell extension entry point for monitor/window hotkeys.
 *
 * On enable() it exports the D-Bus tiling interface, registers every keybinding
 * defined in the extension schema, and listens for pointer-drag releases. On
 * disable() it tears all of that down so the extension can be cleanly reloaded.
 */
export default class MonitorWindowHotkeysExtension extends Extension {
  /**
   * Export the D-Bus interface and register all keybindings and listeners.
   *
   * @returns {void}
   */
  enable() {
    this._settings = this.getSettings();
    this._keybindings = [];
    this._pointerDragState = {
      timeoutId: null,
      window: null,
      pointerX: 0,
      pointerY: 0,
      armed: false,
    };

    const dbusImplementation = {
      TileRightHalf: tileFocusedWindowRightHalf,
      TileLeftHalf: tileFocusedWindowLeftHalf,
      TileTopHalf: tileFocusedWindowTopHalf,
      TileBottomHalf: tileFocusedWindowBottomHalf,
      MoveToMonitor1: () => moveFocusedWindowToMonitor(0),
      MoveToMonitor2: () => moveFocusedWindowToMonitor(1),
      MoveToMonitor3: () => moveFocusedWindowToMonitor(2),
      MoveToMonitor4: () => moveFocusedWindowToMonitor(3),
      MoveToMonitor5: () => moveFocusedWindowToMonitor(4),
      MoveToMonitor6: () => moveFocusedWindowToMonitor(5),
    };
    this._dbusObject = Gio.DBusExportedObject.wrapJSObject(
      DBUS_INTERFACE_XML,
      dbusImplementation,
    );
    this._dbusObject.export(Gio.DBus.session, DBUS_OBJECT_PATH);
    this._dbusOwnerId = Gio.bus_own_name_on_connection(
      Gio.DBus.session,
      DBUS_BUS_NAME,
      Gio.BusNameOwnerFlags.NONE,
      null,
      null,
    );

    this._capturedEventId = global.stage.connect('captured-event', (actor, event) => {
      if (this._pointerDragState?.timeoutId && pointerDragReleaseEvent(event)) {
        stopPointerDrag(this._pointerDragState);
      }

      return Clutter.EVENT_PROPAGATE;
    });

    for (const binding of MONITOR_KEYBINDINGS) {
      Main.wm.addKeybinding(
        binding.name,
        this._settings,
        Meta.KeyBindingFlags.NONE,
        Shell.ActionMode.NORMAL,
        () => moveFocusedWindowToMonitor(binding.monitor),
      );
      this._keybindings.push(binding.name);
    }

    Main.wm.addKeybinding(
      'tile-active-window-right-half',
      this._settings,
      Meta.KeyBindingFlags.NONE,
      Shell.ActionMode.NORMAL,
      tileFocusedWindowRightHalf,
    );
    this._keybindings.push('tile-active-window-right-half');
    Main.wm.addKeybinding(
      'tile-top-half',
      this._settings,
      Meta.KeyBindingFlags.NONE,
      Shell.ActionMode.NORMAL,
      () => tileFocusedWindowTopHalf(),
    );
    this._keybindings.push('tile-top-half');

    Main.wm.addKeybinding(
      'tile-bottom-half',
      this._settings,
      Meta.KeyBindingFlags.NONE,
      Shell.ActionMode.NORMAL,
      () => tileFocusedWindowBottomHalf(),
    );
    this._keybindings.push('tile-bottom-half');

    Main.wm.addKeybinding(
      'tile-left-half',
      this._settings,
      Meta.KeyBindingFlags.NONE,
      Shell.ActionMode.NORMAL,
      () => tileFocusedWindowLeftHalf(),
    );
    this._keybindings.push('tile-left-half');

    Main.wm.addKeybinding(
      POINTER_DRAG_KEY,
      this._settings,
      Meta.KeyBindingFlags.NONE,
      Shell.ActionMode.NORMAL,
      () => {
        // Hold-to-drag: start on press; releasing Super (or a left-button
        // click) ends it. Ignore re-triggers while already active so spamming
        // the chord cannot stack timeouts and overwhelm the shell.
        if (!this._pointerDragState?.timeoutId) {
          startPointerDrag(this._pointerDragState);
        }
      },
    );
    this._keybindings.push(POINTER_DRAG_KEY);
  }

  /**
   * Unregister keybindings, listeners, and the D-Bus interface, releasing all
   * resources acquired in enable().
   *
   * @returns {void}
   */
  disable() {
    if (this._dbusOwnerId) {
      Gio.bus_unown_name(this._dbusOwnerId);
      this._dbusOwnerId = null;
    }

    if (this._dbusObject) {
      this._dbusObject.unexport();
      this._dbusObject = null;
    }

    if (this._pointerDragState) {
      stopPointerDrag(this._pointerDragState);
      this._pointerDragState = null;
    }

    if (this._capturedEventId) {
      global.stage.disconnect(this._capturedEventId);
      this._capturedEventId = null;
    }

    if (this._keybindings) {
      for (const bindingName of this._keybindings) {
        Main.wm.removeKeybinding(bindingName);
      }
      this._keybindings = null;
    }

    this._settings = null;
  }
}
