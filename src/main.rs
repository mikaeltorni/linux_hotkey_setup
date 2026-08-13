//! `lhs-tools` — installer helpers and the window-placement tiler.
//!
//! ```text
//! CURRENT="['a']" lhs-tools append monitor-window-hotkeys@local
//! lhs-tools list-pointers
//! lhs-tools tiler
//! ```

mod gsettings_strv;
mod logging;
mod tiler;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let code = match args.first().map(String::as_str) {
        Some("tiler") | Some("list-pointers") => tiler::run_cli(&args),
        Some("append") | Some("remove") => gsettings_strv::run(&args),
        _ => gsettings_strv::run(&args),
    };
    std::process::exit(code);
}
