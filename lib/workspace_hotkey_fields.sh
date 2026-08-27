#!/usr/bin/env bash
# workspace_hotkey_fields.sh - persisted editable numbered-workspace hotkeys.
#
# Each workspace switch action owns one typed hotkey field. Move bindings are
# derived by adding one shared modifier (Shift by default), which prevents the
# installer menu from duplicating eight nearly identical move-hotkey fields.

: "${WORKSPACE_HOTKEY_CONFIG:=$TARGET_HOME/.config/linux-hotkey-setup/workspace-hotkeys.conf}"
: "${WORKSPACE_MOVE_MODIFIER:=Shift}"

# workspace_default_switch INDEX - print the built-in accelerator for INDEX.
workspace_default_switch() {
  hotkey_default_for_index "$1" "${WORKSPACE_SWITCH_BINDINGS[@]}"
}

# workspace_switch_accelerator INDEX - resolve env/config/default and normalize
# it to the GTK accelerator syntax consumed by gsettings.
workspace_switch_accelerator() {
  local index="$1" key="WORKSPACE_SWITCH_${1}" default_value value
  default_value="$(workspace_default_switch "$index")"
  value="$(isc_hotkey_field_value "$WORKSPACE_HOTKEY_CONFIG" "$key" "$default_value")"
  [[ -z "$value" ]] && return 0
  isc_hotkey_to_accelerator "$value"
}

# workspace_move_modifier - resolve the single modifier shared by all derived
# move-window bindings.
workspace_move_modifier() {
  local value
  value="$(isc_hotkey_field_value "$WORKSPACE_HOTKEY_CONFIG" WORKSPACE_MOVE_MODIFIER "$WORKSPACE_MOVE_MODIFIER")"
  isc_normalize_modifier "$value"
}

# workspace_move_accelerator INDEX - add the configured move modifier to one
# switch binding. Fails if the modifier is already in the switch accelerator.
workspace_move_accelerator() {
  local base modifier
  base="$(workspace_switch_accelerator "$1")"
  [[ -z "$base" ]] && return 0
  modifier="$(workspace_move_modifier)" || return 1
  isc_hotkey_add_modifier "$base" "$modifier"
}

# workspace_validate_switch_candidate ACCELERATOR - reject duplicate switch
# values and values that already contain the move modifier (which would make
# switch and move actions identical).
workspace_validate_switch_candidate() {
  local candidate="$1" current_index="${WORKSPACE_FIELD_INDEX:-0}" index existing modifier
  modifier="$(workspace_move_modifier)" || return 1
  if ! isc_hotkey_add_modifier "$candidate" "$modifier" >/dev/null 2>&1; then
    printf '  Invalid hotkey: the %s move modifier is already in this switch binding.\n' "$modifier" >&2
    return 1
  fi
  for ((index = 1; index <= WORKSPACE_UI_COUNT; index++)); do
    [[ "$index" == "$current_index" ]] && continue
    existing="$(workspace_switch_accelerator "$index")"
    [[ -z "$existing" ]] && continue
    if [[ "${existing,,}" == "${candidate,,}" ]]; then
      printf '  Invalid hotkey: workspace %s already uses this binding.\n' "$index" >&2
      return 1
    fi
  done
  return 0
}

# workspace_validate_move_modifier MODIFIER - ensure adding the modifier changes
# every assigned switch chord rather than overriding its switch action.
workspace_validate_move_modifier() {
  local modifier="$1" index base
  for ((index = 1; index <= WORKSPACE_UI_COUNT; index++)); do
    base="$(workspace_switch_accelerator "$index")"
    [[ -z "$base" ]] && continue
    if ! isc_hotkey_add_modifier "$base" "$modifier" >/dev/null 2>&1; then
      printf '  Invalid modifier: %s is already used by workspace %s (%s).\n' \
        "$modifier" "$index" "$base" >&2
      return 1
    fi
  done
  return 0
}

# configure_workspace_switch_field INDEX - open the framework-owned typed field
# for one switch binding and persist it for standalone and master installs.
configure_workspace_switch_field() {
  local index="$1" key="WORKSPACE_SWITCH_${1}" default_value
  default_value="$(workspace_default_switch "$index")"
  WORKSPACE_FIELD_INDEX="$index" \
    isc_prompt_hotkey_field "$WORKSPACE_HOTKEY_CONFIG" "$key" \
      "Switch to workspace $index" "$default_value" workspace_validate_switch_candidate
}

# configure_workspace_move_modifier_field - open the one shared modifier field.
configure_workspace_move_modifier_field() {
  isc_prompt_modifier_field "$WORKSPACE_HOTKEY_CONFIG" WORKSPACE_MOVE_MODIFIER \
    "Move window to workspace modifier" "$WORKSPACE_MOVE_MODIFIER" \
    workspace_validate_move_modifier
}

workspace_switch_status() {
  local index="$1" value
  value="$(workspace_switch_accelerator "$index")"
  [[ -z "$value" ]] && { printf 'Unassigned\n'; return 0; }
  local dir
  dir="$(isc_hotkey_lib_dir)" || return 1
  python3 "$dir/hotkey_capture.py" display "$value"
}

workspace_move_modifier_status() {
  local modifier
  modifier="$(workspace_move_modifier)" || return 1
  [[ "$modifier" == "Control" ]] && printf 'Ctrl\n' || printf '%s\n' "$modifier"
}

configure_workspace_switch_field_1() { configure_workspace_switch_field 1; }
configure_workspace_switch_field_2() { configure_workspace_switch_field 2; }
configure_workspace_switch_field_3() { configure_workspace_switch_field 3; }
configure_workspace_switch_field_4() { configure_workspace_switch_field 4; }
configure_workspace_switch_field_5() { configure_workspace_switch_field 5; }
configure_workspace_switch_field_6() { configure_workspace_switch_field 6; }
configure_workspace_switch_field_7() { configure_workspace_switch_field 7; }
configure_workspace_switch_field_8() { configure_workspace_switch_field 8; }
configure_workspace_switch_field_9() { configure_workspace_switch_field 9; }
workspace_switch_status_1() { workspace_switch_status 1; }
workspace_switch_status_2() { workspace_switch_status 2; }
workspace_switch_status_3() { workspace_switch_status 3; }
workspace_switch_status_4() { workspace_switch_status 4; }
workspace_switch_status_5() { workspace_switch_status 5; }
workspace_switch_status_6() { workspace_switch_status 6; }
workspace_switch_status_7() { workspace_switch_status 7; }
workspace_switch_status_8() { workspace_switch_status 8; }
workspace_switch_status_9() { workspace_switch_status 9; }
