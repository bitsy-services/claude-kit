#!/usr/bin/env bash
# The real session-branch slice, rendered with core and trunk "master": the
# trunk reaches the guard, the allows and every rendered file, kit check
# passes, the slice's forbids and headings are enforced, and
# branch-context.sh reports the branch.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
t_setup
# Keep every scratch dir the kit makes inside $T, which the harness removes.
mkdir -p "$T/tmp" "$T/in" "$T/empty"
export TMPDIR="$T/tmp"
export GIT_CONFIG_GLOBAL=/dev/null
BASH_BIN="$(command -v bash)"

# basic's inputs (CLAUDE.md import, memory index), with a repo.md holding
# every heading the slice declares.
cp -R "$TEST_ROOT/test/consumers/basic/." "$T/in/"
echo '{"format":1,"slices":["core","session-branch"],"params":{"gate":"bash scripts/check.sh","trunk":"master"},"exclude":[]}' > "$T/in/kit.json"
cat > "$T/in/repo.md" << 'EOF'
## Deploy

A push of `master` deploys production.

## Gate

Run before every commit.

## Conflict stops

A config value or a test expectation.

## Branch names

`fix-login-timeout`, `docs-install`
EOF
mk_kit "$TEST_ROOT/slices"
mk_consumer "$T/in"
kit_run render
is "$RC" 0 "render exits 0"
HOOK="$CON/.claude/hooks/kit/branch-context.sh"
SETTINGS="$CON/.claude/settings.json"

# context <dir> [PATH]: run the rendered SessionStart hook for a project at
# <dir>. Sets OUT, RC and CTX (the additionalContext it returned).
context() {
  OUT="$(cd "$1" && CLAUDE_PROJECT_DIR="$1" PATH="${2:-$PATH}" "$BASH_BIN" "$HOOK" 2>&1)" && RC=0 || RC=$?
  CTX="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2> /dev/null)"
}

# A repo on master, at a path with a space (Review Focus 1).
master_repo() {
  M="$T/My Repo"
  mkdir -p "$M"
  git -C "$M" init -q -b master
  git -C "$M" commit -q --allow-empty -m init
}

t_guard_trunk() {
  is "$(grep -cxF 'TRUNK="master"' "$CON/.claude/hooks/kit/guard-git.sh" 2> /dev/null)" 1 \
    "guard: the trunk default is master"
}

t_allows() {
  local e
  for e in 'Bash(git rebase master)' 'Bash(git fetch origin master:master)'; do
    is "$(jq --arg e "$e" '.permissions.allow | index($e) != null' "$SETTINGS")" true "allow: $e"
  done
}

t_hooks_registered() {
  like "$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command' "$SETTINGS")" \
    'hooks/kit/guard-git\.sh' "hooks: PreToolUse Bash runs guard-git.sh"
  like "$(jq -r '.hooks.SessionStart[] | select((.matcher // "") == "") | .hooks[].command' "$SETTINGS")" \
    'hooks/kit/branch-context\.sh' "hooks: SessionStart runs branch-context.sh"
}

t_no_placeholder_left() {
  local d dests left=""
  dests="$(jq -r '.files | keys[]' "$CON/.claude/kit.lock.json" 2> /dev/null)" || left=" (no lock)"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    if grep -qF '{{kit.' "$CON/$d"; then left="$left $d"; fi
  done <<< "$dests"
  if grep -qF '{{kit.' "$SETTINGS"; then left="$left .claude/settings.json"; fi
  is "${left:-none}" none "render: no rendered file contains {{kit."
}

