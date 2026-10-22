#!/usr/bin/env bash
# kit status, init, scaffold, edit and bump; render's excluded-source notice.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
t_setup
# Keep every scratch dir the kit makes inside $T, which the harness removes.
mkdir -p "$T/tmp"
export TMPDIR="$T/tmp"

BASIC="$TEST_ROOT/test/consumers/basic"

# fresh: a new toy kit and a basic consumer at $T/con, rendered and committed.
fresh() {
  rm -rf "$T/kit" "$T/con"
  mk_kit "$TEST_ROOT/test/kits/toy/slices"
  mk_consumer "$BASIC" "$T/con"
  kit_run render
  git -C "$CON" add -A
  git -C "$CON" commit -q -m "rendered"
}

# exact <file>: the file's bytes, trailing newlines included (ends with "x").
exact() { cat "$1"; printf x; }

# kit_commit <msg>: commit the toy kit's working tree.
kit_commit() {
  git -C "$T/kit" add -A
  git -C "$T/kit" commit -q -m "$1"
}

t_status() {
  fresh
  kit_run status
  is "$RC" 0 "status: exits 0"
  like "$OUT" '^kit [0-9a-f]{7} · files ok · lock ok · jq ok · checkout clean$' "status: clean consumer"
  echo "local" >> "$CON/.claude/rules/kit/a.md"
  kit_run status
  like "$OUT" '· files 1 differ ·' "status: an edited file counts as one difference"
  git -C "$CON" checkout -q -- .claude/rules/kit/a.md
  rm "$CON/.claude/rules/kit/a.md"
  kit_run status
  like "$OUT" '· files 1 differ ·' "status: a missing file counts"
  git -C "$CON" checkout -q -- .claude/rules/kit/a.md
  echo "x" > "$T/kit/x.txt"
  kit_commit "second"
  git -C "$CON/.claude/vendor/kit" fetch -q "$T/kit" main
  git -C "$CON/.claude/vendor/kit" checkout -q FETCH_HEAD
  kit_run status
  like "$OUT" '· checkout off-pin$' "status: head differs from the pin"
  git -C "$CON" add .claude/vendor/kit
  kit_run status
  like "$OUT" '· lock stale ·' "status: pin moved without render"
  echo "dirt" >> "$CON/.claude/vendor/kit/CHANGELOG.md"
  kit_run status
  like "$OUT" '· checkout dirty$' "status: dirty checkout"
  git -C "$CON/.claude/vendor/kit" checkout -q -- CHANGELOG.md
  # An uninitialised checkout has no bin/kit, so run a copy of the code directly.
  mkdir -p "$T/copy"
  cp -R "$TEST_ROOT/bin" "$TEST_ROOT/lib" "$T/copy/"
  find "$CON/.claude/vendor/kit" -mindepth 1 -delete
  OUT="$(cd "$CON" && KIT_PINNED="$(git -C "$CON" ls-files -s .claude/vendor/kit | cut -d' ' -f2)" bash "$T/copy/bin/kit" status 2>&1)" && RC=0 || RC=$?
  is "$RC" 0 "status: absent checkout exits 0"
  like "$OUT" '· checkout absent$' "status: empty checkout is absent"
}

t_init() {
  fresh
  git -C "$CON" config --unset push.recurseSubmodules
  GIT_ALLOW_PROTOCOL=file kit_run init
  is "$RC" 0 "init: exits 0"
  is "$(git -C "$CON" config push.recurseSubmodules)" check "init: push.recurseSubmodules is check"
}

t_scaffold() {
  fresh
  git -C "$CON" rm -q -f .claude/kit.json .claude/rules/repo.md .claude/memory/MEMORY.md
  kit_run scaffold
  is "$RC" 0 "scaffold: exits 0"
  like "$OUT" '^created \.claude/kit\.json$' "scaffold: creates kit.json"
  like "$OUT" '^created \.claude/memory/MEMORY\.md$' "scaffold: creates MEMORY.md"
  like "$OUT" '^created \.claude/memory/friction/\.gitkeep$' "scaffold: creates friction"
  like "$OUT" '^created \.claude/memory/patterns/\.gitkeep$' "scaffold: creates patterns"
  is "$(jq -c . "$CON/.claude/kit.json")" '{"format":1,"slices":["core"],"params":{"gate":""},"exclude":[]}' "scaffold: kit.json content"
  has_file "$CON/.claude/rules/repo.md"
  kit_run scaffold
  unlike "$OUT" '^created' "scaffold: a second run creates nothing"
  is "$(printf '%s\n' "$OUT" | grep -c '^kept ')" 5 "scaffold: a second run keeps five items"
}

