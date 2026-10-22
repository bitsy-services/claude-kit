#!/usr/bin/env bash
# The kit repo's own SessionStart hook (registered in .claude/settings.json):
# names the local branches that origin/main does not hold as of the last
# fetch, which is kit work not yet published (R36). It reads only local
# refs, prints nothing when there are none or when origin/main is unknown,
# and always exits 0.
set -u

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
list="$(git -C "$root" for-each-ref --format='%(refname:short)' --no-merged refs/remotes/origin/main refs/heads/ 2> /dev/null)" || list=""
if [ -n "$list" ]; then
  echo "Local branches not on origin/main as of the last fetch (unpublished kit work):"
  while IFS= read -r b; do
    printf '  %s\n' "$b"
  done <<< "$list"
fi
exit 0
