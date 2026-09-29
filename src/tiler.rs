//! Ctrl + mouse-Back window-placement tiler.
//!
//! Grabs the selected pointer, forwards every other event through a virtual
//! uinput device, and calls the monitor-window-hotkeys D-Bus `TileRightHalf`
//! method when the configured modifier + button chord is pressed.

use std::collections::HashSet;
use std::env;
use std::fs;
use std::os::unix::io::AsRawFd;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use evdev::uinput::VirtualDeviceBuilder;
use evdev::{Device, EventType, InputEvent, Key, RelativeAxisType};
use nix::sys::select::{select, FdSet};
use nix::sys::time::{TimeVal, TimeValLike};

use crate::logging;

const EV_KEY: u16 = 1;
const KEY_LEFTCTRL: u16 = 29;
const KEY_RIGHTCTRL: u16 = 97;
const KEY_LEFTALT: u16 = 56;
const KEY_RIGHTALT: u16 = 100;
const KEY_LEFTMETA: u16 = 125;
const KEY_RIGHTMETA: u16 = 126;
const KEY_LEFTSHIFT: u16 = 42;
const KEY_RIGHTSHIFT: u16 = 54;
const KEY_BACK: u16 = 158;
const BTN_SIDE: u16 = 275;
const BTN_EXTRA: u16 = 276;
const BTN_FORWARD: u16 = 277;

const VIRTUAL_DEVICE_NAME: &str = "ctrl-back-window-tiler";
const DBUS_BUS_NAME: &str = "org.gnome.shell.extensions.MonitorWindowHotkeys";
const DBUS_OBJECT_PATH: &str = "/org/gnome/shell/extensions/monitor_window_hotkeys";
const DBUS_INTERFACE: &str = "org.gnome.shell.extensions.MonitorWindowHotkeys";
const TOPOLOGY_CHECK_INTERVAL: Duration = Duration::from_secs(2);
const MAX_FORWARD_PACKET_EVENTS: usize = 256;
/// How often the tiler re-reads modifier key state from watched keyboards.
///
/// Event streaming alone is not enough: another daemon (Phrase Automation's
/// section interceptor) holds an exclusive `EVIOCGRAB` on the keyboards, so
/// no modifier events ever reach this service. `EVIOCGKEY` state reads keep
/// working through a foreign grab, so the chord is detected from state.
const MODIFIER_POLL_INTERVAL: Duration = Duration::from_millis(20);

/// Sort event device paths by their numeric `eventN` suffix when available.
pub fn input_device_sort_key(path: &str) -> (u8, String) {
    if let Some(suffix) = path.rsplit_once("event").map(|(_, s)| s) {
        if path.contains("/dev/input/") && suffix.chars().all(|c| c.is_ascii_digit()) {
            return (0, format!("{suffix:0>8}"));
        }
    }
    (1, path.to_string())
}

fn modifier_codes_for(name: &str) -> HashSet<u16> {
    match name {
        "Control" => HashSet::from([KEY_LEFTCTRL, KEY_RIGHTCTRL]),
        "Alt" => HashSet::from([KEY_LEFTALT, KEY_RIGHTALT]),
        "Super" => HashSet::from([KEY_LEFTMETA, KEY_RIGHTMETA]),
        "Shift" => HashSet::from([KEY_LEFTSHIFT, KEY_RIGHTSHIFT]),
        _ => HashSet::new(),
    }
}

fn button_codes_for(name: &str) -> HashSet<u16> {
    match name {
        "BTN_FORWARD" => HashSet::from([BTN_FORWARD, BTN_EXTRA]),
        _ => HashSet::from([KEY_BACK, BTN_SIDE, BTN_EXTRA]),
    }
}

/// Return evdev codes for `WINDOW_PLACEMENT_TILE_MODIFIER` (default Control).
pub fn configured_modifier_codes() -> HashSet<u16> {
    let names = env::var("WINDOW_PLACEMENT_TILE_MODIFIER").unwrap_or_else(|_| "Control".into());
    let mut codes = HashSet::new();
    for name in names.replace('|', "+").split('+') {
        codes.extend(modifier_codes_for(name.trim()));
    }
    if codes.is_empty() {
        modifier_codes_for("Control")
    } else {
        codes
    }
}

/// Return evdev codes for `WINDOW_PLACEMENT_TILE_BUTTON` (default BTN_BACK).
pub fn configured_button_codes() -> HashSet<u16> {
    let name = env::var("WINDOW_PLACEMENT_TILE_BUTTON").unwrap_or_else(|_| "BTN_BACK".into());
    button_codes_for(name.trim())
}

