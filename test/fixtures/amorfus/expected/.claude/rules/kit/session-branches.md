<!-- kit: rendered from slices/session-branch/rules/session-branches.md — edit the source in the kit, never this copy -->
# Session branches

Every Claude session contributes through its own development branch. `main` moves only by fast-forward from a session branch; what a push of it does is stated in [repo.md](../repo.md) § Deploy. Several sessions can be open at once, each on its own branch, sharing one checkout, which is why the branch check below runs before every edit, not once per session.

## Questions are answered, not acted on

- A question gets an answer and no file changes: not code, docs, rules or memory. If the answer surfaces something worth recording, say so in one line and record it in the next turn that makes changes.
- A prompt that starts with "I want" is a question about how to accomplish a goal. Answer with the approach (what you looked at, what you would change, what you are guessing) and stop. Build only when the user says to.

## Before the first edit of a turn

Run `git branch --show-current` and `git status --porcelain`, then:

| HEAD is | Tree | Do |
|---|---|---|
| `main` | clean | `git switch -c <topic>` **now**, before touching any file. Then edit. |
| `main` | dirty | Stop. Uncommitted work is sitting on `main`. Report the files and ask; do not branch over it, do not commit it. |
| this session's branch | any | Proceed. |
| another branch, and this session already has one | clean | Another session switched the checkout. `git switch <ours>`, then proceed. |
| another branch, and this session already has one | dirty | Stop and report: the dirty files belong to the other session. |
| a branch other than `main`, and this session has none yet | any | Adopt it as the session branch. Do not create another. |

## Naming

Lowercase kebab-case, two to four words naming the work, no prefix, no date; repo.md § Branch names gives examples. Check `git branch --list --all` first; if the name is taken, add a distinguishing word (a numeric suffix is the fallback). Git is the registry: the branch's first commit subject states its purpose, `git branch --list --merged main` gives status, and the SessionStart hook lists the open branches. Keep no registry file: a tracked list would conflict on every merge.

## Commits

- Commit on the session branch as the work reaches coherent points, and always before the turn ends, so the tree is clean for another session to switch. Subject short and imperative, matching `git log`; body only when the why is not obvious from the diff; end with the attribution trailer the session specifies.
- Run `npm run check` before committing when repo.md § Gate calls for it, and fix any failure first. The gate is never weakened to make a build pass.
- Never commit on `main`. The PreToolUse hook `.claude/hooks/kit/guard-git.sh` refuses `git commit`, `git cherry-pick`, `git revert`, `git am`, `git rebase`, `git reset` with a mode or to another commit, and any `git merge` or `git pull` without `--ff-only` while HEAD is `main`, and refuses deleting any branch.
- Push only when the user asks. Push is not in the allow list, so it prompts; that prompt is the confirmation.
- Branches are kept after merging. Never delete a branch.

## Landing and syncing

- `/merge-to-main` lands the session branch when it is clean: `main` can fast-forward to it and `npm run check` passes on its tip. Otherwise it stops and names the reason.
- `/sync-with-main` brings `main` into the branch (rebase by default, merge if the branch has an upstream) so the next `/merge-to-main` fast-forwards.
- When a merge to `main` has failed (`/merge-to-main` reported not clean, the user says a manual merge hit conflicts, or `git status` shows a merge or rebase in progress), offer `/sync-with-main` in one line.

## Plugins that stand down here

`superpowers:finishing-a-development-branch` (its merge/PR/discard menu and branch deletion) and `superpowers:using-git-worktrees` (worktrees under `.worktrees/`) do not apply in this repo. One checkout, branch switching, and the two skills above.
