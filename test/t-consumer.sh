#!/usr/bin/env bash
# kit status, init, scaffold, apply, edit and bump; render's excluded-source
# notice.
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

# init_again: write kit.json afresh with kit init; GATE is its gate.
init_again() {
  rm -f "$CON/.claude/kit.json"
  GIT_ALLOW_PROTOCOL=file kit_run init
  GATE="$(jq -r .params.gate "$CON/.claude/kit.json")"
}

t_init_kitjson() {
  fresh
  git -C "$CON" rm -q -f .claude/kit.json
  GIT_ALLOW_PROTOCOL=file kit_run init
  is "$RC" 0 "init: exits 0 when it writes kit.json"
  like "$OUT" '^created \.claude/kit\.json$' "init: creates kit.json"
  like "$OUT" '^  slices: core, extra$' "init: names the chosen slices, core first"
  like "$OUT" '^  skipped rival: conflicts with extra$' "init: skips a slice that conflicts with one chosen"
  like "$OUT" '^  gate: bash \.claude/vendor/kit/bin/kit check \(no check command found\)$' "init: the gate falls back to kit check"
  like "$OUT" '^NOTICE no scripts/check\.sh and no check or test script in package\.json, so gate is kit check' \
    "init: the fallback gate gets a notice"
  like "$OUT" '^  memory_root: \.claude/memory \(CLAUDE\.md imports @\.claude/memory/MEMORY\.md\)$' "init: names the memory index it found"
  like "$OUT" '^  trunk: topic \(it is the current branch\)$' "init: the trunk from the current branch"
  like "$OUT" '^next: change \.claude/kit\.json if you want, then run: bash \.claude/vendor/kit/bin/kit apply$' \
    "init: ends with the command to run next"
  is "$(jq -c . "$CON/.claude/kit.json")" \
    '{"format":1,"slices":["core","extra"],"params":{"gate":"bash .claude/vendor/kit/bin/kit check","trunk":"topic"},"exclude":[]}' \
    "init: kit.json holds only the values that differ from a default"
  echo '{"format":1,"slices":["core"],"params":{"gate":"mine"},"exclude":[]}' > "$CON/.claude/kit.json"
  GIT_ALLOW_PROTOCOL=file kit_run init
  is "$RC" 0 "init: exits 0 with a kit.json there"
  unlike "$OUT" 'kit\.json' "init: says nothing about a kit.json that is there"
  is "$(jq -r .params.gate "$CON/.claude/kit.json")" mine "init: never rewrites kit.json"
}

# Slice order and the requires pass: a slice that sorts before core still
# follows it, and a slice whose requirement was skipped is skipped too.
t_init_selection() {
  rm -rf "$T/kit" "$T/con"
  mk_kit "$TEST_ROOT/test/kits/toy/slices"
  mkdir -p "$T/kit/slices/able" "$T/kit/slices/needy"
  echo '{"requires": ["core"]}' > "$T/kit/slices/able/slice.json"
  echo '{"requires": ["rival"]}' > "$T/kit/slices/needy/slice.json"
  kit_commit "able and needy"
  mk_consumer "$BASIC" "$T/con"
  init_again
  is "$(jq -c .slices "$CON/.claude/kit.json")" '["core","able","extra"]' "init selection: core first, then by name"
  like "$OUT" '^  skipped rival: conflicts with extra$' "init selection: the conflict is named"
  like "$OUT" '^  skipped needy: requires rival$' "init selection: a slice whose requirement was skipped is skipped"
}

# A value its pattern rejects, and a trunk with no branch to name, become
# NOTICE lines and are not written.
t_init_notices() {
  fresh
  mkdir -p "$CON/me\$x"
  echo '# Memory' > "$CON/me\$x/MEMORY.md"
  printf '@me$x/MEMORY.md\n' > "$CON/CLAUDE.md"
  git -C "$CON" checkout -q --detach
  init_again
  like "$OUT" '^NOTICE memory_root is not set: me\$x \(CLAUDE\.md imports @me\$x/MEMORY\.md\) does not match its pattern; set "memory_root" in \.claude/kit\.json$' \
    "init notices: a value the pattern rejects"
  is "$(jq -r '.params.memory_root // "unset"' "$CON/.claude/kit.json")" unset "init notices: the rejected value is not written"
  like "$OUT" '^NOTICE no local main or master branch, no origin/HEAD and no current branch, so trunk stays main: ' \
    "init notices: no branch to name the trunk after"
}

