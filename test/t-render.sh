#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
t_setup
# Keep every scratch dir the kit makes inside $T, which the harness removes.
mkdir -p "$T/tmp"
export TMPDIR="$T/tmp"

BASIC="$TEST_ROOT/test/consumers/basic"
SFX=' — edit the source in the kit, never this copy -->'
stamp() { printf '<!-- kit: rendered from %s%s' "$1" "$SFX"; }

# fresh [dir]: a new toy kit and a basic consumer at dir (default $T/con).
fresh() {
  rm -rf "$T/kit" "$T/con" "$T/My Repo"
  mk_kit "$TEST_ROOT/test/kits/toy/slices"
  mk_consumer "$BASIC" "${1:-$T/con}"
}

# set_kitjson <jq-filter>: rewrite the consumer's kit.json.
set_kitjson() {
  jq -c "$1" "$CON/.claude/kit.json" > "$T/kit.json.new"
  cp "$T/kit.json.new" "$CON/.claude/kit.json"
}

# move_pin <msg>: commit the toy kit's working tree and point the consumer at it.
move_pin() {
  git -C "$T/kit" add -A
  git -C "$T/kit" commit -q -m "$1"
  git -C "$CON/.claude/vendor/kit" fetch -q "$T/kit" main
  git -C "$CON/.claude/vendor/kit" checkout -q FETCH_HEAD
  git -C "$CON" add .claude/vendor/kit
}

# exact <file>: the file's bytes, trailing newlines included (ends with "x").
exact() { cat "$1"; printf x; }

