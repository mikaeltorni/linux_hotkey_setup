#!/usr/bin/env bash
# gsettings_helpers.sh - GSettings list and keybinding helpers.
#
# The caller must define run_as_target() before invoking these functions.

user_gsettings() {
  run_as_target gsettings "$@"
}

gsettings_key_exists() {
  local schema="$1" key="$2"
  run_as_target gsettings list-keys "$schema" 2>/dev/null | grep -qx "$key"
}

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

set_gsettings_strv() {
  local schema="$1" key="$2"
  shift 2
  user_gsettings set "$schema" "$key" "$(join_as_gsettings_array "$@")"
}

set_gsettings_strv_if_key_exists() {
  local schema="$1" key="$2"
  shift 2
  if gsettings_key_exists "$schema" "$key"; then
    set_gsettings_strv "$schema" "$key" "$@"
  fi
}

append_gsettings_list() {
  local schema="$1" key="$2" value="$3"
  run_as_target env SCHEMA="$schema" KEY="$key" VALUE="$value" python3 - <<'PY'
import ast
import os
import subprocess
import sys

schema = os.environ["SCHEMA"]
key = os.environ["KEY"]
value = os.environ["VALUE"]
current = subprocess.run(
    ["gsettings", "get", schema, key],
    text=True,
    capture_output=True,
    check=False,
).stdout.strip()
if current.startswith("@as "):
    current = current[4:].strip()
try:
    values = ast.literal_eval(current) if current else []
except Exception:
    values = []
if value not in values:
    values.append(value)
new_value = "[" + ", ".join(repr(v) for v in values) + "]"
result = subprocess.run(["gsettings", "set", schema, key, new_value], check=False)
sys.exit(result.returncode)
PY
}

remove_gsettings_list() {
  local schema="$1" key="$2" value="$3"
  run_as_target env SCHEMA="$schema" KEY="$key" VALUE="$value" python3 - <<'PY'
import ast
import os
import subprocess
import sys

schema = os.environ["SCHEMA"]
key = os.environ["KEY"]
value = os.environ["VALUE"]
current = subprocess.run(
    ["gsettings", "get", schema, key],
    text=True,
    capture_output=True,
    check=False,
).stdout.strip()
if current.startswith("@as "):
    current = current[4:].strip()
try:
    values = ast.literal_eval(current) if current else []
except Exception:
    values = []
values = [item for item in values if item != value]
new_value = "[" + ", ".join(repr(v) for v in values) + "]"
result = subprocess.run(["gsettings", "set", schema, key, new_value], check=False)
sys.exit(result.returncode)
PY
}

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

enable_shell_extension() {
  local ext_id="$1"
  append_gsettings_list org.gnome.shell enabled-extensions "$ext_id"
}

update_custom_keybindings() {
  local path="$1"
  append_gsettings_list org.gnome.settings-daemon.plugins.media-keys custom-keybindings "$path"
}
