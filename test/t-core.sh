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

t_core_check() {
  kit_run check
  is "$RC" 0 "check: kit check exits 0"
  like "$OUT" '^kit check: ok$' "check: kit check reports ok"
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
t_core_check
t_kit_status_hook
t_kit_status_hook_without_jq
t_kit_status_hook_without_checkout
done_testing