# The gate detector: scripts/check.sh, then package.json's check script,
# then its test script unless it is npm's placeholder.
t_init_gate() {
  fresh
  echo '{"scripts":{"test":"echo \"Error: no test specified\" && exit 1"}}' > "$CON/package.json"
  init_again
  is "$GATE" "bash .claude/vendor/kit/bin/kit check" "init gate: npm's placeholder test script is no gate"
  echo '{"scripts":{"test":"vitest run"}}' > "$CON/package.json"
  init_again
  is "$GATE" "npm test" "init gate: a test script"
  like "$OUT" '^  gate: npm test \(package\.json has a test script\)$' "init gate: says where it came from"
  echo '{"scripts":{"test":"vitest run","check":"npm run lint"}}' > "$CON/package.json"
  init_again
  is "$GATE" "npm run check" "init gate: a check script comes before the test script"
  mkdir -p "$CON/scripts"
  printf '#!/usr/bin/env bash\n' > "$CON/scripts/check.sh"
  init_again
  is "$GATE" "bash scripts/check.sh" "init gate: scripts/check.sh comes first"
  unlike "$OUT" '^NOTICE' "init gate: a gate it found has no notice"
}

# The trunk detector: a local branch named as the default, else the one
# origin/HEAD names, else master, else the current branch.
t_init_trunk() {
  fresh
  git -C "$CON" update-ref refs/remotes/origin/develop HEAD
  git -C "$CON" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop
  init_again
  is "$(jq -r .params.trunk "$CON/.claude/kit.json")" develop "init trunk: the branch origin/HEAD names"
  git -C "$CON" branch main
  init_again
  is "$(jq -r '.params.trunk // "unset"' "$CON/.claude/kit.json")" unset "init trunk: a local main is the default, so it is not written"
  like "$OUT" '^  trunk: main \(a local main branch exists; origin/HEAD names develop\)$' \
    "init trunk: printed anyway, with origin/HEAD when it differs"
}

# The memory detector: a MEMORY.md that CLAUDE.md already imports.
t_init_memory() {
  fresh
  mkdir -p "$CON/brain"
  echo '# Memory' > "$CON/brain/MEMORY.md"
  printf 'Notes.\n  @brain/MEMORY.md\n' > "$CON/CLAUDE.md"
  init_again
  is "$(jq -r .params.memory_root "$CON/.claude/kit.json")" brain "init memory: the folder of the index CLAUDE.md imports"
  printf 'Notes.\n@gone/MEMORY.md\n' > "$CON/CLAUDE.md"
  init_again
  is "$(jq -r '.params.memory_root // "unset"' "$CON/.claude/kit.json")" unset "init memory: an import of a missing index is ignored"
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
  like "$OUT" '^created \.gitattributes$' "scaffold: creates .gitattributes"
  is "$(jq -c . "$CON/.claude/kit.json")" \
    '{"format":1,"slices":["core","extra"],"params":{"gate":"bash .claude/vendor/kit/bin/kit check","trunk":"topic"},"exclude":[]}' \
    "scaffold: kit.json is the one kit init writes"
  is "$(cat "$CON/.gitattributes")" '.claude/** text=auto eol=lf' "scaffold: .gitattributes keeps .claude/ text in LF"
  has_file "$CON/.claude/rules/repo.md"
  kit_run scaffold
  unlike "$OUT" '^(created|added|filled) ' "scaffold: a second run changes nothing"
  is "$(printf '%s\n' "$OUT" | grep -c '^kept ')" 5 "scaffold: a second run keeps five items"
}

