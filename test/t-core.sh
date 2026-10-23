#!/usr/bin/env bash
# The real core slice, rendered alone: its six rules fit the always-on budget,
# the gate is allowed once, kit check passes, and kit-status.sh reports.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
t_setup
# Keep every scratch dir the kit makes inside $T, which the harness removes.
mkdir -p "$T/tmp" "$T/in" "$T/empty"
export TMPDIR="$T/tmp"

RULES="tool-use irreversible source-control permissions collaboration memory"
BASH_BIN="$(command -v bash)"

# basic's inputs (CLAUDE.md import, memory index), with core as the only slice.
cp -R "$TEST_ROOT/test/consumers/basic/." "$T/in/"
echo '{"format":1,"slices":["core"],"params":{"gate":"bash scripts/check.sh"},"exclude":[]}' > "$T/in/kit.json"
mk_kit "$TEST_ROOT/slices"
mk_consumer "$T/in"
kit_run render
is "$RC" 0 "render exits 0"
HOOK="$CON/.claude/hooks/kit/kit-status.sh"

# status_hook [PATH]: run the rendered SessionStart hook from the consumer.
status_hook() {
  OUT="$(cd "$CON" && CLAUDE_PROJECT_DIR="$CON" PATH="${1:-$PATH}" "$BASH_BIN" "$HOOK" 2>&1)" && RC=0 || RC=$?
}

t_core_rules() {
  local n f total=0
  for n in $RULES; do
    f="$CON/.claude/rules/kit/$n.md"
    has_file "$f"
    if [ -f "$f" ]; then total=$((total + $(grep -c '' "$f"))); fi
  done
  is "$([ "$total" -le 150 ] && echo within || echo "over: $total")" within "rules: $total rendered lines, budget 150"
}

t_core_gate_allowed_once() {
  is "$(jq '[.permissions.allow[] | select(. == "Bash(bash scripts/check.sh)")] | length' "$CON/.claude/settings.json")" 1 \
    "gate: gate and gate_landing give one allow entry"
}

# guard-write's deny tells Claude to run kit edit, which only prints.
t_core_kit_edit_allowed() {
  is "$(jq '.permissions.allow | index("Bash(bash .claude/vendor/kit/bin/kit edit *)") != null' "$CON/.claude/settings.json")" true \
    "allow: kit edit is allowed"
}