/// Resolve a configured stable path against currently available event nodes.
pub fn select_pointer_path(
    target_device: &str,
    current_pointer: &str,
    paths: &[String],
    realpath: impl Fn(&str) -> String,
    reported_missing: &mut bool,
) -> String {
    if !target_device.is_empty() {
        let resolved = realpath(target_device);
        if paths.iter().any(|p| p == &resolved) {
            *reported_missing = false;
            return resolved;
        }
        if !*reported_missing {
            logging::service(
                "WARN",
                format!("configured pointer device is unavailable: {target_device} -> {resolved}"),
            );
            *reported_missing = true;
        }
        return String::new();
    }
    if paths.iter().any(|p| p == current_pointer) {
        return current_pointer.to_string();
    }
    String::new()
}

/// In-memory tiler: tracks modifier state and decides tile vs forward.
pub struct TilerLogic {
    pub ctrl_pressed: HashSet<(String, u16)>,
    pub suppressed: HashSet<(String, u16)>,
    pub forwarded: Vec<(u16, u16, i32)>,
    pub tile_calls: usize,
    pub ui_ok: bool,
    pub ctrl_codes: HashSet<u16>,
    pub back_codes: HashSet<u16>,
    pub forward_codes: HashSet<(u16, u16)>,
}

impl Default for TilerLogic {
    fn default() -> Self {
        Self {
            ctrl_pressed: HashSet::new(),
            suppressed: HashSet::new(),
            forwarded: Vec::new(),
            tile_calls: 0,
            ui_ok: true,
            ctrl_codes: HashSet::from([KEY_LEFTCTRL, KEY_RIGHTCTRL]),
            back_codes: HashSet::from([KEY_BACK, BTN_SIDE, BTN_EXTRA]),
            forward_codes: HashSet::from([(EV_KEY, BTN_SIDE), (EV_KEY, KEY_LEFTCTRL)]),
        }
    }
}

impl TilerLogic {
    /// Replace the modifier state tracked for `path` with a polled snapshot.
    ///
    /// Arguments:
    ///     path: Event node the state was read from, used to namespace keys.
    ///     active: Modifier codes currently held down on that device.
    ///
    /// Keeping poll and event updates in the same `(path, code)` namespace
    /// makes the two sources idempotent for devices that deliver both.
    pub fn apply_modifier_state(&mut self, path: &str, active: &HashSet<u16>) {
        for code in self.ctrl_codes.clone() {
            let key = (path.to_string(), code);
            if active.contains(&code) {
                self.ctrl_pressed.insert(key);
            } else {
                self.ctrl_pressed.remove(&key);
            }
        }
    }

    /// Drop modifier and suppression state for devices that went away.
    ///
    /// Arguments:
    ///     live_paths: Event nodes still watched after a rescan.
    ///
    /// Without this, a removed keyboard could leave a modifier stuck down and
    /// hold the pointer in an exclusive grab forever.
    pub fn forget_missing_devices(&mut self, live_paths: &HashSet<String>) {
        self.ctrl_pressed
            .retain(|(path, _)| live_paths.contains(path));
        self.suppressed
            .retain(|(path, _)| live_paths.contains(path));
    }

    /// Handle one EV_KEY event from `path`.
    pub fn handle_key(&mut self, path: &str, grabbed: bool, code: u16, value: i32) {
        if self.ctrl_codes.contains(&code) {
            let key = (path.to_string(), code);
            if value == 0 {
                self.ctrl_pressed.remove(&key);
            } else {
                self.ctrl_pressed.insert(key);
            }
            if grabbed {
                self.forward(EV_KEY, code, value);
            }
            return;
        }
        if self.back_codes.contains(&code) {
            let key = (path.to_string(), code);
            if value == 1 && grabbed && !self.ctrl_pressed.is_empty() {
                self.suppressed.insert(key);
                self.tile_calls += 1;
                return;
            }
            if self.suppressed.contains(&key) {
                if value == 0 {
                    self.suppressed.remove(&key);
                }
                return;
            }
            if grabbed {
                self.forward(EV_KEY, code, value);
            }
            return;
        }
        if grabbed {
            self.forward(EV_KEY, code, value);
        }
    }

    /// Forward a non-key event from a grabbed pointer.
    pub fn handle_other(&mut self, grabbed: bool, event_type: u16, code: u16, value: i32) {
        if grabbed {
            self.forward(event_type, code, value);
        }
    }

    fn forward(&mut self, event_type: u16, code: u16, value: i32) {
        if !self.ui_ok {
            return;
        }
        if !self.forward_codes.contains(&(event_type, code)) {
            return;
        }
        self.forwarded.push((event_type, code, value));
    }
}