# /merge-to-main checks publication on the branch, before the fast-forward,
# so an unpublished pin is not clean and nothing moves (R28).
t_published_before_landing() {
  local f="$CON/.claude/skills/merge-to-main/SKILL.md" pub ff
  pub="$(grep -n 'kit check --published' "$f" 2> /dev/null | head -n 1 | cut -d: -f1)"
  ff="$(grep -n 'git merge --ff-only B' "$f" 2> /dev/null | head -n 1 | cut -d: -f1)"
  is "$([ -n "$pub" ] && [ -n "$ff" ] && [ "$pub" -lt "$ff" ] && echo before || echo "published at ${pub:-none}, ff at ${ff:-none}")" \
    before "merge-to-main: kit check --published comes before the fast-forward"
  is "$(grep -c 'kit check --published' "$f" 2> /dev/null)" 1 "merge-to-main: kit check --published runs once"
}

t_check() {
  kit_run check
  is "$RC" 0 "check: kit check exits 0"
  like "$OUT" '^kit check: ok$' "check: kit check reports ok"
}

t_forbid() {
  cp "$SETTINGS" "$T/settings.bak"
  jq '.permissions.allow += ["Bash(git push *)"]' "$T/settings.bak" > "$SETTINGS"
  kit_run check
  is "$RC" 1 "forbid: check exits 1"
  like "$OUT" '^FORBID Bash\(git push \*\) in permissions\.allow \(session-branch\): ' "forbid: git push * is named"
  cp "$T/settings.bak" "$SETTINGS"
}

# C1: a forbidden entry spelled another way, or a broader entry, fails too.
# Each case is <allow entry>|<the FORBID line>.
t_forbid_spellings() {
  local e want
  cp "$SETTINGS" "$T/settings.bak"
  while IFS='|' read -r e want; do
    jq --arg e "$e" '.permissions.allow += [$e]' "$T/settings.bak" > "$SETTINGS"
    kit_run check
    is "$RC" 1 "forbid $e: check exits 1"
    is "$(printf '%s\n' "$OUT" | grep -c '^FORBID ')" 1 "forbid $e: one FORBID line"
    is "$(printf '%s\n' "$OUT" | grep '^FORBID ')" "$want" "forbid $e: the line"
  done << 'EOF'
Bash(gh:*)|FORBID Bash(gh:*) in permissions.allow covers Bash(gh *) (core): broad gh can move origin/main without the push prompt
Bash(git:*)|FORBID Bash(git:*) in permissions.allow (core): the same rule as Bash(git *), which pre-approves deleting branches, rewriting history and pushing
Bash(git push:*)|FORBID Bash(git push:*) in permissions.allow covers Bash(git push *) (session-branch): a push must prompt, since that prompt confirms anything leaving this clone, a deploy included
Bash(npm run:*)|FORBID Bash(npm run:*) in permissions.allow covers Bash(npm run *) (core): npm run * pre-approves npm run deploy; allow named scripts instead
Bash|FORBID Bash in permissions.allow covers Bash(git *) (core): broad git pre-approves deleting branches, rewriting history and pushing
Bash(*)|FORBID Bash(*) in permissions.allow covers Bash(git *) (core): broad git pre-approves deleting branches, rewriting history and pushing
Bash(gh*)|FORBID Bash(gh*) in permissions.allow covers Bash(gh *) (core): broad gh can move origin/main without the push prompt
Bash(git -C *)|FORBID Bash(git -C *) in permissions.allow (core): git -C <dir> runs any git subcommand, so it pre-approves pushing, deleting branches and rewriting history
Bash(git -C * push *)|FORBID Bash(git -C * push *) in permissions.allow covers Bash(git -C *) (core): git -C <dir> runs any git subcommand, so it pre-approves pushing, deleting branches and rewriting history
Bash(git p*)|FORBID Bash(git p*) in permissions.allow covers Bash(git push *) (session-branch): a push must prompt, since that prompt confirms anything leaving this clone, a deploy included
Bash( git push *)|FORBID Bash( git push *) in permissions.allow covers Bash(git push *) (session-branch): a push must prompt, since that prompt confirms anything leaving this clone, a deploy included
Bash(git  push *)|FORBID Bash(git  push *) in permissions.allow covers Bash(git push *) (session-branch): a push must prompt, since that prompt confirms anything leaving this clone, a deploy included
Bash(git push * )|FORBID Bash(git push * ) in permissions.allow covers Bash(git push *) (session-branch): a push must prompt, since that prompt confirms anything leaving this clone, a deploy included
Bash(git :*)|FORBID Bash(git :*) in permissions.allow covers Bash(git *) (core): broad git pre-approves deleting branches, rewriting history and pushing
EOF
  # Narrow entries, and entries of other tools, are not forbidden.
  jq '.permissions.allow += ["Bash(git push origin topic)", "Bash(npm run build)", "Bash(ghq *)", "Bash(git pushd *)", "WebFetch(domain:gh)"]' \
    "$T/settings.bak" > "$SETTINGS"
  kit_run check
  is "$RC" 0 "forbid: narrow entries pass"
  cp "$T/settings.bak" "$SETTINGS"
}

