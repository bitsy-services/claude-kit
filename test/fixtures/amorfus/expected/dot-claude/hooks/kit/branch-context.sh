#!/usr/bin/env bash
# <!-- kit: rendered from slices/session-branch/hooks/branch-context.sh — edit the source in the kit, never this copy -->
# SessionStart hook of the session-branch slice: tell the session where it
# stands in git. The output is added to the session's context. It reads only
# local state (no fetch) and exits 0 in every case.
set -u
TRUNK="main"
REMOTE="origin"
RULE=".claude/rules/kit/session-branches.md"

if ! command -v jq > /dev/null 2>&1; then
  echo "branch-context: jq is not installed, so guard-git.sh blocks every command that mentions git. Install jq outside this session, then start a new one."
  exit 0
fi
repo="${CLAUDE_PROJECT_DIR:-$PWD}"
cd -- "$repo" 2> /dev/null || exit 0
git rev-parse --is-inside-work-tree > /dev/null 2>&1 || exit 0

branch=$(git branch --show-current 2> /dev/null)
[ -z "$branch" ] && branch="(detached HEAD)"

# The tree without the kit checkout (other submodules still count), and
# without optional locks, so the hook never rewrites the index under a
# running session.
dirty=$(git --no-optional-locks status --porcelain -- ':(top)' ':(top,exclude).claude/vendor/kit' 2> /dev/null | wc -l | tr -d ' ')
# The kit pin: one staged but not committed is uncommitted work. A checkout
# at another commit than the staged pin, as a branch switch leaves it, is not
# work; it is named on its own, with its fix.
kit=""
read -r kmode kpin _ < <(git ls-files -s -- .claude/vendor/kit 2> /dev/null) || true
if [ "${kmode:-}" = 160000 ]; then
  hpin=$(git rev-parse -q --verify HEAD:.claude/vendor/kit 2> /dev/null) || hpin=""
  [ "$hpin" = "$kpin" ] || dirty=$((dirty + 1))
  # An uninitialised submodule dir has no .git, and git -C would find this repo's.
  if [ -e .claude/vendor/kit/.git ] && co=$(git -C .claude/vendor/kit rev-parse -q --verify HEAD 2> /dev/null) &&
    [ "$co" != "$kpin" ]; then
    kit=", kit checkout off-pin (run: git submodule update --init .claude/vendor/kit)"
  fi
fi
if [ "$dirty" = "0" ]; then tree="clean"; else tree="$dirty uncommitted path(s)"; fi

state=""
if git rev-parse -q --verify MERGE_HEAD > /dev/null 2>&1; then
  state="a merge is in progress"
elif git rev-parse -q --verify REBASE_HEAD > /dev/null 2>&1; then
  state="a rebase is in progress"
fi

# The trunk against its remote-tracking branch as of the last fetch.
trunkpos=""
has_trunk=0
git rev-parse -q --verify "refs/heads/$TRUNK" > /dev/null 2>&1 && has_trunk=1
if [ "$has_trunk" = 0 ]; then
  trunkpos="There is no local branch '$TRUNK'; if that is not this repo's trunk, set the trunk param in .claude/kit.json."
elif git rev-parse -q --verify "refs/remotes/$REMOTE/$TRUNK" > /dev/null 2>&1; then
  ahead=$(git rev-list --count "refs/remotes/$REMOTE/$TRUNK..refs/heads/$TRUNK" 2> /dev/null)
  behind=$(git rev-list --count "refs/heads/$TRUNK..refs/remotes/$REMOTE/$TRUNK" 2> /dev/null)
  trunkpos="$TRUNK is $ahead ahead / $behind behind $REMOTE/$TRUNK as of the last fetch."
fi

# Other local branches: how many commits they carry past the trunk, and the
# first commit's subject, which is the branch's statement of purpose.
others=""
if [ "$has_trunk" = 1 ]; then
  others=$(git for-each-ref --format='%(refname:short)' refs/heads/ \
    | grep -vxF -- "$TRUNK" | grep -vxF -- "$branch" \
    | while read -r b; do
        n=$(git rev-list --count "refs/heads/$TRUNK..refs/heads/$b" 2> /dev/null)
        if [ "$n" = "0" ]; then
          printf '  %s (nothing past %s)\n' "$b" "$TRUNK"
        else
          subj=$(git log --reverse --format=%s "refs/heads/$TRUNK..refs/heads/$b" 2> /dev/null | head -1)
          printf '  %s (%s past %s: %s)\n' "$b" "$n" "$TRUNK" "$subj"
        fi
      done)
fi

ctx="Git at session start: on branch '$branch', tree $tree$kit"
[ -n "$state" ] && ctx="$ctx, $state"
ctx="$ctx."
[ -n "$trunkpos" ] && ctx="$ctx $trunkpos"
if [ "$branch" = "$TRUNK" ]; then
  ctx="$ctx You are on $TRUNK: before the first edit, create the session branch with 'git switch -c <topic>' (see $RULE)."
else
  ctx="$ctx '$branch' is this session's branch. Confirm HEAD is still '$branch' before each edit; another session may have switched the checkout."
fi
if [ -n "$state" ]; then
  ctx="$ctx Resolve the in-progress operation first: /sync-with-main handles it."
fi
if [ -n "$others" ]; then
  ctx="$ctx
Other local branches:
$others"
fi

jq -cn --arg ctx "$ctx" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}'
exit 0
