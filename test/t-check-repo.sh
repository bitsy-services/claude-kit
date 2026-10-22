#!/usr/bin/env bash
# kit check, consumer content: settings, forbid, breadth, set, memory,
# repo.md, links, dangling, eol, url, jq, clone and published rows.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
t_setup
# Keep every scratch dir the kit makes inside $T, which the harness removes.
mkdir -p "$T/tmp"
export TMPDIR="$T/tmp"

BASIC="$TEST_ROOT/test/consumers/basic"
HOOK='bash "$CLAUDE_PROJECT_DIR/.claude/hooks/kit/h.sh"'

# rendered: a new toy kit and basic consumer, rendered and committed.
rendered() {
  rm -rf "$T/kit" "$T/con"
  mk_kit "$TEST_ROOT/test/kits/toy/slices"
  mk_consumer "$BASIC" "$T/con"
  kit_run render
  git -C "$CON" add -A
  git -C "$CON" commit -q -m "rendered"
}

last_line() { printf '%s\n' "$1" | tail -n 1; }

has_line() {
  local ok=1
  printf '%s\n' "$1" | grep -Fxq -- "$2" && ok=0
  _t_report "$ok" "$3"
  if [ "$ok" != 0 ]; then echo "#   text: $1"; echo "#   wanted line: $2"; fi
}

# edit_settings <jq-filter>: rewrite the consumer's settings.json.
edit_settings() {
  jq "$1" "$CON/.claude/settings.json" > "$T/settings.new"
  cp "$T/settings.new" "$CON/.claude/settings.json"
}

# only <desc> <line>: check failed with exactly this one problem line.
only() {
  is "$RC" 1 "$1: check exits 1"
  has_line "$OUT" "$2" "$1: the line"
  is "$(last_line "$OUT")" "kit check: 1 problems" "$1: one problem"
}

t_clean() {
  rendered
  kit_run check
  is "$RC" 0 "clean: exits 0"
  is "$OUT" "kit check: ok" "clean: nothing else printed"
}

t_settings() {
  rendered
  edit_settings '.permissions.allow -= ["Bash(echo *)"]'
  kit_run check
  only "settings allow" "SETTINGS missing allow Bash(echo *) (core)"
  rendered
  edit_settings '.permissions.allow -= ["Bash(git fetch origin main)"]'
  kit_run check
  only "settings slice" "SETTINGS missing allow Bash(git fetch origin main) (extra)"
  rendered
  edit_settings 'del(.hooks)'
  kit_run check
  only "settings hook" "SETTINGS missing hook PreToolUse Bash $HOOK"
  rendered
  edit_settings '.permissions.allow += ["Bash(mine *)"] | .permissions.deny = ["Bash(x)"]'
  kit_run check
  is "$RC" 0 "settings: local additions are fine"
}

t_forbid() {
  rendered
  edit_settings '.permissions.allow += ["Bash(gh *)"]'
  kit_run check
  only "forbid" "FORBID Bash(gh *) in permissions.allow (core): broad gh can move origin/main without the push prompt"
  rendered
  edit_settings '.permissions.allow += ["Bash(gh:*)"]'
  kit_run check
  only "forbid colon" "FORBID Bash(gh:*) in permissions.allow covers Bash(gh *) (core): broad gh can move origin/main without the push prompt"
  rendered
  edit_settings '.permissions.allow += ["Bash"]'
  kit_run check
  only "forbid bare" "FORBID Bash in permissions.allow covers Bash(gh *) (core): broad gh can move origin/main without the push prompt"
  rendered
  edit_settings '.permissions.allow += ["Bash(ghq *)", "Bash(gh pr view *)", "Bash(gh)"]'
  kit_run check
  is "$RC" 0 "forbid: narrower and unrelated entries pass"
}

# M2: permissions.allow, ask and deny hold only strings.
t_settings_entries() {
  local k v
  for k in allow ask deny; do
    for v in 42 null '{}'; do
      rendered
      edit_settings ".permissions.$k = ((.permissions.$k // []) + [$v])"
      kit_run check
      only "settings $k $v" "SETTINGS permissions.$k entry $v is not a string"
    done
  done
}

# A permissions list that is not an array is named, not an internal error.
t_settings_shape() {
  local v
  for v in 42 '{}' '"Read"'; do
    rendered
    edit_settings ".permissions.allow = $v"
    kit_run check
    only "settings shape $v" "RENDER .claude/settings.json permissions.allow is not an array; fix it"
  done
  rendered
  edit_settings '.permissions = 42'
  kit_run check
  only "settings shape permissions" "RENDER .claude/settings.json permissions is not an object; fix it"
  kit_run render
  is "$RC" 1 "settings shape: render exits 1"
  has_line "$OUT" "RENDER .claude/settings.json permissions is not an object; fix it" "settings shape: render names it"
}

t_breadth() {
  rendered
  edit_settings '.permissions.allow += ["Bash(git -C * status *)"]'
  kit_run check
  only "breadth" "BREADTH Bash(git -C * status *)"
}

t_set() {
  rendered
  edit_settings '.autoMemoryEnabled = true'
  kit_run check
  only "set" "SET autoMemoryEnabled is true; core sets false"
  edit_settings 'del(.autoMemoryEnabled)'
  kit_run check
  only "set unset" "SET autoMemoryEnabled is unset; core sets false"
}

t_memory() {
  rendered
  : > "$CON/CLAUDE.md"
  kit_run check
  only "memory" "MEMORY CLAUDE.md does not import @.claude/memory/MEMORY.md"
  printf 'Notes.\n   @.claude/memory/MEMORY.md  \r\n' > "$CON/CLAUDE.md"
  kit_run check
  is "$RC" 0 "memory: a trimmed line equal to the import passes"
}