# R37: kit render is allowed bare, so render --discard prompts.
t_core_render_allowed_exactly() {
  local s="$CON/.claude/settings.json"
  is "$(jq '.permissions.allow | index("Bash(bash .claude/vendor/kit/bin/kit render)") != null' "$s")" true \
    "allow: kit render is allowed"
  is "$(jq '[.permissions.allow[] | select(startswith("Bash(bash .claude/vendor/kit/bin/kit render "))] | length' "$s")" 0 \
    "allow: no kit render entry takes arguments, so --discard prompts"
}

# kit apply is allowed bare as well, so apply --discard prompts.
t_core_apply_allowed_exactly() {
  local s="$CON/.claude/settings.json"
  is "$(jq '.permissions.allow | index("Bash(bash .claude/vendor/kit/bin/kit apply)") != null' "$s")" true \
    "allow: kit apply is allowed"
  is "$(jq '[.permissions.allow[] | select(startswith("Bash(bash .claude/vendor/kit/bin/kit apply "))] | length' "$s")" 0 \
    "allow: no kit apply entry takes arguments, so --discard prompts"
}

# M3: core sets disableAllHooks false, so a tracked true fails the SET row.
t_core_set_hooks() {
  local s="$CON/.claude/settings.json"
  is "$(jq -c '.disableAllHooks' "$s")" false "set: render writes disableAllHooks false"
  cp "$s" "$T/settings.bak"
  jq '.disableAllHooks = true' "$T/settings.bak" > "$s"
  kit_run check
  is "$RC" 1 "set: disableAllHooks true fails check"
  like "$OUT" '^SET disableAllHooks is true; core sets false$' "set: the SET line"
  cp "$T/settings.bak" "$s"
}

# T9.2, T9.3, I5: what core's rules and kit skill say.
t_core_texts() {
  local c="$CON/.claude/rules/kit/collaboration.md" p="$CON/.claude/rules/kit/permissions.md"
  local k="$CON/.claude/skills/kit/SKILL.md" lead
  lead="$(sed -n '/^## Shape the answer/,/^## /{/^## /d;/^$/d;p}' "$c" | head -n 1)"
  like "$lead" "^Unless the user's own instructions set another order" "collaboration: the section's lead line yields to the user's ordering"
  unlike "$lead" '^- ' "collaboration: the lead line is not a bullet"
  unlike "$(cat "$c")" '^- An answer to a question .*unless' "collaboration: the verdict bullet no longer carries the clause alone"
  unlike "$(cat "$p")" 'Everything before the first `\*` is what limits the rule' "permissions: the false claim is gone"
  like "$(cat "$p")" 'Only the text before the first `\*` fixes which command runs.*the rest still constrains it' \
    "permissions: the text before the first * fixes the command, the rest still constrains it"
  like "$(cat "$k")" 'make that edit first, then run `kit bump`' "kit skill: a BREAKING edit comes first, then the bump"
  like "$(cat "$k")" '`kit check` fails between the two steps, and that is expected' "kit skill: check failing in between is expected"
}

t_core_check() {
  kit_run check
  is "$RC" 0 "check: kit check exits 0"
  like "$OUT" '^kit check: ok$' "check: kit check reports ok"
}

# memory_root is a path inside the repo: no leading /, no .. segment.
t_memory_root_pattern() {
  local p v want
  p="$(jq -r '.params.memory_root.pattern' "$TEST_ROOT/slices/core/slice.json")"
  while IFS='|' read -r v want; do
    is "$(jq -n --arg v "$v" --arg p "$p" '$v | test($p)')" "$want" "memory_root pattern: $v"
  done << 'EOF'
.claude/memory|true
memory|true
docs/a..b/.mem|true
..mem/x|true
/abs/memory|false
..|false
../memory|false
.claude/../memory|false
memory/..|false
memory/../..|false
EOF
}

t_memory_root_rejected() {
  local v
  cp "$CON/.claude/kit.json" "$T/kit.bak"
  for v in /abs/memory ../elsewhere; do
    jq -c --arg v "$v" '.params.memory_root = $v' "$T/kit.bak" > "$CON/.claude/kit.json"
    kit_run check
    is "$RC" 1 "memory_root $v: check exits 1"
    like "$OUT" '^CONFIG param memory_root value does not match its pattern$' "memory_root $v: the pattern line"
  done
  cp "$T/kit.bak" "$CON/.claude/kit.json"
}

t_kit_status_hook() {
  status_hook
  is "$RC" 0 "status: the hook exits 0"
  like "$OUT" '^kit [0-9a-f]{7} · files ok · lock ok · jq ok · checkout clean$' "status: the hook prints kit status"
}

t_kit_status_hook_without_jq() {
  status_hook "$T/empty"
  is "$RC" 0 "no jq: the hook exits 0"
  is "$OUT" "kit: jq is missing, so the git and write guards block what they cannot check" "no jq: the hook says so"
}

# A clone without `git submodule update --init` has an empty mount.
t_kit_status_hook_without_checkout() {
  git -C "$CON" submodule deinit -q -f .claude/vendor/kit
  no_file "$CON/.claude/vendor/kit/bin/kit"
  status_hook
  is "$RC" 0 "no checkout: the hook exits 0"
  is "$OUT" "kit: the kit checkout is absent; run: git submodule update --init .claude/vendor/kit" \
    "no checkout: the hook prints the init hint"
}

t_core_rules
t_core_gate_allowed_once
t_core_kit_edit_allowed
t_core_render_allowed_exactly
t_core_apply_allowed_exactly
t_core_texts
t_core_check
t_core_set_hooks
t_memory_root_pattern
t_memory_root_rejected
t_kit_status_hook
t_kit_status_hook_without_jq
t_kit_status_hook_without_checkout
done_testing
