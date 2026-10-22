---
name: merge-to-main
description: Use when a session branch is ready to land on main — the user says "merge", "land this", "ship it", or "put this on main" — or when deciding whether a branch can be merged cleanly.
---
<!-- kit: rendered from slices/session-branch/skills/merge-to-main/SKILL.md — edit the source in the kit, never this copy -->

# Merge to main

`main` moves only by fast-forward. **Clean** means two things, both checked before anything moves: `main` can fast-forward to the branch, and the gate (`bash scripts/check.sh --landing`) passes on the branch tip. Rules: [session-branches.md](../../rules/kit/session-branches.md).

## Steps

1. **Where are we.** `git submodule update --init .claude/vendor/kit` first, so a kit checkout left at another branch's pin does not show as uncommitted work and is not committed as a stale pin. Then `git branch --show-current` must not be `main`; record it as `B`. `git status --porcelain` must be empty; if not, commit first (it is your branch). If `git rev-parse -q --verify MERGE_HEAD` or `git rev-parse -q --verify REBASE_HEAD` succeeds, an operation is half done: stop and offer `/sync-with-main`, which recovers from it.
2. **Refresh main.** `git fetch origin`, then `git fetch origin main:main` to fast-forward local `main` without leaving the branch. If that refuses, local `main` holds commits `origin` lacks; report that and continue against local `main`.
3. **Fast-forward check.** `git merge-base --is-ancestor main B`. Exit 0: the branch contains `main`, so the merge is a fast-forward. Exit 1: `main` has moved since the branch was made: **not clean**; go to Report.
4. **Gate.** `git submodule update --init .claude/vendor/kit`, so the kit checkout matches the branch's pin, then `bash scripts/check.sh --landing`, then `bash .claude/vendor/kit/bin/kit check --published`, which also fails while the kit pin is unpublished. The result of a fast-forward *is* the branch tip, so this checks the merged result. Any failure: **not clean**; go to Report.
5. **Land.** `git switch main`, then `git merge --ff-only B`. The guard hook allows exactly this form on `main`. Leave HEAD on `main`: a new session then starts from `main`, and if this session keeps working, its next edit creates a fresh branch per the rule table.
6. **Kit checkout.** `git submodule update --init .claude/vendor/kit` again, so the checkout matches the landed pin.
7. **Report.** `git log --oneline ORIG_HEAD..main` lists what landed, and `git rev-list --count origin/main..main` counts what is unpushed. Say: branch, commit count, "fast-forward, gate passed", that `main` is now N ahead of `origin/main`, and what a push of it does, as repo.md § Deploy states (push only on request). The branch stays; never delete it.

## Report when not clean

Name the exact reason, then offer the fix in one line:

- `main` moved: `git log --oneline B..main`. "N commits on main are not in B. Run /sync-with-main, then /merge-to-main again."
- Gate failed: name the failing step and quote its first error line. "Fix on B, commit, rerun."
- Kit pin unpublished: quote the `UNPUBLISHED` line. "Publish the kit with `bash bin/kit publish` in the kit's own clone, then rerun /merge-to-main."

Nothing has moved at that point; no cleanup is needed.

## Do not

- No `git merge` without `--ff-only`, no `--no-ff`, no merge commits on `main`.
- No `git push`. Say that a push is needed and let the user ask.
- No branch deletion.
- No skipping the gate because "it passed earlier": run it on the tip you are about to land. Never weaken the gate to make it pass.