t_render_basic() {
  fresh
  kit_run render
  is "$RC" 0 "basic: render exits 0"
  local r="$CON/.claude"
  is "$(exact "$r/rules/kit/a.md")" \
    "$(stamp slices/core/rules/a.md)
Run \`bash scripts/check.sh\` before committing.
x" "basic: a.md is exactly the stamp then the substituted body"
  is "$(sed -n 3p "$r/rules/kit/b.md")" "---" "basic: b.md frontmatter closes on line 3"
  is "$(sed -n 4p "$r/rules/kit/b.md")" "$(stamp slices/extra/rules/b.md)" "basic: b.md stamp follows the closing ---"
  is "$(sed -n 5p "$r/rules/kit/b.md")" "Trunk is main." "basic: b.md body follows the stamp"
  is "$(sed -n 1p "$r/hooks/kit/h.sh")" "#!/usr/bin/env bash" "basic: h.sh keeps its shebang on line 1"
  is "$(sed -n 2p "$r/hooks/kit/h.sh")" \
    "# <!-- kit: rendered from slices/core/hooks/h.sh — edit the source in the kit, never this copy -->" \
    "basic: h.sh stamp is line 2"
  is "$(sed -n 1p "$r/skills/s/SKILL.md")" "---" "basic: SKILL.md keeps --- on line 1"
  is "$(sed -n 5p "$r/skills/s/SKILL.md")" "$(stamp slices/core/skills/s/SKILL.md)" "basic: SKILL.md stamp follows its frontmatter"
  is "$(jq -r .pin "$r/kit.lock.json")" "$KIT_HEAD" "basic: lock pin is the kit head"
  is "$(jq -r '.files[".claude/rules/kit/a.md"].from' "$r/kit.lock.json")" "slices/core/rules/a.md" "basic: lock names the source"
  is "$(jq -r '.files[".claude/rules/kit/a.md"].blob' "$r/kit.lock.json")" \
    "$(git hash-object -- "$r/rules/kit/a.md")" "basic: lock blob is the rendered file's blob"
  is "$(jq -c 'keys_unsorted' "$r/kit.lock.json")" '["format","pin","files","excluded"]' "basic: lock keys (R2)"
  is "$(jq -c '.files | keys' "$r/kit.lock.json")" \
    '[".claude/hooks/kit/h.sh",".claude/rules/kit/a.md",".claude/rules/kit/b.md",".claude/skills/s/SKILL.md"]' \
    "basic: lock lists every rendered dest"
  is "$(exact "$r/settings.json")" "$(exact "$BASIC/settings.json")" "basic: settings.json untouched (R2)"
}

t_render_idempotent() {
  fresh
  kit_run render
  local s1
  s1="$(git -C "$CON" status --porcelain)"
  cp "$CON/.claude/kit.lock.json" "$T/lock1"
  kit_run render
  is "$RC" 0 "idempotent: second render exits 0"
  is "$(git -C "$CON" status --porcelain)" "$s1" "idempotent: status unchanged by the second render"
  cmp -s "$T/lock1" "$CON/.claude/kit.lock.json"
  is "$?" 0 "idempotent: lock is byte-identical"
  git -C "$CON" add -A
  git -C "$CON" commit -q -m "rendered"
  kit_run render
  is "$(git -C "$CON" status --porcelain)" "" "idempotent: render over a committed render changes nothing"
}

t_render_refuses_edit() {
  fresh
  kit_run render
  echo "local line" >> "$CON/.claude/rules/kit/a.md"
  kit_run render
  is "$RC" 1 "refuses_edit: render exits 1"
  like "$OUT" '^REFUSE \.claude/rules/kit/a\.md: edited in place \(blob differs from the lock\); rerun with --discard to overwrite$' \
    "refuses_edit: REFUSE line"
  like "$(cat "$CON/.claude/rules/kit/a.md")" 'local line' "refuses_edit: the edit survives the refusal"
  kit_run render --discard
  is "$RC" 0 "refuses_edit: --discard exits 0"
  unlike "$(cat "$CON/.claude/rules/kit/a.md")" 'local line' "refuses_edit: --discard overwrites the edit"
}

t_render_refuses_unowned_collision() {
  fresh
  mkdir -p "$CON/.claude/skills/s"
  printf 'local skill\n' > "$CON/.claude/skills/s/SKILL.md"
  kit_run render
  is "$RC" 1 "collision: render exits 1"
  like "$OUT" '^REFUSE \.claude/skills/s/SKILL\.md: exists and is not rendered by the kit; rerun with --discard to overwrite$' \
    "collision: REFUSE line"
  is "$(cat "$CON/.claude/skills/s/SKILL.md")" "local skill" "collision: the local file is untouched"
  no_file "$CON/.claude/rules/kit/a.md"
  no_file "$CON/.claude/kit.lock.json"
  kit_run render --discard
  is "$RC" 0 "collision: --discard exits 0"
  is "$(sed -n 1p "$CON/.claude/skills/s/SKILL.md")" "---" "collision: --discard installs the rendered skill"
}

t_render_exclude() {
  fresh
  set_kitjson '.exclude=[".claude/rules/kit/a.md"]'
  kit_run render
  is "$RC" 0 "exclude: render exits 0"
  no_file "$CON/.claude/rules/kit/a.md"
  local want
  want="$(printf '%s\n%s\n' "$(stamp slices/core/rules/a.md)" 'Run `bash scripts/check.sh` before committing.' | git hash-object --stdin)"
  is "$(jq -r '.excluded[".claude/rules/kit/a.md"]' "$CON/.claude/kit.lock.json")" "$want" \
    "exclude: lock records the excluded dest's rendered blob"
  is "$(jq -r '.files | has(".claude/rules/kit/a.md")' "$CON/.claude/kit.lock.json")" false "exclude: not in files"
  # an excluded dest the consumer keeps locally is neither refused nor touched
  printf 'mine\n' > "$CON/.claude/rules/kit/a.md"
  kit_run render
  is "$RC" 0 "exclude: a local file at an excluded dest is not refused"
  is "$(cat "$CON/.claude/rules/kit/a.md")" "mine" "exclude: a local file at an excluded dest is untouched"
}

t_render_orphan_removed() {
  fresh
  kit_run render
  printf 'mine\n' > "$CON/.claude/rules/kit/mine.md"
  set_kitjson '.slices=["core"]'
  kit_run render
  is "$RC" 0 "orphan: render exits 0"
  no_file "$CON/.claude/rules/kit/b.md"
  has_file "$CON/.claude/rules/kit/a.md"
  has_file "$CON/.claude/rules/kit/mine.md"
  is "$(jq -r '.files | has(".claude/rules/kit/b.md")' "$CON/.claude/kit.lock.json")" false "orphan: dropped from the lock"
}

t_render_orphan_edited() {
  fresh
  kit_run render
  set_kitjson '.slices=["core"]'
  echo "local line" >> "$CON/.claude/rules/kit/b.md"
  kit_run render
  is "$RC" 1 "orphan_edited: render exits 1"
  like "$OUT" '^REFUSE \.claude/rules/kit/b\.md: edited in place \(blob differs from the lock\); rerun with --discard to remove$' \
    "orphan_edited: REFUSE line"
  has_file "$CON/.claude/rules/kit/b.md"
  kit_run render --discard
  is "$RC" 0 "orphan_edited: --discard exits 0"
  no_file "$CON/.claude/rules/kit/b.md"
}

t_render_orphan_skill_dir() {
  fresh
  kit_run render
  git -C "$T/kit" rm -q -r slices/core/skills
  move_pin "drop skill s"
  kit_run render
  is "$RC" 0 "orphan_skill: render exits 0"
  no_file "$CON/.claude/skills/s/SKILL.md"
  no_file "$CON/.claude/skills/s"
}

t_render_path_with_space() {
  fresh "$T/My Repo"
  kit_run render
  is "$RC" 0 "space: render exits 0"
  has_file "$CON/.claude/rules/kit/a.md"
  is "$(sed -n 2p "$CON/.claude/rules/kit/a.md")" 'Run `bash scripts/check.sh` before committing.' "space: a.md rendered"
  set_kitjson '.slices=["core"]'
  kit_run render
  is "$RC" 0 "space: re-render exits 0"
  no_file "$CON/.claude/rules/kit/b.md"
}

t_render_undeclared() {
  fresh
  printf 'Use {{kit.nope}} and {{kit.gate}}.\n' > "$T/kit/slices/core/rules/u.md"
  move_pin "undeclared param"
  kit_run render
  is "$RC" 1 "undeclared: render exits 1"
  like "$OUT" '^RENDER undeclared \{\{kit\.nope\}\} in slices/core/rules/u\.md$' "undeclared: RENDER line"
  unlike "$OUT" 'kit\.gate' "undeclared: declared params are not reported"
  no_file "$CON/.claude/rules/kit/a.md"
  no_file "$CON/.claude/kit.lock.json"
}

t_render_single_pass() {
  fresh
  set_kitjson '.params.trunk="{{kit.gate}}"'
  kit_run render
  is "$RC" 0 "single_pass: render exits 0"
  is "$(sed -n 5p "$CON/.claude/rules/kit/b.md")" "Trunk is {{kit.gate}}." "single_pass: a value is never re-substituted"
}

t_render_config_failure() {
  fresh
  set_kitjson '.format=2'
  kit_run render
  is "$RC" 1 "config_failure: render exits 1"
  like "$OUT" '^CONFIG format 2 is not supported' "config_failure: CONFIG line"
  no_file "$CON/.claude/kit.lock.json"
}

t_render_bad_lock() {
  fresh
  kit_run render
  printf 'outside\n' > "$CON/outside.md"
  jq '.files[".claude/rules/kit/../../outside.md"]={"from":"slices/core/rules/x.md","blob":"0"}' \
    "$CON/.claude/kit.lock.json" > "$T/lock.new"
  cp "$T/lock.new" "$CON/.claude/kit.lock.json"
  kit_run render --discard
  is "$RC" 1 "bad_lock: a lock entry outside the kit destinations fails"
  like "$OUT" '^RENDER \.claude/kit\.lock\.json names \.claude/rules/kit/\.\./\.\./outside\.md, which is not a kit destination$' \
    "bad_lock: RENDER line"
  has_file "$CON/outside.md"
  printf 'not json\n' > "$CON/.claude/kit.lock.json"
  kit_run render
  is "$RC" 1 "bad_lock: an unparsable lock fails"
  like "$OUT" '^RENDER \.claude/kit\.lock\.json is not a valid kit lock' "bad_lock: invalid lock line"
}

t_render_usage() {
  fresh
  kit_run render --bogus
  is "$RC" 2 "usage: an unknown flag exits 2"
}

# R9: "replace a kit file" is exclude it and write your own; render keeps it.
t_render_exclude_keeps_own() {
  fresh
  kit_run render
  set_kitjson '.exclude=[".claude/rules/kit/a.md"]'
  printf 'my own rule\n' > "$CON/.claude/rules/kit/a.md"
  kit_run render
  is "$RC" 0 "exclude_own: excluding an owned dest and replacing it exits 0"
  is "$(cat "$CON/.claude/rules/kit/a.md")" "my own rule" "exclude_own: own content kept"
  is "$(jq -r '.files | has(".claude/rules/kit/a.md")' "$CON/.claude/kit.lock.json")" false "exclude_own: dropped from files"
  is "$(jq -r '.excluded | has(".claude/rules/kit/a.md")' "$CON/.claude/kit.lock.json")" true "exclude_own: recorded in excluded"
  kit_run render --discard
  is "$RC" 0 "exclude_own: --discard exits 0"
  is "$(cat "$CON/.claude/rules/kit/a.md")" "my own rule" "exclude_own: --discard keeps own content too"
}

t_render_exclude_keeps_stamped() {
  fresh
  kit_run render
  cp "$CON/.claude/rules/kit/a.md" "$T/a.stamped"
  set_kitjson '.exclude=[".claude/rules/kit/a.md"]'
  kit_run render
  is "$RC" 0 "exclude_stamped: excluding an owned dest exits 0"
  is "$(exact "$CON/.claude/rules/kit/a.md")" "$(exact "$T/a.stamped")" "exclude_stamped: the stamped file stays on disk"
}

# R10: every scratch dir a kit run makes, the re-exec extract included, is gone after it.
t_render_no_scratch_left() {
  fresh
  local saved="$TMPDIR"
  mkdir -p "$T/scratch"
  export TMPDIR="$T/scratch"
  kit_run render
  is "$RC" 0 "scratch: render exits 0"
  is "$(ls -A "$T/scratch")" "" "scratch: a clean render leaves TMPDIR empty"
  echo "local line" >> "$CON/.claude/rules/kit/a.md"
  kit_run render
  is "$RC" 1 "scratch: refused render exits 1"
  is "$(ls -A "$T/scratch")" "" "scratch: a refused render leaves TMPDIR empty"
  set_kitjson '.format=2'
  kit_run render
  is "$RC" 1 "scratch: CONFIG failure exits 1"
  is "$(ls -A "$T/scratch")" "" "scratch: a CONFIG failure leaves TMPDIR empty"
  export TMPDIR="$saved"
}

t_render_basic
t_render_idempotent
t_render_refuses_edit
t_render_refuses_unowned_collision
t_render_exclude
t_render_orphan_removed
t_render_orphan_edited
t_render_orphan_skill_dir
t_render_path_with_space
t_render_undeclared
t_render_single_pass
t_render_config_failure
t_render_bad_lock
t_render_usage
t_render_exclude_keeps_own
t_render_exclude_keeps_stamped
t_render_no_scratch_left
done_testing
