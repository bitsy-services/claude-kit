#!/usr/bin/env bash
# kit check, render consistency: objects, dirty, off-pin, config, missing,
# drift, orphan, stamp, excluded changed and lock rows.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
t_setup
# Keep every scratch dir the kit makes inside $T, which the harness removes.
mkdir -p "$T/tmp"
export TMPDIR="$T/tmp"

BASIC="$TEST_ROOT/test/consumers/basic"
DRIFT_TAIL=': edited in place, or the pin moved without kit render'

# fresh [dir]: a new toy kit and a basic consumer at dir (default $T/con).
fresh() {
  rm -rf "$T/kit" "$T/con" "$T/My Repo" "$T/fresh" "$T/before"
  mk_kit "$TEST_ROOT/test/kits/toy/slices"
  mk_consumer "$BASIC" "${1:-$T/con}"
}

# rendered [dir]: fresh, then kit render, committed.
rendered() {
  fresh "$@"
  kit_run render
  git -C "$CON" add -A
  git -C "$CON" commit -q -m "rendered"
}

# set_kitjson <jq-filter>: rewrite the consumer's kit.json.
set_kitjson() {
  jq -c "$1" "$CON/.claude/kit.json" > "$T/kit.json.new"
  cp "$T/kit.json.new" "$CON/.claude/kit.json"
}

# move_pin <msg>: commit the toy kit's working tree, check it out in the
# vendor dir and stage it as the pin, without rendering.
move_pin() {
  git -C "$T/kit" add -A
  git -C "$T/kit" commit -q -m "$1"
  git -C "$CON/.claude/vendor/kit" fetch -q "$T/kit" main
  git -C "$CON/.claude/vendor/kit" checkout -q FETCH_HEAD
  git -C "$CON" add .claude/vendor/kit
}

last_line() { printf '%s\n' "$1" | tail -n 1; }

# has_line <text> <line> <desc>: <text> holds <line> as a whole line.
has_line() {
  local ok=1
  printf '%s\n' "$1" | grep -Fxq -- "$2" && ok=0
  _t_report "$ok" "$3"
  if [ "$ok" != 0 ]; then echo "#   text: $1"; echo "#   wanted line: $2"; fi
}

# in_order <text> <line1> <line2> <desc>: both whole lines present, line1 first.
in_order() {
  local a b ok=1
  a="$(printf '%s\n' "$1" | grep -Fxn -- "$2" | head -n 1 | cut -d: -f1)"
  b="$(printf '%s\n' "$1" | grep -Fxn -- "$3" | head -n 1 | cut -d: -f1)"
  if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then ok=0; fi
  _t_report "$ok" "$4"
  if [ "$ok" != 0 ]; then echo "#   text: $1"; echo "#   wanted: $2"; echo "#   before: $3"; fi
}

t_check_clean() {
  rendered
  kit_run check
  is "$RC" 0 "clean: check exits 0"
  is "$(last_line "$OUT")" "kit check: ok" "clean: ends with kit check: ok"
  is "$(ls -A "$T/tmp")" "" "clean: no scratch dir left behind"
  kit_run check --published
  is "$RC" 0 "clean: --published is accepted"
  kit_run check --bogus
  is "$RC" 2 "clean: an unknown flag exits 2"
}

t_check_drift() {
  rendered
  echo "local line" >> "$CON/.claude/rules/kit/a.md"
  kit_run check
  is "$RC" 1 "drift: check exits 1"
  has_line "$OUT" "DRIFT .claude/rules/kit/a.md differs from slices/core/rules/a.md at ${KIT_HEAD:0:7}$DRIFT_TAIL" \
    "drift: DRIFT line"
  is "$(last_line "$OUT")" "kit check: 1 problems" "drift: one problem"
}

t_check_missing() {
  rendered
  rm "$CON/.claude/rules/kit/b.md"
  kit_run check
  is "$RC" 1 "missing: check exits 1"
  has_line "$OUT" "WORKTREE .claude/rules/kit/b.md is missing: run kit render" "missing: WORKTREE line"
  is "$(last_line "$OUT")" "kit check: 1 problems" "missing: one problem"
}

t_check_orphan() {
  rendered
  printf 'stray\n' > "$CON/.claude/rules/kit/stray.md"
  kit_run check
  is "$RC" 1 "orphan: check exits 1"
  has_line "$OUT" "ORPHAN .claude/rules/kit/stray.md is not rendered by any enabled slice: delete it or run kit render" \
    "orphan: ORPHAN line"
  is "$(last_line "$OUT")" "kit check: 1 problems" "orphan: one problem"
}

