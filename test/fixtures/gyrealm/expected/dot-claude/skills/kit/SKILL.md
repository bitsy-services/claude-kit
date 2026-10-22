---
name: kit
description: Use when checking the shared Claude kit's state, bumping it, or changing a file the kit renders (an edit was refused because the file is rendered from the kit).
---
<!-- kit: rendered from slices/core/skills/kit/SKILL.md — edit the source in the kit, never this copy -->

# The kit

This repo vendors a shared kit of Claude Code configuration at `.claude/vendor/kit`, pinned by the submodule's commit. `kit render` writes the slices named in `.claude/kit.json` into `.claude/` as stamped copies, merges their entries into `.claude/settings.json` and records what it wrote in `.claude/kit.lock.json`. `kit check` fails on any difference from the pin. Run every command below as its own Bash call, from the repo root.

## Status

- `bash .claude/vendor/kit/bin/kit status` prints one line: the pin, the rendered files against the lock, the lock against the pin, jq, and the state of the checkout.
- `bash .claude/vendor/kit/bin/kit check` is the full check. Each failure line names its fix.
- An absent checkout is fetched with `git submodule update --init .claude/vendor/kit`.

## Bump

On the session branch, each step its own call:

1. `bash .claude/vendor/kit/bin/kit bump` fetches the kit, moves the pin to the kit's published `main`, renders, and prints the CHANGELOG lines between the two pins. It prompts, and that prompt is the review. If the render fails, it prints those lines, then restores the old pin.
2. Read those CHANGELOG lines. When a `BREAKING:` entry names an edit to `.claude/kit.json` or `.claude/rules/repo.md`, make that edit first, then run `kit bump` (again, if step 1 failed on it). `kit check` fails between the two steps, and that is expected: the edit is for the new pin.
3. Run the gate: `bash scripts/check.sh`.
4. `git add .claude`
5. `git commit -m "Bump kit to <sha7>: <headline>"`

If this repo's rules leave commits to the user, stop before step 4 and report. Changed rules and skills load only in a new session.

If step 1 stops with `bump: cannot stage the gitlink`, `.gitignore` ignores `.claude/vendor/kit`, most often through an unanchored `vendor/` line: anchor it as `/vendor/` and run the bump again.

## Change a rendered file

A rendered file carries a stamp naming its source, and the write guard refuses edits to it. The fix belongs in the kit:

1. `bash .claude/vendor/kit/bin/kit edit <path>` prints the file's source in the kit and the authoring steps.
2. State the change and why, and wait for the user's go-ahead: a kit change reaches every repo that uses the kit at its next bump.
3. In the kit's own clone (ask the user where it is), never in `.claude/vendor/kit`: on a topic branch, edit the slice, add a CHANGELOG line, run `bash bin/kit selftest`, and commit. Writes outside this repo prompt unless the user adds the clone with `/add-dir`.
4. `bash bin/kit publish` in the clone lands the change on the kit's `main`. It prompts, and that prompt is the review.
5. Back in this repo, bump as above.

To keep this repo different instead, exclude the kit's item in `.claude/kit.json`, then run `bash .claude/vendor/kit/bin/kit render`: a file by its path (`.claude/rules/kit/<name>.md`), a settings entry as `allow:<entry>`, a scalar as `set:<key>`. A replacement file goes at the same path, without the stamp. A forbidden entry cannot be excluded.
