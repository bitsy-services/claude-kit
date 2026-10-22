#!/usr/bin/env bash
# The real self-improvement slice, rendered with core and memory_root
# "memory": the rule renders, kit check passes, and the PermissionRequest
# logger appends one line per prompt to the prompt log, skips
# AskUserQuestion, quotes the project dir and never fails the hook.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
t_setup
# Keep every scratch dir the kit makes inside $T, which the harness removes.
mkdir -p "$T/tmp" "$T/in/files/memory"
export TMPDIR="$T/tmp"

# basic's repo.md and settings; CLAUDE.md imports the index under "memory".
cp "$TEST_ROOT/test/consumers/basic/repo.md" "$TEST_ROOT/test/consumers/basic/settings.json" "$T/in/"
echo '{"format":1,"slices":["core","self-improvement"],"params":{"gate":"bash scripts/check.sh","memory_root":"memory"},"exclude":[]}' > "$T/in/kit.json"
echo '@memory/MEMORY.md' > "$T/in/CLAUDE.md.in"
: > "$T/in/files/memory/MEMORY.md"
mk_kit "$TEST_ROOT/slices"
mk_consumer "$T/in"
kit_run render
is "$RC" 0 "render exits 0"

LOG="$CON/memory/friction/project-prompt-log.md"
CMD="$(jq -r '[.hooks.PermissionRequest[]? | select((.matcher // "") == "") | .hooks[].command] | first // ""' \
  "$CON/.claude/settings.json")"

# log_prompt <payload> [project dir]: run the rendered logger as Claude Code
# would, with the payload on stdin.
log_prompt() {
  OUT="$(printf '%s' "$1" | CLAUDE_PROJECT_DIR="${2:-$CON}" bash -c "$CMD" 2>&1)" && RC=0 || RC=$?
}

t_rule_rendered() {
  has_file "$CON/.claude/rules/kit/self-improvement.md"
}

t_check() {
  kit_run check
  is "$RC" 0 "check: kit check exits 0"
  like "$OUT" '^kit check: ok$' "check: kit check reports ok"
}

t_logger_target() {
  like "$CMD" '"\$CLAUDE_PROJECT_DIR/memory/friction/project-prompt-log\.md"' \
    "logger: the PermissionRequest \"\" command appends to the prompt log under memory_root"
}

t_logger_appends() {
  mkdir -p "$CON/memory/friction"
  log_prompt '{"tool_name":"Bash","tool_input":{"command":"ls"}}'
  is "$RC" 0 "logger: exits 0 on a Bash prompt"
  is "$(grep -c '' "$LOG" 2> /dev/null)" 1 "logger: appends one line"
  like "$(cat "$LOG" 2> /dev/null)" '^- [0-9-]{10} \| Bash\(ls\) \| fix: \| pending$' "logger: the line is dated and pending"
}

t_logger_skips_ask() {
  local before
  before="$(cat "$LOG" 2> /dev/null)"
  log_prompt '{"tool_name":"AskUserQuestion"}'
  is "$RC" 0 "ask: exits 0"
  is "$(cat "$LOG" 2> /dev/null)" "$before" "ask: AskUserQuestion appends nothing"
}

# R27: a prompt to write the log itself is not logged; no allow entry can
# cover that protected path, and the line would race the write.
t_logger_skips_own_log() {
  local before
  before="$(cat "$LOG" 2> /dev/null)"
  log_prompt "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$CON/memory/friction/project-prompt-log.md\"}}"
  is "$RC" 0 "own log: exits 0"
  is "$(cat "$LOG" 2> /dev/null)" "$before" "own log: a prompt to write the log appends nothing"
  log_prompt '{"tool_name":"Write","tool_input":{"file_path":"/x/friction/project-prompt-log.md.bak"}}'
  is "$(grep -c '' "$LOG" 2> /dev/null)" "$(( $(printf '%s\n' "$before" | grep -c '') + 1 ))" \
    "own log: another file is still logged"
}

t_logger_path_with_space() {
  mkdir -p "$T/My Repo/memory/friction"
  log_prompt '{"tool_name":"Write","tool_input":{"file_path":"/x/y.md"}}' "$T/My Repo"
  is "$RC" 0 "space: exits 0"
  like "$(cat "$T/My Repo/memory/friction/project-prompt-log.md" 2> /dev/null)" \
    '^- [0-9-]{10} \| Write\(/x/y\.md\) \| fix: \| pending$' "space: appends under a project dir with a space"
}

# Without memory/friction/ the append fails; the hook must still exit 0.
t_logger_without_dir() {
  mkdir -p "$T/bare"
  log_prompt '{"tool_name":"Bash","tool_input":{"command":"ls"}}' "$T/bare"
  is "$RC" 0 "no dir: exits 0"
  no_file "$T/bare/memory"
}

t_rule_rendered
t_check
t_logger_target
t_logger_appends
t_logger_skips_ask
t_logger_skips_own_log
t_logger_path_with_space
t_logger_without_dir
done_testing