# The orphan scope: anything under the kit's rule and hook dirs, and a skill
# dir only when its SKILL.md carries the stamp.
t_check_orphan_scope() {
  rendered
  printf 'stray\n' > "$CON/.claude/hooks/kit/old.sh"
  mkdir -p "$CON/.claude/skills/old" "$CON/.claude/skills/mine"
  sed 's#slices/core/skills/s/#slices/core/skills/old/#' "$CON/.claude/skills/s/SKILL.md" \
    > "$CON/.claude/skills/old/SKILL.md"
  printf -- '---\nname: mine\ndescription: local\n---\nMine.\n' > "$CON/.claude/skills/mine/SKILL.md"
  printf 'Local notes.\n' > "$CON/.claude/rules/local.md"
  kit_run check
  is "$RC" 1 "orphan_scope: check exits 1"
  has_line "$OUT" "ORPHAN .claude/hooks/kit/old.sh is not rendered by any enabled slice: delete it or run kit render" \
    "orphan_scope: a file under hooks/kit"
  has_line "$OUT" "ORPHAN .claude/skills/old/SKILL.md is not rendered by any enabled slice: delete it or run kit render" \
    "orphan_scope: a stamped skill no slice renders"
  unlike "$OUT" 'skills/mine' "orphan_scope: an unstamped local skill is not an orphan"
  unlike "$OUT" 'rules/local\.md' "orphan_scope: a rule outside rules/kit is not an orphan"
  is "$(last_line "$OUT")" "kit check: 2 problems" "orphan_scope: two problems"
}

# R9: an excluded dest is never missing, drift or orphan; only STAMP and the
# excluded-changed notice look at it.
t_check_stamp() {
  rendered
  set_kitjson '.exclude=[".claude/rules/kit/a.md"]'
  kit_run render
  kit_run check
  is "$RC" 1 "stamp: check exits 1"
  has_line "$OUT" "STAMP .claude/rules/kit/a.md is excluded but still carries the kit stamp: replace it with your own file" \
    "stamp: STAMP line"
  unlike "$OUT" '^(WORKTREE|DRIFT|ORPHAN) ' "stamp: an excluded dest is not missing, drift or orphan"
  is "$(last_line "$OUT")" "kit check: 1 problems" "stamp: one problem"
  printf 'my own rule\n' > "$CON/.claude/rules/kit/a.md"
  kit_run check
  is "$RC" 0 "stamp: replacing it with your own file clears it"
  rm "$CON/.claude/rules/kit/a.md"
  kit_run check
  is "$RC" 0 "stamp: an absent excluded dest is not missing"
  # the shell form of the stamp, after the shebang
  set_kitjson '.exclude=[".claude/hooks/kit/h.sh"]'
  kit_run render
  kit_run check
  has_line "$OUT" "STAMP .claude/hooks/kit/h.sh is excluded but still carries the kit stamp: replace it with your own file" \
    "stamp: a stamped hook is found too"
}

t_check_pin_moved() {
  rendered
  printf 'Read the changelog too.\n' >> "$T/kit/slices/core/rules/a.md"
  move_pin "change a.md"
  local p7
  p7="$(git -C "$T/kit" rev-parse HEAD)"
  p7="${p7:0:7}"
  kit_run check
  is "$RC" 1 "pin_moved: check exits 1"
  has_line "$OUT" "DRIFT .claude/rules/kit/a.md differs from slices/core/rules/a.md at $p7$DRIFT_TAIL" \
    "pin_moved: DRIFT line names the new pin"
  has_line "$OUT" "STALE LOCK .claude/kit.lock.json differs from a fresh render at $p7: run kit render" \
    "pin_moved: STALE LOCK line"
  is "$(last_line "$OUT")" "kit check: 2 problems" "pin_moved: two problems"
  kit_run render
  kit_run check
  is "$RC" 0 "pin_moved: kit render clears both"
}

t_check_dirty() {
  rendered
  echo x >> "$CON/.claude/vendor/kit/CHANGELOG.md"
  kit_run check
  is "$RC" 1 "dirty: check exits 1"
  has_line "$OUT" "DIRTY .claude/vendor/kit has local edits; kit source is edited in the kit's own clone" \
    "dirty: DIRTY line"
  is "$(last_line "$OUT")" "kit check: 1 problems" "dirty: one problem"
}

