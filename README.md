# claude-kit

Shared Claude Code rules, skills, hooks and permissions for many repos.

A repo adds this kit as a git submodule and lists the [slices](#slices) it wants in `.claude/kit.json`. `kit apply` copies those slices into the repo's `.claude/` as ordinary committed files, which are what Claude Code reads. `kit check` fails if those files stop matching the kit.

Needs bash 4.4 or later, git and jq, on Linux or WSL. Native Windows is not supported.

Run every command below from the root of your repo. `kit <command>` is short for `bash .claude/vendor/kit/bin/kit <command>`. Start each procedure from a clean `git status`, so that its commit holds only the kit's changes.

## Add the kit to a repo

This works for a new repo and for one that already has its own `CLAUDE.md`, settings or skills.

1. **Add the kit.**

   ```sh
   git submodule add https://github.com/bitsy-services/claude-kit .claude/vendor/kit
   bash .claude/vendor/kit/bin/kit init
   ```

   `init` writes `.claude/kit.json` with every slice that fits the repo, and says what it chose and why:

   ```text
   created .claude/kit.json
     slices: core, self-improvement, session-branch
     skipped hugo-wiki: no themes/hugo-book found
     gate: npm run check (package.json has a check script)
     trunk: main (a local main branch exists)
   ```

2. **Optional: edit `.claude/kit.json`.** Remove a slice you don't want, or set a [parameter](#parameters). A `NOTICE` from `init` names a value it could not find. Most often that is `gate`, the command that checks your repo. If the repo has no check command yet, keep the gate `init` chose and go on; `kit check` repeats the NOTICE until you set one.

   ```json
   {
     "format": 1,
     "slices": ["core", "self-improvement", "session-branch"],
     "params": { "gate": "npm run check" },
     "exclude": []
   }
   ```

3. **Apply it and commit.**

   ```sh
   bash .claude/vendor/kit/bin/kit apply
   git add -A
   git commit -m "Adopt claude-kit"
   ```

   `apply` renders the slices and adds what the repo is missing: `.claude/rules/repo.md` with [cautious defaults](#repomd), the memory folder, a line in `CLAUDE.md` that imports the memory index (`MEMORY.md` in that folder), and a line in `.gitattributes` that keeps `.claude/` in LF line endings, which the hook scripts need. It keeps the repo's own text and settings entries; the only values it changes are the two settings `core` sets. It ends with `kit check: ok`. If it prints a problem instead, fix it as [Troubleshooting](#troubleshooting) says and run `apply` again, until it does.

Every other clone of the repo then runs [Set up a clone](#set-up-a-clone) once.

## Set up a clone

In a new clone of a repo that uses the kit, or in an older clone after it pulls the commit that added the kit:

```sh
git submodule update --init .claude/vendor/kit
bash .claude/vendor/kit/bin/kit init
```

The first command fetches the kit. The second makes `git push` refuse to publish a commit that points at a kit version the kit's own remote does not have; git stores that setting per clone. It leaves `.claude/kit.json` as committed.

## Update the kit

```sh
bash .claude/vendor/kit/bin/kit bump
bash .claude/vendor/kit/bin/kit apply
git add -A
git commit -m "Bump claude-kit"
```

`bump` moves the repo to the latest kit and prints the CHANGELOG lines added since its old version. A line containing `BREAKING:` names an edit the new version needs; make it before `apply`. If `bump` prints `bump: render failed; restored`, make those edits and run `bump` again; `kit check` fails until that second bump succeeds, which is expected. Other clones run `git submodule update --init .claude/vendor/kit` after they pull. In a Claude session, ask Claude to update the kit instead: the `/kit` skill does the same on a session branch.

## Change slices or parameters

Edit `.claude/kit.json`, run `kit apply`, then `git add -A` and commit. `apply` adds the files of a slice you added, removes those of a slice you dropped, and writes default text for any `repo.md` section a new slice needs.

## Cloud sessions

Put this in the cloud environment's setup script:

```sh
git submodule update --init .claude/vendor/kit
```

The kit's files are committed, so a session loads every rule, skill and hook even without it. The `kit` commands need it, and with `session-branch` so does `git push`.

## Slices

A slice is a bundle of rules, skills, hooks and permissions; [Parameters](#parameters) lists each slice's parameters. `kit init` picks every slice except `hugo-wiki`, which it picks only when the repo has a `themes/hugo-book` folder or submodule, at any depth.

### core

Required in every repo.

- **Rules:** confirm before deploying, publishing, using a key or doing anything that cannot be undone. Run one command per Bash call. Never change `~/.claude`; lasting config goes in this repo. Allow narrow commands, not broad patterns. Stop to ask only for a real decision. Keep memory notes in this repo.
- **Skill:** `/kit` shows the kit's status, updates it, and walks through changing a file the kit renders.
- **Hooks:** block edits under `~/.claude`, to files the kit rendered, to `.claude/kit.lock.json` and to `.claude/vendor/kit/`. Print a one-line kit status at session start.
- **Permissions:** pre-approve reading and editing files, web search and fetch, read-only `git` and `gh` commands, common shell tools, the `kit` commands `check`, `status`, `edit`, `render` and `apply`, and your `gate`. `kit check` fails while `.claude/settings.json` allows a broad entry such as `Bash(git *)`, `Bash(gh *)`, `Bash(npm *)` or `Bash(npx *)`.
- **Settings:** sets `autoMemoryEnabled` to false, since memory lives in this repo, and `disableAllHooks` to false.

### self-improvement

Claude learns from friction in this repo. Requires `core`.

- **Rule:** when a session goes badly (corrections, repeated requests, rejected prompts), Claude writes a note under the memory folder. Related notes merge into a pattern, and a pattern that keeps holding is proposed as a new rule.
- **Hook:** logs every permission prompt, so Claude can propose allow entries for the ones that recur.

### session-branch

Each Claude session works on its own branch, and the trunk moves only by fast-forward once the gate passes. Requires `core`.

- **Rule:** create a branch before the first edit, commit before the turn ends, never commit on the trunk, never delete a branch, push only when asked. A question gets an answer, not file changes.
- **Skills:** `/merge-to-main` fast-forwards the trunk to the session branch after the gate passes on it. `/sync-with-main` brings the trunk into the branch and resolves conflicts.
- **Hooks:** refuse commits and non-fast-forward merges on the trunk, any branch deletion, and a push that would publish an unpublished kit version. List the open branches at session start.
- **Permissions:** pre-approve `git add`, `switch`, `commit` and `fetch`, fast-forward merges, and merging or rebasing the trunk into a branch. `git push` always prompts.
- **repo.md:** reads four [sections](#repomd) that say how this repo deploys, gates, resolves conflicts and names branches.

### hugo-wiki

For a Hugo site built on the hugo-book theme and deployed to Cloudflare Workers. Requires `core`.

- **Rules:** link pages to each other, and create a stub for a missing link target. Start pages with `##` sections and avoid the frontmatter names Hugo reserves. Treat the first message of a session as a request for a new page. Pin the Hugo version that Workers Builds uses (this rule loads only while editing `hugo.toml`, `wrangler.*`, `layouts/` or `scripts/`).
- **Permissions:** pre-approve `hugo` builds and `hugo server`. `hugo deploy` always prompts.

## Parameters

Parameters go under `params` in `.claude/kit.json`. One you leave out takes its default.

| Parameter | Slice | Default | What it is |
|---|---|---|---|
| `gate` | core | none (required) | The command that checks this repo, such as `npm run check`. It never prompts. Claude runs it after a kit update and, with `session-branch`, before commits as `repo.md` says. |
| `gate_landing` | core | `gate` | The check `/merge-to-main` runs before landing, if landing needs more than `gate`. |
| `memory_root` | core | `.claude/memory` | The folder for memory notes, relative to the repo root. If you change it, move the notes there and delete the old `@…/MEMORY.md` line from `CLAUDE.md`; `apply` adds the new one. |
| `trunk` | session-branch | `main` | The branch that sessions land on. |
| `remote` | session-branch | `origin` | The remote the trunk is fetched from. |
| `wiki_dir` | hugo-wiki | `content` | The folder that holds the wiki's pages. |

`kit init` fills in four of them from what the repo already has, and prints where each came from:

- `gate`: `bash scripts/check.sh` when that file exists, else `npm run check` or `npm test` from the scripts in `package.json`. Otherwise it is `bash .claude/vendor/kit/bin/kit check`, which checks only the kit's own files; `kit check` then prints a NOTICE until you set a real gate.
- `trunk`: `main` when a local `main` branch exists, else the branch `origin/HEAD` names, else `master`, else the current branch.
- `memory_root`: the folder of a `MEMORY.md` that `CLAUDE.md` already imports.
- `wiki_dir`: the `content` folder beside the theme (`site/content` for `site/themes/hugo-book`), when it holds pages. Otherwise `init`, and every `kit check` after it, prints a NOTICE asking for it.

`gate` and `gate_landing` are each one command, without quotes, `$`, backticks, `;`, `&`, `|` or `\`. The other parameters use only letters, digits, `.`, `_`, `-` and `/`, and `memory_root` stays inside the repo.

## repo.md

`.claude/rules/repo.md` holds facts about this repo that no slice can know. `session-branch` reads four sections. `apply` writes each with a cautious default; replace it with this repo's facts when you can.

| Section | Default | Replace it with |
|---|---|---|
| Deploy | Not stated yet. Treat a push of the trunk as a production deploy, and say so before pushing it. | What a push of the trunk does: deploys production, only runs CI, or nothing. Claude says this after landing a branch. |
| Gate | Run before every commit. | When to run the gate: before every commit, or only for changes under some paths. |
| Conflict stops | Every file: whenever the two sides assert different things, show both versions and ask. | The kinds of change where Claude must not pick a side in a merge conflict. |
| Branch names | `fix-login-timeout`, `add-export-button`, `update-readme` | Two or three example branch names in this repo's style. |

## Opt out of a kit item

To keep this repo different from the kit, add the item to `exclude` in `.claude/kit.json`:

- a file, by its path: `".claude/rules/kit/collaboration.md"`
- a permission: `"allow:Bash(ls *)"`
- a setting: `"set:autoMemoryEnabled"`

For a file, also delete the kit's copy or put your own at the same path. Then run `kit apply`. A slice's forbidden entries, such as `Bash(git *)`, cannot be excluded.

## Troubleshooting

- **`The following paths are ignored by one of your .gitignore files`** from `git submodule add`, **`bump: cannot stage the gitlink`**, or **`IGNORED`** from `kit check`: a `.gitignore` line matches the kit's files, and `git check-ignore -v --no-index <path>` names it. Below a `vendor/` line, add `!/.claude/vendor/`, which keeps other `vendor/` folders ignored. Replace a `.claude/` line with `.claude/settings.local.json`, since the kit's files must be committed. Then run the command again. If a bump stopped this way, first run `git restore --staged .claude/vendor/kit` and `git submodule update .claude/vendor/kit`, so the next bump shows its CHANGELOG lines.
- **`REFUSE <path>: exists and is not rendered by the kit`**: the repo already has its own file where a slice renders one, often a skill. Compare it with the kit's copy under `.claude/vendor/kit/slices/`. Then rename yours (for a skill, its folder and the `name:` in its frontmatter), or run `kit apply --discard`, which replaces every file `apply` refused with the kit's, or keep yours by adding its path to `exclude`. The slice's other files call a skill by name, so one you keep must do the same job.
- **`DRIFT <path> differs from …`** from `kit check`, or **`REFUSE <path>: edited in place`**: a file the kit rendered was edited in this repo. To make the change for every repo, `kit edit <path>` names the kit file it belongs in. To keep it in this repo only, add the path to `exclude` and delete the file's `kit: rendered from` stamp line. To drop it, run `kit apply --discard`.
- **`WORKTREE <path> is missing`** or **`STALE LOCK`**: run `kit apply`. **`ORPHAN <path>`**: run `kit apply`; if the line stays, delete the file it names.
- **`FORBID <entry>`**: `.claude/settings.json` allows a broad command that a slice forbids, such as `Bash(git *)`. Delete it. The slices already allow the narrow commands they need (see [Slices](#slices)); add back only specific ones a session still needs, such as `Bash(npm run lint)`.
- **`BREADTH <entry>`**: an allow entry has a `*` before a literal word. Move the `*` to the end, or delete the entry if the `*` is its first word.
- **`LINK <file> -> <target>`**: a relative link in `CLAUDE.md` or under `.claude/` points at nothing. Fix or remove it.
- **`SET <key> is <value>; <slice> sets <value>`**: `kit apply` sets it back. To keep your own value, add `"set:<key>"` to `exclude` and run `kit apply`; if `apply` already set it back, set it again.
- **`STAMP <path> is excluded but still carries the kit stamp`**: delete that file, or delete its `kit: rendered from` stamp line to keep it as your own. Then run `kit apply`.
- **`CONFIG param gate (core) is required`**, or **`CONFIG param gate value does not match its pattern`**: set `gate` in `.claude/kit.json` to one command, as [Parameters](#parameters) describes.
- **A NOTICE saying `gate is kit check`**: no check command was found. Set `gate` to the command that checks this repo, then run `kit apply`.
- **A NOTICE saying a folder `holds no pages besides _index.md`**: set `wiki_dir` in `.claude/kit.json` to the folder that holds the wiki's pages, then run `kit apply`. If the folder is right and holds only its `_index.md` so far, the NOTICE stops once it holds a page.
- **`usage: kit <command>`** from `kit apply`: the repo's kit version is older than `apply`. Run `kit bump` first; if `gate` in `.claude/kit.json` is empty, set it before the bump.
- **`NOT PRESENT`**, or **`.claude/vendor/kit/bin/kit: No such file or directory`**: this clone lacks the kit's files. Run `git submodule update --init .claude/vendor/kit`.
- **`push.recurseSubmodules is not "check"`**: run `kit init`.

## Changing the kit itself

Changes to the kit are made in a clone of this repo, never in `.claude/vendor/kit`. [CLAUDE.md](CLAUDE.md) covers how. In a repo that uses the kit, the `/kit` skill walks Claude through it.