fn tile_right() {
    let status = std::process::Command::new("busctl")
        .args([
            "--user",
            "call",
            DBUS_BUS_NAME,
            DBUS_OBJECT_PATH,
            DBUS_INTERFACE,
            "TileRightHalf",
        ])
        .status();
    match status {
        Ok(st) if st.success() => {
            logging::service("INFO", "tiled focused window to the right half")
        }
        Ok(st) => logging::service("ERROR", format!("D-Bus tiling failed: status {st}")),
        Err(err) => logging::service("ERROR", format!("D-Bus tiling failed: {err}")),
    }
}

fn stable_device_path(path: &Path) -> PathBuf {
    let Ok(resolved) = fs::canonicalize(path) else {
        return path.to_path_buf();
    };
    let by_id = Path::new("/dev/input/by-id");
    if let Ok(entries) = fs::read_dir(by_id) {
        let mut aliases: Vec<PathBuf> = entries
            .flatten()
            .map(|e| e.path())
            .filter(|p| {
                p.file_name()
                    .and_then(|n| n.to_str())
                    .is_some_and(|n| n.contains("event-mouse"))
                    && fs::canonicalize(p).ok().as_ref() == Some(&resolved)
            })
            .collect();
        aliases.sort();
        if let Some(first) = aliases.into_iter().next() {
            return first;
        }
    }
    path.to_path_buf()
}

fn is_back_pointer(device: &Device) -> bool {
    let keys = device.supported_keys();
    let rels = device.supported_relative_axes();
    let Some(keys) = keys else { return false };
    let Some(rels) = rels else { return false };
    let has_rel = rels.contains(RelativeAxisType::REL_X) && rels.contains(RelativeAxisType::REL_Y);
    let has_back = keys.contains(Key::KEY_BACK)
        || keys.contains(Key::BTN_SIDE)
        || keys.contains(Key::BTN_EXTRA);
    has_rel && has_back
}

/// Print `path|name` lines for back-button pointers (installer device picker).
pub fn list_pointers() -> i32 {
    let mut devices: Vec<(PathBuf, Device)> = evdev::enumerate().collect();
    devices.sort_by_key(|(path, _)| input_device_sort_key(&path.to_string_lossy()));
    for (path, device) in devices {
        let name = device.name().unwrap_or("").to_string();
        if name.contains("Keychron") || name.contains(VIRTUAL_DEVICE_NAME) {
            continue;
        }
        if !is_back_pointer(&device) {
            continue;
        }
        let stable = stable_device_path(&path);
        println!("{}|{name}", stable.display());
    }
    0
}

struct Watched {
    device: Device,
    path: String,
    is_pointer: bool,
    watches_ctrl: bool,
    grabbed: bool,
    grab_failed: bool,
}

/// Return a stable signature for physical evdev nodes without opening them.
///
/// uinput devices are deliberately excluded: Phrase Automation creates and
/// removes virtual relays during normal operation, and that churn must not
/// trigger expensive capability probes against every physical input device.
fn physical_input_topology_entry(name: &str, target: &Path) -> Option<String> {
    (name.starts_with("event") && !is_virtual_input_sysfs_path(target))
        .then(|| format!("{name}:{}", target.display()))
}

fn physical_input_topology() -> Vec<String> {
    let Ok(entries) = fs::read_dir("/sys/class/input") else {
        return Vec::new();
    };
    let mut topology = entries
        .filter_map(Result::ok)
        .filter_map(|entry| {
            let name = entry.file_name().to_string_lossy().into_owned();
            if !name.starts_with("event") {
                return None;
            }
            let target = fs::canonicalize(entry.path()).ok()?;
            physical_input_topology_entry(&name, &target)
        })
        .collect::<Vec<_>>();
    topology.sort();
    topology
}

