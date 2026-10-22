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
  is "$(grep -cF '${KIT_TRUNK:-master}' "$CON/.claude/hooks/kit/guard-git.sh" 2> /dev/null)" 1 \
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

t_repo_lacks_gate() {
  local md="$CON/.claude/rules/repo.md"
  cp "$md" "$T/repo.bak"
  printf '## Deploy\n\nA push deploys.\n\n## Conflict stops\n\nConfig.\n\n## Branch names\n\n`a-b`\n' > "$md"
  kit_run check
  is "$RC" 1 "repo: check exits 1"
  like "$OUT" '^REPO repo\.md lacks ## Gate \(session-branch\)$' "repo: the missing Gate heading is named"
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

t_guard_trunk
t_allows
t_hooks_registered
t_no_placeholder_left
t_check
t_forbid
t_repo_lacks_gate
t_context_on_trunk
t_context_on_branch
t_context_trunk_missing
t_context_without_jq
done_testing