t_repo_lacks_gate() {
  local md="$CON/.claude/rules/repo.md"
  cp "$md" "$T/repo.bak"
  printf '## Deploy\n\nA push deploys.\n\n## Conflict stops\n\nConfig.\n\n## Branch names\n\n`a-b`\n' > "$md"
  kit_run check
  is "$RC" 1 "repo: check exits 1"
  like "$OUT" '^REPO repo\.md lacks ## Gate \(session-branch\): run kit apply$' "repo: the missing Gate heading is named"
  cp "$T/repo.bak" "$md"
}

t_context_on_trunk() {
  master_repo
  context "$M"
  is "$RC" 0 "context: exits 0"
  like "$CTX" "on branch 'master'" "context: names the branch"
  like "$CTX" "create the session branch with 'git switch -c <topic>'" "context: on the trunk, says to branch first"
}

t_context_on_branch() {
  git -C "$M" switch -q -c topic
  context "$M"
  like "$CTX" "'topic' is this session's branch" "context: off the trunk, adopts the branch"
  unlike "$CTX" 'create the session branch' "context: off the trunk, no create line"
}

# A trunk param naming no local branch is reported, not taken for a session branch.
t_context_trunk_missing() {
  local R="$T/on-main"
  mkdir -p "$R"
  git -C "$R" init -q -b main
  git -C "$R" commit -q --allow-empty -m init
  context "$R"
  like "$CTX" "There is no local branch 'master'; if that is not this repo's trunk, set the trunk param" \
    "no trunk: says the trunk param names no local branch"
}

t_context_without_jq() {
  context "$M" "$T/empty"
  is "$RC" 0 "no jq: exits 0"
  like "$OUT" '^branch-context: jq is not installed' "no jq: says so first"
  like "$OUT" 'guard-git\.sh blocks' "no jq: says the guard blocks git commands"
}

# I1: after a branch switch the kit checkout stays at the old pin. That is
# reported as an off-pin checkout, not as uncommitted work; a pin staged but
# not committed is uncommitted work.
t_context_kit_off_pin() {
  local vendor="$CON/.claude/vendor/kit" pin
  pin="$(git -C "$vendor" rev-parse HEAD)"
  git -C "$CON" add -A
  git -C "$CON" commit -q -m "rendered"
  context "$CON"
  like "$CTX" "on branch 'topic', tree clean\." "kit: a consumer at its pin is clean"
  unlike "$CTX" 'off-pin' "kit: at its pin, no off-pin line"
  echo "more" >> "$T/kit/CHANGELOG.md"
  git -C "$T/kit" commit -q -am "more"
  git -C "$vendor" fetch -q "$T/kit" main
  git -C "$vendor" checkout -q FETCH_HEAD
  context "$CON"
  like "$CTX" "tree clean, kit checkout off-pin \(run: git submodule update --init \.claude/vendor/kit\)\." \
    "kit: an off-pin checkout is named, with its fix"
  unlike "$CTX" 'uncommitted' "kit: an off-pin checkout is not uncommitted work"
  git -C "$CON" add .claude/vendor/kit
  context "$CON"
  like "$CTX" "tree 1 uncommitted path\(s\)\." "kit: a staged pin is uncommitted work"
  unlike "$CTX" 'off-pin' "kit: a staged pin matching the checkout is not off-pin"
  git -C "$CON" reset -q -- .claude/vendor/kit
  git -C "$vendor" checkout -q "$pin"
}

