#!/usr/bin/env bash
# gsettings_helpers.sh - GSettings list and keybinding helpers.
#
# The caller must define run_as_target() before invoking these functions.

# user_gsettings — Run gsettings as the target user's session.
# Args: $@ — gsettings subcommand and arguments (e.g. set <schema> <key> <val>).
user_gsettings() {
  run_as_target gsettings "$@"
}

# gsettings_key_exists — Return success when a schema defines the given key.
# Args: $1 — gsettings schema id; $2 — key name to look for.
gsettings_key_exists() {
  local schema="$1" key="$2"
  run_as_target gsettings list-keys "$schema" 2>/dev/null | grep -qx "$key"
}

# join_as_gsettings_array — Serialize arguments into a gsettings string-array
# literal (e.g. ['a', 'b']), single-quote-escaping each value and dropping empty
# ones. Prints the literal to stdout.
# Args: $@ — string values to include in the array.
join_as_gsettings_array() {
  local out="[" sep="" value escaped
  for value in "$@"; do
    [ -n "$value" ] || continue
    escaped="${value//\\/\\\\}"
    escaped="${escaped//\'/\\\'}"
    out+="${sep}'${escaped}'"
    sep=", "
  done
  out+="]"
  printf '%s\n' "$out"
}

# set_gsettings_strv — Set a key to a string array built from the given values.
# Args: $1 — schema id; $2 — key name; $3.. — array values (may be empty for []).
set_gsettings_strv() {
  local schema="$1" key="$2"
  shift 2
  user_gsettings set "$schema" "$key" "$(join_as_gsettings_array "$@")"
}

# set_gsettings_strv_if_key_exists — Like set_gsettings_strv but a no-op when the
# schema does not define the key, so optional keys never abort the run.
# Args: $1 — schema id; $2 — key name; $3.. — array values.
set_gsettings_strv_if_key_exists() {
  local schema="$1" key="$2"
  shift 2
  if gsettings_key_exists "$schema" "$key"; then
    set_gsettings_strv "$schema" "$key" "$@"
  fi
}

# append_gsettings_list — Append a value to a string-array key, de-duplicating
# via gsettings_strv.py so re-runs stay idempotent.
# Args: $1 — schema id; $2 — key name; $3 — value to append.
append_gsettings_list() {
  local schema="$1" key="$2" value="$3" current new_value
  current="$(user_gsettings get "$schema" "$key" 2>/dev/null || printf '[]')"
  new_value="$(CURRENT="$current" python3 "$HOTKEYS_SETUP_LIB_DIR/gsettings_strv.py" append "$value")"
  user_gsettings set "$schema" "$key" "$new_value"
}

# remove_gsettings_list — Remove every occurrence of a value from a string-array
# key via gsettings_strv.py.
# Args: $1 — schema id; $2 — key name; $3 — value to remove.
remove_gsettings_list() {
  local schema="$1" key="$2" value="$3" current new_value
  current="$(user_gsettings get "$schema" "$key" 2>/dev/null || printf '[]')"
  new_value="$(CURRENT="$current" python3 "$HOTKEYS_SETUP_LIB_DIR/gsettings_strv.py" remove "$value")"
  user_gsettings set "$schema" "$key" "$new_value"
}

# set_indexed_keybinding_map — Bind a family of indexed keys (e.g.
# switch-to-workspace-1..N) from "index:binding" entries, setting each
# "<key_prefix><index>" key to a single-element array.
# Args: $1 — schema id; $2 — key name prefix; $3.. — "index:binding" entries.
set_indexed_keybinding_map() {
  local schema="$1" key_prefix="$2"
  shift 2
  local entry idx binding
  for entry in "$@"; do
    idx="${entry%%:*}"
    binding="${entry##*:}"
    set_gsettings_strv "$schema" "${key_prefix}${idx}" "$binding"
  done
}

# enable_shell_extension — Add an extension UUID to org.gnome.shell
# enabled-extensions (idempotent).
# Args: $1 — extension UUID.
enable_shell_extension() {
  local ext_id="$1"
  append_gsettings_list org.gnome.shell enabled-extensions "$ext_id"
}

# update_custom_keybindings — Register a custom media-keys keybinding path in the
# custom-keybindings list (idempotent).
# Args: $1 — custom keybinding dconf path.
update_custom_keybindings() {
  local path="$1"
  append_gsettings_list org.gnome.settings-daemon.plugins.media-keys custom-keybindings "$path"
}
