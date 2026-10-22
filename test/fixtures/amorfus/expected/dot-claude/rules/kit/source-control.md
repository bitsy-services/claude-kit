<!-- kit: rendered from slices/core/rules/source-control.md — edit the source in the kit, never this copy -->
# Source control

Never write or change anything under `~/.claude` except the plan files plan mode writes in `~/.claude/plans/`: not settings, memory or skills. It is outside source control, so a change there cannot be reviewed or reverted and silently follows the user into every repo. The user treats this as absolute.

- Persistent changes go in this repo: permissions and hooks in `.claude/settings.json`, memory under `.claude/memory/`, skills in `.claude/skills/`, rules in `.claude/rules/`.
- Never offer to make a change globally. When a problem really is global, propose a kit change instead (the `kit` skill shows how).
- Reading `~/.claude` is fine.
- The `guard-write.sh` hook denies Edit, Write and NotebookEdit under `~/.claude`, except plan files in `~/.claude/plans/`. It cannot see Bash, but the rule covers Bash writes too.
