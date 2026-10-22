# Changelog

One entry for every change under `slices/`, `bin/` or `lib/` that reaches `main`, newest first. `kit bump` prints the lines added between the old pin and the new one, so each line reads on its own.

An entry starts with `BREAKING:` when the change removes or renames a slice, file or parameter, adds a required parameter or heading, changes a hook's behaviour, or narrows a permission. A `BREAKING:` entry gives the exact edit to `.claude/kit.json` or `.claude/rules/repo.md` that a repo makes at the bump.

## 2026-10-21 — v1: core, self-improvement, session-branch, hugo-wiki

- kit: the `kit` CLI. In a repo that vendors the kit: `scaffold`, `render`, `check`, `status`, `bump`, `init` and `edit`; a failed `bump` prints the CHANGELOG lines before it restores the old pin. In the kit's own clone: `selftest` and `publish`.

- core, mandatory in every repo: rules `tool-use`, `irreversible`, `source-control`, `permissions`, `collaboration` and `memory`; skill `kit` (status, bump, changing a rendered file); hooks `guard-write.sh` (PreToolUse on Edit, Write and NotebookEdit) and `kit-status.sh` (SessionStart). Params `gate` (required), `gate_landing` and `memory_root` (a path inside the repo: no leading `/`, no `..`). Allows `kit check`, `kit status` and `kit edit` with arguments and `kit render` only bare, so `kit render --discard` prompts. Sets `autoMemoryEnabled` and `disableAllHooks` to false. Forbids the broad `git`, `git -C`, `gh`, `npm` and `npx` allow entries, in any spelling: `kit check` also fails on the `:*` form, on bare `Bash`, and on any entry whose text before its first `*` is a prefix of a forbidden one.
- core: the `kit` skill's bump section covers `bump: cannot stage the gitlink`, which an unanchored `vendor/` line in `.gitignore` causes by ignoring `.claude/vendor/kit`.
- core: the text of `tool-use` and `irreversible` comes from uniteum/ai, with thanks.
- self-improvement: rule `self-improvement` (friction notes, patterns, proposed rules) and a PermissionRequest hook that logs each permission prompt to `friction/project-prompt-log.md` under the memory root, except a prompt to write that log itself. Requires core.
- session-branch: rule `session-branches`; skills `merge-to-main` and `sync-with-main`; hooks `guard-git.sh` (PreToolUse on Bash: the trunk moves only by fast-forward, no branch is deleted, and in a repo with a kit lock no pushed ref pins a kit commit that is not on the kit's origin/main) and `branch-context.sh` (SessionStart; reports a kit checkout left off-pin by a branch switch apart from uncommitted work). Params `trunk` and `remote`; `repo.md` headings Deploy, Gate, Conflict stops and Branch names. Requires core.
- session-branch: admitted by the owner with its two consumers named, gyrealm/gyrealm and gargantis/amorfus.
- hugo-wiki: rules `wiki-linking`, `wiki-content` and `wiki-workflow`, always on, and `hugo-on-workers`, scoped to `hugo.toml`, `wrangler.*`, `layouts/` and `scripts/`. Param `wiki_dir`. Allows `hugo` builds and the local server; `hugo deploy` prompts. Requires core.