t_scaffold_headings() {
  fresh
  git -C "$CON" rm -q -f .claude/rules/repo.md
  kit_run scaffold
  like "$OUT" '^created \.claude/rules/repo\.md$' "scaffold: creates repo.md"
  is "$(exact "$CON/.claude/rules/repo.md")" "## Deploy

x" "scaffold: repo.md lists the headings of the listed slices"
  echo "mine" > "$CON/.claude/rules/repo.md"
  kit_run scaffold
  is "$(cat "$CON/.claude/rules/repo.md")" "mine" "scaffold: never overwrites repo.md"
}

t_scaffold_memory_root() {
  fresh
  jq -c '.params.memory_root=".mem"' "$CON/.claude/kit.json" > "$T/k.json"
  cp "$T/k.json" "$CON/.claude/kit.json"
  kit_run scaffold
  like "$OUT" '^created \.mem/MEMORY\.md$' "scaffold: honours memory_root"
  echo '{' > "$CON/.claude/kit.json"
  kit_run scaffold
  is "$RC" 0 "scaffold: an invalid kit.json still exits 0"
  like "$OUT" '^kept \.claude/memory/MEMORY\.md$' "scaffold: invalid kit.json falls back to .claude/memory"
}

t_edit() {
  fresh
  kit_run edit .claude/rules/kit/a.md
  is "$RC" 0 "edit: exits 0"
  like "$OUT" '^\.claude/rules/kit/a\.md is rendered from slices/core/rules/a\.md at [0-9a-f]{7}\.$' "edit: names the source and pin"
  like "$OUT" '^3\. In the standalone clone: `git -C ~/git/bitsy-services/claude-kit switch -c <topic>`' "edit: authoring steps"
  like "$OUT" '^6\. `kit bump` in the consumer' "edit: last step"
  kit_run edit CLAUDE.md
  is "$RC" 1 "edit: a non-rendered dest exits 1"
  is "$OUT" "CLAUDE.md is not rendered by the kit" "edit: says so"
}

t_bump() {
  fresh
  local old new
  old="$(git -C "$CON" rev-parse HEAD)"
  echo "## 2026-10-21 — toy change" >> "$T/kit/CHANGELOG.md"
  kit_commit "toy change"
  new="$(git -C "$T/kit" rev-parse HEAD)"
  kit_run bump --from "$T/kit" main
  is "$RC" 0 "bump: exits 0"
  like "$OUT" 'toy change' "bump: prints the CHANGELOG lines added"
  unlike "$OUT" '^\+' "bump: CHANGELOG lines have no plus"
  is "$(git -C "$CON" ls-files -s .claude/vendor/kit | cut -d' ' -f2)" "$new" "bump: gitlink staged at the new head"
  is "$(git -C "$CON" rev-parse HEAD)" "$old" "bump: no new commit"
  is "$(jq -r .pin "$CON/.claude/kit.lock.json")" "$new" "bump: lock follows the new pin"
}

t_bump_failure() {
  fresh
  local oldpin
  oldpin="$(git -C "$CON" ls-files -s .claude/vendor/kit | cut -d' ' -f2)"
  echo '{' > "$T/kit/slices/core/slice.json"
  kit_commit "break core"
  kit_run bump --from "$T/kit" main
  is "$RC" 1 "bump failure: exits 1"
  like "$OUT" 'bump: render failed; restored '"${oldpin:0:7}" "bump failure: says it restored"
  is "$(git -C "$CON" ls-files -s .claude/vendor/kit | cut -d' ' -f2)" "$oldpin" "bump failure: gitlink back at the old pin"
  is "$(git -C "$CON/.claude/vendor/kit" rev-parse HEAD)" "$oldpin" "bump failure: checkout back at the old pin"
}

# R13
t_excluded_notice() {
  fresh
  jq -c '.exclude=[".claude/rules/kit/a.md"]' "$CON/.claude/kit.json" > "$T/k.json"
  cp "$T/k.json" "$CON/.claude/kit.json"
  kit_run render
  unlike "$OUT" 'NOTICE' "excluded: newly excluded dest prints no notice"
  kit_run render
  unlike "$OUT" 'NOTICE' "excluded: unchanged source prints no notice"
  echo "Another line." >> "$T/kit/slices/core/rules/a.md"
  kit_commit "change a.md"
  kit_run bump --from "$T/kit" main
  like "$OUT" '^NOTICE \.claude/rules/kit/a\.md is excluded; the kit changed its source at [0-9a-f]{7}$' "excluded: bump prints the notice"
  kit_run render
  unlike "$OUT" 'NOTICE' "excluded: the notice does not repeat"
}

t_status
t_init
t_scaffold
t_scaffold_headings
t_scaffold_memory_root
t_edit
t_bump
t_bump_failure
t_excluded_notice
done_testing