# Only the kit checkout is left out of the count: a staged bump of another
# submodule (gyrealm's theme) is uncommitted work.
t_context_other_submodule() {
  local pin
  pin="$(git -C "$CON/.claude/vendor/kit" rev-parse HEAD)"
  git -C "$CON" update-index --add --cacheinfo "160000,$pin,themes/x"
  context "$CON"
  like "$CTX" "tree 1 uncommitted path\(s\)\." "submodule: a staged gitlink outside the kit is uncommitted work"
  git -C "$CON" rm -q --cached themes/x
}

# M5: the hook's git status takes no optional lock, so it never rewrites the
# index under a session that is using it.
t_context_no_index_write() {
  local before
  touch -d '2001-01-01' "$CON/CLAUDE.md"
  before="$(cksum < "$CON/.git/index")"
  context "$CON"
  is "$(cksum < "$CON/.git/index")" "$before" "locks: the index is not rewritten"
}

# before <file> <a> <b>: "before" when the file's first <a> precedes its first <b>.
before() {
  local c pa pb
  c="$(cat "$1" 2> /dev/null)"
  case "$c" in *"$2"*) ;; *) echo "no $2"; return ;; esac
  case "$c" in *"$3"*) ;; *) echo "no $3"; return ;; esac
  pa="${c%%"$2"*}"
  pb="${c%%"$3"*}"
  if [ "${#pa}" -lt "${#pb}" ]; then echo before; else echo after; fi
}

# I1, T11.1, T11.2, T11.4: what the rule and the skills tell Claude to run.
t_texts() {
  local rule="$CON/.claude/rules/kit/session-branches.md"
  local mtm="$CON/.claude/skills/merge-to-main/SKILL.md" swm="$CON/.claude/skills/sync-with-main/SKILL.md"
  local up='git submodule update --init .claude/vendor/kit'
  is "$(before "$rule" "$up" 'git status --porcelain')" before "rule: the kit checkout is updated before git status is read"
  like "$(cat "$mtm")" '^1\. \*\*Where are we\.\*\* `git submodule update --init \.claude/vendor/kit`' \
    "merge-to-main: step 1 starts with the kit checkout"
  like "$(cat "$swm")" '^1\. \*\*[^*]+\*\* `git submodule update --init \.claude/vendor/kit`' \
    "sync-with-main: step 1 starts with the kit checkout"
  unlike "$(cat "$rule")" '^\| another branch' "rule: no row says another branch"
  is "$(grep -c '^| a branch other than `master`, and this session already has one |' "$rule")" 2 \
    "rule: rows 4 and 5 name a branch other than the trunk"
  like "$(cat "$rule")" 'git merge --abort.*git merge --continue.*git rebase --abort.*git rebase --quit.* stay allowed' \
    "rule: the guard line says aborting or continuing a merge and aborting or quitting a rebase stay allowed"
  like "$(sed -n '/^## Do not/,$p' "$swm")" 'git checkout -- <file>.*step 6\.3.s `git checkout <side> -- \.claude/kit\.lock\.json`' \
    "sync-with-main: the Do-not line excepts step 6.3"
}

t_guard_trunk
t_allows
t_hooks_registered
t_no_placeholder_left
t_published_before_landing
t_check
t_forbid
t_forbid_spellings
t_repo_lacks_gate
t_context_on_trunk
t_context_on_branch
t_context_trunk_missing
t_context_without_jq
t_texts
t_context_kit_off_pin
t_context_other_submodule
t_context_no_index_write
done_testing
