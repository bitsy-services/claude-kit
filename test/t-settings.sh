#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
t_setup
mkdir -p "$T/tmp"
export TMPDIR="$T/tmp"

BASIC="$TEST_ROOT/test/consumers/basic"

fresh() {
  rm -rf "$T/kit" "$T/con"
  mk_kit "$TEST_ROOT/test/kits/toy/slices"
  mk_consumer "$BASIC" "$T/con"
}

set_kitjson() {
  jq -c "$1" "$CON/.claude/kit.json" > "$T/kit.json.new"
  cp "$T/kit.json.new" "$CON/.claude/kit.json"
}

move_pin() {
  git -C "$T/kit" add -A
  git -C "$T/kit" commit -q -m "$1"
  git -C "$CON/.claude/vendor/kit" fetch -q "$T/kit" main
  git -C "$CON/.claude/vendor/kit" checkout -q FETCH_HEAD
  git -C "$CON" add .claude/vendor/kit
}

S() { jq -c "$1" "$CON/.claude/settings.json"; }

t_settings_first_render() {
  fresh
  kit_run render
  is "$RC" 0 "first: render exits 0"
  is "$(S .permissions.allow)" '["Read","Bash(echo *)","Bash(git fetch origin main)","Bash(python3 *)"]' "first: allow list"
  is "$(S .autoMemoryEnabled)" false "first: autoMemoryEnabled false"
  is "$(S '.hooks.PreToolUse[0].matcher')" '"Bash"' "first: hook matcher"
  is "$(jq -c .settings.adopted.allow "$CON/.claude/kit.lock.json")" '["Read"]' "first: Read adopted"
  is "$(jq -c .set "$CON/.claude/kit.lock.json")" '{"autoMemoryEnabled":false}' "first: lock set"
}

t_settings_adopted_survives_drop() {
  fresh
  kit_run render
  jq '.permissions.allow |= map(select(. != "Read"))' "$T/kit/slices/core/settings.json" > "$T/s.new"
  cp "$T/s.new" "$T/kit/slices/core/settings.json"
  move_pin "drop Read"
  kit_run render
  is "$RC" 0 "adopted: render exits 0"
  like "$(S .permissions.allow)" '"Read"' "adopted: Read is still allowed"
  is "$(S '.permissions.allow | index("Bash(echo *)") != null')" true "adopted: other kit entries stay"
}

t_settings_renamed_hook_removed() {
  fresh
  kit_run render
  git -C "$T/kit" mv slices/core/hooks/h.sh slices/core/hooks/h2.sh
  sed -i 's#kit/h\.sh#kit/h2.sh#' "$T/kit/slices/core/settings.json"
  move_pin "rename hook"
  kit_run render
  is "$RC" 0 "renamed: render exits 0"
  unlike "$(cat "$CON/.claude/settings.json")" 'h\.sh' "renamed: no handler mentions h.sh"
  like "$(cat "$CON/.claude/settings.json")" 'h2\.sh' "renamed: a handler mentions h2.sh"
  no_file "$CON/.claude/hooks/kit/h.sh"
  has_file "$CON/.claude/hooks/kit/h2.sh"
}

t_settings_entry_excludes() {
  fresh
  set_kitjson '.exclude=["allow:Bash(echo *)","set:autoMemoryEnabled"]'
  kit_run render
  is "$RC" 0 "entry_excludes: render exits 0"
  unlike "$(cat "$CON/.claude/settings.json")" 'echo' "entry_excludes: allow entry dropped"
  is "$(S 'has("autoMemoryEnabled")')" false "entry_excludes: scalar dropped"
  is "$(jq -c .set "$CON/.claude/kit.lock.json")" '{}' "entry_excludes: lock set empty"
}

t_settings_hook_exclude() {
  fresh
  set_kitjson '.exclude=[".claude/hooks/kit/h.sh"]'
  kit_run render
  is "$RC" 0 "hook_exclude: render exits 0"
  is "$(S '(.hooks.PreToolUse // []) | length')" 0 "hook_exclude: no PreToolUse handler"
}

t_settings_absent() {
  fresh
  rm "$CON/.claude/settings.json"
  kit_run render
  is "$RC" 0 "absent: render exits 0"
  has_file "$CON/.claude/settings.json"
  is "$(S .permissions.allow)" '["Read","Bash(echo *)","Bash(git fetch origin main)"]' "absent: kit entries only"
  is "$(jq -c .settings.adopted.allow "$CON/.claude/kit.lock.json")" '[]' "absent: nothing adopted"
}

t_settings_unknown_keys_kept() {
  fresh
  echo '{"model":"opus","permissions":{"defaultMode":"plan","allow":["Read"]}}' > "$CON/.claude/settings.json"
  kit_run render
  is "$RC" 0 "unknown: render exits 0"
  is "$(S .model)" '"opus"' "unknown: top-level key kept"
  is "$(S .permissions.defaultMode)" '"plan"' "unknown: permissions key kept"
}

t_settings_idempotent() {
  fresh
  kit_run render
  cp "$CON/.claude/settings.json" "$T/s1"
  cp "$CON/.claude/kit.lock.json" "$T/l1"
  kit_run render
  cmp -s "$T/s1" "$CON/.claude/settings.json"
  is "$?" 0 "idempotent: settings byte-identical"
  cmp -s "$T/l1" "$CON/.claude/kit.lock.json"
  is "$?" 0 "idempotent: lock byte-identical"
}

t_settings_bad_fragment() {
  fresh
  echo '{"permissions": ' > "$T/kit/slices/core/settings.json"
  move_pin "bad fragment"
  kit_run render
  is "$RC" 1 "bad_fragment: render exits 1"
  like "$OUT" '^RENDER slices/core/settings\.json is not valid JSON$' "bad_fragment: RENDER line"
}

t_settings_first_render
t_settings_adopted_survives_drop
t_settings_renamed_hook_removed
t_settings_entry_excludes
t_settings_hook_exclude
t_settings_absent
t_settings_unknown_keys_kept
t_settings_idempotent
t_settings_bad_fragment
done_testing
