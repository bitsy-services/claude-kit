#!/usr/bin/env bash
# The kit repo's own Stop hook (registered in .claude/settings.json): a turn
# in a kit session does not end while bash bin/kit selftest --lints-only is
# red. It runs the syntax check and the lints, which take seconds; the whole
# selftest, with the test suite, gates kit publish and CI (R35). The block
# reason is the first 20 lines of selftest's report, passing test lines left
# out so the failures show. It honours stop_hook_active, so a turn it has
# blocked once can end and the hook never loops. Without jq it reads the flag
# with grep and blocks by exiting 2 with the reason on stderr.
set -u

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
input="$(cat)"

if command -v jq > /dev/null 2>&1; then
  active="$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2> /dev/null)" || active=false
elif printf '%s' "$input" | grep -Eq '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
  active=true
else
  active=false
fi
if [ "$active" = true ]; then exit 0; fi

if out="$(cd -- "$root" && bash bin/kit selftest --lints-only 2>&1)"; then exit 0; fi

reason="bash bin/kit selftest --lints-only failed:
$(printf '%s\n' "$out" | grep -v -E '^(ok [0-9]+( |$)|1\.\.[0-9]+$|# t-[A-Za-z0-9_-]+\.sh$)' | head -n 20)"

if command -v jq > /dev/null 2>&1; then
  jq -nc --arg r "$reason" '{decision: "block", reason: $r}'
  exit 0
fi
printf '%s\n' "$reason" >&2
exit 2