/// Run the tiler service until the process is stopped.
pub fn run() -> ! {
    logging::service("INFO", "running in direct D-Bus mode");
    let target = env::var("CTRL_BACK_TILE_DEVICE").unwrap_or_default();
    let mut logic = TilerLogic {
        ctrl_codes: configured_modifier_codes(),
        back_codes: configured_button_codes(),
        ..TilerLogic::default()
    };
    let mut watched: Vec<Watched> = Vec::new();
    let mut virtual_dev = None;
    let mut topology = Vec::new();
    let mut last_topology_check = Instant::now() - TOPOLOGY_CHECK_INTERVAL;
    let mut last_modifier_poll = Instant::now() - MODIFIER_POLL_INTERVAL;
    let mut rescan_requested = true;
    let mut reported_missing = false;
    let mut pointer_path = target.clone();

    loop {
        if last_topology_check.elapsed() >= TOPOLOGY_CHECK_INTERVAL {
            let current_topology = physical_input_topology();
            if current_topology != topology {
                topology = current_topology;
                rescan_requested = true;
            }
            last_topology_check = Instant::now();
        }
        if rescan_requested {
            rescan(
                &target,
                &mut pointer_path,
                &mut reported_missing,
                &mut watched,
                &mut logic,
                &mut virtual_dev,
            );
            rescan_requested = false;
        }
        if watched.is_empty() {
            std::thread::sleep(TOPOLOGY_CHECK_INTERVAL);
            continue;
        }
        if last_modifier_poll.elapsed() >= MODIFIER_POLL_INTERVAL {
            poll_modifier_state(&watched, &mut logic);
            sync_pointer_grabs(&mut watched, &logic, virtual_dev.is_some() && logic.ui_ok);
            last_modifier_poll = Instant::now();
        }
        let mut fds = FdSet::new();
        let mut max_fd = 0;
        for entry in &watched {
            let fd = entry.device.as_raw_fd();
            fds.insert(fd);
            if fd > max_fd {
                max_fd = fd;
            }
        }
        let mut timeout = TimeVal::milliseconds(MODIFIER_POLL_INTERVAL.as_millis() as i64);
        match select(max_fd + 1, Some(&mut fds), None, None, Some(&mut timeout)) {
            Ok(0) | Err(_) => continue,
            Ok(_) => {}
        }
        let ready: Vec<i32> = watched
            .iter()
            .map(|e| e.device.as_raw_fd())
            .filter(|fd| fds.contains(*fd))
            .collect();
        let mut disconnected = false;
        for fd in ready {
            let Some(idx) = watched.iter().position(|e| e.device.as_raw_fd() == fd) else {
                continue;
            };
            let events = match watched[idx].device.fetch_events() {
                Ok(iter) => iter.collect::<Vec<_>>(),
                Err(err) => {
                    logging::service("WARN", format!("device read failed: {err}"));
                    disconnected = true;
                    break;
                }
            };
            let path = watched[idx].path.clone();
            for event in events {
                let grabbed = watched[idx].grabbed;
                handle_live_event(&mut logic, &mut virtual_dev, &path, grabbed, event);
                sync_pointer_grabs(&mut watched, &logic, virtual_dev.is_some() && logic.ui_ok);
            }
        }
        if disconnected {
            watched.clear();
            // Closed nodes can never report a modifier release, so drop their
            // state instead of leaving the pointer grabbed on a phantom chord.
            logic.forget_missing_devices(&HashSet::new());
            rescan_requested = true;
            if target.is_empty() {
                pointer_path.clear();
            }
        }
    }
}

/// Refresh modifier state from every watched keyboard via `EVIOCGKEY`.
///
/// Arguments:
///     watched: Currently open input devices.
///     logic: Tiler state whose `ctrl_pressed` set is updated in place.
///
/// State reads keep working while another process holds an exclusive grab on
/// the keyboard, which event reads do not.
fn poll_modifier_state(watched: &[Watched], logic: &mut TilerLogic) {
    let codes = logic.ctrl_codes.clone();
    for entry in watched.iter().filter(|entry| entry.watches_ctrl) {
        let Ok(state) = entry.device.get_key_state() else {
            continue;
        };
        let active: HashSet<u16> = state
            .iter()
            .map(|key| key.code())
            .filter(|code| codes.contains(code))
            .collect();
        logic.apply_modifier_state(&entry.path, &active);
    }
}

fn handle_live_event(
    logic: &mut TilerLogic,
    virtual_dev: &mut Option<evdev::uinput::VirtualDevice>,
    path: &str,
    grabbed: bool,
    event: InputEvent,
) {
    let event_type = event.event_type().0;
    let code = event.code();
    let value = event.value();
    let packet_boundary = event.event_type() == EventType::SYNCHRONIZATION && code == 0;
    let tiles_before = logic.tile_calls;
    if event.event_type() == EventType::KEY {
        logic.handle_key(path, grabbed, code, value);
    } else {
        logic.handle_other(grabbed, event_type, code, value);
    }
    if logic.tile_calls > tiles_before {
        tile_right();
    }
    if let Some(packet) = take_forwarded_packet(logic, packet_boundary) {
        if let Some(ui) = virtual_dev.as_mut() {
            let events: Vec<InputEvent> = packet
                .into_iter()
                .map(|(event_type, code, value)| {
                    InputEvent::new(EventType(event_type), code, value)
                })
                .collect();
            // evdev::VirtualDevice::emit appends exactly one SYN_REPORT. Feed it
            // the physical packet without its boundary so REL_X/REL_Y remain
            // atomic and the virtual device does not generate duplicate SYNs.
            if ui.emit(&events).is_err() {
                logging::service(
                    "ERROR",
                    format!("could not forward input event {event_type}/{code}"),
                );
                *virtual_dev = None;
                logic.ui_ok = false;
            }
        }
    }
}

