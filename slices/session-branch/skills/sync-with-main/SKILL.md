---
name: sync-with-main
description: Use when a session branch has fallen behind {{kit.trunk}} — /merge-to-main reported "not clean", {{kit.trunk}} moved since the branch was made, a manual merge or rebase hit conflicts, or git status shows a merge or rebase in progress.
---

# Sync with {{kit.trunk}}

Brings `{{kit.trunk}}` into the session branch so the next `/merge-to-main` is a fast-forward. Default is rebase, which keeps history linear like `{{kit.trunk}}`. Merge instead when the branch has an upstream, so nothing already pushed is rewritten. Rules: [session-branches.md](../../rules/kit/session-branches.md).

## Steps

1. **Recover a half-done operation first.** `git submodule update --init .claude/vendor/kit` first, so a kit checkout left at another branch's pin does not show as uncommitted work and is not committed as a stale pin. Then:
   - `git rev-parse -q --verify MERGE_HEAD` succeeds: a merge is in progress. On `{{kit.trunk}}` (the user ran `git merge <branch>` there and hit conflicts): `git merge --abort`, `git switch <branch>`, continue at step 2. On the branch (a `git merge {{kit.trunk}}` was started): resolve per steps 5 and 6, then `git commit`; skip to step 8.
   - `git rev-parse -q --verify REBASE_HEAD` succeeds: a rebase is in progress. Resume at step 5.
2. **Where are we.** On a branch `B` other than `{{kit.trunk}}`, with a clean tree. Uncommitted work: commit it first.
3. **Refresh {{kit.trunk}}.** `git fetch {{kit.remote}}`, then `git fetch {{kit.remote}} {{kit.trunk}}:{{kit.trunk}}`. If it refuses, local `{{kit.trunk}}` holds unpushed commits; report and continue against local `{{kit.trunk}}`. Then `git merge-base --is-ancestor {{kit.trunk}} B`: exit 0 means already in sync; report and stop.
4. **Choose the mode.**
   - No upstream (`git rev-parse -q --verify B@{u}` fails): `git rebase {{kit.trunk}}`.
   - Has upstream: `git merge {{kit.trunk}}`. The fast-forward into `{{kit.trunk}}` still works afterwards because B then contains `{{kit.trunk}}`.
5. **Conflicts.** `git diff --name-only --diff-filter=U` lists them. If `.claude/kit.lock.json` or `.claude/vendor/kit` is among them, leave the lock and every file carrying the kit's stamp to step 6. Per remaining file:
   - Both sides added or changed different things and both belong: keep both.
   - One side is a strict superset or an obvious rename of the other: take it.
   - The sides assert different things in a category that repo.md § Conflict stops names: **stop**. Show both versions and ask.
   - `.claude/settings.json`: keep both sides' local entries and leave valid JSON; step 6's render settles the kit's own entries.

   Then `git add <files>`.
6. **Kit pin.** Only when step 5 found the lock or `.claude/vendor/kit`: both sides moved the kit pin. The kit's files are rendered again from one pin, never merged by hand.
   1. The sides are `HEAD` and `REBASE_HEAD` in a rebase, `HEAD` and `MERGE_HEAD` in a merge. `git rev-parse <side>:.claude/vendor/kit` gives each side's pin.
   2. `git -C .claude/vendor/kit log --oneline <pin1>..<pin2>`, then the same with the pins swapped. A range that lists nothing means its first pin descends from (or is) the second: take that pin and its side. If both ranges list commits, as with two unpublished kit branches, **stop**: show both pins and ask. If the checkout lacks a pin, run `git -C .claude/vendor/kit fetch origin` (it prompts) and retry.
   3. `git checkout <side> -- .claude/kit.lock.json` (it prompts).
   4. `git -C .claude/vendor/kit checkout --detach <pin>` (it prompts), then `git add .claude/vendor/kit`.
   5. `bash .claude/vendor/kit/bin/kit render --discard` (it prompts). It writes the rendered files, the lock and the kit's settings entries for the pin, over the conflicted copies.
   6. `bash .claude/vendor/kit/bin/kit check`, then `git add .claude`.
7. **Continue.** `git rebase --continue` (or `git commit` for a merge). Repeat from step 5 until it finishes.
8. **Gate.** `git submodule update --init .claude/vendor/kit`, then `{{kit.gate}}`. If it fails, fix on B and commit; the sync is not done until it passes. Never weaken the gate to make it pass.
9. **Report.** `git log --oneline {{kit.trunk}}..B` is what B still carries. Say: "B is synced with {{kit.trunk}} (rebased|merged, N conflicts resolved in <files>); /merge-to-main will fast-forward."

## Do not

- No `git push --force`. Merge mode exists so it is never needed.
- No resolving a conflict by dropping one side's assertion without asking.
- No `git reset --hard` or `git checkout -- <file>` to escape a conflict; step 6.3's `git checkout <side> -- .claude/kit.lock.json` is the one exception, since the render in step 6.5 rewrites that lock. The exits are `git rebase --abort` and `git merge --abort`.
