---
name: merge-to-main
description: Use when a session branch is ready to land on {{kit.trunk}} — the user says "merge", "land this", "ship it", or "put this on {{kit.trunk}}" — or when deciding whether a branch can be merged cleanly.
---

# Merge to {{kit.trunk}}

`{{kit.trunk}}` moves only by fast-forward. **Clean** means two things, both checked before anything moves: `{{kit.trunk}}` can fast-forward to the branch, and the gate (`{{kit.gate_landing}}`) passes on the branch tip. Rules: [session-branches.md](../../rules/kit/session-branches.md).

## Steps

1. **Where are we.** `git submodule update --init .claude/vendor/kit` first, so a kit checkout left at another branch's pin does not show as uncommitted work and is not committed as a stale pin. Then `git branch --show-current` must not be `{{kit.trunk}}`; record it as `B`. `git status --porcelain` must be empty; if not, commit first (it is your branch). If `git rev-parse -q --verify MERGE_HEAD` or `git rev-parse -q --verify REBASE_HEAD` succeeds, an operation is half done: stop and offer `/sync-with-main`, which recovers from it.
2. **Refresh {{kit.trunk}}.** `git fetch {{kit.remote}}`, then `git fetch {{kit.remote}} {{kit.trunk}}:{{kit.trunk}}` to fast-forward local `{{kit.trunk}}` without leaving the branch. If that refuses, local `{{kit.trunk}}` holds commits `{{kit.remote}}` lacks; report that and continue against local `{{kit.trunk}}`.
3. **Fast-forward check.** `git merge-base --is-ancestor {{kit.trunk}} B`. Exit 0: the branch contains `{{kit.trunk}}`, so the merge is a fast-forward. Exit 1: `{{kit.trunk}}` has moved since the branch was made: **not clean**; go to Report.
4. **Gate.** `git submodule update --init .claude/vendor/kit`, so the kit checkout matches the branch's pin, then `{{kit.gate_landing}}`, then `bash .claude/vendor/kit/bin/kit check --published`, which also fails while the kit pin is unpublished. The result of a fast-forward *is* the branch tip, so this checks the merged result. Any failure: **not clean**; go to Report.
5. **Land.** `git switch {{kit.trunk}}`, then `git merge --ff-only B`. The guard hook allows exactly this form on `{{kit.trunk}}`. Leave HEAD on `{{kit.trunk}}`: a new session then starts from `{{kit.trunk}}`, and if this session keeps working, its next edit creates a fresh branch per the rule table.
6. **Kit checkout.** `git submodule update --init .claude/vendor/kit` again, so the checkout matches the landed pin.
7. **Report.** `git log --oneline ORIG_HEAD..{{kit.trunk}}` lists what landed, and `git rev-list --count {{kit.remote}}/{{kit.trunk}}..{{kit.trunk}}` counts what is unpushed. Say: branch, commit count, "fast-forward, gate passed", that `{{kit.trunk}}` is now N ahead of `{{kit.remote}}/{{kit.trunk}}`, and what a push of it does, as repo.md § Deploy states (push only on request). The branch stays; never delete it.

## Report when not clean

Name the exact reason, then offer the fix in one line:

- `{{kit.trunk}}` moved: `git log --oneline B..{{kit.trunk}}`. "N commits on {{kit.trunk}} are not in B. Run /sync-with-main, then /merge-to-main again."
- Gate failed: name the failing step and quote its first error line. "Fix on B, commit, rerun."
- Kit pin unpublished: quote the `UNPUBLISHED` line. "Publish the kit with `bash bin/kit publish` in the kit's own clone, then rerun /merge-to-main."

Nothing has moved at that point; no cleanup is needed.

## Do not

- No `git merge` without `--ff-only`, no `--no-ff`, no merge commits on `{{kit.trunk}}`.
- No `git push`. Say that a push is needed and let the user ask.
- No branch deletion.
- No skipping the gate because "it passed earlier": run it on the tip you are about to land. Never weaken the gate to make it pass.