/// Take a completed physical packet, with a bounded fallback for malformed input.
fn take_forwarded_packet(
    logic: &mut TilerLogic,
    packet_boundary: bool,
) -> Option<Vec<(u16, u16, i32)>> {
    if logic.forwarded.is_empty()
        || (!packet_boundary && logic.forwarded.len() < MAX_FORWARD_PACKET_EVENTS)
    {
        return None;
    }
    Some(std::mem::take(&mut logic.forwarded))
}

/// Keep the physical pointer direct except while the configured chord is live.
fn pointer_should_be_grabbed(logic: &TilerLogic) -> bool {
    !logic.ctrl_pressed.is_empty() || !logic.suppressed.is_empty()
}

/// Enter or leave exclusive pointer capture as the modifier chord changes.
fn sync_pointer_grabs(watched: &mut [Watched], logic: &TilerLogic, relay_available: bool) {
    let should_grab = relay_available && pointer_should_be_grabbed(logic);
    for entry in watched.iter_mut().filter(|entry| entry.is_pointer) {
        if should_grab && !entry.grabbed && !entry.grab_failed {
            match entry.device.grab() {
                Ok(()) => entry.grabbed = true,
                Err(err) => {
                    entry.grab_failed = true;
                    logging::service(
                        "ERROR",
                        format!("could not grab {} for tiling chord: {err}", entry.path),
                    );
                }
            }
        } else if !should_grab && entry.grabbed {
            if let Err(err) = entry.device.ungrab() {
                logging::service(
                    "ERROR",
                    format!("could not release {} after tiling chord: {err}", entry.path),
                );
            }
            entry.grabbed = false;
            entry.grab_failed = false;
        } else if !should_grab {
            // Permit one fresh grab attempt on the next modifier press.
            entry.grab_failed = false;
        }
    }
}

/// Return whether a stable physical device should supply modifier state.
fn should_watch_ctrl_device(name: &str, is_physical: bool, supports_modifier: bool) -> bool {
    supports_modifier && is_physical && !name.starts_with("section-")
}

fn is_virtual_input_sysfs_path(path: &Path) -> bool {
    path.starts_with("/sys/devices/virtual/input")
}

/// Resolve an event node through sysfs and require a stable physical device.
fn is_physical_input_device(path: &Path) -> bool {
    let Some(event_name) = path.file_name() else {
        return false;
    };
    fs::canonicalize(
        Path::new("/sys/class/input")
            .join(event_name)
            .join("device"),
    )
    .is_ok_and(|resolved| !is_virtual_input_sysfs_path(&resolved))
}

fn rescan(
    target: &str,
    pointer_path: &mut String,
    reported_missing: &mut bool,
    watched: &mut Vec<Watched>,
    logic: &mut TilerLogic,
    virtual_dev: &mut Option<evdev::uinput::VirtualDevice>,
) {
    let mut enumerated: Vec<(PathBuf, Device)> = evdev::enumerate().collect();
    enumerated.sort_by_key(|(path, _)| input_device_sort_key(&path.to_string_lossy()));
    let paths: Vec<String> = enumerated
        .iter()
        .map(|(p, _)| p.to_string_lossy().into_owned())
        .collect();
    let mut selected = select_pointer_path(
        target,
        pointer_path,
        &paths,
        |p| {
            fs::canonicalize(p)
                .map(|x| x.to_string_lossy().into_owned())
                .unwrap_or_else(|_| p.to_string())
        },
        reported_missing,
    );
    if selected.is_empty() && target.is_empty() {
        selected = find_pointer_path(&enumerated);
    }
    if !selected.is_empty() {
        *pointer_path = selected;
    }

    let open: HashSet<String> = watched.iter().map(|w| w.path.clone()).collect();
    let mut forward: HashSet<(u16, u16)> = logic.forward_codes.clone();
    for (path, device) in enumerated {
        let path_s = path.to_string_lossy().into_owned();
        if open.contains(&path_s) {
            continue;
        }
        let name = device.name().unwrap_or("").to_string();
        if name == VIRTUAL_DEVICE_NAME {
            continue;
        }
        let keys = device.supported_keys();
        let supports_modifier = keys.is_some_and(|k| {
            logic
                .ctrl_codes
                .iter()
                .any(|code| k.iter().any(|key| key.code() == *code))
        });
        // Watching uinput relays duplicates physical modifier input and makes
        // their normal teardown churn the grabbed pointer. Resolve through
        // sysfs because uinput can publish a non-empty "physical" label such
        // as py-evdev-uinput even though the kernel device is virtual.
        let watches_ctrl =
            should_watch_ctrl_device(&name, is_physical_input_device(&path), supports_modifier);
        let is_pointer = path_s == *pointer_path;
        if !watches_ctrl && !is_pointer {
            continue;
        }
        if is_pointer {
            if !is_back_pointer(&device) {
                logging::service(
                    "WARN",
                    format!("{path_s} is not a back-button pointing device"),
                );
                pointer_path.clear();
                continue;
            }
            if let Some(keys) = device.supported_keys() {
                for key in keys.iter() {
                    forward.insert((EV_KEY, key.code()));
                }
            }
            if let Some(rels) = device.supported_relative_axes() {
                for axis in rels.iter() {
                    forward.insert((EventType::RELATIVE.0, axis.0));
                }
            }
        }
        let mode = if is_pointer {
            "direct pointer; chord-only grab"
        } else {
            "modifier monitor"
        };
        logging::service("INFO", format!("watching {path_s}: {name} [{mode}]"));
        watched.push(Watched {
            device,
            path: path_s,
            is_pointer,
            watches_ctrl,
            grabbed: false,
            grab_failed: false,
        });
    }
    let caps_changed = logic.forward_codes != forward;
    logic.forward_codes = forward;
    if watched.iter().any(|w| w.is_pointer) && (virtual_dev.is_none() || caps_changed) {
        *virtual_dev = open_virtual(&logic.forward_codes);
        logic.ui_ok = virtual_dev.is_some();
    }
    sync_pointer_grabs(watched, logic, virtual_dev.is_some() && logic.ui_ok);
}

