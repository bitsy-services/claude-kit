# claude-kit

Shared Claude Code rules, skills, hooks and permissions for many repos.

A repo adds this kit as a git submodule at `.claude/vendor/kit` and lists the [slices](#slices) it wants in `.claude/kit.json`. `kit render` copies those slices into the repo's `.claude/` as ordinary committed files, which are what Claude Code reads. `kit check` fails if those files no longer match the kit.

Needs bash 4.4 or later, git and jq, on Linux or WSL. Native Windows is not supported.

Run every command below from the root of your repo, one at a time.

## Add the kit to a repo

This works for a new repo and for one that already has its own `CLAUDE.md`, settings or skills. Start from a clean `git status`.

1. Add the kit:

   ```sh
   git submodule add https://github.com/bitsy-services/claude-kit .claude/vendor/kit
   bash .claude/vendor/kit/bin/kit init
   ```

2. Create `.claude/kit.json`. Pick slices from [Slices](#slices) and set `gate` to the command that checks your repo:

   ```json
   {
     "format": 1,
     "slices": ["core", "self-improvement", "session-branch"],
     "params": { "gate": "npm run check" },
     "exclude": []
   }
   ```

   `core` is required. `gate` is the only required parameter; the others have defaults ([Parameters](#parameters)). Leave `exclude` empty unless you need to [opt out of a kit item](#opt-out-of-a-kit-item).

3. Create the repo's own files:

   ```sh
   bash .claude/vendor/kit/bin/kit scaffold
   ```

   This writes `.claude/rules/repo.md` with one `##` heading for each section your slices need, and the memory folder `.claude/memory/`. It never overwrites an existing file. Write a line or two under each heading in `repo.md` ([what to write](#repomd-sections)). With no headings, leave it empty.

4. Add two lines, one to `CLAUDE.md` so every session loads the memory index, one to `.gitattributes` so the kit's hook scripts keep LF line endings:

   ```sh
   echo '@.claude/memory/MEMORY.md' >> CLAUDE.md
   echo '.claude/** text eol=lf' >> .gitattributes
   ```

5. Render the kit, then check it:

   ```sh
   bash .claude/vendor/kit/bin/kit render
   bash .claude/vendor/kit/bin/kit check
   ```

   Render keeps your own entries in `.claude/settings.json` and adds the kit's beside them. You are done when check prints `kit check: ok`. Each other line it prints names a problem and its fix; [Troubleshooting](#troubleshooting) lists them.

6. Commit:

   ```sh
   git add .gitmodules .gitattributes .claude CLAUDE.md
   git commit -m "Adopt claude-kit"
   ```

Every other clone of the repo then runs [Set up a clone](#set-up-a-clone) once.

## Set up a clone

In a new clone of a repo that uses the kit, or in an older clone after it pulls the commit that added the kit:

```sh
git submodule update --init .claude/vendor/kit
bash .claude/vendor/kit/bin/kit init
```

The first command fetches the kit. The second makes `git push` refuse to publish a commit that points at an unpublished kit version. That setting is stored per clone, so every clone needs it.

## Update the kit

1. Move to the latest kit:

   ```sh
   bash .claude/vendor/kit/bin/kit bump
   ```

   It prints the CHANGELOG lines added since your old version.
2. A line starting `BREAKING:` gives an edit to make in `.claude/kit.json` or `.claude/rules/repo.md`. Make it, then run `bash .claude/vendor/kit/bin/kit render`. If bump printed `bump: render failed; restored`, make the edits and run `kit bump` again instead.
3. Run `bash .claude/vendor/kit/bin/kit check` and fix anything until it prints `kit check: ok`.
4. Commit:

   ```sh
   git add .claude
   git commit -m "Bump claude-kit"
   ```

Other clones run `git submodule update --init .claude/vendor/kit` after they pull the bump.

## Change slices or parameters

Edit `.claude/kit.json`, then run `kit render` and `kit check`. Render adds the files of a new slice and removes those of a dropped one. If a new slice needs `repo.md` sections, check names them; add them by hand.

## Cloud sessions

Put this in the cloud environment's setup script:

```sh
git submodule update --init .claude/vendor/kit
```

The kit's files are committed, so a session loads every rule, skill and hook without it. Only the `kit` commands need it, and with `session-branch` a push is refused until it has run.

## Slices

A slice is a bundle of rules, skills, hooks and permissions. Rules land in `.claude/rules/kit/`, hooks in `.claude/hooks/kit/`, skills in `.claude/skills/`, and permissions and hooks are merged into `.claude/settings.json`.

### core

Required in every repo.

- **Rules:** confirm before deploying, publishing, using a key or doing anything that cannot be undone. Run one command per Bash call. Never change `~/.claude`: lasting config goes in this repo. Allow narrow commands, not broad patterns. Stop to ask only for a real decision. Keep memory notes in this repo, indexed by `MEMORY.md`.
- **Skill:** `/kit` shows the kit's status, bumps it, and walks through changing a file the kit renders.
- **Hooks:** blocks edits under `~/.claude`, to files the kit rendered, to `.claude/kit.lock.json` and to `.claude/vendor/kit/`. Prints a one-line kit status at session start.
- **Permissions:** pre-approves reading and editing files, web search and fetch, read-only `git` and `gh` commands, common shell tools (`ls`, `grep`, `jq` and a few more), `kit check`, `kit status`, `kit edit` and `kit render`, and your `gate`. `kit check` fails while `.claude/settings.json` allows a broad entry such as `Bash(git *)`, `Bash(gh *)`, `Bash(npm *)` or `Bash(npx *)`.
- **Settings:** turns off Claude Code's own auto memory, since memory lives in this repo.
- **Parameters:** `gate`, `gate_landing`, `memory_root`.

### self-improvement

Claude learns from friction in this repo. Requires `core`.

- **Rule:** when a session goes badly (corrections, repeated requests, rejected prompts), Claude writes a note in `.claude/memory/friction/`. Related notes are merged into a pattern in `.claude/memory/patterns/`, and a pattern that keeps holding is proposed as a new rule.
- **Hook:** logs every permission prompt to `.claude/memory/friction/project-prompt-log.md`, so Claude can propose allow entries for the ones that recur.
- **Parameters:** none of its own. It uses `memory_root`.

### session-branch

Each Claude session works on its own branch, and the trunk moves only by fast-forward once the gate passes. Requires `core`.

- **Rule:** create a branch before the first edit, commit before the turn ends, never commit on the trunk, never delete a branch, push only when asked. A question gets an answer, not file changes.
- **Skills:** `/merge-to-main` fast-forwards the trunk to the session branch after the gate passes on it. `/sync-with-main` brings the trunk into the branch and resolves conflicts.
- **Hooks:** refuses commits and non-fast-forward merges on the trunk, any branch deletion, and a push that would publish an unpublished kit version. Lists the open branches at session start.
- **Permissions:** pre-approves `git add`, `switch`, `commit` and `fetch`, fast-forward merges, and merging or rebasing the trunk into a branch. `git push` always prompts.
- **Parameters:** `trunk`, `remote`.
- **repo.md sections:** Deploy, Gate, Conflict stops, Branch names.

### hugo-wiki

For a Hugo site built on the hugo-book theme and deployed to Cloudflare Workers. Requires `core`.

- **Rules:** link pages to each other richly, and create a stub for a missing link target. Start pages with `##` sections and avoid frontmatter names Hugo reserves. Treat the first message of a session as a request for a new page. Pin the Hugo version Workers Builds uses (this rule loads only while editing `hugo.toml`, `wrangler.*`, `layouts/` or `scripts/`).
- **Permissions:** pre-approves `hugo` builds and `hugo server`. `hugo deploy` always prompts.
- **Parameters:** `wiki_dir`.

## Parameters

Set these under `params` in `.claude/kit.json`. A parameter you leave out takes its default.

| Parameter | Slice | Default | What it is |
|---|---|---|---|
| `gate` | core | none, required | The command that checks this repo, such as `npm run check` or `bash scripts/check.sh`. It is pre-approved. Claude runs it after a kit bump and, with `session-branch`, before commits as the Gate section of `repo.md` says. |
| `gate_landing` | core | the value of `gate` | The check `/merge-to-main` runs before landing. Set it only when landing needs a stricter check, such as `bash scripts/check.sh --landing`. |
| `memory_root` | core | `.claude/memory` | The folder for memory notes, relative to the repo root. If you change it, import `<memory_root>/MEMORY.md` in `CLAUDE.md` instead. |
| `trunk` | session-branch | `main` | The branch that sessions land on. |
| `remote` | session-branch | `origin` | The remote the trunk is fetched from. |
| `wiki_dir` | hugo-wiki | `content` | The folder that holds the wiki's pages, such as `content/wiki`. |

`gate` and `gate_landing` must each be a single command: no quotes, `$`, backticks, `;`, `&`, `|` or `\`. The other parameters may use only letters, digits, `.`, `_`, `-` and `/`, and `memory_root` must stay inside the repo (no leading `/`, no `..`). `kit check` rejects a value that breaks these.

## repo.md sections

`.claude/rules/repo.md` holds the facts about this repo that a slice cannot know. `session-branch` needs these four sections, each with at least one line:

```markdown
## Deploy

A push of `main` deploys production through Cloudflare Workers Builds.

## Gate

Run before every commit.

## Conflict stops

Dates, names and quantities in content pages.

## Branch names

`fix-login-timeout`, `add-export-button`
```

- **Deploy:** what a push of the trunk does: deploys production, only runs CI, or nothing. Claude repeats it after landing a branch, so you know what pushing will do.
- **Gate:** when to run the gate before a commit: always, or only for changes under certain paths.
- **Conflict stops:** the kinds of change where Claude must not pick a side in a merge conflict. It shows both versions and asks instead.
- **Branch names:** two or three example branch names, showing the style this repo uses.

The other slices need no sections.

## Opt out of a kit item

To keep this repo different from the kit, add the item to `exclude` in `.claude/kit.json` and run `kit render`:

- a file, by its path: `".claude/rules/kit/collaboration.md"`
- a permission: `"allow:Bash(ls *)"`
- a setting: `"set:autoMemoryEnabled"`

To replace an excluded file, put your own at the same path. A slice's forbidden entries, such as `Bash(git *)`, cannot be excluded.

## Troubleshooting

Messages you may see, and what to do:

- **`The following paths are ignored by one of your .gitignore files`** from `git submodule add`, or **`bump: cannot stage the gitlink`**: a `vendor/` line in `.gitignore` also matches `.claude/vendor/kit`. Change it to `/vendor/`, run the command again, and add `.gitignore` to the commit.
- **`REFUSE <path>: exists and is not rendered by the kit`**: the repo already has its own file where the kit renders one, and render wrote nothing. For each path, either rename your file, keep it by adding the path to `exclude`, or replace it with the kit's by running `kit render --discard`. Then render again.
- **`REFUSE <path>: edited in place`**: a file the kit rendered was edited in this repo. `kit edit <path>` shows where the change belongs in the kit; `kit render --discard` throws it away.
- **`FORBID <entry>`**: `.claude/settings.json` allows a broad command that a slice forbids, such as `Bash(git *)`. Replace it with the specific commands the repo needs.
- **`BREADTH <entry>`**: an allow entry has a `*` before a literal word. Rewrite it with the `*` at the end.
- **`MEMORY CLAUDE.md does not import ...`**: add the line from step 4 of [Add the kit](#add-the-kit-to-a-repo).
- **`REPO repo.md lacks ## <heading>`** or **`is empty`**: add that section to `.claude/rules/repo.md`, or write a line in it.
- **`LINK <file> -> <target>`**: a relative link in `CLAUDE.md` or under `.claude/` points at nothing. Fix or remove it.
- **`NOT PRESENT`**, or **`.claude/vendor/kit/bin/kit: No such file or directory`**: the kit's files are missing in this clone. Run `git submodule update --init .claude/vendor/kit`.
- **`push.recurseSubmodules is not "check"`**: run `bash .claude/vendor/kit/bin/kit init`.

## Changing the kit itself

Changes to the kit are made in a clone of this repo, never in `.claude/vendor/kit`. [CLAUDE.md](CLAUDE.md) covers how. In a repo that uses the kit, the `/kit` skill walks Claude through it.