t_scaffold_headings() {
  fresh
  git -C "$CON" rm -q -f .claude/rules/repo.md
  kit_run scaffold
  like "$OUT" '^created \.claude/rules/repo\.md$' "scaffold: creates repo.md"
  is "$(exact "$CON/.claude/rules/repo.md")" "## Deploy

A push deploys nothing.
x" "scaffold: repo.md holds each heading with the slice's default text"
  echo "mine" > "$CON/.claude/rules/repo.md"
  kit_run scaffold
  like "$OUT" '^added ## Deploy to \.claude/rules/repo\.md$' "scaffold: adds a missing heading"
  is "$(exact "$CON/.claude/rules/repo.md")" "mine

## Deploy

A push deploys nothing.
x" "scaffold: keeps the text there and adds the section after it"
  printf '## Deploy\n\n\n## Other\n\ntext\n' > "$CON/.claude/rules/repo.md"
  kit_run scaffold
  like "$OUT" '^filled ## Deploy in \.claude/rules/repo\.md$' "scaffold: fills an empty heading"
  is "$(exact "$CON/.claude/rules/repo.md")" "## Deploy

A push deploys nothing.

## Other

text
x" "scaffold: the default text goes under the empty heading, the rest stays"
  printf '## Deploy\n\nOurs.\n' > "$CON/.claude/rules/repo.md"
  kit_run scaffold
  is "$(exact "$CON/.claude/rules/repo.md")" "## Deploy

Ours.
x" "scaffold: never changes a heading that has text"
}

t_scaffold_memory_root() {
  fresh
  jq -c '.params.memory_root=".mem"' "$CON/.claude/kit.json" > "$T/k.json"
  cp "$T/k.json" "$CON/.claude/kit.json"
  kit_run scaffold
  like "$OUT" '^created \.mem/MEMORY\.md$' "scaffold: honours memory_root"
  like "$OUT" '^added @\.mem/MEMORY\.md to CLAUDE\.md$' "scaffold: CLAUDE.md imports the index under memory_root"
  echo '{' > "$CON/.claude/kit.json"
  kit_run scaffold
  is "$RC" 0 "scaffold: an invalid kit.json still exits 0"
  like "$OUT" '^kept \.claude/memory/MEMORY\.md$' "scaffold: invalid kit.json falls back to .claude/memory"
  like "$OUT" '^skipped the repo\.md sections and the CLAUDE\.md import: ' "scaffold: an invalid kit.json adds no import"
}

t_apply() {
  fresh
  : > "$CON/.claude/rules/repo.md"
  printf 'Notes.' > "$CON/CLAUDE.md"
  kit_run apply
  is "$RC" 0 "apply: exits 0"
  like "$OUT" '^added ## Deploy to \.claude/rules/repo\.md$' "apply: adds the missing heading"
  like "$OUT" '^added @\.claude/memory/MEMORY\.md to CLAUDE\.md$' "apply: adds the memory import"
  is "$(exact "$CON/CLAUDE.md")" "Notes.
@.claude/memory/MEMORY.md
x" "apply: the import goes on a line of its own"
  is "$(printf '%s\n' "$OUT" | tail -n 1)" "kit check: ok" "apply: ends with the check"
  unlike "$OUT" '^kept ' "apply: names only what it adds"
  jq '.permissions.allow += ["Bash(gh *)"]' "$CON/.claude/settings.json" > "$T/s.json"
  cp "$T/s.json" "$CON/.claude/settings.json"
  kit_run apply
  is "$RC" 1 "apply: a check problem exits 1"
  like "$OUT" '^FORBID Bash\(gh \*\) in permissions\.allow' "apply: prints the check's lines"
}

