#!/usr/bin/env bash
# test/stop-hook.sh, the kit repo's own Stop hook, run from a copy whose
# bin/kit is a stub selftest: it lets a green turn end, blocks a red one with
# the first 20 lines of the report less the passing tests, and lets a turn
# end once stop_hook_active is set, with or without jq.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
t_setup
K="$T/k"
mkdir -p "$K/bin" "$K/test"
cp "$TEST_ROOT/test/stop-hook.sh" "$K/test/stop-hook.sh"

# stub <rc> <lints>: bin/kit records how it ran in $T/ran, then prints a
# selftest report with <lints> LINT lines, one failing test among passing
# ones, and exits <rc>.
stub() {
  cat > "$K/bin/kit" <<EOF
printf '%s|%s\n' "\$*" "\$PWD" > "$T/ran"
i=0
while [ \$i -lt $2 ]; do i=\$((i + 1)); printf 'LINT voice slices/x/rules/r%s.md: line 1: this kit\n' \$i; done
printf '# t-a.sh\n'
i=0
while [ \$i -lt 25 ]; do i=\$((i + 1)); printf 'ok %s - pass %s\n' \$i \$i; done
printf 'not ok 26 - it broke\n#   got:  a\n#   want: b\n1..26\n# 1 failed\n# FAILED t-a.sh\n'
printf 'TESTS test/run.sh failed\nselftest: 2 problems\n'
exit $1
EOF
}

# hook <payload> [PATH]: run the hook. OUT is stdout, ERR stderr.
hook() {
  rm -f "$T/ran"
  OUT="$(printf '%s' "$1" | PATH="${2:-$PATH}" "$(command -v bash)" "$K/test/stop-hook.sh" 2> "$T/err")" && RC=0 || RC=$?
  ERR="$(cat "$T/err")"
}

t_green() {
  stub 0 0
  hook '{"stop_hook_active":false}'
  is "$RC:$OUT" "0:" "green: the turn ends"
  is "$(cat "$T/ran" 2> /dev/null)" "selftest|$K" "green: ran selftest from the kit root"
}

t_red() {
  local reason
  stub 1 1
  hook '{"session_id":"s","stop_hook_active":false}'
  is "$RC" 0 "red: exits 0"
  is "$(printf '%s' "$OUT" | jq -r .decision)" block "red: blocks the turn"
  reason="$(printf '%s' "$OUT" | jq -r .reason)"
  is "$(printf '%s\n' "$reason" | head -n 1)" "bash bin/kit selftest failed:" "red: the reason names the command"
  like "$reason" '^LINT voice slices/x/rules/r1\.md' "red: the LINT line is in the reason"
  like "$reason" '^not ok 26 - it broke$' "red: the failing test is in the reason"
  like "$reason" '^selftest: 2 problems$' "red: the summary is in the reason"
  unlike "$reason" '^(ok [0-9]|1\.\.[0-9]|# t-a\.sh$)' "red: passing tests, plans and file headers are left out"
}

t_cap() {
  local reason
  stub 1 30
  hook '{"stop_hook_active":false}'
  reason="$(printf '%s' "$OUT" | jq -r .reason)"
  is "$(printf '%s\n' "$reason" | wc -l | tr -d ' ')" 21 "cap: the command line and 20 report lines"
  is "$(printf '%s\n' "$reason" | tail -n 1)" "LINT voice slices/x/rules/r20.md: line 1: this kit" "cap: the 20th line is the last"
}

t_active() {
  stub 1 1
  hook '{"stop_hook_active":true}'
  is "$RC:$OUT" "0:" "active: the turn ends"
  no_file "$T/ran"
}

t_no_jq() {
  local bin="$T/nojq" c
  mkdir -p "$bin"
  for c in bash cat dirname grep head; do ln -s "$(command -v "$c")" "$bin/$c"; done
  stub 1 1
  hook '{"stop_hook_active": true}' "$bin"
  is "$RC:$OUT:$ERR" "0::" "no jq: stop_hook_active is read with grep"
  hook '{"stop_hook_active":false}' "$bin"
  is "$RC" 2 "no jq: a red selftest exits 2"
  like "$ERR" '^not ok 26 - it broke$' "no jq: the reason is on stderr"
}

t_green
t_red
t_cap
t_active
t_no_jq
done_testing
