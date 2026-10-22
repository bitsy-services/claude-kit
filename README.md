# claude-kit
Shared Claude Code config, vendored as a git submodule and rendered into each repo's .claude/, with a drift check.

Requires bash 4.4 or later, git and jq, on Linux or WSL. Native Windows is not supported.

Run each command below on its own, from the root of the repo that uses the kit. Changing the kit itself is covered in [CLAUDE.md](CLAUDE.md).

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

## New machine

Clone with the submodule, then run `kit init` in the clone, since `push.recurseSubmodules` is per-clone configuration:

```sh
git clone --recurse-submodules <repo-url>
bash .claude/vendor/kit/bin/kit init
```

A clone made without `--recurse-submodules` needs `git submodule update --init .claude/vendor/kit` first. The kit's SessionStart status line prints that command when the checkout is absent.

## Cloud session

Put this in the environment's setup script:

```sh
git submodule update --init .claude/vendor/kit
```

It is best-effort. The rendered files are committed, so a session without the checkout still loads every rule, skill and hook. Only the `kit` commands need the checkout, the session-branch guard refuses a push until it is present, and the SessionStart status line says when it is absent.
