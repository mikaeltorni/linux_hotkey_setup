//! `lhs-tools` — installer-facing GSettings string-array helper.
//!
//! ```text
//! CURRENT="['a']" lhs-tools append monitor-window-hotkeys@local
//! CURRENT="['a', 'x']" lhs-tools remove x
//! ```

mod gsettings_strv;
mod logging;

fn main() {
    std::process::exit(gsettings_strv::run_cli());
}
