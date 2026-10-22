#!/usr/bin/env bash
# guard-git.sh: the trunk battery in test/guard-git.cases, the template's trunk
# line, the jq-less exit, and the push check on an unpublished kit pin.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
t_setup
# Keep every scratch dir the kit makes inside $T, which the harness removes.
mkdir -p "$T/tmp"
export TMPDIR="$T/tmp"
# The guard resolves aliases through git config; keep the developer's out.
export GIT_CONFIG_GLOBAL=/dev/null
unset KIT_TRUNK

SRC="$TEST_ROOT/slices/session-branch/hooks/guard-git.sh"
G="$T/guard-git.sh"
BASIC="$TEST_ROOT/test/consumers/basic"
# Render the shipped template the way kit render substitutes {{kit.trunk}}.
sed 's/{{kit\.trunk}}/main/g' "$SRC" > "$G"

# verdict <dir> <command>: run the guard on a Bash payload with <dir> as the
# working and project directory. Sets GOT (DENY, allow, or what went wrong)
# and REASON (the deny reason, or stderr on exit 2).
verdict() {
  local out rc
  out="$(cd "$1" && jq -cn --arg c "$2" '{tool_name: "Bash", tool_input: {command: $c}}' \
    | CLAUDE_PROJECT_DIR="$1" bash "$G" 2> "$T/err")" && rc=0 || rc=$?
  REASON=""
  if [ "$rc" = 2 ]; then
    GOT=DENY
    REASON="$(cat "$T/err")"
  elif [ "$rc" != 0 ]; then
    GOT="exit $rc"
  elif [ -z "$out" ]; then
    GOT=allow
  elif REASON="$(printf '%s' "$out" | jq -er 'select(.hookSpecificOutput.permissionDecision == "deny")
      | .hookSpecificOutput.permissionDecisionReason')"; then
    GOT=DENY
  else
    GOT="output $out"
  fi
}

t_template() {
  local n
  n="$(grep -cxF -e 'TRUNK="{{kit.trunk}}"' -e 'TRUNK="${KIT_TRUNK:-$TRUNK}"' "$SRC" 2> /dev/null)"
  is "$n" 2 "template: TRUNK comes from KIT_TRUNK, else {{kit.trunk}}"
}

# The kit's own sessions run the template unrendered with KIT_TRUNK=main
# (.claude/settings.json), so the trunk must be exactly main.
t_unrendered() {
  local R="$T/unrendered" g="$G"
  mkdir -p "$R"
  git -C "$R" init -q -b main
  git -C "$R" commit -q --allow-empty -m init
  G="$SRC"
  export KIT_TRUNK=main
  verdict "$R" "git commit -m x"
  is "$GOT" DENY "unrendered: a commit on main is denied"
  like "$REASON" "^Refusing 'git commit' on 'main'\. 'main' moves only" "unrendered: the reason names main"
  verdict "$R" "git switch -c topic && git commit -m x"
  is "$GOT" allow "unrendered: a commit on a new topic passes"
  unset KIT_TRUNK
  G="$g"
}

# The battery: the scratch repo of the lab's corpus.sh, no kit lock.
t_battery() {
  local R="$T/repo" h want c bad=0 total=0 n
  mkdir -p "$R"
  git -C "$R" init -q -b main
  git -C "$R" commit -q --allow-empty -m init
  git -C "$R" switch -q -c feature
  git -C "$R" commit -q --allow-empty -m f1
  git -C "$R" switch -q main
  git -C "$R" config alias.ci commit
  git -C "$R" config alias.sh '!git commit'
  while IFS='|' read -r -u 3 h want c; do
    case "$h" in '' | '#'*) continue ;; esac
    git -C "$R" switch -q "$h"
    verdict "$R" "$c"
    total=$((total + 1))
    [ "$GOT" = "$want" ] || bad=$((bad + 1))
    is "$GOT" "$want" "battery: $h $c"
  done 3< "$TEST_ROOT/test/guard-git.cases"
  n="$(grep -cv -e '^#' -e '^$' "$TEST_ROOT/test/guard-git.cases")"
  is "$total" "$n" "battery: every case ran"
  is "$bad" 0 "battery: $bad wrong of $total"
}

