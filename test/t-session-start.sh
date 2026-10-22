#!/usr/bin/env bash
# test/session-start.sh, the kit repo's own SessionStart hook (R36), run from
# a copy of the kit: it lists the local branches that origin/main does not
# hold as of the last fetch, offline, prints nothing when there are none, and
# always exits 0. .claude/settings.json registers it.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
t_setup
export GIT_CONFIG_GLOBAL=/dev/null
K="$T/k"
mkdir -p "$K/test" "$T/elsewhere"
cp "$TEST_ROOT/test/session-start.sh" "$K/test/session-start.sh"
git -C "$K" init -q -b main
git -C "$K" add -A
git -C "$K" commit -q -m init

# hook: run the hook from another directory, as Claude Code would.
hook() {
  OUT="$(cd "$T/elsewhere" && bash "$K/test/session-start.sh" < /dev/null 2>&1)" && RC=0 || RC=$?
}

t_registered() {
  like "$(jq -r '.hooks.SessionStart[]? | .hooks[].command' "$TEST_ROOT/.claude/settings.json")" \
    'test/session-start\.sh' "registered: .claude/settings.json runs it at SessionStart"
}

t_no_origin_main() {
  hook
  is "$RC:$OUT" "0:" "no origin/main: exits 0 and prints nothing"
}

t_all_published() {
  git -C "$K" update-ref refs/remotes/origin/main "$(git -C "$K" rev-parse HEAD)"
  git -C "$K" branch merged
  hook
  is "$RC:$OUT" "0:" "all published: exits 0 and prints nothing"
}

t_unpublished() {
  git -C "$K" switch -q -c topic
  git -C "$K" commit -q --allow-empty -m "topic work"
  git -C "$K" switch -q main
  git -C "$K" commit -q --allow-empty -m "local main work"
  hook
  is "$RC" 0 "unpublished: exits 0"
  is "$OUT" "Local branches not on origin/main as of the last fetch (unpublished kit work):
  main
  topic" "unpublished: lists main and topic, not the merged branch"
}

t_registered
t_no_origin_main
t_all_published
t_unpublished
done_testing