/// Choose the first non-keyboard pointing node with a back button.
fn find_pointer_path(enumerated: &[(PathBuf, Device)]) -> String {
    for (path, device) in enumerated {
        let name = device.name().unwrap_or("");
        if name == VIRTUAL_DEVICE_NAME || name.contains("Keychron") {
            continue;
        }
        if is_back_pointer(device) {
            return path.to_string_lossy().into_owned();
        }
    }
    String::new()
}

fn open_virtual(forward: &HashSet<(u16, u16)>) -> Option<evdev::uinput::VirtualDevice> {
    let mut keys = evdev::AttributeSet::<Key>::new();
    let mut rels = evdev::AttributeSet::<RelativeAxisType>::new();
    let mut has_key = false;
    let mut has_rel = false;
    for (ty, code) in forward {
        if *ty == EV_KEY {
            keys.insert(Key::new(*code));
            has_key = true;
        } else if *ty == EventType::RELATIVE.0 {
            rels.insert(RelativeAxisType(*code));
            has_rel = true;
        }
    }
    if !has_key && !has_rel {
        return None;
    }
    let mut builder = VirtualDeviceBuilder::new().ok()?.name(VIRTUAL_DEVICE_NAME);
    if has_key {
        builder = builder.with_keys(&keys).ok()?;
    }
    if has_rel {
        builder = builder.with_relative_axes(&rels).ok()?;
    }
    match builder.build() {
        Ok(dev) => {
            logging::service("INFO", "opened virtual forwarding input device");
            Some(dev)
        }
        Err(err) => {
            logging::service(
                "ERROR",
                format!("could not open virtual forwarding input device: {err}"),
            );
            None
        }
    }
}

