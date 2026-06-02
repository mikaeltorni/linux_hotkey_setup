import Shell from 'gi://Shell';
import Meta from 'gi://Meta';
import GLib from 'gi://GLib';
import Clutter from 'gi://Clutter';
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

const RESIZE_STEP = 40;
const POINTER_DRAG_INTERVAL_MS = 8;
const POINTER_DRAG_MODIFIERS = Clutter.ModifierType.MOD1_MASK | Clutter.ModifierType.MOD4_MASK;
const MIN_WINDOW_WIDTH = 160;
const MIN_WINDOW_HEIGHT = 120;

const RESIZE_KEYBINDINGS = [
  { name: 'resize-active-window-left-out', edge: 'left', direction: -1 },
  { name: 'resize-active-window-left-in', edge: 'left', direction: 1 },
  { name: 'resize-active-window-right-out', edge: 'right', direction: 1 },
  { name: 'resize-active-window-right-in', edge: 'right', direction: -1 },
  { name: 'resize-active-window-up-out', edge: 'top', direction: -1 },
  { name: 'resize-active-window-up-in', edge: 'top', direction: 1 },
  { name: 'resize-active-window-down-out', edge: 'bottom', direction: 1 },
  { name: 'resize-active-window-down-in', edge: 'bottom', direction: -1 },
];

const POINTER_DRAG_KEY = 'drag-active-window-with-pointer';

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

function canMoveResizeWindow(win) {
  if (!win || typeof win.move_resize_frame !== 'function') {
    return false;
  }

  if (
    (typeof win.allows_resize === 'function' && !win.allows_resize()) ||
    (typeof win.allows_move === 'function' && !win.allows_move())
  ) {
    return false;
  }

  return true;
}

function canMoveWindow(win) {
  if (!win || typeof win.move_frame !== 'function') {
    return false;
  }

  if (typeof win.allows_move === 'function' && !win.allows_move()) {
    return false;
  }

  return true;
}

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

function raiseWindow(win) {
  if (typeof win.raise_and_make_recent_on_workspace === 'function') {
    win.raise_and_make_recent_on_workspace(global.workspace_manager.get_active_workspace());
  } else if (typeof win.raise_and_make_recent === 'function') {
    win.raise_and_make_recent();
  }
}

function getWindowWorkArea(win) {
  const monitorIndex = typeof win.get_monitor === 'function'
    ? win.get_monitor()
    : global.display.get_current_monitor();

  return win.get_work_area_for_monitor(monitorIndex);
}

function resizeFocusedWindow(edge, direction) {
  const win = getFocusWindow();
  if (!canMoveResizeWindow(win)) {
    return;
  }

  try {
    prepareWindowForMoveResize(win);

    const frame = win.get_frame_rect();
    const workArea = getWindowWorkArea(win);
    let x = frame.x;
    let y = frame.y;
    let width = frame.width;
    let height = frame.height;
    const delta = direction * RESIZE_STEP;

    switch (edge) {
    case 'left': {
      const newX = Math.max(workArea.x, Math.min(x + delta, x + width - MIN_WINDOW_WIDTH));
      width += x - newX;
      x = newX;
      break;
    }
    case 'right': {
      const right = Math.max(x + MIN_WINDOW_WIDTH, Math.min(x + width + delta, workArea.x + workArea.width));
      width = right - x;
      break;
    }
    case 'top': {
      const newY = Math.max(workArea.y, Math.min(y + delta, y + height - MIN_WINDOW_HEIGHT));
      height += y - newY;
      y = newY;
      break;
    }
    case 'bottom': {
      const bottom = Math.max(y + MIN_WINDOW_HEIGHT, Math.min(y + height + delta, workArea.y + workArea.height));
      height = bottom - y;
      break;
    }
    default:
      return;
    }

    if (width <= 0 || height <= 0) {
      return;
    }

    win.move_resize_frame(true, x, y, width, height);
    raiseWindow(win);
  } catch (error) {
    console.error(`monitor-window-hotkeys: failed to resize focused window: ${error}`);
  }
}

function pointerDragModifiersHeld() {
  const [, , modifiers] = global.get_pointer();
  return (modifiers & POINTER_DRAG_MODIFIERS) === POINTER_DRAG_MODIFIERS;
}

function startPointerDrag(state) {
  if (state.timeoutId) {
    return true;
  }

  const win = getFocusWindow();
  if (!canMoveWindow(win)) {
    return false;
  }

  try {
    prepareWindowForMoveResize(win);

    const [pointerX, pointerY] = global.get_pointer();
    const frame = win.get_frame_rect();

    state.window = win;
    state.pointerX = pointerX;
    state.pointerY = pointerY;
    state.windowX = frame.x;
    state.windowY = frame.y;
    state.timeoutId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, POINTER_DRAG_INTERVAL_MS, () => {
      const activeWindow = state.window;
      if (!activeWindow || !canMoveWindow(activeWindow) || !pointerDragModifiersHeld()) {
        state.timeoutId = null;
        state.window = null;
        return GLib.SOURCE_REMOVE;
      }

      const [currentX, currentY] = global.get_pointer();
      activeWindow.move_frame(
        true,
        state.windowX + currentX - state.pointerX,
        state.windowY + currentY - state.pointerY,
      );
      raiseWindow(activeWindow);

      return GLib.SOURCE_CONTINUE;
    });

    return true;
  } catch (error) {
    console.error(`monitor-window-hotkeys: failed to start pointer window drag: ${error}`);
    return false;
  }
}

