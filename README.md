# Ubuntu Hotkeys Setup — Configurable GNOME keyboard shortcuts

Ubuntu Hotkeys Setup is a configurable GNOME keyboard shortcuts installer for users who want
custom screenshot, numbered workspace, and window placement bindings.

[![Last commit: 2026-11-24](docs/badges/last-commit.svg)](https://github.com/mikaeltorni/linux_hotkey_setup/commits/master) [![Commits in 30 days: 2 as of 2026-11-25](docs/badges/commit-activity.svg)](https://github.com/mikaeltorni/linux_hotkey_setup/graphs/commit-activity) [![Open issues: 0 as of 2026-11-25](docs/badges/issues.svg)](https://github.com/mikaeltorni/linux_hotkey_setup/issues)

Activity snapshot from GitHub’s default branch on 2026-11-25.

[Installation](#installation) · [Configuration](#configuration) · [Component selection](#component-selection) · [Troubleshooting](#troubleshooting) · [MIT license](LICENSE.md)

## Quick start

Run inside the target user's GNOME desktop session. The screenshot component changes the current desktop binding.

```bash
bash install.sh --list-components
bash install.sh --select screenshot
bash install.sh --detect
```

The Ubuntu 24.04.5 GNOME 46 X11 workstation VM installed and detected the selected screenshot and workspace shortcut components. Its virtual mouse lacked the Back button needed by the pointer tiler.

[Installation Scripts](https://github.com/mikaeltorni/installation_scripts) can also run this installer as part of the Ubuntu setup chain.

It owns the configurable screenshot shortcut, numbered workspace switching and moving (up to 8 workspaces), and the window placement tiling user service (formerly the "Ctrl+Back window tiler"). Every hotkey can be chosen interactively through the shared press-to-capture engine. Automatic same-application tiling now installs from the sibling `linux_automatic_window_tiling` repository, pointer-driven window move/resize hotkeys from `linux_hotkey_window_tools`, monitor-move + half-tiling + Super+U send-mode from `linux_monitor_window_hotkeys`, and the numbered workspace popup extension from `linux_workspaces_setup` — each a standalone, directly-installed repository that configures its hotkeys the same interactive way. The Albert launcher toggle binding and the xmousepasteblock primary-paste blocker service also live in `linux_workspaces_setup`.

## Repository dependencies

This repository installs and runs **standalone**; sibling repositories only
enhance it and never block installation when absent.

- **Installer support:** the maintained MIT library is included in
  `.installer-support/`, with its license and verifiable source manifest.
  Framework discovery works offline without a private checkout or credentials.

See the full cross-repository map in
[installation_scripts/DEPENDENCIES.md](https://github.com/mikaeltorni/installation_scripts/blob/master/DEPENDENCIES.md).

## Technology Stack

- Bash installer for GNOME GSettings and systemd user-service setup.
- Rust `lhs-tools` binary for GSettings string-array edits and the window-placement tiler (`src/tiler.rs`).
- Pytest-compatible Python tests that simulate shell behavior without modifying host settings.

## Installation

```bash
bash install.sh
```

This runs in user mode by default. Root-only steps such as `apt` are skipped
and reported; run `sudo bash install.sh` only when you need to apply them.
GSettings and user-service operations run as the target desktop user.

This repository does not ship a GNOME Shell extension, so a Shell reload is
not required after install. Restart `window-placement-tiling.service` after
tiler code changes.

## Development Workflow

Run tests:

```bash
cargo test
python3 -m pytest tests -q
```

Run shell syntax validation:

```bash
bash -n install.sh lib/hotkeys_setup.sh lib/ctrl_back_tiler.sh lib/gsettings_helpers.sh lib/lifecycle.sh
```

## Project Structure

- `install.sh` - standalone entrypoint for applying the full hotkey setup.
- `lib/hotkeys_setup.sh` - shared implementation; each hotkey is captured via the shared `isc_capture_hotkey` engine.
- `lib/ctrl_back_tiler.sh` - pointing-device selection and window-placement-tiling user-service installation (configurable modifier + mouse-button trigger).
- `lib/gsettings_helpers.sh` - reusable GSettings list and keybinding helpers sourced by the setup library.
- `lhs-tools` (Rust, `src/`) - GSettings string-array helper (`append`/`remove`) and the window-placement tiler (`tiler` / `list-pointers`).
- `lib/lifecycle.sh` - per-component detect/uninstall functions.
- `src/tiler.rs` - window-placement-tiling service (modifier + mouse-button half-tiler) and pointer listing.
- `tests/` - simulation tests.

## Configuration

Important defaults:

Interactive capture is used on a terminal; these are the shown defaults and the
environment overrides for automated runs:

- `WORKSPACE_COUNT=8` (numbered workspaces created; capture walks up to 8)
- `SCREENSHOT_HOTKEY` overrides the screenshot default `<Shift><Super>s`
- `WORKSPACE_SWITCH_<n>` overrides one switch field; `WORKSPACE_MOVE_MODIFIER`
  controls every derived move binding (default `Shift`)
- `WINDOW_PLACEMENT_TILING_TRIGGER` overrides the tiling trigger (default `Control|BTN_BACK`)

Pointer-driven window move (`<Alt><Super>W` drag) and resize (`<Alt><Super>E`
center scaling) now live in the standalone `linux_hotkey_window_tools`
repository, installed directly by the master installer. Monitor-move,
half-tiling, and Super+U send-mode live in `linux_monitor_window_hotkeys`.

The window-placement-tiling trigger (default Ctrl + mouse Back) is handled by `lhs-tools tiler`; its modifier and mouse button are configurable via the capture UI. Normal pointer movement stays on the physical device's direct Xorg/libinput path: the tiler grabs and relays the selected pointer only while the configured modifier is held (and through the matching button release), preserving each physical packet with one `SYN_REPORT`. A relay failure releases the physical pointer immediately. Modifier state is read only from physical input devices, so short-lived virtual relays from Phrase Automation or other tools cannot trigger a release/rescan/re-grab cycle for the selected mouse. That state is polled from each physical keyboard with `EVIOCGKEY` every 20 ms instead of being tracked from the event stream alone, because another daemon can hold an exclusive `EVIOCGRAB` on the keyboard (Phrase Automation's section interceptor does) — key *state* reads still succeed through a foreign grab while event reads deliver nothing, so the chord keeps working while those tools run. The service checks physical input topology through sysfs and performs full evdev capability probing only at startup or after an actual physical-device change; it does not reopen every mouse and keyboard on a timer.

Automatic same-application tiling (`linux_automatic_window_tiling`) and
pointer-driven move/resize (`linux_hotkey_window_tools`) are standalone,
directly-installed repositories that own their own extensions, schemas, and
configurable hotkeys (chosen through the same shared capture engine).

## Troubleshooting

- If the window-placement-tiling service cannot find a pointing device with a browser-back button, it skips the service setup.
- The window-placement-tiling service discards each forwarded event after emission and runs with a 64 MiB systemd memory ceiling, preventing a malformed or amplified input stream from exhausting system RAM.
- If `Shift+Super+R` triggers GNOME's screen recording instead of move-to-workspace-8, the installer's unbinding of `org.gnome.shell.keybindings show-screen-recording-ui` has not taken effect yet. Re-run `bash install.sh`. This is a `gsettings` keybinding change, which GNOME Shell applies live, so no Shell reload is needed. Verify with `gsettings get org.gnome.shell.keybindings show-screen-recording-ui` returning `@as []`.

## Deployment

Before deploying:

```bash
bash -n install.sh lib/hotkeys_setup.sh lib/ctrl_back_tiler.sh lib/gsettings_helpers.sh lib/lifecycle.sh
cargo test
python3 -m pytest tests -q
```

Then run:

```bash
bash install.sh
```

Use `sudo bash install.sh` only when you also need the reported root-only
package-management steps.

## Contributing

Keep hotkey values single-sourced. Installer-owned GNOME system bindings belong in named arrays in this repository. Monitor-move and half-tiling bindings belong in `linux_monitor_window_hotkeys`. Avoid hard-coded checkout paths; resolve assets through `SCRIPT_DIR`.

## Setup-chain membership

This repository is cloned and run by the master installer
(`installation_scripts/install.sh`). Membership and order live in
`installation_scripts/scripts/repository_manifest.sh`; the dependency map is
[`installation_scripts/DEPENDENCIES.md`](https://github.com/mikaeltorni/installation_scripts/blob/master/DEPENDENCIES.md).

## Component selection

This repository's `install.sh` participates in the shared installer
component menu (see the [`installation_scripts`](https://github.com/mikaeltorni/installation_scripts)
master installer). Run standalone, it offers an interactive submenu on a
terminal; the master installer drives it non-interactively.

```bash
bash install.sh                 # interactive component selection (TTY), else defaults
bash install.sh --default       # install all default-on components, no prompts
bash install.sh --all           # install every component, no prompts
bash install.sh --select a,b    # install exactly these component ids
bash install.sh --list-components  # print: id<TAB>label<TAB>default
```

In the interactive menu, **space** toggles a component, `a`/`n` select all
or none, and **Enter** installs the selection. Components:

A plain install applies each shown default. On a workspace switch or move
modifier row, press RIGHT to open its typed rebind field. Switch fields accept
multiple modifiers plus exactly one key and display values such as `Super+W`;
the move field accepts one modifier (`Shift`, `Ctrl`, `Alt`, or `Super`) and is
rejected if it would duplicate a switch chord. Values persist under
`~/.config/linux-hotkey-setup/workspace-hotkeys.conf` for both standalone and
master installations.

| Component id | Description | Default |
|---|---|---|
| `screenshot` | Screenshot shortcut (default `<Shift><Super>s`) | on |
| `workspace_behavior` | Static workspace count and shared navigation behavior | on |
| `workspace_switch_1` … `workspace_switch_8` | Editable switch field per workspace | on |
| `workspace_move_modifier` | One modifier added to every switch chord for moving windows | on |
| `window_placement_tiling` | Window placement tiling service (Ctrl + mouse Back) | on |

Automatic same-application window tiling, the pointer-driven window move/resize
hotkeys, and the numbered workspace popup extension are now their own
directly-installed repositories (`linux_automatic_window_tiling`,
`linux_hotkey_window_tools`, and `linux_workspaces_setup`), each configuring its
hotkeys through the same shared press-to-capture engine.

The standalone and master installers both discover these rows from
`bash install.sh --list-components`. For example, reconfigure only
`workspace_switch_2` with RIGHT in either menu, or script that row with
`WORKSPACE_SWITCH_2='<Alt><Super>2'`.


## Detect, reconfigure, and uninstall

This installer tracks what it has installed and can re-apply or remove it, so you
can refresh configuration after a repo update or cleanly back a feature out.

```bash
bash install.sh --detect            # show each component as installed|absent
bash install.sh --reconfigure a,b   # re-apply (idempotent) these component ids
bash install.sh --uninstall a,b     # uninstall these component ids
```

In the interactive menu (run `bash install.sh` on a terminal, or via the master
installer), already-installed components show a green `✓`. Select one with
**space** to **reconfigure** it (`~`), press **`u`** to mark it for **uninstall**
(`✗`), or press **`r`** to reconfigure every installed component at once. Detection
uses a live check where deterministic and otherwise an install receipt under
`${XDG_STATE_HOME:-~/.local/state}/isc/receipts/`; a component without a reversal
step simply clears that receipt on uninstall.

## Disclaimer

This software is provided under the MIT License on an **“as is”** basis, without warranties of any kind. To the maximum extent permitted by applicable law, the authors and copyright holders shall not be liable for any claims, damages, losses, or other liability arising from the use of this software.

You are solely responsible for determining whether this software is suitable, safe, lawful, and appropriate for your intended use. Unless explicitly stated otherwise, this project is general-purpose software and is not designed, tested, certified, or approved for safety-critical, medical, automotive, aviation, industrial-control, life-support, cybersecurity-critical, financial-critical, or other high-risk use cases.

The authors and copyright holders make no guarantees regarding security, reliability, availability, correctness, compliance, non-infringement, or fitness for any particular purpose.

This notice is intended to clarify the nature of the project and does not impose additional restrictions beyond the MIT License.

## Installer lifecycle

Run these commands from this checkout. The component IDs printed by discovery
are the same IDs used by the terminal menu and programmatic actions.

| Command | Behavior |
| --- | --- |
| `bash install.sh` | Open component selection on a terminal; use the default/config selection otherwise. |
| `bash install.sh --help` | Show accepted options (`-h` is equivalent). |
| `bash install.sh --list-components` | Print component IDs, labels and defaults. |
| `bash install.sh --default` | Apply default-on components. |
| `bash install.sh --all` | Apply every component. |
| `bash install.sh --select ID,...` | Apply exactly the named components. |
| `bash install.sh --reconfigure ID,...` | Reapply those components through the same install operations. |
| `bash install.sh --uninstall ID,...` | Run the selected removal operations. |
| `bash install.sh --detect` | Print `ID<TAB>installed` or `ID<TAB>absent`. |
| `bash install.sh --export-selection` | Print selection JSON without applying it. |

The shared interface also accepts `--config NAME` (an installation JSON name
or path) and `--auth` (explicit permission for authenticated component actions).
`--config=NAME`, `--select=ID,...`, `--reconfigure=ID,...`,
`--uninstall=ID,...` and `--configure-component=ID` are equivalent forms.
Advanced discovery is available through `--list-configurable-components`,
`--list-select-configure-components` and `--list-component-config-values`;
`--configure-component ID` opens an available nested screen. Atomic owners
return empty advanced listings and reject unavailable nested configuration.

Explicit `--select ""` selects no optional components; a defined mandatory core
or installation preflight still runs. `--uninstall ""` is a no-op. Unknown or
duplicate IDs, missing operands and conflicting modes reject before component
installation/removal. Help, discovery, detection and export perform no installation.
Cancelling the component menu performs no install/removal. Configuration screens
may save their own settings when explicitly accepted.

The shared terminal screen uses arrows to move, Space to toggle, Enter to
apply and `q`/Escape to cancel; installed components support `u` for removal.
A right-arrow detail action appears where the owner provides configuration.
Removal-only selections skip core installation.

The licensed `.installer-support/` package is generated by
`linux_installation_scripts_functions`; `manifest.json` records provenance and
SHA-256 hashes, and `LICENSE.md` retains the MIT grant. It is a shared library
subset, not an application checkout. The default bootstrap requires no private
download or sibling repository. Explicit `ISC_COMPONENT_LIB_DIR` /
`ISC_FUNCTIONS_DIR` overrides remain available for development and the old setup
chain. Regenerate support from its owner rather than editing copies. Bash and
Python 3 are needed for this library; project build/runtime requirements above
still apply.

For example, inspect IDs first, then use the same ID with either interface:

```bash
bash install.sh --list-components
bash install.sh --select screenshot
bash install.sh --detect
bash install.sh --uninstall screenshot
```