t_check_off_pin() {
  rendered
  local old="$KIT_HEAD" new
  echo "next" >> "$T/kit/CHANGELOG.md"
  move_pin "next"
  new="$(git -C "$T/kit" rev-parse HEAD)"
  kit_run render
  git -C "$CON/.claude/vendor/kit" checkout -q "$old"
  kit_run check
  is "$RC" 0 "off_pin: a notice alone exits 0"
  has_line "$OUT" "NOTICE .claude/vendor/kit is checked out at ${old:0:7}, pinned at ${new:0:7} (run: git submodule update .claude/vendor/kit)" \
    "off_pin: NOTICE line"
  is "$(last_line "$OUT")" "kit check: ok" "off_pin: ends with kit check: ok"
}

# R1: the consumer comes from the working directory, not the script's location.
t_check_not_present() {
  rendered
  git clone -q "$CON" "$T/fresh"
  OUT="$(cd "$T/fresh" && bash "$CON/.claude/vendor/kit/bin/kit" check 2>&1)" && RC=0 || RC=$?
  is "$RC" 1 "not_present: check exits 1"
  has_line "$OUT" "NOT PRESENT ${KIT_HEAD:0:7} run: git submodule update --init .claude/vendor/kit" \
    "not_present: NOT PRESENT line"
}

t_check_config() {
  rendered
  set_kitjson '.format=2 | .slices += ["nope"]'
  kit_run check
  is "$RC" 1 "config: check exits 1"
  has_line "$OUT" "CONFIG format 2 is not supported; this kit reads format 1 (see CHANGELOG)" "config: format line"
  has_line "$OUT" 'CONFIG unknown slice "nope"' "config: unknown slice line"
  unlike "$OUT" '^(WORKTREE|DRIFT|ORPHAN|STAMP|STALE LOCK) ' "config: rows that need a fresh render are skipped"
  is "$(last_line "$OUT")" "kit check: 2 problems" "config: each CONFIG line is a problem"
}

t_check_excluded_changed() {
  fresh
  set_kitjson '.exclude=[".claude/rules/kit/a.md"]'
  kit_run render
  printf 'Read the changelog too.\n' >> "$T/kit/slices/core/rules/a.md"
  move_pin "change a.md"
  local p7 stale notice
  p7="$(git -C "$T/kit" rev-parse HEAD)"
  p7="${p7:0:7}"
  stale="STALE LOCK .claude/kit.lock.json differs from a fresh render at $p7: run kit render"
  notice="NOTICE .claude/rules/kit/a.md is excluded; the kit changed its source at $p7"
  kit_run check
  is "$RC" 1 "excluded_changed: the stale lock is a problem"
  has_line "$OUT" "$notice" "excluded_changed: NOTICE line"
  in_order "$OUT" "$stale" "$notice" "excluded_changed: problems print before notices"
  in_order "$OUT" "$notice" "kit check: 1 problems" "excluded_changed: notices print before the summary"
  is "$(last_line "$OUT")" "kit check: 1 problems" "excluded_changed: the notice is not counted"
  kit_run render
  kit_run check
  is "$RC" 0 "excluded_changed: render records the new source"
  unlike "$OUT" '^NOTICE ' "excluded_changed: no notice once the lock has the new source"
}

t_check_writes_nothing() {
  rendered
  echo "local line" >> "$CON/.claude/rules/kit/a.md"
  rm "$CON/.claude/rules/kit/b.md"
  printf 'stray\n' > "$CON/.claude/rules/kit/stray.md"
  printf '{"format":1}\n' > "$CON/.claude/kit.lock.json"
  local before
  before="$(git -C "$CON" status --porcelain --untracked-files=all)"
  cp -R "$CON/.claude" "$T/before"
  kit_run check
  is "$RC" 1 "writes_nothing: check exits 1"
  diff -r --exclude=vendor "$T/before" "$CON/.claude" > /dev/null
  is "$?" 0 "writes_nothing: .claude is byte-identical after check"
  is "$(git -C "$CON" status --porcelain --untracked-files=all)" "$before" "writes_nothing: git status unchanged"
  is "$(ls -A "$T/tmp")" "" "writes_nothing: no scratch dir left behind"
}

t_check_path_with_space() {
  rendered "$T/My Repo"
  kit_run check
  is "$RC" 0 "space: check exits 0"
  echo "local line" >> "$CON/.claude/rules/kit/a.md"
  kit_run check
  is "$RC" 1 "space: an edit is found"
  has_line "$OUT" "DRIFT .claude/rules/kit/a.md differs from slices/core/rules/a.md at ${KIT_HEAD:0:7}$DRIFT_TAIL" \
    "space: DRIFT line"
}

t_check_clean
t_check_drift
t_check_missing
t_check_orphan
t_check_orphan_scope
t_check_stamp
t_check_pin_moved
t_check_dirty
t_check_off_pin
t_check_not_present
t_check_config
t_check_excluded_changed
t_check_writes_nothing
t_check_path_with_space
done_testing
