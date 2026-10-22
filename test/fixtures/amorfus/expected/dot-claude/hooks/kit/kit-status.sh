#!/usr/bin/env bash
# <!-- kit: rendered from slices/core/hooks/kit-status.sh — edit the source in the kit, never this copy -->
#
# SessionStart hook of the core slice: one line on the state of the kit,
# added to the session's context. It reports and never blocks: it exits 0 in
# every case and writes nothing (GIT_OPTIONAL_LOCKS=0 keeps git status from
# refreshing an index).
#
# It is the one kit hook that runs code from the vendored checkout. That is
# acceptable because it only reports; the guards, which enforce, never read
# the checkout.
set -u

root="${CLAUDE_PROJECT_DIR:-$PWD}"
kit="$root/.claude/vendor/kit/bin/kit"

if [ ! -f "$kit" ]; then
  echo "kit: the kit checkout is absent; run: git submodule update --init .claude/vendor/kit"
  exit 0
fi
if ! command -v jq > /dev/null 2>&1; then
  echo "kit: jq is missing, so the git and write guards block what they cannot check"
  exit 0
fi
(cd -- "$root" && GIT_OPTIONAL_LOCKS=0 bash "$kit" status 2>&1) || true
exit 0
