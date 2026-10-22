# Permissions

Allow-list the exact safe commands, one entry per verb. Never pair a broad entry such as `Bash(git *)` with deny rules: every variant the deny list misses then runs unasked, and a prompt costs less than an unintended destructive command.

How a Bash rule matches, per the Claude Code docs:
- `*` matches any text, spaces included, and may stand anywhere. Everything before the first `*` is what limits the rule: `Bash(git log *)` allows only `git log` commands, while `Bash(git * main)` allows any git subcommand ending in `main`. So put the `*` last; `kit check` reports an allow entry with a `*` before a literal word as `BREADTH`.
- A trailing ` *` also matches the bare command when it is the rule's only wildcard: `Bash(ls *)` matches `ls` and `ls -la`.
- The space before a trailing `*` is a word boundary: `Bash(ls *)` does not match `lsof`; `Bash(ls*)` does.
- `Bash(ls:*)` is the same rule as `Bash(ls *)`. The `:*` form works only at the end.

Practice:
- Keep bare `Edit` and `Write` in the allow list. If edits outside `.claude/` prompt, check that bare `Edit` and `Write` are in the allow list in effect and that the path is inside the working directories; meanwhile Shift+Tab to accept-edits unblocks the session. Writes under `.claude/` prompt whatever the allow list says, because Claude Code protects that directory.
- When a prompt recurs, propose the exact entry that covers it, for `.claude/settings.json`. Never broaden an entry to cover a compound statement; split the command instead.
- The kit forbids some broad entries, such as `Bash(gh *)` and `Bash(npm run *)`. `kit check` fails while one is in `permissions.allow` and names the harm; allow the narrow verbs instead.