# Scaffold writes nothing through a symlink that leads outside the repo, but
# a symlink to a file in the repo is written through.
t_scaffold_symlink() {
  fresh
  printf 'Outside.\n' > "$T/outside.md"
  rm "$CON/CLAUDE.md"
  ln -s "$T/outside.md" "$CON/CLAUDE.md"
  kit_run scaffold
  like "$OUT" '^skipped CLAUDE\.md: it leads outside this repo; add the line @\.claude/memory/MEMORY\.md to it yourself$' \
    "scaffold symlink: an outside target is named and left alone"
  is "$(cat "$T/outside.md")" "Outside." "scaffold symlink: the outside file is unchanged"
  rm "$CON/CLAUDE.md"
  printf 'Shared.\n' > "$CON/AGENTS.md"
  ln -s AGENTS.md "$CON/CLAUDE.md"
  kit_run scaffold
  like "$OUT" '^added @\.claude/memory/MEMORY\.md to CLAUDE\.md$' "scaffold symlink: a target in the repo is written"
  is "$(cat "$CON/AGENTS.md")" "Shared.
@.claude/memory/MEMORY.md" "scaffold symlink: the line lands in the target"
  # A memory folder linked outside: nothing is created out there.
  mkdir -p "$T/outmem"
  rm -rf "$CON/.claude/memory"
  ln -s "$T/outmem" "$CON/.claude/memory"
  kit_run scaffold
  like "$OUT" '^skipped \.claude/memory/friction/\.gitkeep: it leads outside this repo$' "scaffold symlink: a linked folder is named"
  is "$(find "$T/outmem" -mindepth 1 | wc -l | tr -d ' ')" 0 "scaffold symlink: nothing is created outside the repo"
  # A dangling memory folder: skipped, so apply goes on to render and check.
  rm "$CON/.claude/memory"
  ln -s "$T/gone" "$CON/.claude/memory"
  kit_run apply
  like "$OUT" '^skipped \.claude/memory/MEMORY\.md: it goes through a dangling symlink$' "scaffold symlink: a dangling folder is named"
  like "$OUT" '^DANGLING \.claude/memory$' "scaffold symlink: apply still reaches the check"
  is "$RC" 1 "scaffold symlink: a dangling folder is a check problem, not an internal error"
  # A complete repo.md linked outside needs nothing, so nothing is said.
  rm "$CON/.claude/memory"
  git -C "$CON" checkout -q HEAD -- .claude/memory
  cp "$CON/.claude/rules/repo.md" "$T/repo-out.md"
  rm "$CON/.claude/rules/repo.md"
  ln -s "$T/repo-out.md" "$CON/.claude/rules/repo.md"
  kit_run apply
  unlike "$OUT" '^skipped ' "scaffold symlink: a complete repo.md outside is not mentioned"
}

# kit.json through a dangling symlink is not written, and init then does not
# point at a next step.
t_init_dangling_kitjson() {
  fresh
  git -C "$CON" rm -q .claude/kit.json
  ln -s "$T/nowhere/kit.json" "$CON/.claude/kit.json"
  GIT_ALLOW_PROTOCOL=file kit_run init
  is "$RC" 0 "init dangling: exits 0"
  like "$OUT" '^skipped \.claude/kit\.json: it goes through a dangling symlink$' "init dangling: names the link"
  unlike "$OUT" '^next: ' "init dangling: no next step"
  no_file "$T/nowhere"
}

t_apply_discard() {
  fresh
  echo "local" >> "$CON/.claude/rules/kit/a.md"
  kit_run apply
  is "$RC" 1 "apply: a refused render exits 1"
  like "$OUT" '^REFUSE \.claude/rules/kit/a\.md: edited in place' "apply: prints render's refusal"
  unlike "$OUT" '^kit check' "apply: no check after a failed render"
  kit_run apply --discard
  is "$RC" 0 "apply --discard: exits 0"
  unlike "$(cat "$CON/.claude/rules/kit/a.md")" '^local$' "apply --discard: the kit's copy is back"
  kit_run apply --bogus
  is "$RC" 2 "apply: an unknown flag is a usage error"
  like "$OUT" '^usage: kit apply \[--discard\]$' "apply: prints its usage"
}