/// CLI: `tiler` or `list-pointers`.
pub fn run_cli(args: &[String]) -> i32 {
    match args.first().map(String::as_str) {
        None | Some("tiler") => run(),
        Some("list-pointers") => list_pointers(),
        Some(other) => {
            eprintln!("Usage: lhs-tools tiler|list-pointers (got {other})");
            2
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn input_devices_are_sorted_by_numeric_event_suffix() {
        let mut paths = vec![
            "/dev/input/event13".to_string(),
            "/dev/input/event4".to_string(),
            "/dev/input/event6".to_string(),
        ];
        paths.sort_by_key(|p| input_device_sort_key(p));
        assert_eq!(
            paths,
            vec![
                "/dev/input/event4".to_string(),
                "/dev/input/event6".to_string(),
                "/dev/input/event13".to_string()
            ]
        );
    }

    #[test]
    fn configured_stable_pointer_path_is_resolved() {
        let mut reported = false;
        let selected = select_pointer_path(
            "/dev/input/by-id/razer-event-mouse",
            "",
            &["/dev/input/event4".into(), "/dev/input/event13".into()],
            |_| "/dev/input/event4".into(),
            &mut reported,
        );
        assert_eq!(selected, "/dev/input/event4");
    }

    #[test]
    fn missing_configured_pointer_does_not_fall_back() {
        let mut reported = false;
        let selected = select_pointer_path(
            "/dev/input/by-id/razer-event-mouse",
            "/dev/input/event4",
            &["/dev/input/event13".into()],
            |_| "/dev/input/event99".into(),
            &mut reported,
        );
        assert_eq!(selected, "");
        assert!(reported);
    }

    /// End-to-end proof that modifier polling survives a foreign exclusive
    /// grab: create a uinput keyboard, grab it from a second handle the way
    /// Phrase Automation's interceptor does, and confirm the tiler still sees
    /// the modifier go down and up. Requires write access to /dev/uinput.
    #[test]
    fn polled_state_survives_a_foreign_exclusive_grab() {
        let mut keys = evdev::AttributeSet::<Key>::new();
        keys.insert(Key::KEY_LEFTCTRL);
        let Ok(builder) = VirtualDeviceBuilder::new() else {
            eprintln!("skipping: /dev/uinput unavailable");
            return;
        };
        let Ok(mut fake) = builder
            .name("lhs-tools-grab-probe")
            .with_keys(&keys)
            .and_then(|b| b.build())
        else {
            eprintln!("skipping: could not build uinput device");
            return;
        };
        std::thread::sleep(Duration::from_millis(300));
        let Some(path) = evdev::enumerate()
            .find_map(|(path, dev)| (dev.name() == Some("lhs-tools-grab-probe")).then_some(path))
        else {
            eprintln!("skipping: probe device did not appear");
            return;
        };
        let (Ok(mut foreign), Ok(reader)) = (Device::open(&path), Device::open(&path)) else {
            eprintln!("skipping: could not open probe device");
            return;
        };
        if foreign.grab().is_err() {
            eprintln!("skipping: could not take the foreign grab");
            return;
        }

        let mut logic = TilerLogic::default();
        let watched = vec![Watched {
            device: reader,
            path: path.to_string_lossy().into_owned(),
            is_pointer: false,
            watches_ctrl: true,
            grabbed: false,
            grab_failed: false,
        }];

        fake.emit(&[InputEvent::new(EventType::KEY, KEY_LEFTCTRL, 1)])
            .expect("emit press");
        std::thread::sleep(Duration::from_millis(150));
        poll_modifier_state(&watched, &mut logic);
        assert!(
            pointer_should_be_grabbed(&logic),
            "modifier state must be visible through a foreign exclusive grab"
        );

        fake.emit(&[InputEvent::new(EventType::KEY, KEY_LEFTCTRL, 0)])
            .expect("emit release");
        std::thread::sleep(Duration::from_millis(150));
        poll_modifier_state(&watched, &mut logic);
        assert!(!pointer_should_be_grabbed(&logic));
        let _ = foreign.ungrab();
    }

    #[test]
    fn polled_modifier_state_arms_and_disarms_the_chord() {
        let mut tiler = TilerLogic::default();
        tiler.apply_modifier_state("/dev/input/event30", &HashSet::from([KEY_LEFTCTRL]));
        assert!(pointer_should_be_grabbed(&tiler));
        tiler.handle_key("/dev/input/mouse", true, BTN_SIDE, 1);
        tiler.handle_key("/dev/input/mouse", true, BTN_SIDE, 0);
        assert_eq!(tiler.tile_calls, 1);
        assert!(tiler.forwarded.is_empty());

        tiler.apply_modifier_state("/dev/input/event30", &HashSet::new());
        assert!(!pointer_should_be_grabbed(&tiler));
    }

    #[test]
    fn polled_state_does_not_duplicate_event_driven_modifier_tracking() {
        let mut tiler = TilerLogic::default();
        tiler.handle_key("/dev/input/event30", false, KEY_LEFTCTRL, 1);
        tiler.apply_modifier_state("/dev/input/event30", &HashSet::from([KEY_LEFTCTRL]));
        assert_eq!(tiler.ctrl_pressed.len(), 1);
        tiler.apply_modifier_state("/dev/input/event30", &HashSet::new());
        assert!(tiler.ctrl_pressed.is_empty());
    }

    #[test]
    fn vanished_devices_do_not_leave_the_pointer_grabbed() {
        let mut tiler = TilerLogic::default();
        tiler.apply_modifier_state("/dev/input/event30", &HashSet::from([KEY_LEFTCTRL]));
        tiler.handle_key("/dev/input/mouse", true, BTN_SIDE, 1);
        assert!(pointer_should_be_grabbed(&tiler));
        tiler.forget_missing_devices(&HashSet::new());
        assert!(!pointer_should_be_grabbed(&tiler));
    }

    #[test]
    fn ctrl_back_is_consumed_and_tiles_once() {
        let mut tiler = TilerLogic::default();
        tiler.handle_key("/dev/input/keyboard", false, KEY_LEFTCTRL, 1);
        tiler.handle_key("/dev/input/mouse", true, BTN_SIDE, 1);
        tiler.handle_key("/dev/input/mouse", true, BTN_SIDE, 0);
        assert_eq!(tiler.tile_calls, 1);
        assert!(tiler.forwarded.is_empty());
        assert!(tiler.suppressed.is_empty());
    }

    #[test]
    fn plain_back_is_forwarded_to_applications() {
        let mut tiler = TilerLogic::default();
        tiler.handle_key("/dev/input/mouse", true, BTN_SIDE, 1);
        tiler.handle_key("/dev/input/mouse", true, BTN_SIDE, 0);
        assert_eq!(
            tiler.forwarded,
            vec![(EV_KEY, BTN_SIDE, 1), (EV_KEY, BTN_SIDE, 0)]
        );
    }

    #[test]
    fn ungrabbed_ctrl_back_is_not_tiled_or_relayed() {
        let mut tiler = TilerLogic::default();
        tiler.handle_key("/dev/input/keyboard", false, KEY_LEFTCTRL, 1);
        tiler.handle_key("/dev/input/mouse", false, BTN_SIDE, 1);
        tiler.handle_key("/dev/input/mouse", false, BTN_SIDE, 0);
        assert_eq!(tiler.tile_calls, 0);
        assert!(tiler.forwarded.is_empty());
        assert!(tiler.suppressed.is_empty());
    }

    #[test]
    fn pointer_grab_lasts_through_suppressed_button_release() {
        let mut tiler = TilerLogic::default();
        assert!(!pointer_should_be_grabbed(&tiler));
        tiler.handle_key("/dev/input/keyboard", false, KEY_LEFTCTRL, 1);
        assert!(pointer_should_be_grabbed(&tiler));
        tiler.handle_key("/dev/input/mouse", true, BTN_SIDE, 1);
        tiler.handle_key("/dev/input/keyboard", false, KEY_LEFTCTRL, 0);
        assert!(pointer_should_be_grabbed(&tiler));
        tiler.handle_key("/dev/input/mouse", true, BTN_SIDE, 0);
        assert!(!pointer_should_be_grabbed(&tiler));
    }

    #[test]
    fn live_forwarding_does_not_retain_processed_pointer_events() {
        let mut tiler = TilerLogic::default();
        tiler
            .forward_codes
            .insert((EventType::RELATIVE.0, RelativeAxisType::REL_X.0));
        let mut virtual_dev = None;

        for _ in 0..10_000 {
            handle_live_event(
                &mut tiler,
                &mut virtual_dev,
                "/dev/input/mouse",
                true,
                InputEvent::new(EventType::RELATIVE, RelativeAxisType::REL_X.0, 1),
            );
        }

        assert!(tiler.forwarded.len() < MAX_FORWARD_PACKET_EVENTS);
    }

    #[test]
    fn physical_motion_is_flushed_once_at_syn_report() {
        let mut tiler = TilerLogic::default();
        tiler
            .forward_codes
            .insert((EventType::RELATIVE.0, RelativeAxisType::REL_X.0));
        tiler
            .forward_codes
            .insert((EventType::RELATIVE.0, RelativeAxisType::REL_Y.0));

        tiler.handle_other(true, EventType::RELATIVE.0, RelativeAxisType::REL_X.0, 4);
        assert!(take_forwarded_packet(&mut tiler, false).is_none());
        tiler.handle_other(true, EventType::RELATIVE.0, RelativeAxisType::REL_Y.0, -2);
        assert!(take_forwarded_packet(&mut tiler, false).is_none());

        let packet = take_forwarded_packet(&mut tiler, true).expect("physical packet");
        assert_eq!(
            packet,
            vec![
                (EventType::RELATIVE.0, RelativeAxisType::REL_X.0, 4),
                (EventType::RELATIVE.0, RelativeAxisType::REL_Y.0, -2),
            ]
        );
        assert!(tiler.forwarded.is_empty());
    }

    #[test]
    fn transient_virtual_relay_is_not_watched_as_a_modifier_source() {
        assert!(!should_watch_ctrl_device(
            "section-wheel-interceptor",
            false,
            true,
        ));
        assert!(!should_watch_ctrl_device(
            "section-interceptor",
            false,
            true,
        ));
        assert!(should_watch_ctrl_device(
            "Razer Razer Naga V2 HyperSpeed Keyboard",
            true,
            true,
        ));
        assert!(is_virtual_input_sysfs_path(Path::new(
            "/sys/devices/virtual/input/input72"
        )));
        assert!(!is_virtual_input_sysfs_path(Path::new(
            "/sys/devices/pci0000:00/usb1/1-2/input/input7"
        )));
        assert_eq!(
            physical_input_topology_entry(
                "event6",
                Path::new("/sys/devices/pci0000:00/usb1/1-2/input/input7/event6")
            ),
            Some("event6:/sys/devices/pci0000:00/usb1/1-2/input/input7/event6".to_string())
        );
        assert_eq!(
            physical_input_topology_entry(
                "event28",
                Path::new("/sys/devices/virtual/input/input72/event28")
            ),
            None
        );
        assert_eq!(
            physical_input_topology_entry(
                "mouse0",
                Path::new("/sys/devices/pci0000:00/usb1/1-2/input/input7/mouse0")
            ),
            None
        );
    }
}
