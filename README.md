# claude-kit
Shared Claude Code config, vendored as a git submodule and rendered into each repo's .claude/, with a drift check.

Requires bash 4.4 or later, git and jq, on Linux or WSL. Native Windows is not supported.

## Which section to follow

Each section below is a complete procedure for one situation. Find yours and follow that section alone, top to bottom:

- [New repo](#new-repo): a repo you are starting now, with no `CLAUDE.md` or `.claude/` of its own yet.
- [Existing repo](#existing-repo): a repo you already have a clone of, with its own history and perhaps its own `CLAUDE.md`, settings or skills, that does not use the kit yet.
- [New machine](#new-machine): a repo that already uses the kit, on a machine with no clone of it.
- [Update the kit](#update-the-kit): a repo that already uses the kit, moving to a newer kit version.
- [Cloud session](#cloud-session): the setup script of a cloud environment for a repo that already uses the kit.

Run each command on its own, from the root of that repo's clone. None of them runs in a clone of the kit itself. Changing the kit is covered in [CLAUDE.md](CLAUDE.md).

## New repo

1. Make sure git does not ignore the mount point:

   ```sh
   git check-ignore -v .claude/vendor/kit
   ```

   It prints nothing when the path is not ignored. If it names an unanchored `vendor/` line in `.gitignore`, anchor that line as `/vendor/`. Otherwise git refuses to add the submodule, and `kit bump` later stops with `bump: cannot stage the gitlink`.
2. Vendor the kit:

   ```sh
   git submodule add https://github.com/bitsy-services/claude-kit .claude/vendor/kit
   ```

3. `bash .claude/vendor/kit/bin/kit init` fetches the pinned checkout and sets `push.recurseSubmodules` to `check`, so a push stops while the pinned kit commit is unpublished.
4. `bash .claude/vendor/kit/bin/kit scaffold` creates `.claude/kit.json`, `.claude/rules/repo.md` and the memory index where they are absent.
5. Fill in `.claude/kit.json`: the slices (`core` is mandatory) and their params, `gate` being the repo's own check command. Then fill in `.claude/rules/repo.md`, one `## <heading>` section with prose for each heading the chosen slices declare.
6. Add `.claude/** text eol=lf` to `.gitattributes`.
7. `bash .claude/vendor/kit/bin/kit render` writes the rendered files, `.claude/settings.json` and `.claude/kit.lock.json`.
8. `bash .claude/vendor/kit/bin/kit check` must end `kit check: ok`. Each failure line names its fix, such as the `@.claude/memory/MEMORY.md` import that `CLAUDE.md` needs.
9. Commit:

   ```sh
   git add .gitmodules .gitattributes .claude CLAUDE.md
   git commit -m "Adopt claude-kit"
   ```

   Add `.gitignore` to the first command if step 1 changed it.

## Existing repo

Work in the clone you already have. Nothing here clones the repo again.

1. Start with a clean `git status`, so the commit at the end holds only the kit's changes.
2. Make sure git does not ignore the mount point:

   ```sh
   git check-ignore -v .claude/vendor/kit
   ```

   It prints nothing when the path is not ignored. If it names an unanchored `vendor/` line in `.gitignore`, anchor that line as `/vendor/`. Otherwise git refuses to add the submodule.
3. Vendor the kit:

   ```sh
   git submodule add https://github.com/bitsy-services/claude-kit .claude/vendor/kit
   ```

4. `bash .claude/vendor/kit/bin/kit init` fetches the pinned checkout and sets `push.recurseSubmodules` to `check`.
5. `bash .claude/vendor/kit/bin/kit scaffold` creates `.claude/kit.json`, `.claude/rules/repo.md` and the memory index where they are absent, and prints `kept <path>` for each one the repo already has.
6. Fill in `.claude/kit.json`: the slices (`core` is mandatory) and their params, `gate` being the repo's own check command. Then fill in `.claude/rules/repo.md`, one `## <heading>` section with prose for each heading the chosen slices declare.
7. Add the line `@.claude/memory/MEMORY.md` to `CLAUDE.md`, creating the file if the repo has none. If `.claude/kit.json` sets `memory_root`, import `MEMORY.md` from there instead.
8. Add `.claude/** text eol=lf` to `.gitattributes`.
9. `bash .claude/vendor/kit/bin/kit render` writes the rendered files, `.claude/settings.json` and `.claude/kit.lock.json`. The repo's own entries in `.claude/settings.json` stay, with the kit's added beside them. If the repo already has a skill under a name the kit renders, render stops with `REFUSE <path>: exists and is not rendered by the kit` and writes nothing. For each such path, rename the repo's skill, keep it by adding the path to `exclude` in `.claude/kit.json`, or replace it with the kit's using `kit render --discard`. Then render again.
10. `bash .claude/vendor/kit/bin/kit check` must end `kit check: ok`. Each failure line names its fix. The ones an existing setup tends to hit:
    - `FORBID`: an allow entry in `.claude/settings.json` is one a slice forbids, such as `Bash(git *)` or `Bash(npm *)`. Remove it, or narrow it to the commands the repo needs.
    - `BREADTH`: an allow entry has a wildcard that starts an argument. Narrow it.
    - `LINK`: a relative link in `CLAUDE.md` or a Markdown file under `.claude/` points at nothing.
11. Commit:

    ```sh
    git add .gitmodules .gitattributes .claude CLAUDE.md
    git commit -m "Adopt claude-kit"
    ```

    Add `.gitignore` to the first command if step 2 changed it.
12. Every other clone of the repo, after it pulls this commit, runs `git submodule update --init .claude/vendor/kit` and then `bash .claude/vendor/kit/bin/kit init`.

## New machine

Clone with the submodule, then run `kit init` in the clone, since `push.recurseSubmodules` is per-clone configuration:

```sh
git clone --recurse-submodules <repo-url>
cd <repo>
bash .claude/vendor/kit/bin/kit init
```

A clone made without `--recurse-submodules` needs `git submodule update --init .claude/vendor/kit` first. The kit's SessionStart status line prints that command when the checkout is absent.

## Update the kit

1. `bash .claude/vendor/kit/bin/kit bump` fetches the kit, moves the pin to the kit's latest `main`, renders with the new version and prints the CHANGELOG lines added since the old pin. To move to a particular published commit instead, pass it: `kit bump <commit>`. Bump stages the new pin and never commits.
2. Read the CHANGELOG lines it printed. A line that starts `BREAKING:` gives an edit to `.claude/kit.json` or `.claude/rules/repo.md` that the new version needs. Make each one, then run `bash .claude/vendor/kit/bin/kit render`.

   If the render inside the bump failed, the bump printed the lines anyway and restored the old pin. Make the edits they give and run the bump again. A `REFUSE <path>: edited in place` line means a rendered file was changed in this repo. That change belongs in the kit, and `kit edit <path>` says where it comes from. `kit render --discard` throws the local change away.
3. `bash .claude/vendor/kit/bin/kit check` must end `kit check: ok`.
4. Commit:

   ```sh
   git add .claude
   git commit -m "Bump claude-kit"
   ```

5. Every other clone of the repo, after it pulls this commit, runs `git submodule update --init .claude/vendor/kit` to move its checkout to the new pin.

## Cloud session

Put this in the environment's setup script:

```sh
git submodule update --init .claude/vendor/kit
```

It is best-effort. The rendered files are committed, so a session without the checkout still loads every rule, skill and hook. Only the `kit` commands need the checkout, the session-branch guard refuses a push until it is present, and the SessionStart status line says when it is absent.