t_edit() {
  fresh
  kit_run edit .claude/rules/kit/a.md
  is "$RC" 0 "edit: exits 0"
  like "$OUT" '^\.claude/rules/kit/a\.md is rendered from slices/core/rules/a\.md at [0-9a-f]{7}\.$' "edit: names the source and pin"
  like "$OUT" "^3\. In the kit's own clone \(ask the user where it is\)" "edit: authoring steps name the kit's own clone"
  unlike "$OUT" '~/|bitsy-services' "edit: no path on any one machine"
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

# A gitlink .gitignore matches is refused before anything moves, so the
# old pin stays staged and checked out, and the next bump prints this one's
# CHANGELOG lines.
t_bump_ignored() {
  fresh
  local oldpin
  oldpin="$(git -C "$CON" ls-files -s .claude/vendor/kit | cut -d' ' -f2)"
  echo "## 2026-10-23 — toy change" >> "$T/kit/CHANGELOG.md"
  kit_commit "toy change"
  echo 'vendor/' > "$CON/.gitignore"
  kit_run bump --from "$T/kit" main
  is "$RC" 2 "bump ignored: exits 2"
  like "$OUT" '^bump: cannot stage the gitlink: \.gitignore ignores \.claude/vendor/kit' "bump ignored: says why"
  is "$(git -C "$CON" ls-files -s .claude/vendor/kit | cut -d' ' -f2)" "$oldpin" "bump ignored: the old pin stays staged"
  is "$(git -C "$CON/.claude/vendor/kit" rev-parse HEAD)" "$oldpin" "bump ignored: the checkout stays at the old pin"
  printf 'vendor/\n!/.claude/vendor/\n' > "$CON/.gitignore"
  kit_run bump --from "$T/kit" main
  is "$RC" 0 "bump ignored: with the folder un-ignored, the bump goes through"
  like "$OUT" 'toy change' "bump ignored: and prints the CHANGELOG lines"
}

# I5/R24: a BREAKING change that needs a kit.json edit. The failed bump shows
# the CHANGELOG lines before it restores the old pin. The edit is made first;
# check fails until the bump, as expected; then the bump succeeds.
t_bump_breaking() {
  fresh
  local oldpin at_line at_restored
  oldpin="$(git -C "$CON" ls-files -s .claude/vendor/kit | cut -d' ' -f2)"
  jq '.params.region = {"required": true, "pattern": "^[a-z]+$"}' "$T/kit/slices/core/slice.json" > "$T/s.json"
  cp "$T/s.json" "$T/kit/slices/core/slice.json"
  echo '- BREAKING: core requires the param region; add "region": "<name>" to params in .claude/kit.json, then bump.' >> "$T/kit/CHANGELOG.md"
  kit_commit "require region"
  kit_run bump --from "$T/kit" main
  is "$RC" 1 "breaking: the bump exits 1"
  like "$OUT" '^CONFIG param region \(core\) is required$' "breaking: the render names the missing param"
  at_line="$(printf '%s\n' "$OUT" | grep -n '^- BREAKING: core requires the param region' | head -n 1 | cut -d: -f1)"
  at_restored="$(printf '%s\n' "$OUT" | grep -n '^bump: render failed; restored ' | head -n 1 | cut -d: -f1)"
  is "$([ -n "$at_line" ] && [ -n "$at_restored" ] && [ "$at_line" -lt "$at_restored" ] && echo before \
    || echo "CHANGELOG at ${at_line:-none}, restored at ${at_restored:-none}")" before \
    "breaking: the CHANGELOG lines print before the restore line"
  is "$(git -C "$CON" ls-files -s .claude/vendor/kit | cut -d' ' -f2)" "$oldpin" "breaking: gitlink back at the old pin"
  jq -c '.params.region = "west"' "$CON/.claude/kit.json" > "$T/k.json"
  cp "$T/k.json" "$CON/.claude/kit.json"
  kit_run check
  is "$RC" 1 "breaking: with the edit made first, check fails under the old pin"
  like "$OUT" '^CONFIG unknown param "region"' "breaking: the old pin does not know the param"
  kit_run bump --from "$T/kit" main
  is "$RC" 0 "breaking: then the bump succeeds"
  kit_run check
  is "$RC" 0 "breaking: and check passes"
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
t_init_kitjson
t_init_selection
t_init_notices
t_init_gate
t_init_trunk
t_init_memory
t_scaffold
t_scaffold_headings
t_scaffold_memory_root
t_scaffold_symlink
t_init_dangling_kitjson
t_apply
t_apply_discard
t_edit
t_bump
t_bump_ignored
t_bump_failure
t_bump_breaking
t_excluded_notice
done_testing