t_no_jq() {
  local bin="$T/nojq" out rc
  mkdir -p "$bin"
  ln -s "$(command -v cat)" "$bin/cat"
  out="$(printf '%s' '{"tool_input":{"command":"git commit -m x"}}' \
    | PATH="$bin" "$(command -v bash)" "$G" 2>&1)" && rc=0 || rc=$?
  is "$rc" 2 "no jq: a git command exits 2"
  like "$out" '^guard-git: jq is not installed' "no jq: says why"
  out="$(printf '%s' '{"tool_input":{"command":"ls -la"}}' \
    | PATH="$bin" "$(command -v bash)" "$G" 2>&1)" && rc=0 || rc=$?
  is "$rc:$out" "0:" "no jq: a command without git passes"
}

# A consumer push waits until the pinned kit commit is on the kit's
# origin/main as of the last fetch. The consumer path has a space in it.
t_push_unpublished() {
  local vendor pin pin7 lock
  mk_kit "$TEST_ROOT/test/kits/toy/slices"
  mk_consumer "$BASIC" "$T/My Repo"
  kit_run render
  is "$RC" 0 "push: the consumer renders"
  vendor="$CON/.claude/vendor/kit"
  lock="$CON/.claude/kit.lock.json"
  verdict "$CON" "git push -u origin topic"
  is "$GOT" allow "push: a pin on origin/main may be pushed"

  echo two >> "$T/kit/CHANGELOG.md"
  git -C "$T/kit" commit -q -am two
  pin="$(git -C "$T/kit" rev-parse HEAD)"
  pin7="${pin:0:7}"
  git -C "$vendor" fetch -q "$T/kit" main
  git -C "$vendor" checkout -q "$pin"
  git -C "$CON" add .claude/vendor/kit
  git -C "$vendor" update-ref refs/remotes/origin/main "$KIT_HEAD"
  verdict "$CON" "git push -u origin topic"
  is "$GOT" DENY "push: origin/main behind the pin is denied"
  is "$REASON" "kit pin $pin7 is not on the kit's origin/main as of the last fetch: publish the kit first, or run kit check --published" \
    "push: the reason names the pin"
  verdict "$CON" "git push"
  is "$GOT" DENY "push: a bare git push is denied"
  verdict "$CON" "git status && git push upstream topic"
  is "$GOT" DENY "push: a push to another remote, after another command, is denied"
  verdict "$CON" "git status"
  is "$GOT" allow "push: other git commands run"
  mv "$lock" "$T/lock.bak"
  verdict "$CON" "git push -u origin topic"
  is "$GOT" allow "push: without a kit lock there is no check"
  mv "$T/lock.bak" "$lock"

  git -C "$vendor" update-ref refs/remotes/origin/main "$pin"
  verdict "$CON" "git push -u origin topic"
  is "$GOT" allow "push: allowed once origin/main holds the pin"

  find "$vendor" -mindepth 1 -delete
  verdict "$CON" "git push -u origin topic"
  is "$GOT" DENY "push: an absent checkout is denied"
  is "$REASON" "kit checkout is absent, so the pin cannot be verified: run kit init" \
    "push: the reason says to run kit init"

  git -C "$CON" rm -q --cached .claude/vendor/kit
  verdict "$CON" "git push -u origin topic"
  is "$GOT" DENY "push: a lock without a staged pin is denied"
  like "$REASON" '^no kit pin is staged at \.claude/vendor/kit' "push: the reason says no pin is staged"
}

t_template
t_unrendered
t_battery
t_no_jq
t_push_unpublished
done_testing
