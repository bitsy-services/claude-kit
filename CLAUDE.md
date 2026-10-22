# claude-kit: authoring rules

These rules govern changes to the kit itself, made in the kit's own clone. They describe how the kit is authored and give no instructions to a repo that vendors it.

## What the kit is

A public repo of shared Claude Code configuration. A repo that uses it vendors it as a git submodule at `.claude/vendor/kit`, names slices and parameters in `.claude/kit.json`, and runs `bin/kit render`. Render writes the slices' rules, skills and hooks into that repo's `.claude/` as stamped, committed copies, merges their settings fragments into its `.claude/settings.json` and records the result in `.claude/kit.lock.json`. `kit check` fails on any difference from the pinned commit. Claude Code reads only the rendered copies, never the submodule.

- `slices/<slice>/` is the payload: `slice.json` (requires, conflicts, params, headings, set, forbid), `settings.json` (permissions and hooks only), `rules/`, `skills/` and `hooks/`.
- `bin/kit` and `lib/` are the CLI.
- `test/` holds the suite, the toy kit and the fixtures, whose `expected/` trees are each fixture repo's whole rendered result.

## Admission

A file enters a slice only if all six hold:

1. **Demand:** three or more repos use it with the same intent, or the owner names its consumers in the CHANGELOG entry that admits it. Two repos is not a pattern.
2. **Consumer voice:** once its parameters are substituted, it holds no noun from any one repo.
3. **Bundle-complete:** it carries every rule, skill, hook, registration and permission it needs, or its slice declares `requires`.
4. **Public-safe:** no person is named or quoted (a view is paraphrased), and there is no email address, absolute path or SSH remote.
5. **Declared variability:** every per-repo value is a machine parameter, `{{kit.<name>}}` declared with a `pattern`, or a `repo.md` heading.
6. **Enforced:** a mechanical rule ships with the hook or check that enforces it.

`bash bin/kit selftest` lints 2, 4 and 5. The owner reviews 1, 3 and 6 at the `kit publish` prompt.

## Voice and public safety

- The repo is public, and every slice file renders into other repos. Slice text speaks to the repo it lands in ("this repo", "the user"), never about the kit or the repos that use it.
- Public safety covers every file in the kit, docs included, not only `slices/`.
- Core's always-on rules (no `paths`) total at most 150 rendered lines, since each line costs context in every session that loads them.

## Where to edit

Edit in a standalone clone of the kit, on a topic branch, never on `main`. A vendored copy at `.claude/vendor/kit` stays at its pin and is never edited: a change there is not the kit's, and it fails that repo's check.

## Changelog

- Every change under `slices/`, `bin/` or `lib/` gets a `CHANGELOG.md` entry on the same branch, since a repo that bumps the kit runs all three. `kit publish` refuses a branch that changes any of them without one.
- An entry starts with `BREAKING:` when the change removes or renames a slice, file or parameter, adds a required parameter or heading, changes a hook's behaviour, or narrows a permission. It gives the exact `kit.json` or `repo.md` edit that a repo makes at the bump. Prefer additive changes with defaults.
- A change to a rendered file changes the fixtures. Regenerate them with `KIT_UPDATE_EXPECTED=1 bash test/t-fixtures.sh` and read the diff before committing.

## Code

- Code a consumer runs (`bin/`, `lib/`, every hook) uses only bash, git and jq.
- Exit codes: 0 clean, 1 problems found, 2 usage or internal error.
- `bin/` and `lib/` never use `rm -r`. Scratch directories come from `scratch_new` and are removed by `scratch_cleanup`. Nothing writes under `~/.claude`.
- Nothing under `test/` carries a name Claude Code loads as instructions: a fixture stores `.claude` as `dot-claude` and `CLAUDE.md` as `CLAUDE.md.in`.
- Instruction text never shows a compound shell statement (`;`, `&&`, `|`) as one Bash call.

## Check and publish

1. `bash bin/kit selftest` runs the syntax check, the lints and the test suite, and must end `selftest: ok`; it gates `kit publish` and CI. The Stop hook in `.claude/settings.json` runs `bash bin/kit selftest --lints-only` (the syntax check and the lints, which take seconds) at the end of each turn and blocks while it is red, so run the whole selftest before publishing. The SessionStart hook lists the local branches that `origin/main` does not hold as of the last fetch.
2. Commit on the topic branch.
3. `bash bin/kit publish` lands the topic on `main` and pushes it. It refuses on `main`, on a dirty tree, on a red selftest, on a `slices/`, `bin/` or `lib/` change without a CHANGELOG entry, and when the fast-forward leaves `main` anywhere but the topic's head; otherwise it fast-forwards `main` to the topic and pushes `main` to `origin`. It is not pre-approved, so it prompts, and that prompt is the review.
