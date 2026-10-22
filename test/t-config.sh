#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
t_setup
mk_kit "$TEST_ROOT/test/kits/toy/slices"
mk_consumer "$TEST_ROOT/test/consumers/basic"
BASE="$TEST_ROOT/test/consumers/basic/kit.json"

# resolve <kit.json-text>: run config_resolve against the pinned kit; sets OUT, RC.
resolve() {
  printf '%s\n' "$1" > "$CON/.claude/kit.json"
  OUT="$(cd "$CON" && . "$TEST_ROOT/lib/common.sh" && . "$TEST_ROOT/lib/config.sh" &&
    ctx_consumer && rm -rf "$T/tree" && extract "$(pin_of)" "$T/tree" slices &&
    config_resolve "$T/tree" "$T/out.json" 2>&1)" && RC=0 || RC=$?
}
edit() { jq -c "$1" "$BASE"; }

resolve "$(cat "$BASE")"
is "$RC" 0 "valid config resolves"
is "$(jq -r '.params.gate_landing' "$T/out.json")" "bash scripts/check.sh" "default resolved through {{kit.gate}}"
is "$(jq -r '.params.memory_root' "$T/out.json")" ".claude/memory" "plain default applied"
is "$(jq -r '.params.trunk' "$T/out.json")" "main" "default from second slice"
is "$(jq -c '.slices' "$T/out.json")" '["core","extra"]' "slices in kit.json order"
is "$(jq -c '.headings' "$T/out.json")" '{"extra":["Deploy"]}' "headings by slice"
is "$(jq -c '.set' "$T/out.json")" '{"autoMemoryEnabled":false}' "set union"
is "$(jq -c '.forbid' "$T/out.json")" '[{"entry":"Bash(gh *)","reason":"broad gh can move origin/main without the push prompt","slice":"core"}]' "forbid carries slice"
is "$(jq -c '.paths' "$T/out.json")" '[[".claude/rules/kit/a.md","slices/core/rules/a.md","core"],[".claude/skills/s/SKILL.md","slices/core/skills/s/SKILL.md","core"],[".claude/hooks/kit/h.sh","slices/core/hooks/h.sh","core"],[".claude/rules/kit/b.md","slices/extra/rules/b.md","extra"]]' "paths [dest,src,slice]"

resolve "$(edit '.format=2')"
is "$RC" 1 "format 2 fails"
like "$OUT" '^CONFIG format 2 is not supported; this kit reads format 1 \(see CHANGELOG\)$' "format line"

resolve "$(edit '.foo=1')"
like "$OUT" '^CONFIG unknown key "foo" in \.claude/kit\.json$' "unknown key line"

resolve "$(edit '.slices=["extra"]')"
is "$RC" 1 "extra alone fails"
like "$OUT" '^CONFIG slice "core" is mandatory$' "core mandatory line"
like "$OUT" '^CONFIG extra requires core$' "requires line"

resolve "$(edit '.slices=["core","extra","rival"]')"
like "$OUT" '^CONFIG rival conflicts with extra$' "conflicts line"

resolve "$(edit '.slices=["core","nope"]')"
like "$OUT" '^CONFIG unknown slice "nope"$' "unknown slice line"

resolve "$(edit 'del(.params.gate)')"
is "$RC" 1 "missing gate fails"
like "$OUT" '^CONFIG param gate \(core\) is required$' "required line"
unlike "$OUT" 'gate_landing' "no cascade from a missing required param"

resolve "$(edit '.params.bogus="x"')"
like "$OUT" '^CONFIG unknown param "bogus" \(no enabled slice declares it\)$' "unknown param line"

resolve "$(edit '.params.gate="make; rm"')"
is "$RC" 1 "bad pattern fails"
like "$OUT" '^CONFIG param gate value does not match its pattern$' "pattern line"
unlike "$OUT" 'gate_landing' "no cascade from an invalid param"

resolve "$(edit '.params.gate_landing="a {{kit.gate}} b"')"
is "$RC" 0 "explicit value is taken as given"

# duplicate destination across two enabled slices
mkdir -p "$T/kit/slices/extra/rules"
git -C "$T/kit" show HEAD:slices/core/rules/a.md > "$T/kit/slices/extra/rules/a.md"
git -C "$T/kit" add -A
git -C "$T/kit" commit -q -m "dup"
git -C "$CON/.claude/vendor/kit" fetch -q "$T/kit" main
git -C "$CON/.claude/vendor/kit" checkout -q FETCH_HEAD
git -C "$CON" add .claude/vendor/kit
resolve "$(cat "$BASE")"
is "$RC" 1 "duplicate dest fails"
like "$OUT" '^CONFIG \.claude/rules/kit/a\.md is rendered by both core and extra$' "duplicate dest line"

# default cycle is reported, not looped
git -C "$T/kit" rm -q -r --cached slices/extra/rules/a.md
rm "$T/kit/slices/extra/rules/a.md"
jq '.params.p={"default":"{{kit.q}}","pattern":"^.+$"}|.params.q={"default":"{{kit.p}}","pattern":"^.+$"}' \
  "$T/kit/slices/extra/slice.json" > "$T/s.json"
cp "$T/s.json" "$T/kit/slices/extra/slice.json"
git -C "$T/kit" add -A
git -C "$T/kit" commit -q -m "cycle"
git -C "$CON/.claude/vendor/kit" fetch -q "$T/kit" main
git -C "$CON/.claude/vendor/kit" checkout -q FETCH_HEAD
git -C "$CON" add .claude/vendor/kit
resolve "$(cat "$BASE")"
is "$RC" 1 "default cycle fails"
like "$OUT" '^CONFIG param p default cannot be resolved' "cycle line"
done_testing
