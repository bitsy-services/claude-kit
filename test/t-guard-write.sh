#!/usr/bin/env bash
# guard-write.sh: denies writes to ~/.claude (plan files excepted), rendered
# kit files, the lock and the vendored kit, with jq and without it.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
t_setup
# Keep every scratch dir the kit makes inside $T, which the harness removes.
mkdir -p "$T/tmp" "$T/home"
export TMPDIR="$T/tmp"

G="$TEST_ROOT/slices/core/hooks/guard-write.sh"
BASIC="$TEST_ROOT/test/consumers/basic"
H="$T/home"
BASH_BIN="$(command -v bash)"
# A PATH without jq: the jq-less path may use only cat and sed.
NOJQ="$T/nojq"
mkdir -p "$NOJQ"
ln -s "$(command -v cat)" "$NOJQ/cat"
ln -s "$(command -v sed)" "$NOJQ/sed"

# The consumer path has a space in it; the guard must quote every path.
mk_kit "$TEST_ROOT/test/kits/toy/slices"
mk_consumer "$BASIC" "$T/My Repo"
kit_run render
is "$RC" 0 "setup: the consumer renders"

# gw <tool> <path> [nojq]: run the guard on a <tool> payload for <path>, with
# HOME at $H and the consumer as the working and project directory. The Edit
# payload carries a decoy file_path inside its strings, before and after the
# real key. Sets GOT (deny, allow, or what went wrong) and REASON.
gw() {
  local key=file_path payload out rc path="$PATH"
  [ "$1" = NotebookEdit ] && key=notebook_path
  [ "${3:-}" = nojq ] && path="$NOJQ"
  payload="$(jq -cn --arg t "$1" --arg k "$key" --arg p "$2" \
    --arg decoy '{"file_path": "/tmp/decoy", "notebook_path": "/tmp/decoy"}' '{
      session_id: "s", transcript_path: "/tmp/t.jsonl", hook_event_name: "PreToolUse",
      tool_name: $t,
      tool_input: {old_string: $decoy, ($k): $p, new_string: $decoy}
    }')"
  out="$(cd "$CON" && printf '%s' "$payload" \
    | HOME="$H" CLAUDE_PROJECT_DIR="$CON" PATH="$path" "$BASH_BIN" "$G" 2> "$T/err")" && rc=0 || rc=$?
  REASON=""
  if [ "$rc" = 2 ]; then
    GOT=deny
    REASON="$(cat "$T/err")"
  elif [ "$rc" != 0 ]; then
    GOT="exit $rc"
  elif [ -z "$out" ]; then
    GOT=allow
  elif REASON="$(printf '%s' "$out" | jq -er 'select(.hookSpecificOutput.permissionDecision == "deny")
      | .hookSpecificOutput.permissionDecisionReason')"; then
    GOT=deny
  else
    GOT="output $out"
  fi
}

rendered_reason() {
  printf '%s is rendered from %s: edit the source in the kit'"'"'s clone, never this copy (see: kit edit %s)' "$1" "$2" "$1"
}

t_with_jq() {
  gw Edit "$CON/.claude/rules/kit/a.md"
  is "$GOT" deny "jq: an edit of a rendered dest is denied"
  is "$REASON" "$(rendered_reason .claude/rules/kit/a.md slices/core/rules/a.md)" "jq: the reason names the source"
  gw Write "$H/.claude/settings.json"
  is "$GOT" deny "jq: a write to ~/.claude/settings.json is denied"
  gw Write "$H/.claude/plans/p.md"
  is "$GOT" allow "jq: a plan file under ~/.claude/plans is allowed"
  gw Write "$CON/.claude/rules/local.md"
  is "$GOT" allow "jq: a local rule is allowed"
  gw Write "$CON/.claude/vendor/kit/x"
  is "$GOT" deny "jq: a write into the vendored kit is denied"
  gw Write "$CON/.claude/kit.lock.json"
  is "$GOT" deny "jq: a write to the lock is denied"
  gw Edit "$CON/.claude/skills/s/SKILL.md"
  is "$REASON" "$(rendered_reason .claude/skills/s/SKILL.md slices/core/skills/s/SKILL.md)" "jq: a rendered skill is denied"
  gw Edit .claude/hooks/kit/h.sh
  is "$REASON" "$(rendered_reason .claude/hooks/kit/h.sh slices/core/hooks/h.sh)" "jq: a relative path is resolved"
  gw Write "$CON/.claude/rules/../rules/./kit/b.md"
  is "$REASON" "$(rendered_reason .claude/rules/kit/b.md slices/extra/rules/b.md)" "jq: dot segments are resolved"
  gw Write "$H/.claude/plans/../settings.json"
  is "$GOT" deny "jq: plans/.. does not escape the ~/.claude deny"
  gw NotebookEdit "$CON/.claude/vendor/kit/n.ipynb"
  is "$GOT" deny "jq: a notebook path is read"
  gw Write "$T/elsewhere/x.md"
  is "$GOT" allow "jq: a path outside the project is allowed"
  gw Write "$CON/.claude/rules/kit/new.md"
  is "$GOT" allow "jq: a path the lock does not name is allowed"
}

t_bad_lock() {
  cp "$CON/.claude/kit.lock.json" "$T/lock.bak"
  echo 'not json' > "$CON/.claude/kit.lock.json"
  gw Edit "$CON/.claude/rules/kit/a.md"
  is "$GOT" deny "bad lock: a rendered dest is denied"
  gw Write "$CON/.claude/rules/local.md"
  is "$GOT" allow "bad lock: a local rule is allowed"
  cp "$T/lock.bak" "$CON/.claude/kit.lock.json"
}

t_without_jq() {
  gw Edit "$CON/.claude/rules/kit/a.md" nojq
  is "$GOT" deny "no jq: an edit of a rendered dest is denied"
  is "$REASON" "$(rendered_reason .claude/rules/kit/a.md slices/core/rules/a.md)" "no jq: the stamp names the source"
  gw Edit "$CON/.claude/hooks/kit/h.sh" nojq
  is "$REASON" "$(rendered_reason .claude/hooks/kit/h.sh slices/core/hooks/h.sh)" "no jq: a hook's comment stamp names the source"
  gw Write "$CON/.claude/rules/a"$'\t'"b.md" nojq
  is "$GOT" deny "no jq: a path with an escape sed cannot decode is denied"
  gw Write "$H/.claude/settings.json" nojq
  is "$GOT" deny "no jq: a write to ~/.claude/settings.json is denied"
  gw Write "$H/.claude/plans/p.md" nojq
  is "$GOT" allow "no jq: a plan file is allowed"
  gw Write "$CON/.claude/rules/local.md" nojq
  is "$GOT" allow "no jq: a local rule is allowed"
  gw Write "$CON/.claude/vendor/kit/x" nojq
  is "$GOT" deny "no jq: a write into the vendored kit is denied"
  gw NotebookEdit "$CON/.claude/vendor/kit/n.ipynb" nojq
  is "$GOT" deny "no jq: a notebook path is read"
  gw Write "$CON/.claude/rules/kit/new.md" nojq
  is "$GOT" deny "no jq: anything under .claude/rules/kit is denied"
  gw Write "$CON/.claude/skills/s/notes.md" nojq
  is "$GOT" deny "no jq: anything in a stamped skill dir is denied"
  gw Write "$CON/.claude/skills/mine/SKILL.md" nojq
  is "$GOT" allow "no jq: an unstamped skill dir is allowed"
}

t_with_jq
t_bad_lock
t_without_jq
done_testing