function stopPointerDrag(state) {
  if (state.timeoutId) {
    GLib.Source.remove(state.timeoutId);
  }

  state.timeoutId = null;
  state.window = null;
  state.pointerX = 0;
  state.pointerY = 0;
  state.windowX = 0;
  state.windowY = 0;
}

function pointerDragReleaseEvent(event) {
  if (event.type() !== Clutter.EventType.KEY_RELEASE) {
    return false;
  }

  const keySymbol = event.get_key_symbol();
  return keySymbol === Clutter.KEY_w || keySymbol === Clutter.KEY_W;
}

function tileFocusedWindowTopHalf() {
  const win = getFocusWindow();
  if (!canMoveResizeWindow(win)) {
    return;
  }

  try {
    prepareWindowForMoveResize(win);

    const monitorIndex = typeof win.get_monitor === 'function'
      ? win.get_monitor()
      : global.display.get_current_monitor();
    const workArea = win.get_work_area_for_monitor(monitorIndex);
    const topHeight = Math.floor(workArea.height / 2);
    const x = workArea.x;
    const y = workArea.y;
    const width = workArea.width;
    const height = topHeight;

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
    console.error(`monitor-window-hotkeys: failed to tile focused window top: ${error}`);
  }
}

function tileFocusedWindowBottomHalf() {
  const win = getFocusWindow();
  if (!canMoveResizeWindow(win)) {
    return;
  }

  try {
    prepareWindowForMoveResize(win);

    const monitorIndex = typeof win.get_monitor === 'function'
      ? win.get_monitor()
      : global.display.get_current_monitor();
    const workArea = win.get_work_area_for_monitor(monitorIndex);
    const bottomY = workArea.y + Math.floor(workArea.height / 2);
    const x = workArea.x;
    const y = bottomY;
    const width = workArea.width;
    const height = workArea.height - Math.floor(workArea.height / 2);

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
    console.error(`monitor-window-hotkeys: failed to tile focused window bottom: ${error}`);
  }
}

function tileFocusedWindowLeftHalf() {
  const win = getFocusWindow();
  if (!canMoveResizeWindow(win)) {
    return;
  }

  try {
    prepareWindowForMoveResize(win);

    const monitorIndex = typeof win.get_monitor === 'function'
      ? win.get_monitor()
      : global.display.get_current_monitor();
    const workArea = win.get_work_area_for_monitor(monitorIndex);
    const leftWidth = Math.floor(workArea.width / 2);
    const x = workArea.x;
    const y = workArea.y;
    const width = leftWidth;
    const height = workArea.height;

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
    console.error(`monitor-window-hotkeys: failed to tile focused window left: ${error}`);
  }
}

function tileFocusedWindowRightHalf() {
  const win = getFocusWindow();
  if (!canMoveResizeWindow(win)) {
    return;
  }

  try {
    prepareWindowForMoveResize(win);

    const monitorIndex = typeof win.get_monitor === 'function'
      ? win.get_monitor()
      : global.display.get_current_monitor();
    const workArea = win.get_work_area_for_monitor(monitorIndex);
    const leftWidth = Math.floor(workArea.width / 2);
    const x = workArea.x + leftWidth;
    const y = workArea.y;
    const width = workArea.width - leftWidth;
    const height = workArea.height;

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
    console.error(`monitor-window-hotkeys: failed to tile focused window right: ${error}`);
  }
}

export default class MonitorWindowHotkeysExtension extends Extension {
  enable() {
    this._settings = this.getSettings();
    this._keybindings = [];
    this._pointerDragState = {
      timeoutId: null,
      window: null,
      pointerX: 0,
      pointerY: 0,
      windowX: 0,
      windowY: 0,
    };
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

    for (const binding of RESIZE_KEYBINDINGS) {
      Main.wm.addKeybinding(
        binding.name,
        this._settings,
        Meta.KeyBindingFlags.NONE,
        Shell.ActionMode.NORMAL,
        () => resizeFocusedWindow(binding.edge, binding.direction),
      );
      this._keybindings.push(binding.name);
    }

    Main.wm.addKeybinding(
      POINTER_DRAG_KEY,
      this._settings,
      Meta.KeyBindingFlags.NONE,
      Shell.ActionMode.NORMAL,
      () => startPointerDrag(this._pointerDragState),
    );
    this._keybindings.push(POINTER_DRAG_KEY);
  }

  disable() {
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