t_repo() {
  rendered
  : > "$CON/.claude/rules/repo.md"
  kit_run check
  only "repo lacks" "REPO repo.md lacks ## Deploy (extra)"
  printf '## Deploy\n\n## Other\n\ntext\n' > "$CON/.claude/rules/repo.md"
  kit_run check
  only "repo empty" "REPO repo.md ## Deploy is empty (extra)"
  printf '## Deploy\n\n### Sub\n\ntext\n' > "$CON/.claude/rules/repo.md"
  kit_run check
  is "$RC" 0 "repo: a body under a subheading counts"
}

t_links() {
  rendered
  printf 'See [x](missing.md) and [k](kit/a.md#top) and [d](kit) and [w](http://x.invalid/y) and [a](#here).\n' \
    > "$CON/.claude/rules/local.md"
  kit_run check
  only "link" "LINK .claude/rules/local.md -> missing.md"
  printf 'Code `[x](missing.md)` here.\n\n```\n[y](gone.md)\n```\n\n[ok](kit/a.md)\n' > "$CON/.claude/rules/local.md"
  kit_run check
  is "$RC" 0 "link: code spans and fenced blocks are skipped"
  printf '[v](missing.md)\n' > "$CON/.claude/vendor/kit/CHANGELOG.md"
  printf '[c](nowhere.md)\n' >> "$CON/CLAUDE.md"
  kit_run check
  has_line "$OUT" "LINK CLAUDE.md -> nowhere.md" "link: CLAUDE.md is scanned"
  unlike "$OUT" 'LINK .*vendor' "link: the vendored kit is not scanned"
  # I4: a leading-/ target is a site URL in a Hugo repo, not a repo path.
  rendered
  printf 'See [w](/wiki/places/) and [r](/README.md) and [x](missing.md).\n' > "$CON/.claude/rules/local.md"
  kit_run check
  only "link site url" "LINK .claude/rules/local.md -> missing.md"
}

t_dangling() {
  rendered
  ln -s nowhere "$CON/.claude/skills/gone"
  kit_run check
  only "dangling" "DANGLING .claude/skills/gone"
}

t_eol() {
  rendered
  printf '#!/usr/bin/env bash\r\necho hook\r\n' > "$T/kit/slices/core/hooks/h.sh"
  git -C "$T/kit" add -A
  git -C "$T/kit" commit -q -m "crlf hook"
  git -C "$CON/.claude/vendor/kit" fetch -q "$T/kit" main
  git -C "$CON/.claude/vendor/kit" checkout -q FETCH_HEAD
  git -C "$CON" add .claude/vendor/kit
  kit_run render
  kit_run check
  only "eol" "EOL .claude/hooks/kit/h.sh has CRLF line endings"
}

t_url() {
  rendered
  git config -f "$CON/.gitmodules" submodule..claude/vendor/kit.url git@github.com:x/y
  kit_run check
  only "url" "URL .gitmodules records .claude/vendor/kit as git@github.com:x/y; use https://"
}

t_need_jq() {
  rendered
  local bin="$T/nojq" t
  mkdir -p "$bin"
  for t in bash git tar mktemp cat dirname find sed grep mkdir rm cp cmp sort head tail cut env readlink uname rmdir; do
    ln -s "$(command -v "$t")" "$bin/$t"
  done
  OUT="$(cd "$CON" && PATH="$bin" CLAUDE_PROJECT_DIR="$CON" "$(command -v bash)" "$CON/.claude/vendor/kit/bin/kit" check 2>&1)" && RC=0 || RC=$?
  is "$RC" 1 "need jq: exits 1"
  is "$OUT" "$(printf 'NEED jq\nkit check: 1 problems')" "need jq: prints NEED jq and the summary"
}

t_published() {
  rendered
  kit_run check --published
  is "$RC" 0 "published: a pin on origin/main passes"
  # a pin on a side branch that origin/main does not hold
  git -C "$T/kit" switch -q -c side
  echo side >> "$T/kit/CHANGELOG.md"
  git -C "$T/kit" add -A
  git -C "$T/kit" commit -q -m "side"
  local p7
  p7="$(git -C "$T/kit" rev-parse HEAD)"
  p7="${p7:0:7}"
  git -C "$CON/.claude/vendor/kit" fetch -q "$T/kit" side
  git -C "$CON/.claude/vendor/kit" checkout -q FETCH_HEAD
  git -C "$CON" add .claude/vendor/kit
  kit_run render
  kit_run check
  is "$RC" 0 "published: without the flag a side-branch pin passes"
  kit_run check --published
  only "published" "UNPUBLISHED $p7 is not on the kit's origin/main"
  git -C "$CON/.claude/vendor/kit" remote set-url origin "$T/gone"
  kit_run check --published
  only "published unreachable" "UNPUBLISHED cannot reach the kit's origin to verify $p7"
}

t_clone() {
  rendered
  git -C "$CON" config --unset push.recurseSubmodules
  kit_run check
  is "$RC" 0 "clone: a notice alone exits 0"
  has_line "$OUT" 'NOTICE push.recurseSubmodules is not "check": run kit init' "clone: NOTICE line"
  kit_run check --published
  only "clone published" 'CLONE push.recurseSubmodules is not "check": run kit init'
}

t_clean
t_settings
t_forbid
t_settings_entries
t_settings_shape
t_breadth
t_set
t_memory
t_repo
t_links
t_dangling
t_eol
t_url
t_need_jq
t_published
t_clone
done_testing
