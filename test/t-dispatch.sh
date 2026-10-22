#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
t_setup
mk_kit "$TEST_ROOT/test/kits/toy/slices"
mk_consumer "$TEST_ROOT/test/consumers/basic"

kit_run nonsense
is "$RC" 2 "unknown command exits 2"
like "$OUT" '^usage: kit ' "unknown command prints usage"

kit_run
is "$RC" 2 "no args exits 2"
like "$OUT" '^usage: kit ' "no args prints usage"

# consumer mode, no vendored kit
mkdir -p "$T/nokit/bin" "$T/plain"
cp -R "$TEST_ROOT/bin/." "$T/nokit/bin/"
cp -R "$TEST_ROOT/lib" "$T/nokit/lib"
git -C "$T/plain" init -q -b topic
OUT="$(cd "$T/plain" && bash "$T/nokit/bin/kit" status 2>&1)" && RC=0 || RC=$?
is "$RC" 2 "status outside a consumer exits 2"
like "$OUT" 'not a kit consumer' "status outside a consumer says so"

# kit mode refuses consumer commands (R5)
OUT="$(cd "$T/kit" && bash "$T/kit/bin/kit" status 2>&1)" && RC=0 || RC=$?
is "$RC" 2 "consumer command in kit mode exits 2"
like "$OUT" 'not a kit consumer: status runs in a repo that vendors the kit' "kit mode names the rule"

# consumer mode refuses kit commands (R5)
kit_run selftest
is "$RC" 2 "kit command in consumer mode exits 2"
like "$OUT" 'selftest runs in the kit repo' "consumer mode names the rule"

# valid command with no implementation yet is an internal error
kit_run status
is "$RC" 2 "unimplemented command exits 2"
like "$OUT" 'internal error: cmd_status' "unimplemented command is reported"

# re-exec at the pin: a commit that moves the submodule HEAD must not change what runs
git -C "$CON/.claude/vendor/kit" rev-parse HEAD > /dev/null
echo "# marker" >> "$CON/.claude/vendor/kit/bin/kit"
kit_run status
like "$OUT" 'internal error: cmd_status' "re-exec runs the pinned bin, not the edited working copy"

# pin not present in the vendor checkout
git -C "$CON" update-index --cacheinfo "160000,1111111111111111111111111111111111111111,.claude/vendor/kit"
kit_run status
is "$RC" 1 "absent pin exits 1"
like "$OUT" 'NOT PRESENT 1111111 run: git submodule update --init .claude/vendor/kit' "absent pin prints the init hint"

done_testing
